import Cocoa
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
}
