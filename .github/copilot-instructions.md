# AltierTabbier AI Coding Instructions

## Project Overview
AltierTabbier is a macOS menu bar application that provides an alternative window switcher (like Alt+Tab) using SwiftUI and AppKit. It uses Accessibility APIs to enumerate and focus windows, with a glassmorphic overlay UI.

## Architecture
- **Hybrid AppKit/SwiftUI**: AppDelegate manages lifecycle and global state; SwiftUI handles UI with `@EnvironmentObject` injection.
- **Central State**: `AppState` (ObservableObject) drives all UI updates and coordinates between services.
- **Services Pattern**: Singleton services handle specific domains:
  - `WindowManager`: Fetches windows via CGWindowList, filters out system noise.
  - `AccessibilityService`: Focuses windows using AXUIElement APIs.
  - `InputListener`: Captures global Cmd+Tab via CGEventTap.
- **Data Flow**: Services → AppState → SwiftUI views react automatically.

## Key Patterns
- **Window Filtering**: Exclude layer != 0, alpha < 0.01, tiny sizes, and ignored apps (Dock, Window Server, etc.) in `WindowManager.shouldInclude()`.
- **Accessibility Bridge**: Use AXUIElementCreateApplication + AXWindowsAttribute to find windows by CGWindowID via "AXWindowID" attribute.
- **Event Tap Lifecycle**: Store CFMachPort and CFRunLoopSource; handle tap disable/re-enable in callback.
- **Async Thumbnails**: Use `.task` modifier in `WindowCardView` to load previews via `SCScreenshotManager` (macOS 14+).
- **Overlay UI**: NSPanel with `.nonactivatingPanel` to avoid stealing focus; `VisualEffectView` for glass background.
- **Auto-scroll**: `ScrollViewReader` with `.onChange(of: selectedIndex)` for smooth centering.

## Development Workflow
- **Build**: Standard Xcode project; requires Accessibility entitlements in Signing & Capabilities.
- **Permissions**: Check `AXIsProcessTrusted()` on launch; prompt with `AXTrustedCheckOptionPrompt`.
- **Debugging**: Extensive `print()` statements for event flow; test event tap with mouse clicks.
- **Hotkey Handling**: Suppress Cmd+Tab events by returning `nil` from callback; commit on Cmd release.

## Conventions
- Singleton services accessed via `.shared`.
- Extensive inline comments explaining API choices and "why" decisions.
- `SystemWindow` uses `CGWindowID` as Identifiable id.
- UI constants defined as `let` in views (e.g., `itemWidth: 160`).
- Preferences via `@AppStorage` in `PreferencesView`.

## Common Pitfalls
- CGEventTap requires Input Monitoring permission (separate from Accessibility).
- AXUIElement operations are slow; avoid in hot paths.
- SCK screenshots async-only; use `await` in `.task`.
- NSPanel sizing set in AppDelegate, not SwiftUI frame.