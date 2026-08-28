---@type table Boot reporter (server.boot): one console summary instead of per-module prints.
local boot = require 'server.boot'

---@type table Photos persistence layer (server.photos.store): photo/album row CRUD.
local store    = require 'server.photos.store'
---@type table Authoritative photo/album handlers (server.photos.actions).
local actions  = require 'server.photos.actions'
---@type table Fivemanage uploader (server.photos.uploader): server-side base64 media upload.
local uploader = require 'server.photos.uploader'
---@type table Player bridge (bridge.server.player): citizenid for the shared upload budget.
local player   = require 'bridge.server.player'
---@type table Shared media-upload budget (server.photos.mediaLimit): cooldown + rolling byte cap.
local mediaLimit = require 'server.photos.mediaLimit'
---@type table Shared server helpers (server.util): finite-number guard for the export boundary.
local util     = require 'server.util'

---@type string Kennung des Foto-Moduls. Wird beim Start in die Konsole geschrieben, damit auf
---einen Blick erkennbar ist, WELCHER Stand auf dem Server laeuft.
---
---Hintergrund: die Fehlersuche an den Foto-Uploads ist mehrfach ins Leere gelaufen, weil
---Aenderungen zwar geschrieben, aber nicht auf den Server uebertragen waren - getestet wurde
---dann gegen alten Code, ohne dass es jemandem auffiel. Bei jeder weiteren Aenderung hier die
---Zahl hochzaehlen; erscheint sie nach dem Neustart nicht in der Konsole, ist der neue Stand
---nicht angekommen und alles Weitere eruebrigt sich.
local MODULE_REV <const> = 'photos-rev6 (Stueckuebertragung statt Latent Event)'

CreateThread(function()
    print(('^2[sd-phone:photos]^0 %s'):format(MODULE_REV))
end)

---Bootstraps the schema in a thread, pcall-guarded.
CreateThread(function()
    local ok, err = pcall(store.ensureSchema)
    if not ok then
        boot.schemaFailed('photos', err)
        return
    end
    boot.schemaReady()
end)

-- Authoritative gallery-read callback: thin delegate into server.photos.actions.
lib.callback.register('sd-phone:server:photos:list', function(src, payload)
    return actions.list(src, payload)
end)

-- Hard payload ceilings for the capture upload.
---@type integer Max accepted photo data-URL size in bytes (~4 MB).
local MAX_PHOTO_BYTES <const> = 4  * 1024 * 1024
---@type integer Max accepted video data-URL size in bytes (~32 MB).
local MAX_VIDEO_BYTES <const> = 32 * 1024 * 1024

---Weist einen Upload ab: Zeile in die Serverkonsole UND eine Meldung ans Handy.
---
---Ohne den zweiten Teil bricht die Kamera stumm ab - der Spieler sieht nur, dass nichts
---passiert, und der Grund steht in einem Log, das er nie zu Gesicht bekommt. Genau daran ist
---die Fehlersuche bei den Foto-Uploads mehrfach gescheitert.
---@param src number
---@param logLine string Text fuer die Serverkonsole
---@param playerMsg string Text fuer den Spieler
local function denyUpload(src, logLine, playerMsg)
    print(('^1[sd-phone:photos]^0 [UPLOAD] src=%s abgewiesen - %s'):format(tostring(src), logLine))
    TriggerClientEvent('sd-phone:client:photos:uploadFailed', src, playerMsg)
end

---@type integer Wie viele Aufnahmen ein Spieler gleichzeitig anstehen haben darf. Darueber
---hinaus wird abgewiesen - ohne Deckel koennte ein veraenderter Client unbegrenzt Arbeit
---anhaeufen. Sechs deckt jedes normale Draufloshalten ab.
local MAX_QUEUE <const> = 6

---@type table<number, { jobs: table[], draining: boolean }> Warteschlange je Spieler.
---
---Hier stand vorher ein einfaches "ein Upload gleichzeitig"-Flag, und alles was waehrend eines
---laufenden Uploads eintraf, wurde verworfen. Da die Uebertragung zum Server mehrere Sekunden
---dauert, traf das zuverlaessig das zweite Foto: der Ausloeser war laengst wieder frei, der
---Server aber noch beschaeftigt. Jetzt wird angenommen und der Reihe nach abgearbeitet.
local queues = {}

