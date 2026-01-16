import Cocoa
import CoreGraphics
import ScreenCaptureKit
import Foundation
import ApplicationServices

// Not provided as a Swift constant; define it for Accessibility API usage
private let kAXWindowNumberAttribute: CFString = "AXWindowNumber" as CFString

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
        
        // Build a set of already included window IDs to avoid duplicates
        var includedIDs = Set(windows.map { $0.windowID })

        // Preferences for inclusion at the window level
        let includeHidden = UserDefaults.standard.object(forKey: "IncludeHiddenApps") as? Bool ?? true
        let includeMinimized = UserDefaults.standard.object(forKey: "IncludeMinimizedApps") as? Bool ?? true

        // If either preference allows additional windows beyond on-screen ones, merge from Accessibility
        if includeHidden || includeMinimized {
            let running = NSWorkspace.shared.runningApplications.filter { $0.activationPolicy == .regular }
            for appRef in running {
                let isHidden = appRef.isHidden
                // If app is hidden and we don't include hidden, skip its windows entirely
                if isHidden && !includeHidden { continue }

                let appAX = AXUIElementCreateApplication(appRef.processIdentifier)
                var axWindowsRef: CFTypeRef?
                if AXUIElementCopyAttributeValue(appAX, kAXWindowsAttribute as CFString, &axWindowsRef) == .success,
                   let axWindows = axWindowsRef as? [AXUIElement] {
                    for axWin in axWindows {
                        // Read window number to map to CGWindowID
                        var numberRef: CFTypeRef?
                        guard AXUIElementCopyAttributeValue(axWin, kAXWindowNumberAttribute as CFString, &numberRef) == .success,
                              let number = numberRef as? Int,
                              number != 0 else { continue }
                        let wid = CGWindowID(number)
                        if includedIDs.contains(wid) { continue }

                        // Check minimized state
                        var minRef: CFTypeRef?
                        var isMinimized = false
                        if AXUIElementCopyAttributeValue(axWin, kAXMinimizedAttribute as CFString, &minRef) == .success,
                           let min = minRef as? Bool {
                            isMinimized = min
                        }
                        if isMinimized && !includeMinimized { continue }

                        // Title
                        var titleRef: CFTypeRef?
                        let title: String = {
                            if AXUIElementCopyAttributeValue(axWin, kAXTitleAttribute as CFString, &titleRef) == .success,
                               let t = titleRef as? String, !t.isEmpty {
                                return t
                            }
                            return ""
                        }()

                        let ownerName = appRef.localizedName ?? "Unknown"
                        let window = SystemWindow(
                            windowID: wid,
                            title: title,
                            appName: ownerName,
                            ownerPID: appRef.processIdentifier,
                            owningApplication: appRef,
                            appIcon: appRef.icon,
                            frame: .zero
                        )
                        windows.append(window)
                        includedIDs.insert(wid)
                    }
                }
            }
        }
        
        var sorted = windows
        WindowRecents.shared.sortWindowsByRecency(&sorted)
        return sorted
    }
    
    /// Returns one entry per running app that has at least one visible window.
    func getOpenApps() -> [SystemApp] {
        // Visible windows are used to compute counts and recent ordering
        let windows = getOpenWindows()
        // Group windows by owning PID for counts
        let grouped = Dictionary(grouping: windows, by: { $0.ownerPID })

        // Preferences for inclusion
        let includeHidden = UserDefaults.standard.object(forKey: "IncludeHiddenApps") as? Bool ?? true
        let includeMinimized = UserDefaults.standard.object(forKey: "IncludeMinimizedApps") as? Bool ?? true

        // Enumerate running apps (regular apps only)
        let running = NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular }

        var apps: [SystemApp] = []
        apps.reserveCapacity(running.count)

        let ignoredBundleIDs: Set<String> = [
            Bundle.main.bundleIdentifier ?? "",
        ].filter { !$0.isEmpty }.reduce(into: Set<String>()) { $0.insert($1) }
        let ignoredAppNames: Set<String> = ["Dock", "Window Server", "Control Center", "Notification Center", "Commander Tabbington"]

        for appRef in running {
            // Skip our own app and system components by name or bundle id
            if let bid = appRef.bundleIdentifier, ignoredBundleIDs.contains(bid) { continue }
            if let name = appRef.localizedName, ignoredAppNames.contains(name) { continue }

            // Apply hidden preference (app-level)
            let isHidden = appRef.isHidden
            if !includeHidden && isHidden { continue }

            let pid = appRef.processIdentifier
            let visibleWindowCount = grouped[pid]?.count ?? 0

            // An app is considered "all minimized" if it's not hidden and has no visible windows
            let isAllMinimized = !isHidden && (visibleWindowCount == 0)
            if !includeMinimized && isAllMinimized { continue }

            let name = appRef.localizedName ?? "Unknown"
            let icon = appRef.icon

            var app = SystemApp(ownerPID: pid,
                                appName: name,
                                owningApplication: appRef,
                                appIcon: icon,
                                windowCount: visibleWindowCount)
            if UserDefaults.standard.object(forKey: "showNotificationBadges") as? Bool ?? true {
                app.badgeCount = DockBadgeService.shared.badgeCount(for: appRef)
            }
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
            let ignoredApps = ["Dock", "Window Server", "Control Center", "Notification Center", "Commander Tabbington"]
            if ignoredApps.contains(appName) {
                return false
            }
        }
        
        return true
    }
    
}

