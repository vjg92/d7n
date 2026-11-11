# d7n (dictation) — private hold-to-talk dictation

First working prototype for Apple Silicon Macs running macOS 26 or newer.
Built using Apple's on-device SpeechTranscriber/SpeechAnalyzer, with no third-party dependencies.

## Install

1. Drag `d7n.app` into your Applications folder **before first launch**.
2. Open d7n. It shows setup once; there is no Dock icon or menu-bar item.
3. In Keyboard settings, set **Press Globe key to → Do Nothing**. Remove any Fn/Globe shortcut for Apple Dictation and disable Wispr Flow's Fn shortcut.
4. Click **Prepare / Retry**. Allow Microphone, Accessibility and Input Monitoring when requested. After changing permissions, click Retry; if macOS requires it, quit and reopen the app.
5. Wait for **Ready**. The initial Apple speech-model download may need an internet connection. The app requests launch at login after successful setup; approve this in macOS Login Items if requested.
6. Close setup, focus a text field, hold Fn and speak, then release Fn. Transcription happens locally after release.

Reopening d7n.app shows setup/status/quit controls. Closing setup keeps the app running. To stop autostart, click **Disable Login Launch** before quitting, or use macOS Login Items.

This development build is locally ad-hoc signed, not Developer ID signed or notarized. Build from the included source if you prefer. Permission grants may need refreshing after rebuilding because the signing identity is not stable across versions.

## Behaviour and privacy

- No recording overlay, sounds, notifications, Dock icon or menu-bar item.
- macOS still displays its own microphone privacy indicator.
- Audio capture is active only during the Fn hold (plus normal device stop latency).
- Audio buffers are held in memory, never deliberately written to files by this app; macOS manages memory/swap independently.
- No transcript history, analytics SDK, cloud transcription fallback or app-authored network requests. Apple's system service downloads/manages speech models.
- Text is inserted using Accessibility, with Unicode keyboard events as fallback. No clipboard reads or writes.
- Fn plus another key cancels recording, allowing normal Fn keyboard shortcuts to pass through.
- Clicking, typing or changing foreground apps cancels pending dictation. Focus is checked again before insertion. Protected password fields are excluded.
- Recording is capped at two minutes. Sleep/session deactivation cancels it. A watchdog stops capture if the Fn release event is lost. Processing times out after 45 seconds.
- Presses during transcription are ignored; wait for text insertion before the next hold.
- No automatic sentence rewriting or generative cleanup.

## Current limitations

- Live microphone, Fn hardware behaviour, target-app insertion, offline transcription and login startup require verification on the installed app with permissions granted. These have not yet been verified end to end.
- Global event access may require quitting/reopening after approval.
- Some editors do not support AX selection replacement or Unicode event insertion. This prototype intentionally has no clipboard fallback.
- There is no audible/visible ready/error signal during normal use. Reopen the app to see the most recent status.
- The initial microphone start has hardware latency; pause briefly after pressing Fn before speaking.
- This is a prototype, not yet a replacement validated across all your apps.

## Build and test

Requires Xcode with Swift 6.2 or newer and the macOS 26 SDK.

```sh
cd Source
bash build.sh
swift test
```

Output: `dist/d7n.app`.

The builder can accept `SWIFT_BUILD_FLAGS=--disable-sandbox` in environments that cannot run SwiftPM's nested sandbox. This is a build-tool option only, not an app permission change.

Source files:

- `App.swift`: setup, login item, event monitor and lifecycle.
- `HoldState.swift`: physical Fn state machine.
- `Audio.swift`: bounded memory recording, conversion and local transcription.
- `Insertion.swift`: focus checking and clipboard-free insertion.
- `Info.plist`: hidden-app and permission declarations.

Tests cover hold/release deduplication, cancellation, modifier chords, arrow-key false positives, sleep reset, audio buffer ownership and recording bounds.
