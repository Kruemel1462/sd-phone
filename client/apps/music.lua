---AirShare a song or playlist to a nearby phone. Thin forward into server/music.
RegisterNUICallback('sd-phone:music:share', function(payload, cb)
    cb(lib.callback.await('sd-phone:server:music:share', false, payload) or { success = false, message = 'No response from server' })
end)

-- ── external now playing ─────────────────────────────────────────────────────
-- Lets a third-party resource with its own audio engine (not the built-in Music app) drive the
-- Control Center card, the dynamic-island mini-player and the Now Playing widget, exactly like
-- Music does. Only one provider holds the slot at a time — the most recent `setExternalNowPlaying`
-- call wins outright, no queueing or priority.

---@type table<string, fun(action: string, value: number?)> appId -> action callback
local nowPlayingProviders = {}

---@type table<string, string> appId -> the resource that claimed it, so one resource can neither
---overwrite nor clear a card another resource owns.
local providerOwners = {}

---@type string? appId currently holding the Now Playing slot, so a stale `clear` from a provider
---that already lost it to a newer one is a no-op rather than wiping the newer card.
local activeProvider = nil

---@param appId string identifies the calling resource's app, e.g. its custom-app id
---@param track table { title, artist?, thumb?, playing, position, duration, canNext?, canPrev? }
---@param onAction fun(action: 'toggle'|'next'|'prev'|'seek', value: number?) called for taps on
---the card/island/widget this pushes to; `action == 'seek'` carries the target position as `value`
exports('setExternalNowPlaying', function(appId, track, onAction)
    if type(appId) ~= 'string' or appId == '' or type(track) ~= 'table' then return false end
    local resource = GetInvokingResource()
    local owner = providerOwners[appId]
    if owner and owner ~= resource then return false end
    providerOwners[appId] = resource
    activeProvider = appId
    nowPlayingProviders[appId] = onAction
    SendNUIMessage({ action = 'sd-phone:nowPlaying:set', data = { appId = appId, track = track } })
    return true
end)

---@param appId string must match the appId passed to setExternalNowPlaying
exports('clearExternalNowPlaying', function(appId)
    if type(appId) ~= 'string' or providerOwners[appId] ~= GetInvokingResource() then return end
    providerOwners[appId], nowPlayingProviders[appId] = nil, nil
    if activeProvider == appId then activeProvider = nil end
    SendNUIMessage({ action = 'sd-phone:nowPlaying:clear', data = { appId = appId } })
end)

---Drops any Now Playing slot a stopping resource still held, so a restarted provider cannot leave
---a dead card (and a dangling onAction) on the Control Center, island, widget and lock screen.
---@param resource string
AddEventHandler('onResourceStop', function(resource)
    for appId, owner in pairs(providerOwners) do
        if owner == resource then
            providerOwners[appId], nowPlayingProviders[appId] = nil, nil
            if activeProvider == appId then activeProvider = nil end
            SendNUIMessage({ action = 'sd-phone:nowPlaying:clear', data = { appId = appId } })
        end
    end
end)

RegisterNUICallback('sd-phone:nowPlaying:action', function(data, cb)
    local onAction = data and nowPlayingProviders[data.appId]
    if onAction then
        local ok = pcall(onAction, data.action, data.value)
        if not ok then
            lib.print.debug(('external now playing: %s\'s onAction errored on %s'):format(data.appId, tostring(data.action)))
        end
    end
    cb('ok')
end)

-- ── Phone speaker ────────────────────────────────────────────────────────────────────────────
-- The Music app's speaker toggle: broadcasts the current track over xsound so nearby players
-- hear it too, positioned on the broadcaster's own ped. xsound is optional - every entry point
-- here is a no-op if it isn't running.
---@type number Metres before a listener stops hearing a broadcast.
local SPEAKER_DISTANCE <const> = 20.0
---@type number Volume xsound plays a broadcast at for a listener.
local SPEAKER_VOLUME <const> = 0.35

---@param volume any raw NUI value, clamped to a sane 0-1
---@return number
local function clampVolume(volume)
    volume = tonumber(volume) or 1.0
    if volume < 0.0 then return 0.0 end
    if volume > 1.0 then return 1.0 end
    return volume
end

---@param payload { url?: string, volume?: number }
RegisterNUICallback('sd-phone:music:speaker:start', function(payload, cb)
    local url = payload and payload.url
    if GetResourceState('xsound') ~= 'started' or type(url) ~= 'string' or url == '' then
        cb({ success = false })
        return
    end
    TriggerServerEvent('sd-phone:server:music:speaker:start', { url = url, volume = clampVolume(payload.volume) })
    cb({ success = true })
end)

