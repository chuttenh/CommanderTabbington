import SwiftUI
import Combine
import Cocoa

class AppState: ObservableObject {
    
    // MARK: - Published Properties (UI Drivers)
    
    /// Controls the visibility of the switcher overlay.
    /// When true, the UI appears; when false, it vanishes.
    @Published var isSwitcherVisible: Bool = false
    
    /// The list of apps currently available to switch to.
    /// This is updated every time the switcher is invoked.
    @Published var visibleApps: [SystemApp] = []
    @Published var visibleWindows: [SystemWindow] = []
    
    enum SwitcherMode { case perApp, perWindow }
    @Published var mode: SwitcherMode = .perApp
    
    // Delayed open support
    private var pendingOpenWorkItem: DispatchWorkItem?
    
    init() {
        // Initialize mode from user defaults (default: perApp)
        let perApp = UserDefaults.standard.object(forKey: "perAppMode") as? Bool ?? true
        self.mode = perApp ? .perApp : .perWindow
    }
    
    /// The index of the currently highlighted app in the `visibleApps` array.
    @Published var selectedIndex: Int = 0
    
    // MARK: - Internal State
    
    /// A cache or handle to the previously active application,
    /// used if we need to "cancel" the switch and return to where we were.
    var previousApp: NSRunningApplication?
    
    // MARK: - Actions
    
