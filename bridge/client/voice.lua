---@type table Detected voice backend (bridge.shared.voice): resource name + API dialect.
local backend = require 'bridge.shared.voice'

---@type string|nil Resource exports are invoked on.
local RESOURCE = backend.resource
---@type string|nil API dialect: 'pma-voice', 'saltychat' or 'yaca-voice'.
local PROVIDER = backend.provider

---@type number SaltyChat's radio volume ceiling. Its SetRadioVolume clamps to 0.0-1.6 where
---pma-voice takes the phone's own 0-100, so the two cannot share a number.
local SALTY_VOLUME_MAX <const> = 1.6

---@type integer Which of YaCA's radio SLOTS the phone drives. YaCA hands a player several radios
---at once (slot 1 primary, slot 2 secondary), so unlike the other two backends the phone has to
---claim one rather than simply being the radio.
local YACA_SLOT <const> = backend.yaca.radioChannel
---@type boolean Whether turning the phone radio on also makes its slot YaCA's ACTIVE channel, so
---the player's push-to-talk keys the phone rather than whichever slot was selected before.
local YACA_SET_ACTIVE <const> = backend.yaca.setActiveChannel

---@type table Module table; the table returned at end of file. One API over the supported voice
---scripts, so no app module has to know which one is running.
local voice = {}

---@type table<string, boolean> Export names already reported as failing.
local yacaWarned = {}

---Calls a YaCA export and SAYS SO when it fails, rather than swallowing it.
---
---Every backend call here has to be guarded - a missing or renamed export raises rather than
---returning nil - but a guard that discards the error turns "the radio does nothing" into a bug
---nobody can chase. One line per export name names the culprit without flooding the console.
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

---@type boolean Local transmit state, tracked from the backend's own event because neither
---TeamSpeak backend has a native to poll. Mumble backends read the native instead and never
---touch this.
local talking = false

if PROVIDER == 'saltychat' then
    AddEventHandler('SaltyChat_TalkStateChanged', function(isTalking)
        talking = isTalking == true
    end)
elseif PROVIDER == 'yaca-voice' then
    AddEventHandler('yaca:external:isTalking', function(state)
        talking = state == true
    end)
end

---Detected voice resource name, or nil when none is running. Read-only.
---@return string|nil
function voice.resource() return RESOURCE end

---Detected API dialect ('pma-voice' | 'saltychat' | 'yaca-voice'), or nil. Read-only.
---@return string|nil
function voice.provider() return PROVIDER end

---What this backend can actually do, for callers that must not offer a control the running voice
---script cannot honour.
---
---`mute` is the one that matters: SaltyChat is TeamSpeak-based, so every Mumble native the phone
---would mute with is a silent no-op there, and SaltyChat exposes its mic state as READ-ONLY with
---no setter at any scope. A Mute button on that backend would look like it worked and do nothing,
---so the call UI drops it instead. YaCA is TeamSpeak-based too but DOES have a setter - a
---server-side one, muteOnPhone - so its Mute button stays.
---
---`callVolume` is pma-voice only: neither TeamSpeak backend has a per-call volume, and YaCA's
---nearest equivalent is a per-PLAYER modifier that would need the other party's server id, which
---this API deliberately does not carry.
---@return { mute: boolean, callVolume: boolean, transmitState: boolean, radio: boolean }
function voice.capabilities()
    return {
        mute          = PROVIDER == 'pma-voice' or PROVIDER == 'yaca-voice',
        callVolume    = PROVIDER == 'pma-voice',
        transmitState = PROVIDER ~= nil,
        radio         = PROVIDER ~= nil,
    }
end

---Mutes or unmutes the local mic for the call.
---
---pma-voice is silenced right here, and covers proximity too: switching the voice target to 0
---(the default, which carries no call channels) keeps audio off the call channel, and zeroing the
---input distance silences proximity as well.
---
---YaCA has no client-side setter - its mute lives on the server as muteOnPhone - so the request
---goes over the wire and the server bridge applies it. It is scoped to the CALL there, which is
---what a phone's Mute button means anyway: the player stays audible to whoever is standing next
---to them.
---@param on boolean true to mute
---@return boolean handled false when the backend has no way to mute
function voice.setMuted(on)
    if PROVIDER == 'yaca-voice' then
        TriggerServerEvent('sd-phone:server:voice:mute', on == true)
        return true
    end

    if PROVIDER ~= 'pma-voice' then return false end
    if on then
        MumbleSetVoiceTarget(0)
        MumbleSetAudioInputDistance(0.0)
    else
        MumbleSetVoiceTarget(1)
        MumbleSetAudioInputDistance(9999.0)
    end
    return true
end

---How loud the other party sounds, 0-100.
---@param volume number 0-100
---@return boolean handled
function voice.setCallVolume(volume)
    if PROVIDER ~= 'pma-voice' or not RESOURCE then return false end
    return pcall(function() exports[RESOURCE]:setCallVolume(volume) end)
end

---@type number|nil Last volume the Radio app asked for, on the phone's 0-100 scale. YaCA refuses
---volume changes while its radio is disabled, and the Radio app sets the volume BEFORE the
---channel, so the figure is held here and re-applied once the radio is up.
local yacaVolume = nil
---@type boolean True while the phone holds YaCA's radio open.
local yacaRadioOn = false

