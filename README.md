# Commander Tabbington

<img src="art/tabbington.png" align="right" width="180" alt="Tabbington" />

Commander Tabbington (just Tabbington is preferred, or El Commanderino if you're not into the whole brevity thing...) is a lightweight macOS app/window switcher that shows a non-activating overlay with a grid of apps or windows and lets you cycle selection from the keyboard. It favors speed, predictability, and minimal visual noise over thumbnails or live previews.

### Project Status
This is exceptionally early-stage software. I built it for personal use and am sharing it in case others find it helpful - expect rough edges. It's also vibe coded up one side and down the other. I know neither Swift nor Cocoa - although I do know about a half dozen other languages and frameworks, so it's not as if I'm flying blind. I'm much more of a debugger than a developer in this case, though.

## Features
- Fast, keyboard-driven switching with a non-activating overlay (doesn't steal focus).
- App grid view (one icon per app), with an optional per-window mode.
- Deterministic MRU ordering for predictable cycling.
- Preference-driven inclusion/exclusion of hidden and/or minimized apps.

## Why Another Switcher?
I wanted something that's:
- Open source.
- Minimal (no thumbnails, no live previews).
- Decluttered - segregates hidden and minimized apps.

I've found [AltTab](https://alt-tab-macos.netlify.app) to be too buggy for consistent use, and [Contexts](https://contexts.co) lacks a per-app mode and is commercial. [Witch](https://manytricks.com/witch/) has this weird `.prefPane` thing going, and also didn't provide the modes or configurability that I wanted. But of course your mileage may vary - Tabbington may be just as bad for you as the alternatives were for me!

## Design Goals
- Reduce visual clutter and improve responsiveness.
- No thumbnails; prefer one icon per app (with optional per-window mode).
- Segregate or omit hidden and/or minimized apps based on preferences.
- Keep the overlay non-activating so it does not steal focus.
- Maintain deterministic MRU ordering for quick switching.

## How It Works (High Level)
- Enumerates windows/apps via CoreGraphics and Accessibility.
- Renders a SwiftUI grid inside a borderless, non-activating `NSPanel`.
- Keyboard input cycles selection; focus/activation happens only on commit.
- Supports per-app and per-window modes in Preferences.

## Requirements
- macOS 12.0 or later.
- Accessibility permission (see below).
- Xcode (recent version recommended).

## Permissions
Commander Tabbington requires **Accessibility** permission to enumerate and focus other apps/windows.

To enable it:
1. Open **System Settings** → **Privacy & Security** → **Accessibility**
2. Add/enable **Commander Tabbington**
3. Quit and relaunch the app (if it's already running)

On some systems, Input Monitoring may still be required for global shortcut capture; if event taps fail, the app will prompt you to grant it.

## Build and Run
- Open `CommanderTabbington.xcodeproj` in Xcode.
- Select the `CommanderTabbington` target.
- Use your local signing setup to run on your machine.
- Build and run as usual from Xcode.

## Art Assets
The `art/` directory contains optional artwork you can use for highlights or branding (not required to build or run the app).

## Contributing
Issues and PRs are welcome. I may handle contributions somewhat ad hoc due to limited maintainer bandwidth; if you have a bugfix or improvement, a short, focused PR description is appreciated.

## Known Limitations
This has literally only been tested in my own environment. I'll improve compatibility and edge cases as time allows.

## Contact
Preferred: GitHub issues. Backup: `chuttenh@gmail.com`.

## License
MIT. See `LICENSE`.