---Arbeitet die Warteschlange eines Spielers ab, eine Aufnahme nach der anderen. Laeuft immer nur
---einmal je Spieler; ein zweiter Aufruf kehrt sofort zurueck und ueberlaesst der laufenden
---Schleife die neu angehaengten Eintraege.
---@param src number
local function drainQueue(src)
    local q = queues[src]
    if not q or q.draining then return end

    q.draining = true

    CreateThread(function()
        while true do
            local job = table.remove(q.jobs, 1)
            if not job then break end

            print(('^3[sd-phone:photos]^0 [QUEUE] src=%s arbeite %s ab (%d warten noch)')
                :format(tostring(src), job.filename, #q.jobs))

            -- Der Uploader arbeitet mit Callback. Ueber ein Promise wird daraus ein Warten,
            -- damit die Schleife wirklich seriell bleibt und nicht alles gleichzeitig anstoesst.
            local p = promise.new()
            uploader.uploadMedia(job.image, job.filename, function(url, err)
                p:resolve({ url = url, err = err })
            end)

            local res = Citizen.Await(p)

            if not res.url then
                denyUpload(src, ('Upload fehlgeschlagen: %s'):format(tostring(res.err)), 'Upload fehlgeschlagen - Server nicht erreichbar?')
            else
                local saveRes = actions.saveFromUrl(src, res.url)

                if saveRes and saveRes.success and saveRes.data and saveRes.data.photo then
                    TriggerClientEvent('sd-phone:client:photos:added', src, saveRes.data.photo)
                else
                    denyUpload(src, ('Speichern fehlgeschlagen: %s'):format(tostring(saveRes and saveRes.message or 'unbekannt')), 'Foto konnte nicht gespeichert werden.')
                end
            end
        end

        q.draining = false

        -- Nur aufraeumen, wenn zwischenzeitlich nichts Neues dazugekommen ist.
        if #q.jobs == 0 then queues[src] = nil end
    end)
end

---Nimmt eine fertig zusammengesetzte Aufnahme an: prueft Form und Groesse, haengt sie an die
---Warteschlange des Spielers und stoesst deren Abarbeitung an. Hochgeladen und gespeichert wird
---in drainQueue, eine Aufnahme nach der anderen.
---@param src number player server id
---@param image string base64 data-URL (data:image/... or data:video/...)
---@param kind string 'video' for clips; anything else is treated as a photo
local function enqueueUpload(src, image, kind)
    local isVideo = kind == 'video'

    -- Erste Zeile im Ablauf, VOR jeder Pruefung: erscheint sie nicht, ist die Aufnahme gar nicht
    -- erst beim Server angekommen und die Ursache liegt auf der Uebertragung, nicht hier. Ohne
    -- diesen Punkt liess sich ein stiller Ausfall nicht von einer stillen Abweisung unterscheiden.
    print(('^3[sd-phone:photos]^0 [EINGANG] src=%s kind=%s bytes=%s')
        :format(tostring(src), tostring(kind), type(image) == 'string' and #image or 'n/a'))

    local prefix  = isVideo and 'data:video/' or 'data:image/'
    if type(image) ~= 'string' or image:sub(1, #prefix) ~= prefix then
        denyUpload(src, ('kein %s-Datenformat'):format(isVideo and 'Video' or 'Bild'), 'Aufnahme konnte nicht gelesen werden.')
        return
    end
    if #image > (isVideo and MAX_VIDEO_BYTES or MAX_PHOTO_BYTES) then
        denyUpload(src, ('zu gross (%d Bytes)'):format(#image), 'Aufnahme ist zu gross.')
        return
    end
    local q = queues[src]
    if not q then
        q = { jobs = {}, draining = false }
        queues[src] = q
    end

    if #q.jobs >= MAX_QUEUE then
        denyUpload(src, ('Warteschlange voll (%d)'):format(#q.jobs), 'Zu viele Aufnahmen auf einmal - kurz warten.')
        return
    end

    -- Mindestabstand uebersprungen: die Warteschlange serialisiert bereits, ein zweiter Riegel
    -- wuerde nur verwerfen, was sie gerade auffangen soll. Das Byte-Budget greift weiterhin.
    local okLimit, why = mediaLimit.check(player.getIdentifier(src), #image, true)
    if not okLimit then
        denyUpload(src, ('Ratenlimit (%s)'):format(tostring(why)), 'Zu schnell - einen Moment warten.')
        return
    end

    local ext = 'jpg'
    if isVideo then
        ext = image:find('^data:video/mp4') and 'mp4' or 'webm'
    end

    q.jobs[#q.jobs + 1] = {
        image    = image,
        filename = ('sdphone-%d-%d-%d.%s'):format(src, os.time(), #q.jobs + 1, ext),
    }

    drainQueue(src)
end

-- Wiederzusammensetzung der Aufnahme.
--
-- Der Client schickt sie in Stuecken ueber gewoehnliche Events (client/apps/camera.lua). Vorher
-- kam sie ueber ein Latent Event, und das blieb nach der ersten Uebertragung stumm: das zweite
-- Foto erreichte den Server nie, im Log fehlte selbst die Eingangszeile. Gewoehnliche Events
-- zeigen dieses Verhalten nicht, dafuer eine Groessengrenze - daher die Stuecke.
---@type integer Groesstes zulaessiges Stueck. Der Client schickt 8 KB (siehe CHUNK_BYTES in
---client/apps/camera.lua - dort auch, warum es nicht mehr sein darf); die Reserve faengt
---Rundungen ab, ohne ein Scheunentor zu sein.
local MAX_CHUNK_BYTES <const> = 32 * 1024
---@type integer Meiste Stuecke je Uebertragung. 64 MB Video bei 8 KB sind 8192 - der Deckel
---liegt darueber, die eigentliche Grenze ist der Byte-Zaehler unten. War 4096 bei 16 KB
---Stuecken (also derselbe 64-MB-Rahmen); verdoppelt, als CHUNK_BYTES halbiert wurde.
local MAX_CHUNKS <const> = 8192
---@type integer Nach so langer Stille gilt eine Uebertragung als abgebrochen (ms). Ein Spieler,
---dessen Verbindung mitten in einer Aufnahme wegbricht, haelt den Speicher damit nicht dauerhaft.
local TRANSFER_IDLE_MS <const> = 30000

---@type table<number, { seq: number, kind: string, total: number, got: number, bytes: number, parts: string[], last: number }>
---Angefangene Uebertragungen je Spieler. Immer nur eine: eine neue laufende Nummer verwirft die
---vorige, statt zwei Aufnahmen ineinanderlaufen zu lassen.
local transfers = {}

---Nimmt ein Stueck entgegen und setzt die Aufnahme zusammen. Das letzte Stueck uebergibt an
---enqueueUpload; von dort ab ist der Weg derselbe wie zuvor.
---@param payload table { seq: number, index: number, total: number, kind: string, data: string }
RegisterNetEvent('sd-phone:server:photos:uploadChunk', function(payload)
    local src = source

    if type(payload) ~= 'table' then return end

    local seq   = tonumber(payload.seq)
    local index = tonumber(payload.index)
    local total = tonumber(payload.total)
    local data  = payload.data

    -- Stillschweigend verworfen statt beantwortet: was hier nicht durchkommt, stammt nicht aus
    -- der Kamera, und ein veraenderter Client soll aus Fehlermeldungen nichts lernen.
    if not seq or not index or not total or type(data) ~= 'string' then return end
    if index % 1 ~= 0 or total % 1 ~= 0 or total < 1 or total > MAX_CHUNKS then return end
    if index < 1 or index > total then return end
    if #data == 0 or #data > MAX_CHUNK_BYTES then return end

    local t = transfers[src]

    if not t or t.seq ~= seq then
        -- Nur ein erstes Stueck darf eine Uebertragung eroeffnen. Sonst koennte ein verspaetetes
        -- Stueck einer abgebrochenen Aufnahme eine neue anfangen, die nie vollstaendig wird.
        if index ~= 1 then return end

        t = {
            seq   = seq,
            kind  = payload.kind == 'video' and 'video' or 'photo',
            total = total,
            got   = 0,
            bytes = 0,
            parts = {},
            last  = GetGameTimer(),
        }
        transfers[src] = t

        print(('^3[sd-phone:photos]^0 [STUECKE] src=%s Nr=%s beginnt (%d Stueck, %s)')
            :format(tostring(src), tostring(seq), total, t.kind))
    end

    if total ~= t.total then return end
    -- Ein doppelt eingetroffenes Stueck zaehlt nicht zweimal, sonst gilt die Uebertragung als
    -- vollstaendig, waehrend eine Luecke offen ist.
    if t.parts[index] then return end

    local cap = t.kind == 'video' and MAX_VIDEO_BYTES or MAX_PHOTO_BYTES
    if t.bytes + #data > cap then
        transfers[src] = nil
        denyUpload(src, ('zu gross (ueber %d Bytes)'):format(cap), 'Aufnahme ist zu gross.')
        return
    end

    t.parts[index] = data
    t.got   = t.got + 1
    t.bytes = t.bytes + #data
    t.last  = GetGameTimer()

    if t.got < t.total then return end

    transfers[src] = nil
    enqueueUpload(src, table.concat(t.parts), t.kind)
end)

-- Angefangene Uebertragungen, an denen nichts mehr passiert, wieder freigeben. Ohne das haelt
-- eine abgerissene Aufnahme ihre Stuecke bis zum naechsten Serverneustart im Speicher.
CreateThread(function()
    while true do
        Wait(TRANSFER_IDLE_MS)
        local now = GetGameTimer()
        for src, t in pairs(transfers) do
            if now - t.last >= TRANSFER_IDLE_MS then
                print(('^1[sd-phone:photos]^0 [STUECKE] src=%s abgebrochen (%d von %d)')
                    :format(tostring(src), t.got, t.total))
                transfers[src] = nil
                TriggerClientEvent('sd-phone:client:photos:uploadFailed', src, 'Uebertragung abgebrochen.')
            end
        end
    end
end)

---Clears a departing player's in-flight upload flag so a disconnect mid-upload can't leave them
---permanently unable to upload after reconnecting on the same source id.
AddEventHandler('playerDropped', function()
    queues[source] = nil
    transfers[source] = nil
end)

---Saves an already-hosted media URL for the caller and pushes photos:added with the new row.
---Player-supplied, so the URL must pass config.Photos.AllowImport + the block/allow lists.
lib.callback.register('sd-phone:server:photos:saveUrl', function(src, payload)
    if not actions.importEnabled() then
        return { success = false, message = 'URL import is disabled on this server' }
    end
    if not actions.isAllowedImportUrl(payload and payload.url) then
        return { success = false, message = 'Images from that site aren\'t allowed' }
    end
    -- Same budget the capture upload uses: saving a hosted URL is a deliberate tap, so the 1s
    -- gap is invisible, and without it this path writes and prunes phone_photos at line rate.
    local okLimit = mediaLimit.check(player.getIdentifier(src), #(payload and payload.url or ''))
    if not okLimit then return { success = false, message = 'Slow down a moment' } end
    local res = actions.saveFromUrl(src, payload and payload.url)
    if res and res.success and res.data and res.data.photo then
        TriggerClientEvent('sd-phone:client:photos:added', src, res.data.photo)
    end
    return res
end)

-- Authoritative photo/album callbacks: thin delegates into server.photos.actions.
lib.callback.register('sd-phone:server:photos:setFavorite', function(src, payload)
    return actions.setFavorite(src, payload and payload.photoId or '', payload and payload.value)
end)

lib.callback.register('sd-phone:server:photos:delete', function(src, payload)
    return actions.delete(src, payload and payload.photoId or '')
end)

lib.callback.register('sd-phone:server:albums:list', function(src)
    return actions.listAlbums(src)
end)

lib.callback.register('sd-phone:server:albums:create', function(src, payload)
    return actions.createAlbum(src, payload and payload.name or '')
end)

lib.callback.register('sd-phone:server:albums:delete', function(src, payload)
    return actions.deleteAlbum(src, payload and payload.albumId or '')
end)

lib.callback.register('sd-phone:server:albums:addPhotos', function(src, payload)
    return actions.addPhotosToAlbum(src, payload and payload.albumId or '', payload and payload.photoIds or {})
end)

lib.callback.register('sd-phone:server:albums:removePhoto', function(src, payload)
    return actions.removePhotoFromAlbum(src, payload and payload.albumId or '', payload and payload.photoId or '')
end)

lib.callback.register('sd-phone:server:albums:photos', function(src, payload)
    return actions.listAlbumPhotos(src, payload and payload.albumId or '')
end)

---Public export: exports['sd-phone']:getPhotos(source, opts). Reads a player's gallery, newest
---first, for other resources: a vehicle-listing photo picker, an evidence board, a print shop.
---Read-only, and only ever the caller's own photos. Always an array, empty when nothing resolves.
---@param source number acting player's server id (the gallery owner resolves from it)
---@param opts { limit: number|nil, filter: 'favorites'|'videos'|nil }|nil
---@return { id: string, url: string, isVideo: boolean, favorite: boolean, timestamp: integer }[]
exports('getPhotos', function(source, opts)
    if type(source) ~= 'number' then return {} end
    local cid = player.getIdentifier(source)
    if not cid then return {} end
    return actions.listForCid(cid, opts)
end)

---Public export: exports['sd-phone']:getPhotosByIdentifier(citizenid, opts). The same read keyed
---by owner id rather than a live source, for offline owners and for callers holding a phone
---number: resolve it through getIdentifierByNumber first. Read-only.
---@param citizenid string owner's framework per-character id
---@param opts { limit: number|nil, filter: 'favorites'|'videos'|nil }|nil
---@return { id: string, url: string, isVideo: boolean, favorite: boolean, timestamp: integer }[]
exports('getPhotosByIdentifier', function(citizenid, opts)
    return actions.listForCid(citizenid, opts)
end)

---Public export: exports['sd-phone']:addPhoto(source, url). Saves an already-hosted http(s) URL
---into a player's gallery and pushes photos:added; a non-integer source returns { success = false }.
---@param source number acting player's server id (the gallery owner resolves from it)
---@param url string http(s) URL of the hosted media
---@return { success: boolean, photo?: table }
exports('addPhoto', function(source, url)
    if type(source) ~= 'number' or not util.finite(source) or source % 1 ~= 0 then
        return { success = false }
    end
    local res = actions.saveFromUrl(source, url)
    if res and res.success and res.data and res.data.photo then
        TriggerClientEvent('sd-phone:client:photos:added', source, res.data.photo)
        return { success = true, photo = res.data.photo }
    end
    return { success = false }
end)

---Public export: exports['sd-phone']:uploadMedia(dataUrl, filename, cb). Uploads a base64
---data-URL to Fivemanage and calls cb(url|nil, err|nil) exactly once; per-kind byte caps apply.
---@param dataUrl string media as a base64 data-URL (data:image/... or data:video/...)
---@param filename string|nil suggested filename stored alongside the upload
---@param cb fun(url: string|nil, err: string|nil)
---@return boolean accepted false when the callback or payload shape is unusable
exports('uploadMedia', function(dataUrl, filename, cb)
    if type(cb) ~= 'function' then return false end
    if type(dataUrl) ~= 'string' or not lib.string.startsWith(dataUrl, 'data:') then
        cb(nil, 'Expected a base64 data: URL')
        return false
    end
    local cap = lib.string.startsWith(dataUrl, 'data:video/') and MAX_VIDEO_BYTES or MAX_PHOTO_BYTES
    if #dataUrl > cap then
        cb(nil, ('Payload too large (%d bytes, cap %d)'):format(#dataUrl, cap))
        return false
    end
    uploader.uploadMedia(dataUrl, type(filename) == 'string' and filename or nil, cb)
    return true
end)
