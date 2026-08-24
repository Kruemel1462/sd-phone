---@type table sd-phone config root (configs/config.lua) - config.ApiKeys holds the media token.
local config = require 'configs.config'

---@type table Uploader module; the table returned at end of file.
local uploader = {}

-- Eigener Medienspeicher auf dem VPS (_tools/genesis-cdn). Antwortet bewusst in derselben Form
-- wie Fivemanage: { data = { id, url }, status = "ok" }, deshalb bleibt der Rest der Datei
-- unveraendert. Das Token dazu steht in configs/server/apikeys.lua.
---@type string Upload-Endpunkt.
local UPLOAD_URL = 'https://cdn.metrocityrp.eu/upload'

-- Media key: configs/server/apikeys.lua (FivemanageMedia), else the legacy convar below.
---@type string Legacy convar name still honoured when the config key is blank.
local CONVAR_KEY = 'sd_fivemanage_key'

-- PerformHttpRequest gibt KEINE Zusage, seinen Callback jemals aufzurufen. Bleibt eine Anfrage
-- haengen - haeufigste Ursache: eine gepoolte Verbindung, die die Gegenstelle laengst geschlossen
-- hat -, dann wartet der Aufrufer ewig. Fuer die Warteschlange in server/photos/init.lua waere das
-- toedlich: sie steht in Citizen.Await, `draining` bleibt gesetzt, und jede weitere Aufnahme des
-- Spielers reiht sich ein, ohne je abgearbeitet zu werden. Ein einziger stummer Request wuerde
-- damit alle Uploads dieses Spielers bis zum Serverneustart stilllegen.
--
-- Deshalb bekommt jede Anfrage hier eine Frist. Laeuft sie ab, wird der Callback mit einem Fehler
-- bedient - die Warteschlange laeuft weiter, der Spieler sieht eine Meldung statt eines
-- Standbilds. Das ist eine Absicherung gegen einen Ausfall des Medienspeichers, nicht der Fix fuer
-- die abbrechenden Kamera-Uploads: die lagen an der Uebertragung Client -> Server und sind in
-- client/apps/camera.lua behoben.
--
-- 15 s, zusammen mit dem einen Wiederholungsversuch also hoechstens 30 s. Genau so lange haelt die
-- Kamera in web/src/apps/camera/Camera.tsx ihren Ausloeser gesperrt (CAPTURE_TIMEOUT_MS): der
-- Spieler bekommt damit im schlechtesten Fall eine Fehlermeldung statt eines Ausloesers, der sich
-- schon wieder gedrueckt haben laesst, waehrend hier noch etwas laeuft. Ein Foto sind rund 150 KB
-- und normalerweise unter einer Sekunde durch; 15 s sind reichlich Luft, keine knappe Frist.
---@type integer Frist fuer Bilder/Audio (ms).
local TIMEOUT_MS <const> = 15000
---@type integer Frist fuer Videos (ms). Bis zu 32 MB wollen erst einmal auf die Leitung.
local VIDEO_TIMEOUT_MS <const> = 120000

-- Ein abgelaufener Versuch wird EINMAL wiederholt. Genau dafuer ist die haeufigste Ursache
-- anfaellig: der zweite Versuch faellt nicht mehr auf dieselbe tote Verbindung, sondern baut eine
-- neue auf und geht durch. Ohne den Wiederholungsversuch waere jedes zweite Foto ein Fehlschlag
-- statt einer kurzen Verzoegerung.
---@type integer Zusaetzliche Versuche nach einer abgelaufenen Frist.
local RETRIES <const> = 1

---Returns the Fivemanage Media token: configs/server/apikeys.lua first, else the legacy
---convar; read fresh on every upload.
---@return string key the media token, or '' when unconfigured
local function mediaKey()
    local k = (config.ApiKeys or {}).FivemanageMedia
    if type(k) == 'string' and k ~= '' then return k end
    return GetConvar(CONVAR_KEY, '')
end

