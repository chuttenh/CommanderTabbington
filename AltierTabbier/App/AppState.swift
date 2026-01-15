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
            // 1. Activate Switcher
            refreshCurrentList()
            
            if visibleApps.isEmpty && visibleWindows.isEmpty {
                print("⚠️ No apps or windows available to show in switcher.")
            }
            
            isSwitcherVisible = true
            print("🔎 Switcher opened. apps=\(visibleApps.count) windows=\(visibleWindows.count) selectedIndex=\(selectedIndex)")
            
            // 2. Select the second app (index 1) by default
            // Index 0 is usually the currently focused app/window.
            let count: Int
            switch mode {
            case .perApp: count = visibleApps.count
            case .perWindow: count = visibleWindows.count
            }
            selectedIndex = (count > 1) ? 1 : 0
            
        } else {
            // 3. Cycle Selection
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
        
        // Ensure the switcher is actually visible
        guard isSwitcherVisible else {
            print("⚠️ commitSelection ignored: switcher not visible")
            return
        }
        
        // Hide UI immediately for responsiveness
        isSwitcherVisible = false
        print("🫥 Hiding switcher overlay before activation")
        
        switch mode {
        case .perApp:
            guard visibleApps.indices.contains(selectedIndex) else {
                print("❌ Selection index out of range for visibleApps: index=\(selectedIndex) count=\(visibleApps.count)")
                return
            }
            let selectedApp = visibleApps[selectedIndex]
            print("Switching to app: \(selectedApp.appName) (PID: \(selectedApp.ownerPID))")
            if let app = selectedApp.owningApplication {
                let success = app.activate(options: .activateIgnoringOtherApps)
                print(success ? "✅ App activation requested successfully" : "⚠️ App activation returned false")
            } else {
                print("❓ No NSRunningApplication for selected app; cannot activate directly")
            }
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
        // Optional: Return focus to previousApp if needed
    }
    
    // MARK: - Private Helpers
    
    private func refreshCurrentList() {
        switch mode {
        case .perApp:
            let apps = WindowManager.shared.getOpenApps()
            self.visibleApps = apps
        case .perWindow:
            let windows = WindowManager.shared.getOpenWindows()
            self.visibleWindows = windows
        }
    }
}

// Helper Enum for cycling direction
enum SelectionDirection {
    case next      // Tab
    case previous  // Shift + Tab
}

