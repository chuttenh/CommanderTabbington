import Cocoa
import CoreGraphics
import ApplicationServices

class AccessibilityService {
    
    static let shared = AccessibilityService()
    private init() {}
    
    /// The specific command to bring a window to the foreground.
    func focus(window: SystemWindow) {
        // 1. Activate the owning application first.
        // This is much more reliable than trying to raise the window in a background app.
        // .activateIgnoringOtherApps is crucial so it steals focus from us.
        guard let app = window.owningApplication else { return }
        
        // We use the NSApplication API for the app activation part (high level)
        app.activate(options: .activateIgnoringOtherApps)
        
        // 2. Locate the specific window via Accessibility API (low level)
        // We need to create an AXUIElement from the Process ID (PID).
        let appElement = AXUIElementCreateApplication(window.ownerPID)
        
        // 3. Find the matching window element in that app
        // Note: This can be slow. In a production app, you might optimize this
        // by caching the AXUIElement in the SystemWindow struct during the initial fetch.
        if let targetWindowElement = findAXWindow(in: appElement, matching: window.windowID) {
            
            // 4. Raise the window
            performAction(.raise, on: targetWindowElement)
            
            // 5. Explicitly focus the window (sometimes Raise isn't enough)
            // Note: AXUIElementSetAttribute is how we change properties (like "Main" status).
            AXUIElementSetAttributeValue(targetWindowElement, kAXMainAttribute as CFString, kCFBooleanTrue)
        }
    }
    
    private func findAXWindow(in appElement: AXUIElement, matching targetID: CGWindowID) -> AXUIElement? {
        var windowsRef: CFTypeRef?
        
        // Ask the app for its list of windows
        let result = AXUIElementCopyAttributeValue(appElement, kAXWindowsAttribute as CFString, &windowsRef)
        
        guard result == .success, let windows = windowsRef as? [AXUIElement] else {
            return nil
        }
        
        // Iterate through the AX windows to find the one that matches our CGWindowID.
        // Unfortunately, AX and CG use different ID systems, so we have to bridge them
        // by checking the _AXWindowID_ attribute.
        for axWindow in windows {
            var idRef: CFTypeRef?
            _ = AXUIElementCopyAttributeValue(axWindow, "AXWindowID" as CFString, &idRef)
            
            if let idNum = idRef as? Int32, CGWindowID(idNum) == targetID {
                return axWindow
            }
        }
        
        return nil
    }
    
    private enum WindowAction {
        case raise
    }
    
    private func performAction(_ action: WindowAction, on element: AXUIElement) {
        let actionName: String
        switch action {
        case .raise: actionName = kAXRaiseAction
        }
        
        AXUIElementPerformAction(element, actionName as CFString)
    }
    
    /// Activates the app and raises all of its on-screen windows above other apps while preserving the app's internal z-order.
    func bringAllWindowsToFront(for app: NSRunningApplication) {
        let pid = app.processIdentifier

        // Activate the app so it becomes frontmost
        app.activate(options: .activateIgnoringOtherApps)

        // AX app element
        let appElement = AXUIElementCreateApplication(pid)

        // Ensure the app isn't hidden
        AXUIElementSetAttributeValue(appElement, kAXHiddenAttribute as CFString, kCFBooleanFalse)

        // Collect AX windows and map to CGWindowIDs
        var windowsRef: CFTypeRef?
        var axWindowsAll: [AXUIElement] = []
        if AXUIElementCopyAttributeValue(appElement, kAXWindowsAttribute as CFString, &windowsRef) == .success,
           let arr = windowsRef as? [AXUIElement] {
            axWindowsAll = arr
        }

        // Filter to standard AX windows (role == AXWindow)
        var axWindows: [AXUIElement] = []
        for ax in axWindowsAll {
            var roleRef: CFTypeRef?
            var isWindow = false
            if AXUIElementCopyAttributeValue(ax, kAXRoleAttribute as CFString, &roleRef) == .success,
               let role = roleRef as? String {
                isWindow = (role == kAXWindowRole as String)
            }
            if isWindow { axWindows.append(ax) }
        }

        // Map AX elements by their CGWindowID (prefer AXWindowID; fall back to AXWindowNumber)
        var elementByID: [CGWindowID: AXUIElement] = [:]
        for ax in axWindows {
            var idRef: CFTypeRef?
            if AXUIElementCopyAttributeValue(ax, "AXWindowID" as CFString, &idRef) == .success,
               let idNum = idRef as? Int32 {
                elementByID[CGWindowID(idNum)] = ax
            } else if AXUIElementCopyAttributeValue(ax, "AXWindowNumber" as CFString, &idRef) == .success,
                      let idNum = idRef as? Int {
                elementByID[CGWindowID(idNum)] = ax
            }
        }

        // Determine the topmost window for this app from CG (topmost first)
        var topElement: AXUIElement?
        if let infoList = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] {
            for entry in infoList {
                if let owner = entry[kCGWindowOwnerPID as String] as? Int32, owner == pid,
                   let layer = entry[kCGWindowLayer as String] as? Int, layer == 0,
                   let alpha = entry[kCGWindowAlpha as String] as? Double, alpha >= 0.01,
                   let idNum = entry[kCGWindowNumber as String] as? Int {
                    let wid = CGWindowID(idNum)
                    if let el = elementByID[wid] {
                        topElement = el
                        break
                    }
                }
            }
        }

        // Fallback to any AX window if we couldn't map a CG window
        if topElement == nil { topElement = axWindows.first }

        // If we have a top element, ensure it is unminimized, raised, and focused
        if let topEl = topElement {
            var minRef: CFTypeRef?
            var isMinimized = false
            if AXUIElementCopyAttributeValue(topEl, kAXMinimizedAttribute as CFString, &minRef) == .success,
               let min = minRef as? Bool {
                isMinimized = min
            }
            if isMinimized {
                AXUIElementSetAttributeValue(topEl, kAXMinimizedAttribute as CFString, kCFBooleanFalse)
            }

            // Raise just the top window to avoid flicker between multiple windows
            AXUIElementPerformAction(topEl, kAXRaiseAction as CFString)

            // Mark as main and focused
            AXUIElementSetAttributeValue(topEl, kAXMainAttribute as CFString, kCFBooleanTrue)
            AXUIElementSetAttributeValue(appElement, kAXFocusedWindowAttribute as CFString, topEl)
        }

        // Ensure the app is marked frontmost
        AXUIElementSetAttributeValue(appElement, kAXFrontmostAttribute as CFString, kCFBooleanTrue)

        // One lightweight follow-up to reinforce frontmost state without re-raising all windows
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.06) {
            AXUIElementSetAttributeValue(appElement, kAXFrontmostAttribute as CFString, kCFBooleanTrue)
        }
    }
}

