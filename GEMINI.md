My apologies—I completely misunderstood the intent. I treated the request as a "context dump" for a code parser rather than a **project knowledge base** for an AI agent.

Here is the correct `GEMINI.md`. This file is designed to give you (and any AI assistant) a high-level understanding of the architecture, the specific system-level hacks we used, and the known "gotchas" regarding macOS permissions.

---

# GEMINI.md

## Project Overview

**AltierTabbier** is a native macOS utility designed to replace the system default Application Switcher (`Cmd+Tab`). It is built using **Swift 5** and **SwiftUI**, relying heavily on low-level C-APIs (`CoreGraphics`, `ApplicationServices`) to intercept global keyboard events and manipulate window focus.

* **Type:** Agent Application (`LSUIElement = YES`)
* **Minimum OS:** macOS 14.0 (Due to `ScreenCaptureKit` usage)
* **Sandboxing:** **MUST BE DISABLED** (Required for `CGEventTap` and `AXUIElement`)

---

## Architecture

The project follows a **Service-Oriented Architecture** to separate clean SwiftUI views from "unsafe" system APIs.

### 1. The Core Loop (`AppState`)

* **Role:** Single Source of Truth (`ObservableObject`).
* **Behavior:**
* Listens for `InputListener` events.
* Queries `WindowManager` to populate `visibleWindows`.
* Maintains the `selectedIndex`.
* Triggers `AccessibilityService` to switch focus upon commit.



### 2. System Services (The Engine)

* **`InputListener`**: Wraps `CGEvent.tapCreate`. It installs a `.headInsertEventTap` at the `.cgSessionEventTap` level to intercept `Cmd+Tab` before the Dock sees it.
* *Critical Note:* Uses an "Auto-Revive" mechanism to restart the tap if macOS disables it due to timeouts.


* **`WindowManager`**: Hybrid approach for performance.
* **Synchronous:** Uses `CGWindowListCopyWindowInfo` to fetch window metadata (ID, Frame, Title) instantly.
* **Asynchronous:** Uses `ScreenCaptureKit` (SCK) to fetch high-res thumbnails lazily.


* **`AccessibilityService`**: Wraps `AXUIElement` C-APIs.
* Bridges `CGWindowID` (Graphics) to `AXUIElement` (Accessibility) to perform the "Raise" and "Focus" actions.



### 3. UI Layer

* **Overlay Window:** Managed manually in `AppDelegate` via an `NSPanel`. It uses `.nonactivatingPanel` style mask to float above other apps without stealing focus (which would break the switcher logic).
* **Views:** Pure SwiftUI. `WindowCardView` handles its own async image loading via `.task`.

---

## Directory Structure

```text
Sources/
├── App/
│   ├── AltierTabbierApp.swift  // Entry point (Empty Settings scene)
│   ├── AppDelegate.swift       // Lifecycle, Menu Bar, Window Management
│   └── AppState.swift          // Global State & Logic
├── Models/
│   └── SystemWindow.swift      // Identifiable Struct for Window Data
├── Services/
│   ├── WindowManager.swift     // CGWindowList + ScreenCaptureKit
│   ├── InputListener.swift     // CGEventTap (Keyboard Hooks)
│   └── AccessibilityService.swift // AXUIElement (Focus Control)
└── UI/
    ├── Overlay/
    │   ├── SwitcherView.swift  // Main Horizontal ScrollView
    │   └── WindowCardView.swift // Individual Thumbnail Cell
    └── Settings/
        └── PreferencesView.swift // Config Screen

```

---

## Development Workflow & conventions

### 1. Build Configuration

* **Target:** Native macOS (Not Catalyst/iPad).
* **Signing:** "App Sandbox" must be **OFF** in entitlements.
* **Permissions:** Requires **Accessibility** (`tccutil reset Accessibility` often needed during dev).

### 2. Coding Conventions

* **Concurrency:** Use `async/await` for image fetching; keep the main event loop synchronous.
* **C-Interop:** All `UnsafePointer` or `CFRef` code must be isolated inside the `Services/` folder. The UI should never import `CoreGraphics` or `ApplicationServices` directly if possible.
* **Window Management:** Do not use SwiftUI's `WindowGroup`. All windows are `NSPanel` or `NSWindow` created programmatically in `AppDelegate` to ensure specific behaviors (floating, non-activating).

---

## Troubleshooting Guide (The "Silent Failure" Checks)

If `Cmd+Tab` stops working, consult this checklist:

1. **The Zombie Permission:**
* *Symptom:* App runs, logs "Tap Created", but ignores keys.
* *Fix:* Run `tccutil reset Accessibility` in Terminal and rebuild.


2. **Secure Input Lockout:**
* *Symptom:* App is silent; `ioreg -l -w 0 | grep SecureInput` returns a PID.
* *Fix:* Close the app holding Secure Input (often Terminal or a password manager).


3. **The Debugger Curse:**
* *Symptom:* App works for mouse clicks but ignores keyboard when running from Xcode.
* *Fix:* Archive/Build the app and launch it directly from **Finder**, or add the app to **Input Monitoring** permissions.


4. **Dock Conflict:**
* *Symptom:* App detects "A" key but not "Cmd+Tab".
* *Fix:* Run `killall Dock` to force the Dock to re-register its hotkeys *after* your app has started.
