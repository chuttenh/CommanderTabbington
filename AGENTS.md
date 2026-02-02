// AI_CONTEXT — Commander Tabbington

// Last updated: 2026-01-16

// This document is the authoritative context for AI coding assistants working on this repository in Xcode. It summarizes the project’s purpose, goals, conventions, and code organization, and provides concrete guidance for how an assistant should propose and apply changes.

// It supersedes any content in older files like GEMINI.md or copilot-instructions.md if those exist and disagree with this document.

When a major feature or algorithmic change is implemented, update this file with the new information.

## Project purpose
Commander Tabbington is a lightweight macOS app/window switcher. It displays a non-activating overlay with a grid of running apps (Per App mode) or individual windows (Per Window mode), lets the user cycle selection via the keyboard, and then focuses the chosen app/window. It aims to be fast, predictable, and respectful of the user’s current focus.


## High-level goals
- Fast and stable: Never block the UI thread; avoid flicker when opening the overlay.
- Non-disruptive: Overlay must not steal focus while visible; focus changes only occur on commit.
- Predictable ordering: Sort by MRU (most-recently-used), with sensible tie-breakers and active-first behavior.
- Two modes: Per App and Per Window, switchable in Preferences.
- Minimal dependencies: Use Apple frameworks (AppKit, SwiftUI, CoreGraphics, Accessibility) and keep the footprint small.
- Respect user preferences: Hidden/minimized/no-window inclusion, badges, layout sizing, and open delay.

Non-goals (for now):
- Full window thumbnails or live previews (ScreenCaptureKit is imported but not used yet).
- Launch-at-login setup (UI placeholder exists but is disabled).


## Architecture and data flow
- Entry point: `CommanderTabbingtonApp` delegates to `AppDelegate` for lifecycle and UI orchestration.
- Input: A keyboard listener (see “Referenced components” below) detects the hotkey sequence and calls `AppState.handleUserActivation`.
- Input robustness: InputListener includes a command-release watchdog and tap-disabled bailout to avoid stuck overlays during event-loop stalls.
- State: `AppState` is the single source of truth for overlay visibility, mode, lists, and selection index. It defers overlay appearance by a configurable delay to avoid flicker on quick taps.
- Startup ordering: first activation waits for `AppRecents.ensureSeeded` and `WindowRecents.ensureSeeded` before showing the overlay to avoid MRU races.
- Enumeration: `WindowManager` builds lists of `SystemWindow` and `SystemApp` using Core Graphics (`CGWindowListCopyWindowInfo`) and augments with Accessibility for hidden/minimized windows when preferences allow.
- Enumeration is executed off the main thread and published back to the UI thread; immediately after wake, `WindowManager` skips AX merges/summaries for a short grace period to avoid post-sleep stalls.
- Ordering: `AppRecents` and `WindowRecents` maintain MRU lists and provide sort helpers. When MRU is missing, they derive a best-effort ordering from WindowServer z-order lists.
- UI: `SwitcherView` (SwiftUI) renders a grid of `AppCardView` items inside a glassy background, embedded in a borderless, non-activating `NSPanel` created by `AppDelegate`.
- Commit: On key release, `AppState.commitSelection` hides the overlay and triggers `AccessibilityService` to activate the selected app or focus the specific window.
- Sync: `AppDelegate` observes NSWorkspace notifications (launch, terminate, hide/unhide, activate) and preferences changes to refresh lists and recompute overlay size when relevant.


## File map and responsibilities
- `CommanderTabbingtonApp.swift`: SwiftUI `@main` entry. Bridges to `AppDelegate`.
- `AppDelegate.swift`: Lifecycle, single-instance enforcement, status bar menu, overlay `NSPanel` creation, size computations, observers (NSWorkspace + UserDefaults), and Preferences window.
- `AppState.swift`: Observable state for overlay visibility, mode (Per App vs Per Window), visible items, selection, delayed open, and commit/cancel logic.
- `WindowManager.swift`: Enumerates windows and apps, filters out system/ghost windows, merges Accessibility-derived data if allowed, builds `SystemWindow`/`SystemApp`, and sorts via Recents helpers.
- `SystemWindow.swift`: Value-type model for a window with identity (`CGWindowID`), metadata, visuals, and hashing.
- `SystemApp.swift`: Value-type model for an app keyed by `ownerPID`, with metadata and optional badge count.
- `AppRecents.swift`: Tracks MRU order of apps (PIDs), seeds from current z-order, and provides sort helper (`sortAppsByRecency`).
- `WindowRecents.swift`: Tracks MRU order of windows (CGWindowID), seeds from current z-order, and provides sort helper (`sortWindowsByRecency`).
- `AccessibilityService.swift`: Bridges to the Accessibility API to focus a specific window or bring an app’s windows to the front reliably.
- `SwitcherView.swift`: SwiftUI overlay; glass background; grid layout; selection scroll-to-center.
- `SwitcherLayout.swift`: Shared layout constants used by `SwitcherView` and overlay sizing.
- `AppCardView.swift`: Renders an app icon, name, optional subtitle (window title), and notification badge.
- `PreferencesView.swift`: UI for the main preferences (mode, layout, inclusion toggles, badges, and overlay open delay).

