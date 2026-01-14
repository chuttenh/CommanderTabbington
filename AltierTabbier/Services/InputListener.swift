import Cocoa
import CoreGraphics
import Carbon

class InputListener {
    
    static let shared = InputListener()
    
    // Internal properties
    let kVK_Tab: Int64 = 0x30
    var isCommandPressed = false
    weak var appState: AppState?
    
    private(set) var usingHIDTap: Bool = false
    var receivedKeyboardEvent: Bool = false
    
    // The tap must be stored as a CFMachPort
    var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    
    #if DEBUG
        var enableDiagnostics: Bool = true
    #else
        let enableDiagnostics: Bool = false
    #endif
    
    // Diagnostics and monitoring
    private var globalKeyMonitor: Any?
    private var secureInputTimer: Timer?
    private var postStartDiagnosticTimer: Timer?
    
    private init() {}
    
    func start() {
        print("--- Attempting to Start Input Listener (Session Tap) ---")
        let trusted = AXIsProcessTrusted()
        print("🔒 AXIsProcessTrusted: \(trusted)")
        
        // Check for Secure Input (can block session taps, sometimes affects HID taps)
        if IsSecureEventInputEnabled() {
            print("⚠️ WARNING: Secure Input is enabled! Keyboard events may be suppressed.")
        }
        
        // DELAY START to ensure RunLoop is ready
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            
            // Diagnostics: clear previous monitors/timers
            if let t = self.secureInputTimer { t.invalidate(); self.secureInputTimer = nil }
            if let t = self.postStartDiagnosticTimer { t.invalidate(); self.postStartDiagnosticTimer = nil }
            if let m = self.globalKeyMonitor { NSEvent.removeMonitor(m); self.globalKeyMonitor = nil }
            
            #if DEBUG
            if self.enableDiagnostics {
                // Periodically log Secure Input status
                self.secureInputTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { _ in
                    if IsSecureEventInputEnabled() {
                        print("🔐 Secure Input is ON – keyboard taps will be blocked.")
                    }
                }
                // Add a global NSEvent monitor to help trigger Input Monitoring prompt and verify key events
                self.globalKeyMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.keyDown, .flagsChanged]) { e in
                    print("🛰️ NSEvent global key: \(e.keyCode) flags: \(e.modifierFlags)")
                }
            }
            #endif
            
            // 1. EVENT MASK
            // We listen for KeyDown, KeyUp, FlagsChanged, and MouseDown (to verify tap is alive)
            let mask: CGEventMask = (CGEventMask(1) << CGEventType.keyDown.rawValue) |
                                    (CGEventMask(1) << CGEventType.keyUp.rawValue) |
                                    (CGEventMask(1) << CGEventType.flagsChanged.rawValue) |
                                    (CGEventMask(1) << CGEventType.leftMouseDown.rawValue)
            
            // 2. CREATE TAP
            var createdTap: CFMachPort? = nil

            // Try HID-level tap first for reliability; fall back to Session-level.
            createdTap = CGEvent.tapCreate(
                tap: .cghidEventTap,
                place: .headInsertEventTap,
                options: .defaultTap,
                eventsOfInterest: mask,
                callback: inputCallback,
                userInfo: Unmanaged.passUnretained(self).toOpaque()
            )

            if let _ = createdTap {
                self.usingHIDTap = true
                if self.enableDiagnostics {
                    print("🧲 Using HID-level event tap (suppression enabled).")
                }
            } else {
                print("ℹ️ HID-level tap failed. Falling back to Session-level tap.")
                createdTap = CGEvent.tapCreate(
                    tap: .cgSessionEventTap,
                    place: .headInsertEventTap,
                    options: .defaultTap,
                    eventsOfInterest: mask,
                    callback: inputCallback,
                    userInfo: Unmanaged.passUnretained(self).toOpaque()
                )
                self.usingHIDTap = false
                if self.enableDiagnostics {
                    print("🧭 Using Session-level event tap (system shortcuts like Cmd+Tab may not be suppressible).")
                }
            }
            
            guard let tap = createdTap else {
                print("❌ FATAL: Could not create event tap. Check Accessibility and Input Monitoring permissions. If running under Xcode, add Xcode to Input Monitoring.")
                return
            }
            
            self.eventTap = tap
            
            // 3. ATTACH TO MAIN RUNLOOP
            let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
            self.runLoopSource = source
            CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
            
            // 4. ENABLE
            CGEvent.tapEnable(tap: tap, enable: true)
            print("✅ Input Listener Attached (Session Level). Waiting for events...")
            
            // Post-start diagnostic: if we don't see any keyboard events shortly, print guidance
            self.receivedKeyboardEvent = false
            self.postStartDiagnosticTimer = Timer.scheduledTimer(withTimeInterval: 5.0, repeats: false) { [weak self] _ in
                guard let self = self else { return }
                if !self.receivedKeyboardEvent {
                    print("❗️ No keyboard events detected yet. If mouse events work but keys do not, verify Input Monitoring in System Settings and that Secure Keyboard Entry is OFF. If running under Xcode, add Xcode to Input Monitoring and relaunch.")
                }
            }
        }
    }
    
    func stop() {
        if let tap = eventTap {
            CGEvent.tapEnable(tap: tap, enable: false)
            if let source = runLoopSource {
                CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
            }
        }
        // Diagnostics cleanup
        if let m = globalKeyMonitor { NSEvent.removeMonitor(m); globalKeyMonitor = nil }
        secureInputTimer?.invalidate(); secureInputTimer = nil
        postStartDiagnosticTimer?.invalidate(); postStartDiagnosticTimer = nil
    }
    
    func noteKeyboardEventReceived() {
        DispatchQueue.main.async {
            self.receivedKeyboardEvent = true
            self.postStartDiagnosticTimer?.invalidate()
            self.postStartDiagnosticTimer = nil
        }
    }
}

