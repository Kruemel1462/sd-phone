---@type table Detected voice backend (bridge.shared.voice): resource name + API dialect.
local backend = require 'bridge.shared.voice'

---@type string|nil Resource exports are invoked on.
local RESOURCE = backend.resource
---@type string|nil API dialect: 'pma-voice', 'saltychat' or 'yaca-voice'.
local PROVIDER = backend.provider

---@type table Module table; the table returned at end of file. One API over the supported voice
---scripts for call membership and speakerphone.
local voice = {}

---@type table<number, string> Source -> the SaltyChat call identifier they are currently in.
---
---Needed because the backends model leaving a call differently: pma-voice takes channel 0 as
---"leave whatever you were in", while SaltyChat's RemovePlayerFromCall demands the identifier of
---the call being left. Nothing else knows it by then - the phone has already torn the session
---down - so the bridge has to remember it. Unused on the other backends.
local inCall = {}

-- YaCA has no call CHANNEL at all: its callPlayer(src, target, state) wires up exactly two
-- players. The phone's channel is therefore emulated as a full mesh - every member is called
-- against every other - which is the only way a group or merged call works on this backend. The
-- three tables below are that mesh's bookkeeping, and stay empty on the other backends.
---@type table<number, number> Source -> the phone call channel they are currently meshed into.
local yacaChannel = {}
---@type table<number, table<number, boolean>> Channel -> the set of sources meshed into it.
local yacaMembers = {}
---@type table<number, boolean> Sources whose phone mute the phone last asked for.
local yacaMuted = {}
---@type table<number, boolean> Sources whose speakerphone the phone last turned on.
local yacaSpeaker = {}

---@type table<string, boolean> Export names already reported as failing.
local yacaWarned = {}

---Calls a YaCA export and SAYS SO when it fails, rather than swallowing it.
---
---Every backend call in this file has to be guarded - a missing or renamed export raises rather
---than returning nil - but a guard that discards the error turns "the speakerphone does nothing"
---into a bug nobody can chase. One line per export name names the culprit without flooding a
---console during a live call.
---@param name string export name, for the message
---@param fn fun() the call itself
---@return boolean ok
local function yacaCall(name, fn)
    local ok, err = pcall(fn)
    if not ok and not yacaWarned[name] then
        yacaWarned[name] = true
        print(('^1[sd-phone:voice]^0 %s export %s failed: %s'):format(RESOURCE, name, err))
    end
    return ok
end

---Detected API dialect ('pma-voice' | 'saltychat' | 'yaca-voice'), or nil. Read-only.
---@return string|nil
function voice.provider() return PROVIDER end

---Whether the backend has a real speakerphone of its own. When false the caller has to build one,
---which is what the proximity sweep in server/calls/actions.lua is for.
---
---YaCA's is claimed only when the config still says so, because whether it actually carries is a
---property of the YaCA INSTALL rather than of the dialect: enablePhoneSpeaker sets a state bag
---that YaCA's own client loop has to act on, and nothing readable from Lua says whether it will.
---An operator whose YaCA speaker stays silent flips Yaca.NativeSpeaker off and gets the phone's
---own proximity circle instead of a button that does nothing.
---@return boolean
function voice.nativeSpeaker()
    if PROVIDER == 'yaca-voice' then return backend.yaca.nativeSpeaker end
    return PROVIDER == 'saltychat'
end

---Re-asserts mute and speakerphone for everyone still meshed into a YaCA channel.
---
---Both need it, for different reasons, and both only after the membership has changed:
---  * callPlayer(..., false) clears the phone mute of BOTH legs it tears down, so dropping one
---    party out of a conference silently unmutes whoever they were meshed with.
---  * enablePhoneSpeaker snapshots who the holder is in a call WITH at the moment it is called,
---    so a third party merged in afterwards is inaudible to the bystanders around the speaker
---    until it is run again.
---@param channel number
local function yacaResync(channel)
    local members = yacaMembers[channel]
    if not members or not RESOURCE then return end
    for src in pairs(members) do
        if yacaMuted[src] then
            yacaCall('muteOnPhone', function() exports[RESOURCE]:muteOnPhone(src, true) end)
        end
        if yacaSpeaker[src] then
            yacaCall('enablePhoneSpeaker', function() exports[RESOURCE]:enablePhoneSpeaker(src, true) end)
        end
    end
end

