# GraphicEQ for Mac

A simple, system-wide graphic equalizer for macOS. It shapes *all* audio leaving your Mac —
not just one app — using a 10-band EQ, and lives in the menu bar.

macOS has no public API to intercept "all system audio" directly, so this app uses the same
trick as apps like eqMac and Boom3D: route system audio through a virtual loopback driver
([BlackHole](https://github.com/ExistentialAudio/BlackHole)), process it, and re-emit it to
your real speakers/headphones. See `CODE_WALKTHROUGH.md` for the full technical explanation.

## Requirements

- macOS 13+
- [Homebrew](https://brew.sh)
- Xcode command line tools (for `swift build`)

## Setup

1. **Install BlackHole** (one-time, needs your admin password — run it yourself in a real
   Terminal window, not through an automated tool, since `sudo` needs an interactive prompt):

   ```
   ./setup_blackhole.sh
   ```

   Afterwards, confirm "BlackHole 2ch" appears in System Settings → Sound → Output. If it
   doesn't, a reboot may be required (Homebrew's cask caveat says so explicitly).

2. **Build the app**:

   ```
   ./build_app.sh
   ```

   This produces `GraphicEQ.app`, ad-hoc codesigned so microphone-permission (TCC) checks
   work correctly.

3. **Launch it**:

   ```
   open GraphicEQ.app
   ```

   First launch requires right-click → Open to bypass Gatekeeper (the app is unsigned/
   unnotarized — fine for personal local use, not for distribution).

## Using it

- Click the slider icon in the menu bar to open the popover.
- Pick your real output device (speakers/headphones) from the picker.
- Toggle **Enable EQ** on. macOS will prompt for microphone-style permission the first time
  (see "Why does it need microphone access?" below) — approve it.
- Drag the 10 band sliders (32Hz–16kHz) to shape the sound. Changes apply live.
- Toggle **Enable EQ** off, or click **Quit**, to fully restore your original output device.

### Why does it need microphone access?

It doesn't touch your actual microphone. macOS's privacy system (TCC) gates *any* Core Audio
input capture — including from a virtual loopback device like BlackHole — behind the same
microphone permission category. There's no way around this; it's how the OS is designed.

## Development

```
swift build              # iterate quickly (debug build, runs from .build/debug/GraphicEQ)
swift run                # build + run in one step
./build_app.sh           # release build + assemble/codesign GraphicEQ.app for real use
```

Project layout:

```
Package.swift
setup_blackhole.sh        # one-time BlackHole install (user-run)
build_app.sh               # release build + .app bundle assembly + codesign
Resources/Info.plist
Sources/GraphicEQ/
    main.swift                  # NSApplication bootstrap
    AppDelegate.swift            # status item, popover, lifecycle
    AudioDeviceManager.swift     # CoreAudio device enumeration/default-output get-set
    EQEngineController.swift     # the two AVAudioEngines + bridge (the core algorithm)
    RingBuffer.swift             # thread-safe circular buffer bridging the two engines
    EQBand.swift                 # ISO band frequency definitions
    AppState.swift               # observable UI state + persistence
    StatusBarPopoverView.swift   # SwiftUI popover UI
    EQSliderView.swift           # one vertical EQ slider
```

## Known limitations

- Minor clock-drift artifacts (occasional clicks/micro-gaps) are possible over long sessions,
  since BlackHole and your real output device aren't clock-locked — mitigated with a
  watermark ring buffer, not a full adaptive resampler.
- One real output device at a time (no simultaneous multi-output mixing).
- Requires the one-time manual `./setup_blackhole.sh` before first use.
- Ad-hoc signed only — for personal local use, not distribution.
- Affects all system audio uniformly; no per-app EQ or bypass.
- **Known open issue**: re-enabling EQ after disabling it doesn't reliably work yet
  (currently being debugged — see git history / open issues for status).

## Uninstalling

```
brew uninstall blackhole-2ch
rm -rf GraphicEQ.app
```
