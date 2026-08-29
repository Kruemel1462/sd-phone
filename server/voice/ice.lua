---@type table sd-phone config root (configs/config.lua).
local config = require 'configs.config'

---@type table Voice config (configs/voice.lua): STUN list + TURN provisioning.
local CFG  = config.Voice or {}
---@type table Public STUN server URLs, always offered to every peer connection.
local STUN = CFG.StunServers or { 'stun:stun.l.google.com:19302' }
---@type table TURN provisioning config (CFG.Turn): Provider + TtlSeconds.
local TURN = CFG.Turn or {}

---@type { servers: table, expires: number }|nil Shared ICE server list. Cloudflare issues per
---TTL rather than per player, so one entry serves the whole server.
local iceCache = nil
---@type table|nil In-flight provisioning promise; concurrent callers await it instead of
---refetching, so a burst of calls cannot fan outbound HTTPS requests at Cloudflare.
local icePending = nil
---@type integer Seconds a failed provisioning is cached for. Short enough that a transient
---Cloudflare outage heals on its own, long enough that it can never become a request loop.
local ICE_FAILURE_TTL = 60

---@type table ICE module; the table returned at end of file.
local ice = {}

---The always-available STUN portion of an iceServers list, built fresh so callers can append.
---@return table servers array of { urls = string }
local function baseStun()
    local servers = {}
    for _, url in ipairs(STUN) do servers[#servers + 1] = { urls = url } end
    return servers
end

---Provisions a Cloudflare Realtime TURN credential set from the sd_cf_turn_* convars. Returns
---nil when unconfigured or on any transport/decode failure.
---@return table|nil iceServers Cloudflare's iceServers object, nil on failure
local function fetchCloudflareTurn()
    local tokenId  = GetConvar('sd_cf_turn_token_id', '')
    local apiToken = GetConvar('sd_cf_turn_api_token', '')
    if tokenId == '' or apiToken == '' then return nil end

    local ttl = tonumber(TURN.TtlSeconds) or 86400
    local p = promise.new()
    PerformHttpRequest(
        ('https://rtc.live.cloudflare.com/v1/turn/keys/%s/credentials/generate-ice-servers'):format(tokenId),
        function(status, body)
            if status ~= 201 or not body then return p:resolve(nil) end
            local ok, decoded = pcall(json.decode, body)
            p:resolve(ok and decoded and decoded.iceServers or nil)
        end,
        'POST',
        json.encode({ ttl = ttl }),
        {
            ['Authorization'] = 'Bearer ' .. apiToken,
            ['Content-Type']  = 'application/json',
            ['Accept']        = 'application/json',
        }
    )
    return Citizen.Await(p)
end

---ICE servers shared by every WebRTC feature (video calls, the nearby-voice mesh, Live and
---bodycams): STUN always, Cloudflare TURN appended when provisioning is configured. Cached
---server-wide until a minute before the credential lapses, with one shared flight.
---@return table servers iceServers array for RTCPeerConnection
function ice.servers()
    if iceCache and iceCache.expires > os.time() then return iceCache.servers end
    if icePending then return Citizen.Await(icePending) end

    local p = promise.new()
    icePending = p

    local servers = baseStun()
    local provisioned = true
    if TURN.Provider == 'cloudflare' then
        local ok, turn = pcall(fetchCloudflareTurn)
        if ok and turn then servers[#servers + 1] = turn else provisioned = false end
    end

    local ttl = provisioned and ((tonumber(TURN.TtlSeconds) or 86400) - 60) or ICE_FAILURE_TTL
    iceCache = { servers = servers, expires = os.time() + ttl }
    -- Cleared before the resolve so anyone woken by it reads the fresh cache, never a stale flight.
    icePending = nil
    p:resolve(servers)
    return servers
end

---True when Cloudflare TURN provisioning is configured, whatever its current health.
---@return boolean
function ice.cloudflareConfigured()
    return TURN.Provider == 'cloudflare'
        and GetConvar('sd_cf_turn_token_id', '') ~= ''
        and GetConvar('sd_cf_turn_api_token', '') ~= ''
end

return ice