---Setzt EINEN Versuch ab und meldet ueber `done` genau einmal - entweder aus dem HTTP-Callback
---oder aus der Frist, je nachdem was zuerst eintritt.
---@param body string fertiger JSON-Rumpf
---@param key string Medien-Token
---@param timeout integer Frist in Millisekunden
---@param attempt integer laufende Nummer, nur fuer die Logzeile
---@param done fun(url: string|nil, err: string|nil, timedOut: boolean)
local function attemptUpload(body, key, timeout, attempt, done)
    ---@type boolean Verhindert, dass Frist und Callback beide melden.
    local settled = false

    ---@param url string|nil
    ---@param err string|nil
    ---@param timedOut boolean
    local function settle(url, err, timedOut)
        if settled then return end
        settled = true
        done(url, err, timedOut)
    end

    SetTimeout(timeout, function()
        if settled then return end
        print(('^1[sd-phone:photos]^0 [UPLOAD] Versuch %d ohne Antwort nach %d ms - %s')
            :format(attempt, timeout, UPLOAD_URL))
        settle(nil, ('Medienspeicher antwortet nicht (%d ms)'):format(timeout), true)
    end)

    PerformHttpRequest(UPLOAD_URL, function(status, responseBody, _headers)
        if status ~= 200 and status ~= 201 then
            settle(nil, ('Medien-Upload fehlgeschlagen: HTTP %s'):format(tostring(status)), false)
            return
        end

        if not responseBody or responseBody == '' then
            settle(nil, 'Leere Antwort vom Medienspeicher', false)
            return
        end

        local okJson, decoded = pcall(json.decode, responseBody)
        if not okJson or type(decoded) ~= 'table' then
            settle(nil, 'Antwort des Medienspeichers nicht lesbar', false)
            return
        end

        local url = type(decoded.data) == 'table' and decoded.data.url or nil
        if type(url) ~= 'string' or url == '' then
            settle(nil, 'Medienspeicher lieferte keine URL', false)
            return
        end

        settle(url, nil, false)
    end, 'POST', body, {
        ['Content-Type']  = 'application/json',
        ['Authorization'] = key,
        -- Keine Verbindung wiederverwenden. Das ist die Gegenseite derselben Muenze wie der
        -- Watchdog oben: eine gepoolte Verbindung, die die Gegenstelle nach ihrem Keep-Alive-
        -- Fenster geschlossen hat, verschluckt den naechsten Request lautlos. Jeder Upload holt
        -- sich lieber eine frische Verbindung - bei ein paar Fotos pro Minute kostet das nichts.
        ['Connection']    = 'close',
    })
end

---Uploads a base64 data-URL to the media store and hands back the hosted CDN URL. Asynchronous:
---calls `cb(url|nil, err)` exactly once. Eine haengende Anfrage laeuft nach einer Frist in einen
---Fehler statt ewig offen zu bleiben, und wird einmal wiederholt.
---@param base64Image string media as a base64 data-URL (data:image/...;base64,...)
---@param filename string suggested filename stored alongside the upload
---@param cb fun(url: string|nil, err: string|nil)
function uploader.uploadMedia(base64Image, filename, cb)
    local key = mediaKey()

    if key == '' then
        print('^1[sd-phone:photos]^0 aborting — no Fivemanage key configured')
        cb(nil, 'No Fivemanage key configured. Set FivemanageMedia in configs/server/apikeys.lua.')
        return
    end

    if type(base64Image) ~= 'string' or base64Image == '' then
        print('^1[sd-phone:photos]^0 aborting — empty image payload')
        cb(nil, 'Empty image payload')
        return
    end

    local body = json.encode({
        base64   = base64Image,
        filename = filename or ('sdphone-%d.jpg'):format(os.time()),
    })

    local timeout = base64Image:sub(1, 11) == 'data:video/' and VIDEO_TIMEOUT_MS or TIMEOUT_MS

    print(('^3[sd-phone:photos]^0 [UPLOAD] -> %s (%d Bytes, Frist %d ms)')
        :format(UPLOAD_URL, #body, timeout))

    ---@type integer Bisherige Versuche.
    local tries = 0

    local function run()
        tries = tries + 1
        attemptUpload(body, key, timeout, tries, function(url, err, timedOut)
            -- Nur eine abgelaufene Frist wird wiederholt. Ein HTTP 401 oder 413 kommt beim
            -- zweiten Mal genauso zurueck und waere nur verlorene Zeit.
            if timedOut and tries <= RETRIES then
                print(('^3[sd-phone:photos]^0 [UPLOAD] Wiederholung %d/%d'):format(tries, RETRIES))
                run()
                return
            end

            if url then
                print(('^2[sd-phone:photos]^0 [UPLOAD] ok (Versuch %d) -> %s'):format(tries, url))
            else
                print(('^1[sd-phone:photos]^0 [UPLOAD] endgueltig fehlgeschlagen: %s'):format(tostring(err)))
            end

            cb(url, err)
        end)
    end

    run()
end

return uploader
