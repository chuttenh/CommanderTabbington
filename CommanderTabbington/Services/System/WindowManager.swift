import Cocoa
import CoreGraphics
import ScreenCaptureKit
import Foundation
import ApplicationServices
import OSLog

// Not provided as a Swift constant; define it for Accessibility API usage
private let kAXWindowNumberAttribute: CFString = "AXWindowNumber" as CFString

class WindowManager {
    
    // Singleton for easy access
    static let shared = WindowManager()
    private init() {}
    
    
    /// Fetches a list of all relevant open windows.
    func getOpenWindows() -> [SystemWindow] {
        let totalStart = CFAbsoluteTimeGetCurrent()
        let slowThresholdMS = 100.0
        let logSlowStep: (_ label: String, _ start: CFAbsoluteTime, _ extra: String?) -> Void = { label, start, extra in
            let elapsedMS = (CFAbsoluteTimeGetCurrent() - start) * 1000.0
            guard elapsedMS >= slowThresholdMS else { return }
            if let extra = extra {
                AppLog.app.info("⏱️ WindowManager \(label, privacy: .public) slow: \(elapsedMS, privacy: .public)ms \(extra, privacy: .public)")
            } else {
                AppLog.app.info("⏱️ WindowManager \(label, privacy: .public) slow: \(elapsedMS, privacy: .public)ms")
            }
        }

        // 1. Define the options
        // .optionOnScreenOnly: Excludes minimized or hidden windows (essential for a clean switcher).
        // .excludeDesktopElements: Hides the wallpaper and desktop icons.
        let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
        
        let hiddenPref = PreferenceUtils.hiddenPlacement()
        let minimizedPref = PreferenceUtils.minimizedPlacement()
        
        // 2. Query Core Graphics
        // This returns a CFArray of CFDictionaries.
        let cgListStart = CFAbsoluteTimeGetCurrent()
        guard let infoList = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] else {
            return []
        }
        logSlowStep("CGWindowListCopyWindowInfo", cgListStart, "count=\(infoList.count)")
        
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
            
        // Determine tier based on app hidden/minimized status and preferences
        var tier: VisibilityTier = .normal
        if let app = appRef {
            let appIsActive = app.isActive
            let appHidden = app.isHidden
            // We don't have minimized info from CGWindowList, so treat as normal here.
            if appIsActive {
                tier = .normal
            } else if appHidden {
                switch hiddenPref {
                case .exclude:
                    continue
                case .atEnd:
                    tier = .atEnd
                case .normal:
                    tier = .normal
                }
            } else {
                // For minimized, no info here, so treat as normal
                tier = .normal
            }
            }
            
            // 5. Generate Screenshot (Thumbnail)
            