Referenced components (expected in the project even if not shown above):
- `InputListener`: Hooks key events and forwards to `AppState.handleUserActivation(direction:)` and commit/cancel.
- `FocusMonitor`: Observes frontmost app/window transitions and updates MRU recency.
- `DockBadgeService`: Provides per-app badge counts used by `AppCardView`.


## Key UI and behavior constraints
- Overlay window must be a borderless, non-activating `NSPanel` at `.statusBar` level with `.canJoinAllSpaces` and `.fullScreenAuxiliary`. It should be transparent and ignore mouse events while visible; SwiftUI handles content.
- Sizing algorithm prefers width first, then uses up to a user-configurable number of rows, then falls back to vertical scrolling. See `AppDelegate.updateOverlaySize()`.
- Selection defaults to index 1 when possible (to make quick tap-and-release return to the second-most-recent item), otherwise 0.
- Sorting rules:
  - Apps: active-first; then MRU rank; then localized case-insensitive app name.
  - Windows: MRU rank; then original array order; then app name; then window title.
  - Startup fallback: when MRU is missing, derive order from window lists—first on-screen, then the full list (best-effort).
- Visibility preferences: hidden/minimized exclusions do not apply to the active app, so it always remains selectable.
- Filtering rules (WindowManager.shouldInclude): layer 0 only, alpha >= 0.01, minimum size ~50x50, ignore known system apps (“Dock”, “Window Server”, “Control Center”, “Notification Center”, and this app).


## Preferences and defaults (UserDefaults keys)
- `perAppMode: Bool` — true = Per App, false = Per Window (default: true)
- `showNotificationBadges: Bool` — show per-app badges (default: true)
- `HiddenAppsPlacement: Int` — normal / at-end / exclude hidden apps (default: normal)
- `MinimizedAppsPlacement: Int` — normal / at-end / exclude minimized windows/apps (default: normal)
- `NoWindowAppsPlacement: Int` — normal / at-end / exclude apps with no windows (default: at-end)
- `maxWidthFraction: Double` — max overlay width as a fraction of screen width (default: 0.9)
- `maxVisibleRows: Int` — maximum rows before enabling vertical scroll (default: 2)
- `showDesktopWindows: Bool` — placeholder toggle (not fully wired)
- `switcherOpenDelayMS: Int` — delay before overlay becomes visible (default: 100)


## Coding conventions
- Language and frameworks: Swift, SwiftUI for UI, AppKit for windowing/status bar, CoreGraphics for window lists, Accessibility for activation/focus.
- Models (`SystemApp`, `SystemWindow`) are value types, `Identifiable` and `Hashable` by a single stable identifier.
- Single source of truth: `AppState` publishes everything the overlay needs; UI binds to it.
- Threading: UI updates occur on the main thread; MRU lists maintain their own serial queues.
- Logging: Use `OSLog`/`Logger` via `AppLog`; prefer consistent phrasing and include relevant IDs/names. Emoji markers are acceptable for quick scanning.
- Avoid unnecessary global state; prefer file-private helpers and singletons only where justified (e.g., `WindowManager.shared`).


## Build, run, and permissions
- macOS target: modern macOS (AppKit + SwiftUI). Accessibility permission is required to enumerate/focus other apps/windows; a custom permissions window guides the user on startup.
- Menu bar item: provides Preferences and Quit.
- Single-instance: on startup, a second instance signals the running one to open Preferences and exits.

### Permissions UX
- The app uses a custom permissions window (not the system prompt) to guide users to grant Accessibility permission.
- The window shows status, opens System Settings to the Accessibility pane, and auto-relaunches once permission is granted.
- Input Monitoring is not treated as a hard requirement; if global event taps fail, the app presents a separate Input Monitoring alert from `InputListener`.


## Common tasks and checklists

