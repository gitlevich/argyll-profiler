# ArgyllKit engine notes

The process layer for a native macOS front end to ArgyllCMS. Three files:

`PTYProcess.swift` spawns a tool on a pseudo-terminal via `posix_spawn` + `openpty`. A pty, not a pipe, because libc line-buffers stdout only for a terminal (otherwise progress arrives in 4 KB bursts), and because Argyll reads its "hit any key" answers in raw mode, which needs a tty.

`ArgyllRunner.swift` runs one tool and parses its output into `ArgyllEvent`s: `.line`, `.progress(done:total:)`, `.prompt(.placeOnWhiteTile | .placeOnDisplay | .other)`, `.error`, `.exited`. Prompts have no line terminator, so the parser matches the unterminated tail on every chunk. `Argyll.displays()` and `Argyll.instruments()` parse `dispwin -?` and `spotread -?` for the display and instrument lists.

`ProfilingSession.swift` is an actor running targen → (dispcal) → dispread → colprof → dispwin in a working directory, forwarding `(Stage, ArgyllEvent)` and routing `answerPrompt()` to whichever tool is waiting.

## Prerequisites

`brew install argyll-cms`. Do not sandbox the app: Argyll talks to the i1Pro 2 through its own libusb and needs raw USB access.

## Usage

```swift
let displays = try await Argyll.displays()       // pick the Studio Display's index
let instruments = try await Argyll.instruments() // the i1Pro 2's port

var options = ProfilingOptions(displayIndex: 2, instrumentPort: 1, profileName: "StudioDisplay_2026-09-28")
options.patchCount = 400
options.calibration = nil          // profile as-is; the display stays in its Apple preset
options.patchServerPort = 8080     // optional: render patches yourself in a WKWebView

let session = ProfilingSession(options: options, directory: workDir)

Task {
    for await (stage, event) in session.events {
        switch event {
        case .prompt(.placeOnWhiteTile):
            // Sheet: "Put the i1Pro 2 on its white tile", button calls session.answerPrompt()
        case .prompt(.placeOnDisplay):
            // Sheet: "Now place it on the patch window", same button
        case .progress(let done, let total):
            // update a ProgressView; stage tells you which step you're in
        case .error(let message):
            // surface it; the session throws at the end of the stage anyway
        default:
            break
        }
    }
}

let profile = try await session.run()
```

With `patchServerPort` set, open a borderless `NSWindow` at level `.screenSaver` covering the target `NSScreen`, put a `WKWebView` in it pointing at `http://localhost:8080`, and close it when `dispread` exits. Without it, Argyll draws its own patch window on display `displayIndex`.

## Notes

The i1Pro 2 self-calibrates on its white tile at the start of every tool that measures, so expect `.placeOnWhiteTile` from `dispcal`, `dispread` and `spotread` each. It may ask again mid-run after a long session; the same handler covers it.

Argyll also supports `ARGYLL_NOT_INTERACTIVE=1`, which makes prompts read a full line instead of a raw key. That does not remove the need for the pty (buffering), so the runner uses raw keys. If you ever see a prompt the parser classifies as `.other`, add its wording to the patterns in `ArgyllOutputParser`.

`colprof -as` builds a shaper/matrix profile. Keep it that way on macOS 14+: LUT-based display profiles are the ones ColorSync stopped honouring.

## Before trusting the parser

Run `spotread -?` and one real `dispread` in Terminal with the instrument attached and check the exact wording of the tile and display prompts against the regexes in `ArgyllOutputParser`. The `.other` case catches anything that doesn't match without breaking the flow.


## Releasing

Locally: `Scripts/release.sh` builds the app with ArgyllCMS bundled from Homebrew, signs
it with the Developer ID certificate in your keychain, notarizes it, staples the ticket
and produces `.build/Argyll-Profiler-<version>.dmg`.

On GitHub: push a tag `vX.Y` and `.github/workflows/release.yml` does the same on an
Apple silicon runner and attaches the DMG to a GitHub Release. Nothing runs on ordinary
pushes; only tags use Actions minutes. It needs these repository
secrets (Settings > Secrets and variables > Actions):

- `MACOS_CERTIFICATE_P12` — your "Developer ID Application" certificate with its private
  key, exported from Keychain Access as .p12 and base64-encoded: `base64 -i cert.p12 | pbcopy`
- `MACOS_CERTIFICATE_PASSWORD` — the password you set when exporting the .p12
- `KEYCHAIN_PASSWORD` — any string; protects the temporary keychain on the runner
- `APPLE_ID` — the Apple ID of the developer account
- `APPLE_APP_PASSWORD` — an app-specific password for that account
- `APPLE_TEAM_ID` — the ten-character team ID on the certificate

The version in `Resources/Info.plist` is overwritten from the tag, so tag from `main` and
don't bump it by hand.