RegisterNUICallback('sd-phone:music:speaker:stop', function(_, cb)
    TriggerServerEvent('sd-phone:server:music:speaker:stop')
    cb('ok')
end)

---@param payload { playing?: boolean }
RegisterNUICallback('sd-phone:music:speaker:playstate', function(payload, cb)
    TriggerServerEvent('sd-phone:server:music:speaker:playstate', payload and payload.playing == true)
    cb('ok')
end)

---Mirrors the Music app's own volume slider onto the broadcast - it's the broadcaster's phone
---speaker, so turning it down should turn it down for everyone hearing it too.
---@param payload { volume?: number }
RegisterNUICallback('sd-phone:music:speaker:volume', function(payload, cb)
    TriggerServerEvent('sd-phone:server:music:speaker:volume', clampVolume(payload and payload.volume))
    cb('ok')
end)

-- Listening side: every other player's active broadcast, keyed by their server id as a string -
-- that string doubles as the xsound sound name.
---@type table<string, boolean>
local speakers = {}

---@param serverId number
---@param url string
---@param volume number 0-1, the broadcaster's own Music app volume slider
RegisterNetEvent('sd-phone:client:music:speaker:start', function(serverId, url, volume)
    if serverId == GetPlayerServerId(PlayerId()) then return end
    if GetResourceState('xsound') ~= 'started' then return end

    local name = tostring(serverId)
    local target = GetPlayerFromServerId(serverId)
    local ped = target ~= -1 and GetPlayerPed(target) or 0
    local pos = ped ~= 0 and GetEntityCoords(ped) or vector3(0.0, 0.0, 0.0)

    speakers[name] = true
    exports.xsound:PlayUrlPos(name, url, (tonumber(volume) or 1.0) * SPEAKER_VOLUME, pos, false)
    exports.xsound:Distance(name, SPEAKER_DISTANCE)
end)

---@param serverId number
RegisterNetEvent('sd-phone:client:music:speaker:stop', function(serverId)
    local name = tostring(serverId)
    if not speakers[name] then return end
    speakers[name] = nil
    if GetResourceState('xsound') == 'started' then exports.xsound:Destroy(name) end
end)

---@param serverId number
---@param playing boolean
RegisterNetEvent('sd-phone:client:music:speaker:playstate', function(serverId, playing)
    local name = tostring(serverId)
    if not speakers[name] or GetResourceState('xsound') ~= 'started' then return end
    if playing then exports.xsound:Resume(name) else exports.xsound:Pause(name) end
end)

---@param serverId number
---@param volume number 0-1
RegisterNetEvent('sd-phone:client:music:speaker:volume', function(serverId, volume)
    local name = tostring(serverId)
    if not speakers[name] or GetResourceState('xsound') ~= 'started' then return end
    exports.xsound:setVolumeMax(name, (tonumber(volume) or 1.0) * SPEAKER_VOLUME)
end)

-- Fired when this player turns Streamer Mode on (server/settings/init.lua). From that moment the
-- server stops sending this client any speaker events at all, which would otherwise leave a
-- broadcast already playing stuck running forever - even its own "stop" would now be filtered.
RegisterNetEvent('sd-phone:client:music:speaker:clearAll', function()
    if GetResourceState('xsound') == 'started' then
        for name in pairs(speakers) do exports.xsound:Destroy(name) end
    end
    speakers = {}
end)

-- Keeps every active broadcast anchored to its owner's live position, and drops one whose owner
-- disconnected or fell out of scope before their own "stop" could arrive.
CreateThread(function()
    while true do
        Wait(250)
        for name in pairs(speakers) do
            local serverId = tonumber(name)
            local player = serverId and GetPlayerFromServerId(serverId)
            if player and player ~= -1 then
                if GetResourceState('xsound') == 'started' then
                    exports.xsound:Position(name, GetEntityCoords(GetPlayerPed(player)))
                end
            else
                speakers[name] = nil
                if GetResourceState('xsound') == 'started' then exports.xsound:Destroy(name) end
            end
        end
    end
end)

---Server push: a song / playlist shared to us was accepted server-side. Hands it to the NUI
---and surfaces a notification.
---@param data table { kind: 'track'|'playlist', ... } from server/music/init.lua
RegisterNetEvent('sd-phone:client:music:receive', function(data)
    SendNUIMessage({ action = 'sd-phone:music:receive', data = data })
    SendNUIMessage({ action = 'sd-phone:notification', data = {
        app   = 'music',
        titleKey = 'music.musicTitle', title = 'Music',
        body  = (data and data.kind == 'playlist')
            and 'A playlist was added to your library.'
            or  'A song was added to your library.',
    } })
end)