### Add a new preference
1) UI: Add a control in `PreferencesView` using `@AppStorage("YourKey")` and bind it to your state.
2) Defaults: Register a default (if necessary) early in app launch (e.g., `applicationDidFinishLaunching`).
3) Behavior: Read the preference where behavior is computed (e.g., `WindowManager`, `AppState`, or overlay sizing) and apply it.
4) Recompute: If it affects layout or lists, ensure observers trigger `updateOverlaySize()` or `refreshNow()` as needed.
5) Persistence: Keep the key naming consistent with existing keys; use clear, descriptive names.

### Change ordering/sorting rules
1) Apps: Update `AppRecents.sortAppsByRecency(_:)` and maintain the active-first rule and name tiebreaker.
2) Windows: Update `WindowRecents.sortWindowsByRecency(_:)`; preserve stable tiebreakers.
3) Seeding: If initial MRU handling changes, update the startup fallback logic in the recents sorters.
4) Validate: Exercise both Per App and Per Window modes; check quick-switch behavior and overlay selection defaults.

### Filter window noise more/less aggressively
1) Edit `WindowManager.shouldInclude(windowInfo:)` with explicit, documented criteria.
2) Ensure legitimate windows aren’t filtered out (watch for alpha, layer, and tiny utility windows).
3) Keep the ignored app list in sync with `getOpenApps()`.

### Add window thumbnails (future)
1) Use ScreenCaptureKit to request window snapshots by `CGWindowID`.
2) Ensure capture requests are asynchronous and cached; avoid blocking UI.
3) Add optional visuals in `AppCardView` behind the app icon, gated by a preference.


## How to work with ChatGPT in Xcode (assistant guidelines)
When the user asks for changes:
- Read this file first. Preserve the architecture and constraints described above.
- Make minimal, focused edits. Don’t reformat unrelated code or perform sweeping refactors unless the user explicitly requests it.
- If a change impacts both modes (Per App/Per Window), update both paths.
- Keep the overlay non-activating and avoid stealing focus; only activate/focus on commit.
- Keep MRU logic consistent and deterministic; adjust both the recency trackers and sorters if needed.
- When adding preferences, touch the three places: UI, defaults, and behavior. Ensure observers will recompute size or refresh lists.
- Use SwiftUI `#Preview` only for new views if helpful; keep previews lightweight.
- Prefer Apple frameworks already in use; avoid adding third-party dependencies.
- If you introduce a new architectural convention (e.g., moving from Combine to Swift Concurrency for a path), document it here.

Response style in Xcode:
- Start with a short summary of the requested change.
- Outline a brief plan (1–3 bullets) describing which files you’ll edit and why.
- Apply changes directly, keeping diffs small and targeted.
- After edits, summarize what changed and any follow-up steps or caveats.


## Safety and privacy considerations
- Accessibility APIs require user consent; all features depending on AX must degrade gracefully if permission is missing.
- Avoid using private APIs.
- Don’t enumerate or store more information than needed to render the switcher.


## Known limitations / TODOs
- Thumbnails/previews are not implemented.
- “Launch at Login” is present in UI but disabled.
- `showDesktopWindows` is a placeholder and not fully wired into filtering.
- Badge counts depend on `DockBadgeService` which must be present and performant; if unavailable, badge rendering should be disabled via preference.
- Accessibility permission changes require relaunch; the app auto-restarts when granted.
- Hidden/minimized ordering at startup is best-effort when no MRU history exists.


## Glossary
- CGWindowID: Identifier for a window from Core Graphics (Window Server).
- AXUIElement: Accessibility API element for interacting with apps and windows.
- MRU: Most-Recently-Used ordering; index 0 is most recent.
- Non-activating panel: An `NSPanel` that can appear without stealing focus from the current app.


## Quick references (code anchors)
- Overlay creation: `AppDelegate.setupOverlayWindow()`
- Overlay sizing: `AppDelegate.updateOverlaySize()`
- Permissions window: `AppDelegate.presentPermissionsWindow`, `AppDelegate.restartApplication`
- State transitions: `AppState.handleUserActivation`, `AppState.commitSelection`, `AppState.cancelSelection`
- Enumeration: `WindowManager.getOpenWindows()`, `WindowManager.getOpenApps()`
- Filtering: `WindowManager.shouldInclude(windowInfo:)`
- Sorting (Apps): `AppRecents.sortAppsByRecency(_:)`
- Sorting (Windows): `WindowRecents.sortWindowsByRecency(_:)`
- Focus/activation: `AccessibilityService.focus(window:)`, `AccessibilityService.bringAllWindowsToFront(for:)`


## Contributing notes
- Keep this file updated when changing high-level behavior, preferences, or architectural choices.
- Prefer small, reviewable PRs with a clear summary of user-visible changes and any permission/behavior impacts.