---Forgets a source's mesh membership, optionally without touching YaCA itself.
---@param src number
---@param teardown boolean true to unwire the player from every peer first
local function yacaLeave(src, teardown)
    local channel = yacaChannel[src]
    yacaChannel[src] = nil
    yacaMuted[src]   = nil

    if teardown and yacaSpeaker[src] and RESOURCE then
        yacaCall('enablePhoneSpeaker', function() exports[RESOURCE]:enablePhoneSpeaker(src, false) end)
    end
    yacaSpeaker[src] = nil

    if not channel then return end
    local members = yacaMembers[channel]
    if not members then return end
    members[src] = nil

    if teardown and RESOURCE then
        for peer in pairs(members) do
            yacaCall('callPlayer', function() exports[RESOURCE]:callPlayer(src, peer, false) end)
        end
    end

    if next(members) == nil then
        yacaMembers[channel] = nil
    else
        yacaResync(channel)
    end
end

---Wires a source into every existing member of a channel, then re-asserts the channel's state.
---@param src number
---@param channel number
local function yacaJoin(src, channel)
    local members = yacaMembers[channel]
    if not members then
        members = {}
        yacaMembers[channel] = members
    end

    if RESOURCE then
        for peer in pairs(members) do
            yacaCall('callPlayer', function() exports[RESOURCE]:callPlayer(src, peer, true) end)
        end
    end

    members[src]     = true
    yacaChannel[src] = channel
    yacaResync(channel)
end

---Moves a player in or out of a call channel. Channel 0 leaves.
---
---SaltyChat identifies calls with STRINGS, so the phone's numeric channel is stringified rather
---than passed through - handing it the number joins a call nobody else is in, silently. YaCA has
---no channel concept whatsoever and is meshed pairwise instead; see the tables above.
---@param src number player source
---@param channel number 0 to leave
---@return boolean handled
function voice.setPlayerCall(src, channel)
    if not RESOURCE then return false end
    channel = math.floor(tonumber(channel) or 0)

    if PROVIDER == 'yaca-voice' then
        if channel <= 0 then
            yacaLeave(src, true)
            return true
        end
        if yacaChannel[src] == channel then return true end
        yacaLeave(src, true)
        yacaJoin(src, channel)
        return true
    end

    if PROVIDER == 'saltychat' then
        local previous = inCall[src]
        if channel <= 0 then
            if not previous then return true end
            inCall[src] = nil
            return pcall(function() exports[RESOURCE]:RemovePlayerFromCall(previous, src) end)
        end

        local identifier = tostring(channel)
        if previous == identifier then return true end
        if previous then
            pcall(function() exports[RESOURCE]:RemovePlayerFromCall(previous, src) end)
        end
        inCall[src] = identifier
        return pcall(function() exports[RESOURCE]:AddPlayerToCall(identifier, src) end)
    end

    return pcall(function() exports[RESOURCE]:setPlayerCall(src, channel) end)
end

---Turns a player's speakerphone on or off, where the backend has one.
---
---YaCA's enablePhoneSpeaker refuses outright for a player who is not yet in a call, so switching
---it on is rejected here rather than issued and lost - the phone reads the false as "no native
---speaker for this one" and nothing is left half-applied.
---@param src number player source
---@param on boolean
---@return boolean handled false when the caller must fall back to its own proximity circle
function voice.setPhoneSpeaker(src, on)
    if not RESOURCE then return false end

    if PROVIDER == 'yaca-voice' then
        on = on == true
        if on and not yacaChannel[src] then return false end
        yacaSpeaker[src] = on or nil
        return yacaCall('enablePhoneSpeaker', function() exports[RESOURCE]:enablePhoneSpeaker(src, on) end)
    end

    if PROVIDER ~= 'saltychat' then return false end
    return pcall(function() exports[RESOURCE]:SetPhoneSpeaker(src, on == true) end)
end

---Mutes or unmutes a player on their current call, for backends whose mute lives server-side.
---
---Only YaCA has one. The state is remembered as well as applied because YaCA drops it whenever
---the mesh changes - see `yacaResync`.
---@param src number player source
---@param on boolean
---@return boolean handled
function voice.setPlayerMuted(src, on)
    if PROVIDER ~= 'yaca-voice' or not RESOURCE then return false end
    on = on == true
    yacaMuted[src] = on or nil
    return yacaCall('muteOnPhone', function() exports[RESOURCE]:muteOnPhone(src, on) end)
end

-- The client bridge's Mute button on YaCA, which has no client-side setter. Self-scoped: a player
-- can only ever mute their own source, so there is nothing here to authorise.
RegisterNetEvent('sd-phone:server:voice:mute', function(on)
    voice.setPlayerMuted(source, on == true)
end)

-- A player who disconnects mid-call never reaches the phone's own teardown, which would otherwise
-- leave their source keyed in the maps forever and, worse, hand a recycled source the previous
-- occupant's call identifier. The YaCA mesh is torn down WITHOUT re-issuing exports for the gone
-- source - YaCA has already dropped them itself - but the survivors are still resynced, since
-- that teardown reset their mute and speaker just the same.
AddEventHandler('playerDropped', function()
    inCall[source] = nil
    yacaLeave(source, false)
end)

return voice