            let window = SystemWindow(
                windowID: windowID,
                title: title,
                appName: ownerName,
                ownerPID: ownerPID,
                owningApplication: appRef,
                appIcon: appRef?.icon,
                frame: frame,
                tier: tier
            )
            windows.append(window)
        }
        
        // Build a set of already included window IDs to avoid duplicates
        var includedIDs = Set(windows.map { $0.windowID })

        // Preferences for inclusion at the window level
        // let includeHidden = UserDefaults.standard.object(forKey: "IncludeHiddenApps") as? Bool ?? true
        // let includeMinimized = UserDefaults.standard.object(forKey: "IncludeMinimizedApps") as? Bool ?? true

        // If either preference allows additional windows beyond on-screen ones, merge from Accessibility
        if hiddenPref != .exclude || minimizedPref != .exclude {
            let axMergeStart = CFAbsoluteTimeGetCurrent()
            let running = NSWorkspace.shared.runningApplications.filter { $0.activationPolicy == .regular }
            for appRef in running {
                // let isHidden = appRef.isHidden
                // if isHidden && !includeHidden { continue }
                let appHidden = appRef.isHidden

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
                        let appIsActive = appRef.isActive

                        let tier: VisibilityTier
                        if isMinimized {
                            // Respect exclusion unless it's the active app.
                            if minimizedPref == .exclude && !appIsActive { continue }
                            if appIsActive {
                                tier = .normal
                            } else {
                                // Placement preference: either segregate at end or keep in main tier.
                                tier = (minimizedPref == .atEnd) ? .atEnd : .normal
                            }
                        } else if appHidden {
                            // Respect exclusion unless it's the active app.
                            if hiddenPref == .exclude && !appIsActive { continue }
                            if appIsActive {
                                tier = .normal
                            } else {
                                // Placement preference: either segregate at end or keep in main tier.
                                tier = (hiddenPref == .atEnd) ? .atEnd : .normal
                            }
                        } else {
                            // Not minimized and app not hidden; if it wasn't in CG list, skip to avoid duplicates
                            continue
                        }

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
                            frame: .zero,
                            tier: tier
                        )
                        windows.append(window)
                        includedIDs.insert(wid)
                    }
                }
            }
            logSlowStep("AX merge", axMergeStart, "runningApps=\(running.count)")
        }
        
        var sorted = windows
        WindowRecents.shared.sortWindowsByRecency(&sorted)
        logSlowStep("getOpenWindows total", totalStart, "returned=\(sorted.count)")
        return sorted
    }
    
    /// Returns one entry per running app, including optional no-window apps based on preferences.
    func getOpenApps() -> [SystemApp] {
        let totalStart = CFAbsoluteTimeGetCurrent()
        let slowThresholdMS = 100.0
        let logSlowStep: (_ label: String, _ start: CFAbsoluteTime, _ extra: String?) -> Void = { label, start, extra in
            let elapsedMS = (CFAbsoluteTimeGetCurrent() - start) * 1000.0
            guard elapsedMS >= slowThresholdMS else { return }
            if let extra = extra {
                AppLog.app.info("⏱️ WindowManager \(label, privacy: .public) slow: \(elapsedMS, privacy: .public)ms \(extra, privacy: .public)")
            } else {
                AppLog.app.info("⏱️ WindowManager \(label, privacy: .public) slow: \(elapsedMS, privacy: .public)ms")
            }
        }

        // Visible windows are used to compute counts and recent ordering
        let windows = getOpenWindows()
        
        let hiddenPref = PreferenceUtils.hiddenPlacement()
        let minimizedPref = PreferenceUtils.minimizedPlacement()
        let noWindowPref = PreferenceUtils.noWindowPlacement()
        let debugTiering = UserDefaults.standard.object(forKey: "DebugTiering") as? Bool ?? false
        let debugTieringAppName = UserDefaults.standard.string(forKey: "DebugTieringAppName")
        if debugTiering {
            AppLog.app.info("🧭 Tiering prefs hidden=\(hiddenPref.rawValue, privacy: .public) minimized=\(minimizedPref.rawValue, privacy: .public) noWindow=\(noWindowPref.rawValue, privacy: .public)")
        }
        
        // Group windows by owning PID for counts
        // let grouped = Dictionary(grouping: windows, by: { $0.ownerPID })
        let groupedVisible = Dictionary(grouping: windows.filter { $0.tier == .normal }, by: { $0.ownerPID })
        let windowPresence = buildWindowPresenceByPID()

        // Preferences for inclusion
        // let includeHidden = UserDefaults.standard.object(forKey: "IncludeHiddenApps") as? Bool ?? true
        // let includeMinimized = UserDefaults.standard.object(forKey: "IncludeMinimizedApps") as? Bool ?? true

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

            let appHidden = appRef.isHidden
            let appIsActive = appRef.isActive

            let pid = appRef.processIdentifier
            let visibleWindowCount = groupedVisible[pid]?.count ?? 0
            let axSummary = axStandardWindowSummary(for: appRef, debugAppName: debugTieringAppName)
            let hasAnyWindows: Bool
            var hasVisibleUserWindows: Bool
            if let summary = axSummary {
                hasAnyWindows = summary.total > 0 || visibleWindowCount > 0
                hasVisibleUserWindows = summary.visible > 0 || visibleWindowCount > 0
            } else {
                hasAnyWindows = visibleWindowCount > 0 || (windowPresence[pid] ?? false)
                hasVisibleUserWindows = visibleWindowCount > 0
            }

            // An app is considered "all minimized" if it's not hidden, has windows, and none are visible
            let isAllMinimized = !appHidden && !hasVisibleUserWindows && hasAnyWindows
            let hasNoWindows = !appHidden && !hasAnyWindows

            if !appIsActive {
                if appHidden && hiddenPref == .exclude { continue }
                if isAllMinimized && minimizedPref == .exclude { continue }
                if hasNoWindows && noWindowPref == .exclude { continue }
            }

            let name = appRef.localizedName ?? "Unknown"
            let icon = appRef.icon

            var tier: VisibilityTier = .normal
            if appIsActive {
                tier = .normal
            } else if appHidden {
                if hiddenPref == .atEnd {
                    tier = .atEnd
                }
            } else if isAllMinimized {
                if minimizedPref == .atEnd {
                    tier = .atEnd
                }
            } else if hasNoWindows {
                if noWindowPref == .atEnd {
                    tier = .atEnd
                }
            }
            if debugTiering {
                let name = appRef.localizedName ?? "Unknown"
                let axTotal = axSummary?.total ?? -1
                let axVisible = axSummary?.visible ?? -1
                AppLog.app.info("🧭 Tiering app=\(name, privacy: .public) active=\(appIsActive, privacy: .public) hidden=\(appHidden, privacy: .public) visible=\(hasVisibleUserWindows, privacy: .public) any=\(hasAnyWindows, privacy: .public) allMin=\(isAllMinimized, privacy: .public) noWin=\(hasNoWindows, privacy: .public) axTotal=\(axTotal, privacy: .public) axVisible=\(axVisible, privacy: .public) tier=\(tier.rawValue, privacy: .public)")
            }

            var app = SystemApp(ownerPID: pid,
                                appName: name,
                                owningApplication: appRef,
                                appIcon: icon,
                                windowCount: visibleWindowCount,
                                tier: tier)
            if UserDefaults.standard.object(forKey: "showNotificationBadges") as? Bool ?? true {
                app.badgeCount = DockBadgeService.shared.badgeCount(for: appRef)
            }
            apps.append(app)
        }

        // Sort by recency (MRU), active-first, then name as tiebreaker
        AppRecents.shared.sortAppsByRecency(&apps)

        logSlowStep("getOpenApps total", totalStart, "returned=\(apps.count) windows=\(windows.count)")
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

    /// Best-effort map of PIDs that have at least one real window (on-screen or off-screen).
    private func buildWindowPresenceByPID() -> [pid_t: Bool] {
        var presence: [pid_t: Bool] = [:]
        let options: CGWindowListOption = [.excludeDesktopElements]
        guard let infoList = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] else {
            return presence
        }
        for entry in infoList {
            if !shouldInclude(windowInfo: entry) { continue }
            if let ownerPID = entry[kCGWindowOwnerPID as String] as? Int32 {
                presence[ownerPID] = true
            }
        }
        return presence
    }

    /// Summarizes standard AX windows for an app, or nil if unavailable.
    private func axStandardWindowSummary(for app: NSRunningApplication, debugAppName: String?) -> (total: Int, visible: Int)? {
        let appAX = AXUIElementCreateApplication(app.processIdentifier)
        var axWindowsRef: CFTypeRef?
        if AXUIElementCopyAttributeValue(appAX, kAXWindowsAttribute as CFString, &axWindowsRef) == .success,
           let axWindows = axWindowsRef as? [AXUIElement] {
            var total = 0
            var visible = 0
            let shouldDebug = debugAppName != nil && (app.localizedName?.caseInsensitiveCompare(debugAppName ?? "") == .orderedSame)
            for axWin in axWindows {
                var subroleRef: CFTypeRef?
                if AXUIElementCopyAttributeValue(axWin, kAXSubroleAttribute as CFString, &subroleRef) == .success,
                   let subrole = subroleRef as? String,
                   subrole != kAXStandardWindowSubrole as String {
                    continue
                }

                var minRef: CFTypeRef?
                var isMinimized = false
                if AXUIElementCopyAttributeValue(axWin, kAXMinimizedAttribute as CFString, &minRef) == .success,
                   let min = minRef as? Bool {
                    isMinimized = min
                }

                var titleRef: CFTypeRef?
                let title = (AXUIElementCopyAttributeValue(axWin, kAXTitleAttribute as CFString, &titleRef) == .success)
                    ? (titleRef as? String ?? "")
                    : ""
                var sizeRef: CFTypeRef?
                let hasSize = AXUIElementCopyAttributeValue(axWin, kAXSizeAttribute as CFString, &sizeRef) == .success
                let size = hasSize ? (sizeRef as? CGSize ?? .zero) : .zero

                if shouldDebug {
                    AppLog.app.info("🧭 AX window app=\(app.localizedName ?? "Unknown", privacy: .public) title=\(title, privacy: .public) size=\(Int(size.width), privacy: .public)x\(Int(size.height), privacy: .public) minimized=\(isMinimized, privacy: .public)")
                }

                // Ignore zero-sized AX windows unless they are minimized (minimized windows often report 0x0).
                if hasSize && size.width == 0 && size.height == 0 && !isMinimized {
                    continue
                }

                total += 1
                if !isMinimized { visible += 1 }
            }
            return (total, visible)
        }
        return nil
    }
}
