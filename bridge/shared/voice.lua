---@type table sd-phone config root (configs/config.lua).
local config = require 'configs.config'

---@type table Voice config (configs/voice.lua): backend pin plus the detection order.
local V = type(config.Voice) == 'table' and config.Voice or {}

---@type table YaCA-specific options (configs/voice.lua Yaca). Defaulted here rather than read
---straight off the config so a server whose configs predate YaCA support still boots.
local Y = type(V.Yaca) == 'table' and V.Yaca or {}

---@type { name: string, provider: string }[] Detection order used when the config omits one, so a
---server whose configs predate this file still resolves a backend.
---
---yaca-voice sits ahead of saltychat on purpose: YaCA ships a SaltyChat compatibility bridge, and
---a server running both would otherwise resolve to the emulated dialect when the native one is
---right there. Pin the provider if you actually want the bridge.
local DEFAULT_RESOURCES <const> = {
    { name = 'pma-voice', provider = 'pma-voice' },
    { name = 'yaca-voice', provider = 'yaca-voice' },
    { name = 'saltychat', provider = 'saltychat' },
}

---Resolves which voice resource is running and which API dialect it speaks.
---
---The two are tracked separately on purpose: the RESOURCE is what exports are called on, the
---PROVIDER is which calls are legal. A renamed SaltyChat fork has its own resource name and still
---speaks 'saltychat', and sniffing exports to tell them apart is not possible - both scripts
---register only their own names, and a missing export raises rather than returning nil.
---
---A pin wins outright, including over a resource that is not reporting as started: an operator
---who names a dialect has told us more than GetResourceState can.
---@return string|nil resource, string|nil provider
local function detect()
    local list = type(V.Resources) == 'table' and #V.Resources > 0 and V.Resources or DEFAULT_RESOURCES

    local pin = V.Provider
    if pin and pin ~= 'auto' then
        for _, entry in ipairs(list) do
            if entry.provider == pin and GetResourceState(entry.name) == 'started' then
                return entry.name, pin
            end
        end
        for _, entry in ipairs(list) do
            if entry.provider == pin then return entry.name, pin end
        end
        return pin, pin
    end

    for _, entry in ipairs(list) do
        if GetResourceState(entry.name) == 'started' then return entry.name, entry.provider end
    end
    return nil, nil
end

local RESOURCE, PROVIDER = detect()

---@type table Module table; the table returned at end of file. Resolved once at require time,
---because a server does not swap voice scripts while running.
return {
    ---@type string|nil Resource name exports are invoked on, nil when no supported script runs.
    resource = RESOURCE,
    ---@type string|nil API dialect: 'pma-voice', 'saltychat' or 'yaca-voice'. nil when none was
    ---found.
    provider = PROVIDER,
    ---@type { radioChannel: integer, setActiveChannel: boolean } YaCA tuning, unread on other
    ---backends. YaCA gives a player several radio SLOTS rather than one radio, so the phone has
    ---to be told which slot is its own.
    yaca = {
        radioChannel     = math.floor(tonumber(Y.RadioChannel) or 1),
        setActiveChannel = Y.SetActiveChannel ~= false,
    },
}
