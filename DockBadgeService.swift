import Cocoa
import ApplicationServices

private let AXStatusLabelAttributeName: CFString = "AXStatusLabel" as CFString

private enum PrefKeys {
    static let includeHiddenApps = "IncludeHiddenApps"
    static let includeMinimizedApps = "IncludeMinimizedApps"
}

extension UserDefaults {
    var includeHiddenApps: Bool {
        get { object(forKey: PrefKeys.includeHiddenApps) as? Bool ?? true }
        set { set(newValue, forKey: PrefKeys.includeHiddenApps) }
    }
    var includeMinimizedApps: Bool {
        get { object(forKey: PrefKeys.includeMinimizedApps) as? Bool ?? true }
        set { set(newValue, forKey: PrefKeys.includeMinimizedApps) }
    }
}

extension Notification.Name {
    static let dockBadgePreferencesDidChange = Notification.Name("DockBadgePreferencesDidChange")
}

extension DockBadgeService {
    static var includeHiddenApps: Bool {
        get { UserDefaults.standard.includeHiddenApps }
        set {
            UserDefaults.standard.includeHiddenApps = newValue
            NotificationCenter.default.post(name: .dockBadgePreferencesDidChange, object: nil)
        }
    }
    static var includeMinimizedApps: Bool {
        get { UserDefaults.standard.includeMinimizedApps }
        set {
            UserDefaults.standard.includeMinimizedApps = newValue
            NotificationCenter.default.post(name: .dockBadgePreferencesDidChange, object: nil)
        }
    }
}

final class DockBadgeService {
    static let shared = DockBadgeService()
    private init() {
        UserDefaults.standard.register(defaults: [
            PrefKeys.includeHiddenApps: true,
            PrefKeys.includeMinimizedApps: true
        ])
    }

    // Returns: nil = no badge, 0 = badge dot without number, >0 = numeric badge count
    func badgeCount(for app: NSRunningApplication?) -> Int? {
        guard let app = app else { return nil }

        // Respect preferences for hidden or minimized apps
        let includeHidden = UserDefaults.standard.includeHiddenApps
        if !includeHidden && app.isHidden {
            return nil
        }

        // Find the Dock application
        guard let dockApp = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.dock").first else {
            return nil
        }
        let dockAX = AXUIElementCreateApplication(dockApp.processIdentifier)
        // Traverse Dock UI to find the item for this app and read AXStatusLabel
        if let item = findDockItem(forApp: app, in: dockAX) {
            // Optionally exclude minimized apps based on preference
            let includeMinimized = UserDefaults.standard.includeMinimizedApps
            if !includeMinimized {
                var isMinimized = false
                // First, try Dock item's minimized state
                var minimizedRef: CFTypeRef?
                if AXUIElementCopyAttributeValue(item, kAXMinimizedAttribute as CFString, &minimizedRef) == .success,
                   let minimized = minimizedRef as? Bool {
                    isMinimized = minimized
                } else {
                    // Fallback: check if all windows are minimized or hidden via app's AX element
                    let appAX = AXUIElementCreateApplication(app.processIdentifier)
                    var windowsRef: CFTypeRef?
                    if AXUIElementCopyAttributeValue(appAX, kAXWindowsAttribute as CFString, &windowsRef) == .success,
                       let windows = windowsRef as? [AXUIElement] {
                        var anyVisible = false
                        for win in windows {
                            var minimizedWinRef: CFTypeRef?
                            if AXUIElementCopyAttributeValue(win, kAXMinimizedAttribute as CFString, &minimizedWinRef) == .success,
                               let winMin = minimizedWinRef as? Bool {
                                if !winMin { anyVisible = true; break }
                            } else {
                                // If we can't read minimized, assume visible to avoid false exclusion
                                anyVisible = true; break
                            }
                        }
                        isMinimized = !anyVisible
                    }
                }
                if isMinimized { return nil }
            }

            var labelRef: CFTypeRef?
            let result = AXUIElementCopyAttributeValue(item, AXStatusLabelAttributeName, &labelRef)
            if result == .success, let label = labelRef as? String {
                let trimmed = label.trimmingCharacters(in: .whitespacesAndNewlines)
                if trimmed.isEmpty {
                    // Some badges may be non-empty semantics; treat empty as a dot
                    return 0
                }
                if let n = Int(trimmed) {
                    return n
                } else {
                    // Non-numeric badge (e.g., symbol). Show dot only.
                    return 0
                }
            }
        }
        return nil
    }

    private func findDockItem(forApp app: NSRunningApplication, in dockAX: AXUIElement) -> AXUIElement? {
        // The Dock exposes items as children; we search for a child whose title matches the app name
        var childrenRef: CFTypeRef?
        let res = AXUIElementCopyAttributeValue(dockAX, kAXChildrenAttribute as CFString, &childrenRef)
        guard res == .success, let children = childrenRef as? [AXUIElement] else { return nil }
        let targetNames = Set([app.localizedName, app.bundleIdentifier].compactMap { $0 })
        for child in children {
            if let match = findDockItemRecursive(in: child, targetNames: targetNames) {
                return match
            }
        }
        return nil
    }

    private func findDockItemRecursive(in element: AXUIElement, targetNames: Set<String>) -> AXUIElement? {
        // Check this element's title
        var titleRef: CFTypeRef?
        if AXUIElementCopyAttributeValue(element, kAXTitleAttribute as CFString, &titleRef) == .success,
           let title = titleRef as? String,
           targetNames.contains(title) {
            return element
        }
        // Recurse into children
        var childrenRef: CFTypeRef?
        if AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &childrenRef) == .success,
           let children = childrenRef as? [AXUIElement] {
            for child in children {
                if let found = findDockItemRecursive(in: child, targetNames: targetNames) {
                    return found
                }
            }
        }
        return nil
    }
}