    /// Called when the user presses the hotkey (e.g., Cmd+Tab).
    /// If the switcher is hidden, it opens it and captures the current state.
    /// If open, it cycles to the next app.
    func handleUserActivation(direction: SelectionDirection = .next) {
        if !isSwitcherVisible {
            // If no pending open, capture current state and schedule UI appearance after a small delay
            if pendingOpenWorkItem == nil {
                refreshCurrentList()
                if visibleApps.isEmpty && visibleWindows.isEmpty {
                    print("⚠️ No apps or windows available to show in switcher.")
                }
                // Preselect the second entry (index 1) by default
                let count: Int = (mode == .perApp) ? visibleApps.count : visibleWindows.count
                selectedIndex = (count > 1) ? 1 : 0

                // Schedule showing the overlay after the configured delay
                let delayMS = UserDefaults.standard.object(forKey: "switcherOpenDelayMS") as? Int ?? 100
                var workItem: DispatchWorkItem?
                workItem = DispatchWorkItem { [weak self] in
                    guard let self = self else { return }
                    // Ensure this is still the active pending item; if it was canceled or superseded, do nothing
                    guard self.pendingOpenWorkItem === workItem else { return }
                    self.isSwitcherVisible = true
                    self.pendingOpenWorkItem = nil
                    print("🔎 Switcher opened (delayed). apps=\(self.visibleApps.count) windows=\(self.visibleWindows.count) selectedIndex=\(self.selectedIndex)")
                }
                if let wi = workItem {
                    pendingOpenWorkItem = wi
                    DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(max(0, delayMS)), execute: wi)
                }
            } else {
                // Already pending; allow cycling before the UI becomes visible
                cycleSelection(direction: direction)
            }
        } else {
            // UI is visible; normal cycling
            cycleSelection(direction: direction)
        }
    }
    
    /// Moves the selection index, wrapping around the array bounds.
    func cycleSelection(direction: SelectionDirection) {
        guard !visibleApps.isEmpty || !visibleWindows.isEmpty else { return }
        let count: Int = (mode == .perApp) ? visibleApps.count : visibleWindows.count
        guard count > 0 else { return }
        
        switch direction {
        case .next:
            selectedIndex = (selectedIndex + 1) % count
        case .previous:
            selectedIndex = (selectedIndex - 1 + count) % count
        }
    }
    
    /// Called when the user releases the modifier key (Cmd).
    /// Commits the selection and hides the UI.
    func commitSelection() {
        // Diagnostics: entry log
        print("commitSelection invoked. mode=\(mode) selectedIndex=\(selectedIndex) isVisible=\(isSwitcherVisible) apps=\(visibleApps.count) windows=\(visibleWindows.count)")
        
        // Allow commit even if the UI hasn't appeared yet, as long as an open is pending
        let hadPendingOpen = (pendingOpenWorkItem != nil)
        if hadPendingOpen {
            pendingOpenWorkItem?.cancel()
            pendingOpenWorkItem = nil
        }
        
        guard isSwitcherVisible || hadPendingOpen else {
            print("⚠️ commitSelection ignored: switcher not visible and no pending open")
            return
        }
        
        if isSwitcherVisible { isSwitcherVisible = false }
        print("🫥 Hiding switcher overlay before activation")
        
        switch mode {
        case .perApp:
            guard visibleApps.indices.contains(selectedIndex) else {
                print("❌ Selection index out of range for visibleApps: index=\(selectedIndex) count=\(visibleApps.count)")
                return
            }
            let selectedApp = visibleApps[selectedIndex]
            print("Switching to app: \(selectedApp.appName) (PID: \(selectedApp.ownerPID))")

            // Prefer the stored NSRunningApplication, but fall back to resolving by PID if needed
            let targetApp = selectedApp.owningApplication ?? NSRunningApplication(processIdentifier: selectedApp.ownerPID)

            guard let app = targetApp else {
                print("❓ No NSRunningApplication for selected app; cannot activate directly")
                return
            }

            // Try high-level activation first
            let activated = app.activate(options: [.activateIgnoringOtherApps])
            if activated {
                print("✅ App activation requested successfully")
            } else {
                print("⚠️ App activation returned false; attempting AX-based bring-to-front fallback")
            }

            // Use AccessibilityService to ensure the app is unhidden and all windows are raised/focused.
            AccessibilityService.shared.bringAllWindowsToFront(for: app)
        case .perWindow:
            guard visibleWindows.indices.contains(selectedIndex) else {
                print("❌ Selection index out of range for visibleWindows: index=\(selectedIndex) count=\(visibleWindows.count)")
                return
            }
            let selectedWindow = visibleWindows[selectedIndex]
            print("Switching to window: \(selectedWindow.title) (ID: \(selectedWindow.windowID)) of app \(selectedWindow.appName) (PID: \(selectedWindow.ownerPID))")
            print("➡️ Bumping window recency and requesting focus")
            WindowRecents.shared.bump(windowID: selectedWindow.windowID)
            AccessibilityService.shared.focus(window: selectedWindow)
            print("📣 Focus request sent to AccessibilityService")
        }
    }
    
    func cancelSelection() {
        isSwitcherVisible = false
        if let w = pendingOpenWorkItem { w.cancel(); pendingOpenWorkItem = nil }
        // Optional: Return focus to previousApp if needed
    }
    
    /// Public trigger to refresh the currently visible list (apps or windows),
    /// respecting the current switcher mode.
    func refreshNow() {
        refreshCurrentList()
    }
    
    // MARK: - Private Helpers
    
    private func refreshCurrentList() {
        switch mode {
        case .perApp:
            var apps = WindowManager.shared.getOpenApps()
            // Sort by tier then MRU; inside tier preserve existing ordering rules
            apps.sortByTierAndRecency()
            self.visibleApps = apps
        case .perWindow:
            var windows = WindowManager.shared.getOpenWindows()
            // Normalize tier according to current preferences (map to .normal when preference is .normal)
            let hiddenPref = PreferenceUtils.hiddenPlacement()
            let minimizedPref = PreferenceUtils.minimizedPlacement()
            if hiddenPref == .normal || minimizedPref == .normal {
                windows = windows.map { w in
                    var copy = w
                    if w.tier == .hidden && hiddenPref == .normal { copy.tier = .normal }
                    if w.tier == .minimized && minimizedPref == .normal { copy.tier = .normal }
                    return copy
                }
            }
            // Sort by tier then MRU
            windows.sortByTierAndRecency()
            self.visibleWindows = windows
        }
    }
}

// Helper Enum for cycling direction
enum SelectionDirection {
    case next      // Tab
    case previous  // Shift + Tab
}

