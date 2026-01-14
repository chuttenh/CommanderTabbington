import Cocoa
import CoreGraphics
import ScreenCaptureKit

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
                windowPreview: nil, // <--- Pass nil here for instant loading
                frame: frame
            )
            windows.append(window)
        }
        
        return windows
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
    
    // Helper to get image ONLY if you are on macOS 14+
    // If you are on older macOS, you must stick to the old CGWindowListCreateImage
    func captureWindowImage(windowID: CGWindowID) async -> CGImage? {
        
        if #available(macOS 14.0, *) {
            // 1. We need a "Content Filter" to tell SCK which window to grab
            // Unfortunately, SCK requires us to fetch 'SCShareableContent' first to find the window object
            // This is heavy. For a quick thumbnail, this adds latency.
            
            do {
                let content = try await SCShareableContent.current
                
                guard let window = content.windows.first(where: { $0.windowID == windowID }) else {
                    return nil
                }
                
                let filter = SCContentFilter(desktopIndependentWindow: window)
                let config = SCStreamConfiguration()
                
                // Match the window size to save memory
                config.width = Int(window.frame.width)
                config.height = Int(window.frame.height)
                config.showsCursor = false
                
                // Take the shot
                return try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
                
            } catch {
                print("Failed to capture window \(windowID): \(error)")
                return nil
            }
        } else {
            // Fallback for older macOS (if your target supports it)
            // If your compiler blocks this, you might have to wrap it in a C-function or unchecked block
            return nil
        }
    }
    
    // Note: It is 'async' which is why we couldn't call it in the loop above.
    func fetchThumbnail(for windowID: CGWindowID) async -> CGImage? {
        // Only available on macOS 12.3+, but realistic for "Modern" apps
        guard #available(macOS 14.0, *) else { return nil }
        
        do {
            // 1. Get all shareable content (windows, displays, apps)
            let content = try await SCShareableContent.current
            
            // 2. Find our specific window in the SCK list
            guard let match = content.windows.first(where: { $0.windowID == windowID }) else {
                return nil
            }
            
            // 3. Configure the capture
            let filter = SCContentFilter(desktopIndependentWindow: match)
            let config = SCStreamConfiguration()
            config.width = Int(match.frame.width)
            config.height = Int(match.frame.height)
            config.showsCursor = false
            
            // 4. Capture
            return try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
        } catch {
            print("SCK Error for window \(windowID): \(error)")
            return nil
        }
    }
}
