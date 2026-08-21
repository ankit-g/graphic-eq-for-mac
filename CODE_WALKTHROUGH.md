# Code Walkthrough: How the System-Wide EQ Actually Works

This is the part that isn't obvious from reading SwiftUI code: macOS gives you no API to
"intercept all system audio, process it, and send it back out." Everything in
`EQEngineController.swift` and `RingBuffer.swift` exists to work around that. This document
explains the algorithm end-to-end.

## The core problem

An `AVAudioEngine` normally binds to exactly one input device and one output device, and
both run on the *same* hardware clock (the device's own sample clock drives the whole
render graph). To EQ "everything," we need audio to flow: **[all apps] → [something we can
read] → [EQ] → [real speakers]**. macOS has no "audio tap on the whole system" API, so step
one is inventing a place for "something we can read" to exist at all.

## Step 1: BlackHole — hijacking the default output device

[BlackHole](https://github.com/ExistentialAudio/BlackHole) is a virtual audio driver: to
macOS it looks like a real audio device, but it has no speaker or microphone behind it —
it's a loopback. Whatever you send to its *output* becomes instantly readable from its
*input*.

`EQEngineController.enableEQMode(realOutputDeviceID:)` does this:

```swift
savedOriginalOutputDeviceID = AudioDeviceManager.getDefaultOutputDevice()
AudioDeviceManager.setDefaultOutputDevice(blackHole.id)
```

That single call is what makes this "system-wide": every app on the Mac sends its audio to
whatever `kAudioHardwarePropertyDefaultOutputDevice` points at. By pointing it at BlackHole,
we've made *all* system audio observable, without touching a single other app.

`AudioDeviceManager.swift` wraps the raw Core Audio HAL calls this needs:
`AudioObjectGetPropertyData`/`AudioObjectSetPropertyData` against
`kAudioObjectSystemObject` with the `kAudioHardwarePropertyDefaultOutputDevice` selector.
The "read the current value first" step matters: it's how we know what to restore later.

## Step 2: two engines, not one

Here's the part that looks over-engineered but isn't. You might expect one `AVAudioEngine`
with BlackHole as input and your speakers as output. That doesn't work reliably: BlackHole
has no real clock (it's virtual), and your speakers have their own hardware clock. A single
engine's render graph assumes one shared clock driving both ends. Feed it two independent
clocks and you get drift, underruns, or the engine simply refusing to run sanely.

So there are two separate, independently-clocked engines:

- **Engine A** (`engineA`) — input only. Its job is *only* to capture whatever's arriving at
  BlackHole.
- **Engine B** (`engineB`) — output only. Its graph is `playerNode → eqNode → mainMixerNode
  → outputNode`, pointed at your real hardware device.

They're bridged manually, in software, via a ring buffer — not by any engine-level connection.
That bridge is where the "clock drift" problem actually gets handled (Step 4).

### Pinning an engine to a specific hardware device

Both `AVAudioEngine`s default to whatever the *system* default input/output device is. That's
not good enough here — Engine A needs BlackHole specifically (regardless of what's currently
the system default), and Engine B needs your *chosen real device* specifically (even though
the system default is now BlackHole, from Step 1). The trick, in `setCurrentDevice(_:on:)`:

```swift
AudioUnitSetProperty(
    audioUnit,
    kAudioOutputUnitProperty_CurrentDevice,
    kAudioUnitScope_Global, 0,
    &deviceID, UInt32(MemoryLayout<AudioDeviceID>.size)
)
```

Every `AVAudioEngine` node that talks to hardware (`inputNode`, `outputNode`) is backed by a
legacy `AudioUnit` (an "AUHAL" unit) under the hood, reachable via `.audioUnit`. Setting
`kAudioOutputUnitProperty_CurrentDevice` on that unit — despite the "output" in the name, it
applies to input units too — is how you tell it "talk to *this* device, not whatever's
default." This has to happen **before** `engine.prepare()`/`engine.start()`; setting it on a
running engine doesn't take effect.

## Step 3: capturing from BlackHole and converting

`startEngineA` sets Engine A's input device to BlackHole, then:

```swift
let inputFormat = input.inputFormat(forBus: 0)   // read AFTER setting the device
converter = AVAudioConverter(from: inputFormat, to: bridgeFormat)
input.installTap(onBus: 0, bufferSize: 2048, format: inputFormat) { buffer, _ in
    self?.handleCapturedBuffer(buffer)
}
```

`inputFormat` has to be read *after* binding the device, because it reflects BlackHole's
native sample rate/channel layout, which may not match our internal "bridge format" (fixed
at 48kHz stereo Float32, non-interleaved — the format Engine B's graph is built around).
`AVAudioConverter` handles that mismatch once, up front, rather than assuming they always
match.

Every ~2048 frames, `installTap`'s callback fires with a raw buffer from BlackHole.
`handleCapturedBuffer` runs it through the converter, then `writeInterleavedToRing`
deinterleaves-then-reinterleaves it (`AVAudioPCMBuffer` stores channels as separate planar
arrays; `RingBuffer` stores one flat interleaved array for simplicity) into `ringBuffer`.

This all happens on the realtime audio thread — no allocations beyond the per-callback
`AVAudioPCMBuffer`, no blocking calls, just a lock around a plain array copy.

## Step 4: the ring buffer — bridging two clocks that disagree

This is the actual interesting algorithm, in `RingBuffer.swift`. Two independent clocks
means the producer (Engine A's tap, running on BlackHole's virtual clock) and the consumer
(Engine B's drain timer, running on your real hardware's clock) will *never* produce and
consume at exactly the same rate. Over time, one will outpace the other. Left unhandled,
that's either unbounded growing latency or hard audio glitches.

`RingBuffer` is a fixed-capacity circular buffer (~400ms of audio) with two safety valves:

- **Producer runs ahead (`write`)**: if a write would push the buffer past 80% full (the
  "high watermark"), the *oldest* samples are dropped to make room — not the new ones.
  This trades a tiny, usually inaudible skip for keeping latency bounded instead of growing
  forever.
- **Consumer runs ahead (`read`)**: if there isn't enough data to satisfy a read, the
  shortfall is padded with silence rather than blocking or returning a short buffer. A
  silent gap is far less jarring than a glitch or a stall.

```swift
if availableFramesCount + framesToWrite > highWatermarkFrames {
    let overflow = (availableFramesCount + framesToWrite) - highWatermarkFrames
    availableFramesCount = max(0, availableFramesCount - overflow)   // drop oldest
}
...
if framesToRead < frameCount {
    // pad remainder with silence
}
```

This is a deliberately simple compromise, not a full adaptive resampler/PLL — the plan
document calls this out explicitly as a known limitation. A production-grade version would
measure the actual drift rate and apply micro sample-rate adjustments; this version just
bounds the damage.

`reset()` clears the buffer's indices/count — called at the start of every `enableEQMode`
so a fresh session doesn't play stale audio left over from a previous one.

## Step 5: the EQ itself and playback

Engine B's graph (`player → eqNode → mainMixerNode → outputNode`) is built once, in `init`,
and never torn down:

```swift
eqNode = AVAudioUnitEQ(numberOfBands: EQBands.count)   // 10 bands
```

`configureEQBands` sets each band to `.parametric`, centered at the ISO frequencies defined
in `EQBand.swift` (32Hz…16kHz), with a fixed bandwidth (`0.8` octaves — chosen empirically as
a reasonable tradeoff between distinct-sounding bands and excessive overlap) and gain in
`[-12, +12]` dB.

A `DispatchSourceTimer` (`drainTimer`) fires every 20ms and calls `drainRingBufferToPlayer`,
which pulls one 20ms chunk out of the ring buffer, deinterleaves it into a fresh
`AVAudioPCMBuffer`, and calls `playerNode.scheduleBuffer(_:)`. That buffer flows through the
already-connected `eqNode` and out to your real hardware device.

Slider changes don't require restarting anything: `AVAudioUnitEQ.bands[i].gain` is safe to
mutate on a running engine (`applyGains`, wired to `AppState.$bandGains` via Combine) —
Apple's audio units support live parameter automation without glitching.

## Step 6: making it safe to turn off

Because Step 1 hijacked the *system-wide* default output device, leaving that in place if
the app crashes or is force-quit would leave the user with silent audio system-wide. Two
layers guard against that:

1. `disableEQMode()` restores `savedOriginalOutputDeviceID` — called both from the UI
   toggle and from `AppDelegate.applicationWillTerminate`.
2. A `SIGTERM` handler (`installTerminationSignalHandlers` in `AppDelegate.swift`) calls the
   same restore path — because a force-quit or logout doesn't always route through
   `applicationWillTerminate` cleanly.

## Why persistent engines, not fresh ones per toggle

An earlier version of this code created a brand-new `AVAudioEngine()` on every single
"Enable EQ" toggle. That turned out to be unreliable: Core Audio doesn't always release a
HAL device binding from a just-stopped engine instance fast enough before a second, freshly
created engine tries to claim the *same* device — so the second `enable` would report no
error, but produce no audio. The current version creates both engines exactly once (in
`EQEngineController.init`) and only ever stops/reconfigures/restarts the same instances.
(As of this writing, re-enabling after a disable is still being debugged further — see the
README's "Known limitations" section.)

## Glossary of the non-obvious API calls

| Call | Why it's here |
|---|---|
| `kAudioHardwarePropertyDefaultOutputDevice` | Read/write the system-wide default output device — the whole "make everything route through BlackHole" trick. |
| `kAudioOutputUnitProperty_CurrentDevice` | Pin a specific `AVAudioEngine` node to a specific hardware device, overriding the system default. |
| `AVAudioConverter` | Reconcile BlackHole's native format with the fixed 48kHz/stereo/Float32 "bridge format" the EQ graph expects. |
| Ring buffer watermarks | Bound latency/glitches from two independently-clocked engines without a full resampler. |
| `AVAudioUnitEQ.bands[i].gain` live mutation | Slider changes apply instantly with no engine restart. |
