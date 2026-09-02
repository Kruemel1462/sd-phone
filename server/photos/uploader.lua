---@type table sd-phone config root (configs/config.lua) - config.ApiKeys holds the media token.
local config = require 'configs.config'

---@type table Qbox CDN provider (server.photos.qbox): the multipart route through the Node helper.
local qbox = require 'server.photos.qbox'

---@type table Uploader module; the table returned at end of file.
local uploader = {}

---@type table Photos config (configs/photos.lua): which CDN the uploads go to.
local PHOTOS = type(config.Photos) == 'table' and config.Photos or {}

-- Response shape: { data = { id, url }, status = "ok" }.
---@type string Fivemanage media upload endpoint (v3 base64 route).
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

---Which CDN this server uploads to. Anything other than 'qbox' stays on Fivemanage, so a typo
---never silently sends media somewhere the owner did not choose.
---@return 'fivemanage'|'qbox'
function uploader.provider()
    return tostring(PHOTOS.Provider or 'fivemanage'):lower() == 'qbox' and 'qbox' or 'fivemanage'
end

---True when the active provider has a token set. Read at boot so a server missing its key is
---told once at startup, instead of every player discovering it as a capture that never lands.
---@return boolean
function uploader.configured()
    if uploader.provider() == 'qbox' then return qbox.configured() end
    return mediaKey() ~= ''
end

---Uploads a base64 data-URL to Fivemanage and hands back the hosted CDN URL. Asynchronous:
---calls `cb(url|nil, err, code)` exactly once. `err` is the human sentence the recording and
---bodycam UIs already surface; `code` is a stable token the phone maps to a translated line, so
---a caller can localise the reason without matching on English prose.
---@param base64Image string media as a base64 data-URL (data:image/...;base64,...)
---@param filename string suggested filename stored alongside the upload
---@param cb fun(url: string|nil, err: string|nil, code: 'no-key'|'bad-data'|'provider'|nil)
local function uploadFivemanage(base64Image, filename, cb)
    local key = mediaKey()

    if key == '' then
        print('^1[sd-phone:photos]^0 [UPLOAD] aborting: no Fivemanage media key. Set FivemanageMedia in configs/server/apikeys.lua, or the sd_fivemanage_key convar.')
        cb(nil, 'No Fivemanage media key configured on this server', 'no-key')
        return
    end

    if type(base64Image) ~= 'string' or base64Image == '' then
        print('^1[sd-phone:photos]^0 [UPLOAD] aborting: empty media payload')
        cb(nil, 'Empty media payload', 'bad-data')
        return
    end

    local body = json.encode({
        base64   = base64Image,
        filename = filename or ('sdphone-%d.jpg'):format(os.time()),
    })

    local timeout = base64Image:sub(1, 11) == 'data:video/' and VIDEO_TIMEOUT_MS or TIMEOUT_MS

    print(('^3[sd-phone:photos]^0 [UPLOAD] -> %s (%d Bytes, Frist %d ms)')
        :format(UPLOAD_URL, #body, timeout))

        -- Each branch reports the same 'provider' code to the player, who can act on none of
        -- them, while the console line names the one that actually happened.
        if status ~= 200 and status ~= 201 then
            print(('^1[sd-phone:photos]^0 [UPLOAD] Fivemanage rejected the upload: HTTP %s %s')
                :format(tostring(status), tostring(responseBody)))
            cb(nil, ('Fivemanage upload failed: HTTP %s'):format(tostring(status)), 'provider')
            return
        end

        if not responseBody or responseBody == '' then
            print('^1[sd-phone:photos]^0 [UPLOAD] Fivemanage returned an empty response body')
            cb(nil, 'Empty response from Fivemanage', 'provider')
            return
        end

        local okJson, decoded = pcall(json.decode, responseBody)
        if not okJson or type(decoded) ~= 'table' then
            print(('^1[sd-phone:photos]^0 [UPLOAD] unparseable Fivemanage response: %s')
                :format(tostring(responseBody)))
            cb(nil, 'Could not parse the Fivemanage response', 'provider')
            return
        end

        local url = type(decoded.data) == 'table' and decoded.data.url or nil
        if type(url) ~= 'string' or url == '' then
            print(('^1[sd-phone:photos]^0 [UPLOAD] Fivemanage returned no URL: %s'):format(tostring(responseBody)))
            cb(nil, 'Fivemanage returned no URL', 'provider')
            return
        end

    run()
end

---Uploads a base64 data-URL to whichever CDN this server is set to and hands back the hosted URL.
---Asynchronous: calls `cb(url|nil, err, code)` exactly once.
---@param base64Image string media as a base64 data-URL (data:image/...;base64,...)
---@param filename string suggested filename stored alongside the upload
---@param cb fun(url: string|nil, err: string|nil, code: 'no-key'|'bad-data'|'provider'|nil)
function uploader.uploadMedia(base64Image, filename, cb)
    if uploader.provider() == 'qbox' then
        qbox.uploadMedia(base64Image, filename, cb)
        return
    end
    uploadFivemanage(base64Image, filename, cb)
end

return uploader
