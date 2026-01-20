import SwiftUI
import Combine
import Cocoa
import CoreGraphics
import OSLog

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
    private var pendingOpenGateToken: UUID?
    
    init() {
        // Initialize mode from user defaults (default: perApp)
        let perApp = UserDefaults.standard.object(forKey: "perAppMode") as? Bool ?? true
        self.mode = perApp ? .perApp : .perWindow
    }
    
    /// The index of the currently highlighted app in the `visibleApps` array.
    @Published var selectedAppID: pid_t? = nil
    @Published var selectedWindowID: CGWindowID? = nil

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
        if !self.isSwitcherVisible {
            // If no pending open, capture current state and schedule UI appearance after a small delay
            if self.pendingOpenWorkItem == nil {
                let gateToken = UUID()
                self.pendingOpenGateToken = gateToken
                let prepareAndScheduleOpen = { [weak self] in
                    guard let self = self else { return }
                    guard self.pendingOpenGateToken == gateToken else { return }
                    self.refreshCurrentList()
                    if self.visibleApps.isEmpty && self.visibleWindows.isEmpty {
                        AppLog.appState.log("⚠️ No apps or windows available to show in switcher.")
                    }
                    // Preselect the second entry (index 1) by default
                    let count: Int = (self.mode == .perApp) ? self.visibleApps.count : self.visibleWindows.count
                    self.selectedIndex = (count > 1) ? 1 : 0

                    self.applySelectionForCurrentMode()

                    // Schedule showing the overlay after the configured delay
                    let delayMS = UserDefaults.standard.object(forKey: "switcherOpenDelayMS") as? Int ?? 100
                    var workItem: DispatchWorkItem?
                    workItem = DispatchWorkItem { [weak self] in
                        guard let self = self else { return }
                        // Ensure this is still the active pending item; if it was canceled or superseded, do nothing
                    guard self.pendingOpenWorkItem === workItem else { return }
                    self.isSwitcherVisible = true
                    self.pendingOpenWorkItem = nil
                    self.pendingOpenGateToken = nil
                    AppLog.appState.info("🔎 Switcher opened (delayed). apps=\(self.visibleApps.count, privacy: .public) windows=\(self.visibleWindows.count, privacy: .public) selectedIndex=\(self.selectedIndex, privacy: .public)")
                }
                    if let wi = workItem {
                        self.pendingOpenWorkItem = wi
                        DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(max(0, delayMS)), execute: wi)
                    }
                }

                let fallbackDelay: DispatchTimeInterval = .milliseconds(300)
                var didPrepare = false

                let runOnce: () -> Void = { [weak self] in
                    guard let self = self, !didPrepare else { return }
                    guard self.pendingOpenGateToken == gateToken else { return }
                    guard !self.isSwitcherVisible else { return }
                    didPrepare = true
                    prepareAndScheduleOpen()
                }

                AppRecents.shared.ensureSeeded {
                    WindowRecents.shared.ensureSeeded {
                        runOnce()
                    }
                }

                DispatchQueue.main.asyncAfter(deadline: .now() + fallbackDelay) {
                    runOnce()
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
        guard !self.visibleApps.isEmpty || !self.visibleWindows.isEmpty else { return }
        let count: Int = (self.mode == .perApp) ? self.visibleApps.count : self.visibleWindows.count
        guard count > 0 else { return }
        
        switch direction {
        case .next:
            self.selectedIndex = (self.selectedIndex + 1) % count
        case .previous:
            self.selectedIndex = (self.selectedIndex - 1 + count) % count
        }
        
        applySelectionForCurrentMode()
    }
    
    /// Called when the user releases the modifier key (Cmd).
    /// Commits the selection and hides the UI.
    func commitSelection() {
        // Diagnostics: entry log
        AppLog.appState.info("🧭 commitSelection invoked. mode=\(String(describing: self.mode), privacy: .public) selectedIndex=\(self.selectedIndex, privacy: .public) isVisible=\(self.isSwitcherVisible, privacy: .public) apps=\(self.visibleApps.count, privacy: .public) windows=\(self.visibleWindows.count, privacy: .public)")
        
        // Allow commit even if the UI hasn't appeared yet, as long as an open is pending
        let hadPendingOpen = (self.pendingOpenWorkItem != nil)
        if hadPendingOpen {
            self.pendingOpenWorkItem?.cancel()
            self.pendingOpenWorkItem = nil
            self.pendingOpenGateToken = nil
        }
        
        guard self.isSwitcherVisible || hadPendingOpen else {
            AppLog.appState.log("⚠️ commitSelection ignored: switcher not visible and no pending open")
            return
        }
        
        if self.isSwitcherVisible { self.isSwitcherVisible = false }
        AppLog.appState.debug("🫥 Hiding switcher overlay before activation")
        
        switch self.mode {
        case .perApp:
            commitAppSelection()
        case .perWindow:
            commitWindowSelection()
        }
    }
    
    func cancelSelection() {
        self.isSwitcherVisible = false
        if let w = self.pendingOpenWorkItem { w.cancel(); self.pendingOpenWorkItem = nil }
        self.pendingOpenGateToken = nil
        // Optional: Return focus to previousApp if needed
    }
    
    /// Public trigger to refresh the currently visible list (apps or windows),
    /// respecting the current switcher mode.
    func refreshNow() {
        refreshCurrentList()
    }
    
    // MARK: - Private Helpers
    
    private func refreshCurrentList() {
        switch self.mode {
        case .perApp:
            let prevID = self.selectedAppID
            var apps = WindowManager.shared.getOpenApps()
            // Sort by tier then MRU; inside tier preserve existing ordering rules
            apps.sortByTierAndRecency()

            let newSelectedID: pid_t? = {
                if let prev = prevID, apps.contains(where: { $0.id == prev }) { return prev }
                let count = apps.count
                if count == 0 { return nil }
                let fallbackIndex = min(self.selectedIndex, count - 1)
                return apps[fallbackIndex].id
            }()
            let newIndex: Int = {
                if let sel = newSelectedID, let idx = apps.firstIndex(where: { $0.id == sel }) { return idx }
                return 0
            }()

            // Publish list then identity and index
            self.visibleApps = apps
            self.selectedAppID = newSelectedID
            self.selectedIndex = newIndex
        case .perWindow:
            let prevID = self.selectedWindowID
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

            let newSelectedID: CGWindowID? = {
                if let prev = prevID, windows.contains(where: { $0.id == prev }) { return prev }
                let count = windows.count
                if count == 0 { return nil }
                let fallbackIndex = min(self.selectedIndex, count - 1)
                return windows[fallbackIndex].id
            }()
            let newIndex: Int = {
                if let sel = newSelectedID, let idx = windows.firstIndex(where: { $0.id == sel }) { return idx }
                return 0
            }()

            // Publish list then identity and index
            self.visibleWindows = windows
            self.selectedWindowID = newSelectedID
            self.selectedIndex = newIndex
        }
    }

    private func applySelectionForCurrentMode() {
        switch self.mode {
        case .perApp:
            if self.visibleApps.indices.contains(self.selectedIndex) {
                self.selectedAppID = self.visibleApps[self.selectedIndex].id
            } else {
                self.selectedAppID = nil
            }
            self.selectedWindowID = nil
        case .perWindow:
            if self.visibleWindows.indices.contains(self.selectedIndex) {
                self.selectedWindowID = self.visibleWindows[self.selectedIndex].id
            } else {
                self.selectedWindowID = nil
            }
            self.selectedAppID = nil
        }
    }

    private func commitAppSelection() {
        guard self.visibleApps.indices.contains(self.selectedIndex) else {
            AppLog.appState.error("❌ Selection index out of range for visibleApps: index=\(self.selectedIndex, privacy: .public) count=\(self.visibleApps.count, privacy: .public)")
            return
        }
        let selectedApp = self.visibleApps[self.selectedIndex]
        AppLog.appState.info("🚀 Switching to app: \(selectedApp.appName, privacy: .public) (PID: \(selectedApp.ownerPID, privacy: .public))")

        // Prefer the stored NSRunningApplication, but fall back to resolving by PID if needed
        let targetApp = selectedApp.owningApplication ?? NSRunningApplication(processIdentifier: selectedApp.ownerPID)

        guard let app = targetApp else {
            AppLog.appState.error("❓ No NSRunningApplication for selected app; cannot activate directly")
            return
        }

        // Try high-level activation first
        let activated = app.activate(options: [.activateIgnoringOtherApps])
        if activated {
            AppLog.appState.info("✅ App activation requested successfully")
        } else {
            AppLog.appState.log("⚠️ App activation returned false; attempting AX-based bring-to-front fallback")
        }

        // Use AccessibilityService to ensure the app is unhidden and all windows are raised/focused.
        AccessibilityService.shared.bringAllWindowsToFront(for: app)
    }

    private func commitWindowSelection() {
        guard self.visibleWindows.indices.contains(self.selectedIndex) else {
            AppLog.appState.error("❌ Selection index out of range for visibleWindows: index=\(self.selectedIndex, privacy: .public) count=\(self.visibleWindows.count, privacy: .public)")
            return
        }
        let selectedWindow = self.visibleWindows[self.selectedIndex]
        AppLog.appState.info("🚀 Switching to window: \(selectedWindow.title, privacy: .public) (ID: \(selectedWindow.windowID, privacy: .public)) of app \(selectedWindow.appName, privacy: .public) (PID: \(selectedWindow.ownerPID, privacy: .public))")
        AppLog.appState.debug("➡️ Bumping window recency and requesting focus")
        WindowRecents.shared.bump(windowID: selectedWindow.windowID)
        AccessibilityService.shared.focus(window: selectedWindow)
        AppLog.appState.debug("📣 Focus request sent to AccessibilityService")
    }
}

// Helper Enum for cycling direction
enum SelectionDirection {
    case next      // Tab
    case previous  // Shift + Tab
}
