import Cocoa
import ApplicationServices

extension Notification.Name {
    static let windowVisibilityDidChange = Notification.Name("WindowVisibilityDidChange")
}

final class FocusMonitor {
    static let shared = FocusMonitor()

    private var observer: AXObserver?
    private var runLoopSource: CFRunLoopSource?

    private init() {}

    func start() {
        // Attach an AXObserver to the system-wide element to receive focus change notifications
        let systemElement = AXUIElementCreateSystemWide()
        var observerRef: AXObserver?
        let pid = getpid()
        let callback: AXObserverCallback = { (observer, element, notification, refcon) in
            guard let notification = notification as String? else { return }
            if notification == kAXFocusedWindowChangedNotification as String || notification == kAXFocusedUIElementChangedNotification as String {
                FocusMonitor.handleFocusChange()
            }
            if notification == kAXWindowMiniaturizedNotification as String || notification == kAXWindowDeminiaturizedNotification as String {
                FocusMonitor.handleWindowStateChange()
            }
        }
        let result = AXObserverCreate(pid, callback, &observerRef)
        if result != .success || observerRef == nil {
            print("⚠️ FocusMonitor: Failed to create AXObserver (result=\(result.rawValue))")
            return
        }
        observer = observerRef
        if let obs = observer {
            AXObserverAddNotification(obs, systemElement, kAXFocusedWindowChangedNotification as CFString, nil)
            AXObserverAddNotification(obs, systemElement, kAXFocusedUIElementChangedNotification as CFString, nil)
            AXObserverAddNotification(obs, systemElement, kAXWindowMiniaturizedNotification as CFString, nil)
            AXObserverAddNotification(obs, systemElement, kAXWindowDeminiaturizedNotification as CFString, nil)
            let source = AXObserverGetRunLoopSource(obs)
            runLoopSource = source
            CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
            if let app = NSWorkspace.shared.frontmostApplication {
                AppRecents.shared.bump(pid: app.processIdentifier)
            }
        }
    }

    func stop() {
        if let source = runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
            runLoopSource = nil
        }
        observer = nil
    }

    private static func handleFocusChange() {
        // Get the focused application and window
        if let frontApp = NSWorkspace.shared.frontmostApplication {
            AppRecents.shared.bump(pid: frontApp.processIdentifier)
        }
        if let infoList = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] {
            // The first entry in the on-screen list is typically the frontmost window
            if let first = infoList.first,
               let idNum = first[kCGWindowNumber as String] as? Int,
               let ownerPID = first[kCGWindowOwnerPID as String] as? Int32 {
                let winID = CGWindowID(idNum)
                WindowRecents.shared.bump(windowID: winID)
                AppRecents.shared.bump(pid: ownerPID)
            }
        }
    }
    
    private static func handleWindowStateChange() {
        // Notify listeners (e.g., AppDelegate) to refresh lists when window minimized/unminimized changes
        NotificationCenter.default.post(name: .windowVisibilityDidChange, object: nil)
    }
}