// MARK: - Global Callback
// @convention(c) ensures this is treated as a C function pointer
func inputCallback(proxy: CGEventTapProxy, type: CGEventType, event: CGEvent, refcon: UnsafeMutableRawPointer?) -> Unmanaged<CGEvent>? {
    
    // 1. RECOVER THE LISTENER SAFELY
    guard let refcon = refcon else { return Unmanaged.passUnretained(event) }
    let listener = Unmanaged<InputListener>.fromOpaque(refcon).takeUnretainedValue()

    // 2. CHECK FOR TAP DEATH
    if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
        print("⚠️ WARNING: Event Tap disabled (Type: \(type.rawValue)). Re-enabling...")
        if let tap = listener.eventTap {
            CGEvent.tapEnable(tap: tap, enable: true)
        }
        return Unmanaged.passUnretained(event)
    }
    
    // 3. LOGGING (Temporary)
    if type == .leftMouseDown { print("🖱️ Mouse Click") }
    
    if type == .keyDown {
        let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
        listener.noteKeyboardEventReceived()
        
        let flags = event.flags
        let hasCommand = (flags.rawValue & CGEventFlags.maskCommand.rawValue) != 0
        let cmdActive = hasCommand || listener.isCommandPressed
        
        // Check for Cmd+Tab (or Cmd+Shift+Tab) and suppress
        if cmdActive && keyCode == listener.kVK_Tab {
            if listener.enableDiagnostics {
                print("🚀 DETECTED Cmd+Tab (suppressing, HID tap: \(listener.usingHIDTap))")
                print("📣 Invoking appState.handleUserActivation from InputListener")
            }
            let direction: SelectionDirection = flags.contains(.maskShift) ? .previous : .next
            
            DispatchQueue.main.async {
                if let appState = listener.appState {
                    if listener.enableDiagnostics {
                        print("🧩 InputListener will call handleUserActivation on AppState: \(Unmanaged.passUnretained(appState).toOpaque())")
                    }
                    appState.handleUserActivation(direction: direction)
                } else if let appDelegate = NSApp.delegate as? AppDelegate {
                    if listener.enableDiagnostics {
                        print("🧷 Fallback to AppDelegate.appState for handleUserActivation")
                    }
                    appDelegate.appState.handleUserActivation(direction: direction)
                } else {
                    print("❓ No AppState available to handle activation.")
                }
            }
            
            // Return nil to suppress the event (prevent system App Switcher)
            return nil
        }
        
        print("⌨️ Key Down: \(keyCode)")
    }
    
    if type == .keyUp {
        let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
        let flags = event.flags
        let hasCommand = (flags.rawValue & CGEventFlags.maskCommand.rawValue) != 0
        let cmdActive = hasCommand || listener.isCommandPressed
        if cmdActive && keyCode == listener.kVK_Tab {
            if listener.enableDiagnostics {
                print("🛑 Suppressing Cmd+Tab keyUp (HID tap: \(listener.usingHIDTap))")
            }
            return nil
        }
    }
    
    // 4. KEYBOARD LOGIC - flagsChanged and command pressed logic remain unchanged
    if type == .flagsChanged {
        let flags = event.flags
        let isCmdNow = (flags.rawValue & CGEventFlags.maskCommand.rawValue) != 0
        
        listener.noteKeyboardEventReceived()
        
        // If Command was released and the switcher is visible, commit selection
        if listener.isCommandPressed && !isCmdNow {
            if let appDelegate = NSApp.delegate as? AppDelegate {
                let appState = appDelegate.appState
                if appState.isSwitcherVisible {
                    DispatchQueue.main.async {
                        appState.commitSelection()
                    }
                }
            }
        }
        listener.isCommandPressed = isCmdNow
    }
    
    return Unmanaged.passUnretained(event)
}