---Pushes the remembered volume into YaCA's slot. Silent when nothing has asked for one yet.
local function yacaApplyVolume()
    if not RESOURCE or yacaVolume == nil then return end
    -- Note the argument order: YaCA's export is (volume, channel), not (channel, volume), and it
    -- clamps to 0.0-1.0 rather than taking the phone's 0-100.
    yacaCall('changeRadioChannelVolumeRaw', function() exports[RESOURCE]:changeRadioChannelVolumeRaw(yacaVolume / 100.0, YACA_SLOT) end)
end

---Joins or leaves the phone's YaCA radio slot.
---
---YaCA names frequencies with a decimal STRING ('12.5'), which is the same figure the Radio app
---turned into its integer channel, so the channel is turned back rather than stringified whole:
---handing YaCA '125' would put the phone on a frequency no other YaCA script would ever tune to.
---
---Leaving sets the slot's frequency to '0', YaCA's own "no frequency" marker, and stops there. It
---deliberately does NOT call enableRadio(false): that is a per-PLAYER master switch, so a server
---running a job radio on the other slot would have it go dead the moment someone switched the
---phone's radio off.
---@param channel integer 0 to leave
---@return boolean handled
local function yacaSetRadio(channel)
    if channel <= 0 then
        if not yacaRadioOn then return true end
        yacaRadioOn = false
        return yacaCall('changeRadioFrequencyRaw', function() exports[RESOURCE]:changeRadioFrequencyRaw(YACA_SLOT, '0') end)
    end

    -- Enabled on every join rather than once: setActiveRadioChannel and the volume export both
    -- refuse while the radio is off, and enableRadio itself no-ops until YaCA's TeamSpeak plugin
    -- has connected - so an attempt made too early has to be able to heal on the next one.
    yacaCall('enableRadio', function() exports[RESOURCE]:enableRadio(true) end)
    yacaRadioOn = true

    if YACA_SET_ACTIVE then
        yacaCall('setActiveRadioChannel', function() exports[RESOURCE]:setActiveRadioChannel(YACA_SLOT) end)
    end
    yacaApplyVolume()

    local frequency = string.format('%.1f', channel / 10)
    return yacaCall('changeRadioFrequencyRaw', function() exports[RESOURCE]:changeRadioFrequencyRaw(YACA_SLOT, frequency) end)
end

---Joins or leaves a radio channel. Channel 0 means leave.
---
---The channel arrives as the integer the Radio app derives from the frequency; SaltyChat names
---channels with STRINGS, so the same 125 has to go over as '125' or it joins nothing.
---@param channel integer 0 to leave
---@return boolean handled
function voice.setRadioChannel(channel)
    if not RESOURCE then return false end
    channel = math.floor(tonumber(channel) or 0)

    if PROVIDER == 'yaca-voice' then
        return yacaSetRadio(channel)
    end

    if PROVIDER == 'saltychat' then
        if channel <= 0 then
            return pcall(function() exports[RESOURCE]:SetRadioChannel(nil, true) end)
        end
        return pcall(function() exports[RESOURCE]:SetRadioChannel(tostring(channel), true) end)
    end

    return pcall(function() exports[RESOURCE]:setRadioChannel(channel) end)
end

---Radio loudness on the phone's own 0-100 scale.
---@param volume number 0-100
---@return boolean handled
function voice.setRadioVolume(volume)
    if not RESOURCE then return false end
    volume = tonumber(volume) or 0
    if volume < 0 then volume = 0 elseif volume > 100 then volume = 100 end

    if PROVIDER == 'yaca-voice' then
        yacaVolume = volume
        yacaApplyVolume()
        return true
    end

    if PROVIDER == 'saltychat' then
        local level = volume / 100.0 * SALTY_VOLUME_MAX
        return pcall(function() exports[RESOURCE]:SetRadioVolume(level) end)
    end

    return pcall(function() exports[RESOURCE]:setRadioVolume(volume) end)
end

---Subscribes to "am I transmitting on the radio right now", for the on-air indicator.
---
---The three backends announce it differently: pma-voice fires a single boolean; SaltyChat reports
---all four traffic directions and only the two TRANSMIT halves mean the local player is keying up
---- passing its receive flags through would light the indicator whenever anyone else spoke; YaCA
---reports per SLOT, and only the phone's own slot is ours to light.
---@param handler fun(active: boolean)
function voice.onRadioTransmit(handler)
    if PROVIDER == 'yaca-voice' then
        AddEventHandler('yaca:external:isRadioTalking', function(state, channel)
            if channel ~= YACA_SLOT then return end
            handler(state == true)
        end)
        return
    end

    if PROVIDER == 'saltychat' then
        AddEventHandler('SaltyChat_RadioTrafficStateChanged', function(_, primaryTransmit, _, secondaryTransmit)
            handler(primaryTransmit == true or secondaryTransmit == true)
        end)
        return
    end

    AddEventHandler('pma-voice:radioActive', function(active)
        handler(active == true)
    end)
end

---Whether the local player is transmitting voice in-game. Fails OPEN (reported as talking) when
---the backend cannot say, so a recording never silently captures nothing.
---@return boolean transmitting
function voice.isTransmitting()
    if PROVIDER == 'saltychat' or PROVIDER == 'yaca-voice' then return talking end

    local ok, isTalking = pcall(MumbleIsPlayerTalking, cache.playerId)
    if not ok then return true end
    return isTalking == true or isTalking == 1
end

return voice
