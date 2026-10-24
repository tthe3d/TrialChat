Sound emotes
============

Place `.mp3` or `.ogg` files in this folder before starting or restarting World
of Warcraft. The included placeholder sounds are `ding`, `boing`, `pop`,
`boom`, and `oof`.

Type a sound emote in TrialChat with two slashes:

    //laugh
    //cheer
    //vineboom

By default, `//laugh` looks for `laugh.mp3`. To use another filename or
extension, add a mapping to `TrialChatSoundEmotes.lua`:

    laugh = "laugh.ogg",

The sound name is sent to nearby TrialChat players and your group, so each
player needs the matching file locally. A sound that is also a normal WoW
emote sends both the sound and the emote; a sound-only emote only plays audio.
Missing files are ignored.

Playback is queued so sounds do not overlap. Add custom durations to
`TrialChatSoundEmotes.lua` when a file is longer than the default:

    TrialChatCommon.SoundEmoteDurations = {
        ["laugh.mp3"] = 1.24,
    }

The game controls addon audio volume. TrialChat plays sounds through the
configured channels in `TrialChatCommon.lua`, respecting each channel's volume.
