import Cocoa

struct SystemWindow: Identifiable, Hashable {
    
    // MARK: - Identity
    
    /// The unique ID assigned by the Window Server (kCGWindowNumber).
    /// This acts as the primary key for the window.
    let windowID: CGWindowID
    
    /// Conformance to Identifiable ensures SwiftUI can track this item efficiently.
    var id: CGWindowID { windowID }
    
    // MARK: - Metadata
    
    let title: String
    let appName: String
    let ownerPID: pid_t
    let owningApplication: NSRunningApplication?
    
    // MARK: - Visuals
    
    let appIcon: NSImage?
    
    // MARK: - Layout
    
    let frame: CGRect
    var tier: VisibilityTier = .normal
    
    // MARK: - Equatable & Hashable
    
    static func == (lhs: SystemWindow, rhs: SystemWindow) -> Bool {
        return lhs.windowID == rhs.windowID && 
               lhs.tier == rhs.tier &&
               lhs.title == rhs.title
    }
    
    func hash(into hasher: inout Hasher) {
        hasher.combine(windowID)
        hasher.combine(tier)
    }
}

// MARK: - Debugging Helper
extension SystemWindow: CustomStringConvertible {
    var description: String {
        return "Window[\(windowID)] '\(title)' (\(appName))"
    }
}
