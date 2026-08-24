# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

A system-wide graphic EQ for macOS: a menu-bar SwiftUI app that applies a 10-band EQ to
*all* system audio (not just one app), by routing audio through the BlackHole virtual audio
driver, processing it, and re-emitting it to the user's real output device. See
`CODE_WALKTHROUGH.md` for the full technical explanation of the algorithm — read it before
touching `EQEngineController.swift` or `RingBuffer.swift`; the approach is non-obvious and
the walkthrough explains *why* each piece exists, not just what it does.

## Commands

```
swift build                # debug build, iterate quickly
swift run                  # build + run in one step
./setup_blackhole.sh       # one-time: brew install blackhole-2ch (user must run in a real
                            # Terminal — needs an interactive sudo prompt, will fail under
                            # non-interactive/sandboxed shells)
./build_app.sh              # release build + assembles/ad-hoc-codesigns GraphicEQ.app
open GraphicEQ.app          # launch the built app (first launch needs right-click -> Open
                            # to bypass Gatekeeper, since it's unsigned/unnotarized)
```

There is no test target and no linter configured in this project.

## Architecture

Two independently-clocked `AVAudioEngine`s bridged by a hand-rolled ring buffer — this is
the core design and the reason the code isn't a single simple engine graph:

- **Engine A** (capture-only): its input node is pinned to BlackHole via
  `kAudioOutputUnitProperty_CurrentDevice` (not the system default input), taps the incoming
  audio, converts it to a fixed 48kHz/stereo/Float32 "bridge format," and writes it into
  `RingBuffer`.
- **Engine B** (playback-only): `AVAudioPlayerNode -> AVAudioUnitEQ (10 bands) ->
  mainMixerNode -> outputNode`, with `outputNode` pinned to the user's chosen real hardware
  device. A `DispatchSourceTimer` drains the ring buffer every 20ms into the player node.

Both engines are created **once**, in `EQEngineController.init`, and never torn down/
recreated — enable/disable only stops, reconfigures, and restarts the same instances.
(An earlier version recreated a fresh `AVAudioEngine` on every toggle; that was unreliable
because Core Audio doesn't always release a HAL device binding from a just-stopped engine
before a new one claims the same device.)

`RingBuffer` bridges the two engines' independent clocks with watermark logic, not a full
adaptive resampler: it drops oldest samples if the producer runs too far ahead, and pads
reads with silence if the consumer runs ahead of available data. This bounds latency/glitch
severity rather than eliminating drift entirely — see `CODE_WALKTHROUGH.md` for the tradeoff
rationale.

`AudioDeviceManager` is the only place that talks to raw Core Audio HAL APIs (device
enumeration, reading/writing `kAudioHardwarePropertyDefaultOutputDevice`, finding BlackHole
by name, resolving a persisted device UID back to a live `AudioDeviceID`). Anything needing
device info goes through it rather than calling `AudioObjectGetPropertyData` directly
elsewhere.

`AppState` is the single source of UI truth (`isEnabled`, `bandGains`, selected output device
UID) and owns `UserDefaults` persistence. `EQEngineController` observes `AppState` via
Combine and reacts — it never gets called directly by the SwiftUI views; the views only ever
mutate `AppState`.

Because enabling this app hijacks the *system-wide* default output device, correctly
restoring the original device on disable/quit/crash is a correctness requirement, not a nice-
to-have. `AppDelegate.applicationWillTerminate` and a `SIGTERM` handler are both wired to the
same restore path (`disableEQMode()`) as a safety net — a force-quit or logout doesn't always
route through the normal termination callback.

Three invariants keep that restore path honest — don't break them:

1. **Never save BlackHole as the device to restore to.** `captureOriginalOutputDevice` falls
   back to the user's selected device when BlackHole is already the default. Saving BlackHole
   makes restore a permanent no-op: every later disable/quit "restores" to a silent virtual
   device, and the user has no in-app way out.
2. **`enableEQMode` is guarded by `isActive`.** Enabling twice without an intervening disable
   is what re-captures BlackHole as the original in the first place.
3. **The restore target is persisted as a UID, not an `AudioDeviceID`.** IDs get recycled
   across unplug/replug. It's written to `UserDefaults` so `recoverFromUncleanShutdown()` can
   un-strand the user at next launch after a crash or force-quit.

Also: `AVAudioEngine`'s `inputNode.audioUnit` and `outputNode.audioUnit` are the *same* AU
instance, so pinning engine A's input to BlackHole pins its output there too. Engine A's
mixer is muted (`outputVolume = 0`) purely to stop that from becoming a BlackHole→BlackHole
feedback loop.

## Known open issues

- No `AVAudioEngineConfigurationChangeNotification` observer. When it fires (device
  hot-plug, format change) the engine stops itself, audio dies silently, and the UI still
  shows enabled. `switchRealOutputDevice` also doesn't reconnect `mainMixerNode ->
  outputNode` after a device change, so that connection keeps its original format.
- The drain timer schedules into `playerNode` with no back-pressure (`nil` completion
  handler), so there's no feedback path to correct wall-clock-vs-audio-clock drift.
- The capture path is not real-time safe: it allocates per callback and `RingBuffer` uses
  an `NSLock`. `converter` is also written on main and read from the tap thread unsynchronized.
