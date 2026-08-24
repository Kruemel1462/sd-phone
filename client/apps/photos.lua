---@type fun(nuiAction: string, serverEvent: string) NUI->server pass-through registrar (client.nui).
local proxyCallback = require 'client.nui'
---@type table Notify-Bruecke (bridge.client.notify): backend-unabhaengige Meldungen.
local notify = require 'bridge.client.notify'

-- Thin delegates into server/photos: photo listing, deletion, favourites, URL saves and album
-- CRUD.
proxyCallback('sd-phone:photos:list',        'sd-phone:server:photos:list')
proxyCallback('sd-phone:photos:delete',      'sd-phone:server:photos:delete')
proxyCallback('sd-phone:photos:setFavorite', 'sd-phone:server:photos:setFavorite')
proxyCallback('sd-phone:photos:saveUrl',     'sd-phone:server:photos:saveUrl')

proxyCallback('sd-phone:albums:list',        'sd-phone:server:albums:list')
proxyCallback('sd-phone:albums:create',      'sd-phone:server:albums:create')
proxyCallback('sd-phone:albums:delete',      'sd-phone:server:albums:delete')
proxyCallback('sd-phone:albums:addPhotos',   'sd-phone:server:albums:addPhotos')
proxyCallback('sd-phone:albums:removePhoto', 'sd-phone:server:albums:removePhoto')
proxyCallback('sd-phone:albums:photos',      'sd-phone:server:albums:photos')

---Server push: a photo finished saving (camera shutter or clip upload); relays it to the
---gallery and any app listening for a fresh capture.
---@param photo table photo record from server/photos/init.lua
RegisterNetEvent('sd-phone:client:photos:added', function(photo)
    SendNUIMessage({ action = 'sd-phone:photos:added', data = photo })
end)

---Server-Push: ein Upload wurde abgewiesen oder ist fehlgeschlagen. Ohne diese Meldung bricht
---die Kamera stumm ab und der Spieler haelt es fuer einen Wackler.
---@param message string Grund im Klartext
RegisterNetEvent('sd-phone:client:photos:uploadFailed', function(message)
    notify.show({
        title       = 'Kamera',
        description = message or 'Upload fehlgeschlagen.',
        type        = 'error',
    })

    -- Auch an die NUI: die Kamera haelt ihren Ausloeser gesperrt, bis der Server geantwortet
    -- hat. Ohne diese Nachricht bliebe sie es bis zum Sicherheits-Timeout.
    SendNUIMessage({ action = 'sd-phone:photos:uploadFailed', data = message })
end)
