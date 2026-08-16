-- Phone voice capture for camera videos and Photogram Live. The recorder's own mic is always
-- mixed in client-side; the settings below govern capturing NEARBY players' voices, done with a
-- real WebRTC mesh (each nearby player's client streams their mic peer-to-peer, mixed into the
-- recording).
--
-- Provider/Resources pick which voice script carries CALLS and the RADIO. The three supported
-- dialects are not interchangeable: pma-voice takes numeric call channels and Mumble natives;
-- SaltyChat takes string call identifiers and has no mic-mute API at all, so the phone hides its
-- in-call Mute button there rather than offering one that does nothing; YaCA has no call channel
-- of any kind, so the phone meshes its participants pair by pair and mutes server-side.
return {
    -- Which voice API the phone speaks. 'auto' takes the first started entry of Resources
    -- below; naming a dialect outright pins it, which is what you want when two scripts are
    -- installed or the resource has been renamed.
    --   'auto' | 'pma-voice' | 'saltychat' | 'yaca-voice'
    --
    -- Running YaCA with its SaltyChat compatibility bridge? Leave this on 'auto' to get NATIVE
    -- YaCA, which is the better of the two (real speakerphone, working Mute button). Pin
    -- 'saltychat' only if you specifically want the phone to go through the bridge.
    Provider = 'auto',

    -- Detection order for 'auto', and the map from a resource name to the dialect it speaks.
    -- Add an entry for a renamed fork rather than editing the bridge: a fork of SaltyChat
    -- called something else still speaks 'saltychat'.
    Resources = {
        { name = 'pma-voice', provider = 'pma-voice' },
        { name = 'yaca-voice', provider = 'yaca-voice' },
        { name = 'saltychat', provider = 'saltychat' },
    },

    -- YaCA only; ignored on the other backends. YaCA gives each player SEVERAL radios at once
    -- rather than one, so the phone has to be told which of them is its own.
    Yaca = {
        -- The radio slot the phone's Radio app drives. Move it off 1 if a job radio script
        -- already owns the primary slot.
        RadioChannel     = 1,

        -- Switching the phone radio on also makes that slot YaCA's ACTIVE channel, so the
        -- player's push-to-talk keys the phone. Set false to leave the active channel alone,
        -- and the phone's radio becomes receive-only unless the player selects its slot.
        SetActiveChannel = true,
    },

    -- Master switch. When false, recordings carry only the recorder's own voice. Note:
    -- capturing other players' microphones may have privacy implications on your server.
    RecordNearbyVoices = true,

    -- Metres - how close another player must be to be captured.
    NearbyRange        = 12.0,

    -- Cap on simultaneous nearby voices mixed into one recording (protects
    -- bandwidth/CPU on busy streets).
    MaxNearbyVoices    = 6,

    -- Only capture a nearby player while they're actually transmitting in-game
    -- (push-to-talk or open mic), so silent/muted players aren't recorded and
    -- you capture what you'd actually hear. Every supported backend can report
    -- this: pma-voice through Mumble, SaltyChat and YaCA through their own talk
    -- events. Set false to stream their mic the whole time instead.
    TransmitGated      = true,

    -- 'cloudflare' provisions TURN relays (needed for players on different networks) from
    -- Cloudflare Realtime; 'none' uses STUN only (works on LAN / permissive NATs only).
    -- TURN secrets are read from server convars (NOT committed to the repo):
    --     set sd_cf_turn_token_id   "your-cloudflare-turn-token-id"
    --     set sd_cf_turn_api_token  "your-cloudflare-turn-api-token"
    -- Create them at Cloudflare dash → Realtime → TURN. See the Cloudflare TURN docs.
    Turn = {
        Provider   = 'cloudflare',   -- 'cloudflare' | 'none'
        TtlSeconds = 86400,          -- lifetime of provisioned TURN credentials
    },

    -- Always-available public STUN (free). TURN is layered on top when configured.
    StunServers = {
        'stun:stun.l.google.com:19302',
        'stun:stun1.l.google.com:19302',
    },
}
