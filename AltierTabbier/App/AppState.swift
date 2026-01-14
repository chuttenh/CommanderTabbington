import SwiftUI
import Combine

class AppState: ObservableObject {
    
    // MARK: - Published Properties (UI Drivers)
    
    /// Controls the visibility of the switcher overlay.
    /// When true, the UI appears; when false, it vanishes.
    @Published var isSwitcherVisible: Bool = false
    
    /// The list of windows currently available to switch to.
    /// This is updated every time the switcher is invoked.
    @Published var visibleWindows: [SystemWindow] = []
    
    /// The index of the currently highlighted window in the `visibleWindows` array.
    @Published var selectedIndex: Int = 0
    
    // MARK: - Internal State
    
    /// A cache or handle to the previously active application,
    /// used if we need to "cancel" the switch and return to where we were.
    var previousApp: NSRunningApplication?
    
    // MARK: - Actions
    
    /// Called when the user presses the hotkey (e.g., Cmd+Tab).
    /// If the switcher is hidden, it opens it and captures the current state.
    /// If open, it cycles to the next window.
    func handleUserActivation(direction: SelectionDirection = .next) {
        if !isSwitcherVisible {
            // 1. Activate Switcher
            refreshWindowList()
            
            if visibleWindows.isEmpty {
                print("⚠️ No windows available to show in switcher.")
            }
            
            isSwitcherVisible = true
            print("🔎 Switcher opened. windows=\(visibleWindows.count) selectedIndex=\(selectedIndex)")
            
            // 2. Select the second window (index 1) by default
            // Index 0 is usually the currently focused window.
            selectedIndex = (visibleWindows.count > 1) ? 1 : 0
            
        } else {
            // 3. Cycle Selection
            cycleSelection(direction: direction)
        }
    }
    
    /// Moves the selection index, wrapping around the array bounds.
    func cycleSelection(direction: SelectionDirection) {
        guard !visibleWindows.isEmpty else { return }
        
        switch direction {
        case .next:
            selectedIndex = (selectedIndex + 1) % visibleWindows.count
        case .previous:
            selectedIndex = (selectedIndex - 1 + visibleWindows.count) % visibleWindows.count
        }
    }
    
    /// Called when the user releases the modifier key (Cmd).
    /// Commits the selection and hides the UI.
    func commitSelection() {
        guard isSwitcherVisible else { return }
        
        // Hide UI immediately for responsiveness
        isSwitcherVisible = false
        print("✅ Committing selection index=\(selectedIndex) total=\(visibleWindows.count)")
        
        guard visibleWindows.indices.contains(selectedIndex) else { return }
        let selectedWindow = visibleWindows[selectedIndex]
        
        // This is where we will eventually call our AccessibilityService
        // to actually perform the switch.
        print("Switching to: \(selectedWindow.title) (ID: \(selectedWindow.windowID))")
        
        AccessibilityService.shared.focus(window: selectedWindow)
    }
    
    func cancelSelection() {
        isSwitcherVisible = false
        // Optional: Return focus to previousApp if needed
    }
    
    // MARK: - Private Helpers
    
    private func refreshWindowList() {
        // Fetch the real windows from the system
        let windows = WindowManager.shared.getOpenWindows()
        
        // Update the published property
        self.visibleWindows = windows
    }
}

// Helper Enum for cycling direction
enum SelectionDirection {
    case next      // Tab
    case previous  // Shift + Tab
}

