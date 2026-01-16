import Cocoa

struct SystemWindow: Identifiable, Hashable {
    
    // MARK: - Identity
    
    /// The unique ID assigned by the Window Server (kCGWindowNumber).
    /// This acts as the primary key for the window.
    let windowID: CGWindowID
    
    /// Conformance to Identifiable ensures SwiftUI can track this item efficiently.
    var id: CGWindowID { windowID }
    
    // MARK: - Metadata
    
    /// The title of the window (e.g., "Inbox - Gmail").
    /// Note: Some windows have empty titles.
    let title: String
    
    /// The name of the application owning the window (e.g., "Chrome").
    let appName: String
    
    /// The process ID (PID) of the owning application.
    let ownerPID: pid_t
    
    /// The actual reference to the running application.
    /// Critical for activating/focusing the app later.
    /// Excluded from Hashable logic to simplify equality checks.
    let owningApplication: NSRunningApplication?
    
    // MARK: - Visuals
    
    /// The application icon (e.g., the Chrome logo).
    let appIcon: NSImage?
    
    // MARK: - Layout
    
    /// The window's position and size on screen.
    /// Used by the UI to determine the aspect ratio of the thumbnail.
    let frame: CGRect
    
    var tier: VisibilityTier = .normal
    
    // MARK: - Equatable & Hashable
    
    // We define equality solely by windowID. If the ID is the same,
    // it's the same window, regardless of whether the title changed slightly.
    static func == (lhs: SystemWindow, rhs: SystemWindow) -> Bool {
        return lhs.windowID == rhs.windowID
    }
    
    func hash(into hasher: inout Hasher) {
        hasher.combine(windowID)
    }
}

// MARK: - Debugging Helper
extension SystemWindow: CustomStringConvertible {
    var description: String {
        return "Window[\(windowID)] '\(title)' (\(appName))"
    }
}
