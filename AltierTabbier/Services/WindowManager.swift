import Cocoa
import CoreGraphics
import ScreenCaptureKit
import Foundation

class WindowManager {
    
    // Singleton for easy access
    static let shared = WindowManager()
    private init() {}
    
    /// Fetches a list of all relevant open windows.
    func getOpenWindows() -> [SystemWindow] {
        // 1. Define the options
        // .optionOnScreenOnly: Excludes minimized or hidden windows (essential for a clean switcher).
        // .excludeDesktopElements: Hides the wallpaper and desktop icons.
        let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
        
        // 2. Query Core Graphics
        // This returns a CFArray of CFDictionaries.
        guard let infoList = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] else {
            return []
        }
        
        var windows: [SystemWindow] = []
        
        for entry in infoList {
            // 3. Filter "Ghost" Windows
            if !shouldInclude(windowInfo: entry) {
                continue
            }
            
            // 4. Parse the dictionary
            guard let idNum = entry[kCGWindowNumber as String] as? Int,
                  let ownerPID = entry[kCGWindowOwnerPID as String] as? Int32 else {
                continue
            }
            
            let windowID = CGWindowID(idNum)
            let title = entry[kCGWindowName as String] as? String ?? ""
            let ownerName = entry[kCGWindowOwnerName as String] as? String ?? "Unknown"
            
            // Get the running application reference (needed for icons and activation)
            let appRef = NSRunningApplication(processIdentifier: ownerPID)
            
            // Parse bounds (frame)
            let boundsDict = entry[kCGWindowBounds as String] as? [String: Any]
            let frame = CGRect(dictionaryRepresentation: boundsDict as CFDictionary? ?? [:] as CFDictionary) ?? .zero
            
            // 5. Generate Screenshot (Thumbnail)
            
            let window = SystemWindow(
                windowID: windowID,
                title: title,
                appName: ownerName,
                ownerPID: ownerPID,
                owningApplication: appRef,
                appIcon: appRef?.icon,
                frame: frame
            )
            windows.append(window)
        }
        
        var sorted = windows
        WindowRecents.shared.sortWindowsByRecency(&sorted)
        return sorted
    }
    
    /// Returns one entry per running app that has at least one visible window.
    func getOpenApps() -> [SystemApp] {
        let windows = getOpenWindows()
        guard !windows.isEmpty else { return [] }

        // Group windows by owning PID
        let grouped = Dictionary(grouping: windows, by: { $0.ownerPID })

        var apps: [SystemApp] = []
        apps.reserveCapacity(grouped.count)

        for (pid, group) in grouped {
            // Prefer non-empty app name from any window in the group
            let name = group.first?.appName ?? "Unknown"
            let appRef = group.first?.owningApplication
            let icon = appRef?.icon
            let count = group.count

            let app = SystemApp(ownerPID: pid,
                                appName: name,
                                owningApplication: appRef,
                                appIcon: icon,
                                windowCount: count)
            apps.append(app)
        }

        // Sort by recency (MRU), active-first, then name as tiebreaker
        AppRecents.shared.sortAppsByRecency(&apps)

        return apps
    }
    
    /// The "Anti-Ghost" Filter.
    /// Determines if a window is a real user window or system noise.
    private func shouldInclude(windowInfo: [String: Any]) -> Bool {
        
        // A. Layer Check
        // Normal application windows are on Layer 0.
        // Menus, docks, and overlays are usually on different layers.
        if let layer = windowInfo[kCGWindowLayer as String] as? Int, layer != 0 {
            return false
        }
        
        // B. Transparency Check
        // Some apps create invisible 0-alpha windows to catch clicks.
        if let alpha = windowInfo[kCGWindowAlpha as String] as? Double, alpha < 0.01 {
            return false
        }
        
        // C. Size Check
        // Filter out tiny 1x1 tracking windows.
        if let boundsDict = windowInfo[kCGWindowBounds as String] as? [String: Any],
           let width = boundsDict["Width"] as? Double,
           let height = boundsDict["Height"] as? Double {
            if width < 50 || height < 50 { return false }
        }
        
        // D. System App Check
        // We generally don't want to switch to the Dock or the Window Server.
        if let appName = windowInfo[kCGWindowOwnerName as String] as? String {
            let ignoredApps = ["Dock", "Window Server", "Control Center", "Notification Center", "AltierTabbier"]
            if ignoredApps.contains(appName) {
                return false
            }
        }
        
        return true
    }
    
}

