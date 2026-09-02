---@type table AirShare core (server.share.core): request handshake + server-side proximity checks.
local share = require 'server.share.core'
---@type table Shared server helpers (server.util): field-length caps for the share payload.
local util  = require 'server.util'
---@type table Settings persistence layer (server.settings.store): the Streamer Mode cache the
---Phone speaker relay reads before sending anyone a broadcast.
local settingsStore = require 'server.settings.store'

---@type integer Tracks carried by one shared playlist. A hand-built library playlist is a few
---dozen songs, so this only stops a scripted array.
local MAX_SHARE_TRACKS = 200

---Rebuilds a client track as a fresh, field-capped table. Nothing nested is carried across, so a
---held share request can never retain an attacker-sized object graph.
---@param raw any client-supplied track
---@return table|nil track { id?, title, artist?, album?, url, addedAt? }
local function safeTrack(raw)
    if type(raw) ~= 'table' then return nil end
    local title = util.limitedString(raw.title, 200)
    local url   = util.limitedString(raw.url, 512)
    if not title or not url then return nil end
    local addedAt = tonumber(raw.addedAt)
    return {
        id      = util.limitedString(raw.id, 40),
        title   = title,
        artist  = util.limitedString(raw.artist, 200),
        album   = util.limitedString(raw.album, 200),
        url     = url,
        addedAt = util.finite(addedAt) and addedAt or nil,
    }
end

---Delivers an accepted single-song share: pushes the track to the recipient's client, which
---merges it into its localStorage library even while the Music app is closed.
---@param targetSrc number recipient server id
---@param payload table share payload ({ track: table })
---@return boolean delivered
local function deliverTrack(targetSrc, payload)
    if type(payload) ~= 'table' or type(payload.track) ~= 'table' then return false end
    TriggerClientEvent('sd-phone:client:music:receive', targetSrc, { kind = 'track', track = payload.track })
    return true
end

---Delivers an accepted playlist share: pushes the playlist name + all its tracks in one event.
---Runs only on the recipient's accept.
---@param targetSrc number recipient server id
---@param payload table share payload ({ name: string, tracks: table[] })
---@return boolean delivered
local function deliverPlaylist(targetSrc, payload)
    if type(payload) ~= 'table' or type(payload.tracks) ~= 'table' or #payload.tracks == 0 then return false end
    TriggerClientEvent('sd-phone:client:music:receive', targetSrc, {
        kind = 'playlist', name = payload.name, tracks = payload.tracks,
    })
    return true
end

-- The two music share kinds AirShare can deliver; each handler runs on recipient accept.
share.registerHandler('music-track',    deliverTrack)
share.registerHandler('music-playlist', deliverPlaylist)

---Opens an AirShare request for a song or playlist; share.request validates the kind and the
---nearby target, and the request expires after 60s unanswered.
---@param src number sender server id
---@param payload table { target: number, kind: string, track?/name?/tracks?: any }
lib.callback.register('sd-phone:server:music:share', function(src, payload)
    if type(payload) ~= 'table' then payload = {} end

    -- Whitelisted here, not just in share.request: without it this endpoint reaches the notes,
    -- documents, voice and signature handlers with a payload none of them sanitised.
    local built
    if payload.kind == 'music-track' then
        local track = safeTrack(payload.track)
        if not track then return { success = false, messageKey = 'music.nothingShare', message = 'Nothing to share' } end
        built = { track = track }
    elseif payload.kind == 'music-playlist' then
        local raw, tracks = type(payload.tracks) == 'table' and payload.tracks or {}, {}
        for i = 1, math.min(#raw, MAX_SHARE_TRACKS) do
            tracks[#tracks + 1] = safeTrack(raw[i])
        end
        if #tracks == 0 then return { success = false, messageKey = 'music.nothingShare', message = 'Nothing to share' } end
        built = { name = util.limitedString(payload.name, 100) or 'Shared Playlist', tracks = tracks }
    else
        return { success = false, messageKey = 'music.unknownShareType', message = 'Unknown share type' }
    end

    local sent, refusal = share.request(src, payload.target, payload.kind, built)
    if sent then return { success = true } end
    return refusal or { success = false }
end)

-- ── Phone speaker ────────────────────────────────────────────────────────────────────────────
-- Broadcasts the Music app's current track to nearby players over xsound (client/apps/music.lua
-- renders it; xsound itself is optional and never required here). This layer only relays who is
-- broadcasting what - position, distance falloff and the actual sound are entirely the listening
-- client's job, resolved from the broadcaster's own networked ped exactly like xsound's own
-- crewphone addon does it.

---@type table<number, true> Server ids currently broadcasting, so a late "stop" or a disconnect
---for a player who was never broadcasting is a no-op instead of a spurious relay.
local speakers = {}

---@param volume any raw client value, clamped to a sane 0-1
---@return number
local function clampVolume(volume)
    volume = tonumber(volume) or 1.0
    if volume < 0.0 then return 0.0 end
    if volume > 1.0 then return 1.0 end
    return volume
end

---Sends a Phone-speaker event to every player except those with Streamer Mode on. Their client
---never even learns a broadcast started, so a music match can never end up on their stream and
---risk a copyright claim over a song they never chose to play. Cheap: an in-memory cache lookup
---per online player, not a database read - see store.isStreamerMode.
---@param event string
---@param ... any
local function relayToListeners(event, ...)
    for _, playerId in ipairs(GetPlayers()) do
        local dst = tonumber(playerId)
        if dst and not settingsStore.isStreamerMode(dst) then
            TriggerClientEvent(event, dst, ...)
        end
    end
end

---Starts, or retargets to a new track, a player's phone-speaker broadcast.
---@param payload { url: string, volume?: number }
RegisterNetEvent('sd-phone:server:music:speaker:start', function(payload)
    local src = source
    if type(payload) ~= 'table' then return end
    local url = util.limitedString(payload.url, 512)
    if not url then return end
    speakers[src] = true
    relayToListeners('sd-phone:client:music:speaker:start', src, url, clampVolume(payload.volume))
end)

RegisterNetEvent('sd-phone:server:music:speaker:stop', function()
    local src = source
    if not speakers[src] then return end
    speakers[src] = nil
    relayToListeners('sd-phone:client:music:speaker:stop', src)
end)

---@param playing boolean
RegisterNetEvent('sd-phone:server:music:speaker:playstate', function(playing)
    local src = source
    if not speakers[src] then return end
    relayToListeners('sd-phone:client:music:speaker:playstate', src, playing == true)
end)

---Mirrors the Music app's own volume slider onto an already-live broadcast.
---@param volume number
RegisterNetEvent('sd-phone:server:music:speaker:volume', function(volume)
    local src = source
    if not speakers[src] then return end
    relayToListeners('sd-phone:client:music:speaker:volume', src, clampVolume(volume))
end)

AddEventHandler('playerDropped', function()
    local src = source
    if not speakers[src] then return end
    speakers[src] = nil
    TriggerClientEvent('sd-phone:client:music:speaker:stop', -1, src)
end)

---Gives a track straight to a player's music library (exports['sd-phone']:giveTrack), skipping
---the consent handshake. Returns false for an offline source or a malformed track.
---@param source number recipient server id, must be an online player
---@param track table { title: string, url: string, artist?: string, ... }
---@return boolean delivered
exports('giveTrack', function(source, track)
    if type(source) ~= 'number' or not GetPlayerName(source) then return false end
    if type(track) ~= 'table' then return false end
    if type(track.title) ~= 'string' or track.title == '' then return false end
    if type(track.url) ~= 'string' or track.url == '' then return false end
    return deliverTrack(source, { track = track })
end)
