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

    // When false, we create a listen-only tap that cannot suppress events
    var suppressionEnabled: Bool = true
    
    // The tap must be stored as a CFMachPort
    var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var localEventMonitor: Any?
    private var commandReleasePoller: Timer?
    
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
            if let m = self.localEventMonitor { NSEvent.removeMonitor(m); self.localEventMonitor = nil }
            
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
                
                // Local monitor fallback: works when our app is key and a text field has focus
                self.localEventMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .flagsChanged, .keyUp]) { [weak self] e in
                    guard let self = self else { return e }
                    let keyCode = e.keyCode
                    let hasCommand = e.modifierFlags.contains(.command)

                    switch e.type {
                    case .keyDown:
                        if hasCommand && keyCode == UInt16(self.kVK_Tab) {
                            if self.enableDiagnostics { print("🧩 Local monitor detected Cmd+Tab (fallback)") }
                            // Avoid double-trigger if HID tap already handled
                            if !self.receivedKeyboardEvent {
                                DispatchQueue.main.async { [weak self] in
                                    guard let self = self else { return }
                                    let appState = self.appState ?? (NSApp.delegate as? AppDelegate)?.appState
                                    appState?.handleUserActivation(direction: e.modifierFlags.contains(.shift) ? .previous : .next)
                                }
                            }
                            return nil // suppress in our app
                        }
                    case .flagsChanged:
                        let isCmdNow = hasCommand
                        if !isCmdNow {
                            let appState = self.appState ?? (NSApp.delegate as? AppDelegate)?.appState
                            if let appState = appState {
                                if self.enableDiagnostics { print("✅ Local monitor committing on Command release (fallback)") }
                                DispatchQueue.main.async {
                                    appState.commitSelection()
                                    self.stopCommandReleasePoller()
                                }
                                return nil
                            }
                        }
                    case .keyUp:
                        if keyCode == UInt16(self.kVK_Tab) {
                            if !hasCommand {
                                let appState = self.appState ?? (NSApp.delegate as? AppDelegate)?.appState
                                if let appState = appState {
                                    if self.enableDiagnostics { print("✅ Local monitor committing on Tab keyUp (fallback)") }
                                    DispatchQueue.main.async {
                                        appState.commitSelection()
                                        self.stopCommandReleasePoller()
                                    }
                                }
                            }
                            return nil
                        }
                    default:
                        break
                    }
                    return e
                }
            }
            #endif
            
            // 1. EVENT MASK
            // We listen only for KeyDown, KeyUp, and FlagsChanged (keyboard-only).
            let mask: CGEventMask = (CGEventMask(1) << CGEventType.keyDown.rawValue) |
                                    (CGEventMask(1) << CGEventType.keyUp.rawValue) |
                                    (CGEventMask(1) << CGEventType.flagsChanged.rawValue)
            
            // 2. CREATE TAP
            let tapOptions: CGEventTapOptions = self.suppressionEnabled ? .defaultTap : .listenOnly
            
            var createdTap: CFMachPort? = nil

            // Try HID-level tap first for reliability; fall back to Session-level.
            createdTap = CGEvent.tapCreate(
                tap: .cghidEventTap,
                place: .headInsertEventTap,
                options: tapOptions,
                eventsOfInterest: mask,
                callback: inputCallback,
                userInfo: Unmanaged.passUnretained(self).toOpaque()
            )

            if let _ = createdTap {
                self.usingHIDTap = true
                if self.enableDiagnostics {
                    print(self.suppressionEnabled ? "🧲 Using HID-level event tap (suppression enabled)." : "👂 Using HID-level event tap (listen-only, no suppression).")
                }
            } else {
                print("ℹ️ HID-level tap failed. Falling back to Session-level tap.")
                createdTap = CGEvent.tapCreate(
                    tap: .cgSessionEventTap,
                    place: .headInsertEventTap,
                    options: tapOptions,
                    eventsOfInterest: mask,
                    callback: inputCallback,
                    userInfo: Unmanaged.passUnretained(self).toOpaque()
                )
                self.usingHIDTap = false
                if self.enableDiagnostics {
                    print(self.suppressionEnabled ? "🧭 Using Session-level event tap (suppression enabled)." : "👂 Using Session-level event tap (listen-only, no suppression).")
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
        if let m = localEventMonitor { NSEvent.removeMonitor(m); localEventMonitor = nil }
        secureInputTimer?.invalidate(); secureInputTimer = nil
        postStartDiagnosticTimer?.invalidate(); postStartDiagnosticTimer = nil
        stopCommandReleasePoller()
    }
    
    func noteKeyboardEventReceived() {
        DispatchQueue.main.async {
            self.receivedKeyboardEvent = true
            self.postStartDiagnosticTimer?.invalidate()
            self.postStartDiagnosticTimer = nil
        }
    }
    
    fileprivate func startCommandReleasePoller() {
        stopCommandReleasePoller()
        // Poll for Command key release independent of event delivery
        commandReleasePoller = Timer.scheduledTimer(withTimeInterval: 0.03, repeats: true) { [weak self] _ in
            guard let self = self else { return }
            // If switcher not visible, stop polling
            let appState = self.appState ?? (NSApp.delegate as? AppDelegate)?.appState
            guard let appState = appState, appState.isSwitcherVisible else {
                self.stopCommandReleasePoller()
                return
            }
            // Check current flags state for Command key
            let flags = CGEventSource.flagsState(.combinedSessionState)
            let commandDown = flags.contains(.maskCommand)
            if !commandDown {
                if self.enableDiagnostics { print("🕵️‍♂️ Poller detected Command release -> committing selection") }
                DispatchQueue.main.async {
                    appState.commitSelection()
                }
                self.stopCommandReleasePoller()
            }
        }
    }

    fileprivate func stopCommandReleasePoller() {
        commandReleasePoller?.invalidate()
        commandReleasePoller = nil
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
                let appState = listener.appState ?? (NSApp.delegate as? AppDelegate)?.appState
                if let appState = appState {
                    if listener.enableDiagnostics {
                        print("🧩 InputListener will call handleUserActivation on AppState: \(Unmanaged.passUnretained(appState).toOpaque())")
                    }
                    appState.handleUserActivation(direction: direction)
                    // Start release poller to handle cases where flagsChanged/keyUp are suppressed
                    listener.startCommandReleasePoller()
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

        // Diagnostic logging
        if listener.enableDiagnostics {
            print("⬆️ keyUp: keyCode=\(keyCode) hasCommand=\(hasCommand) isCmdPressed=\(listener.isCommandPressed)")
        }

        if keyCode == listener.kVK_Tab {
            // If Command is no longer held, but our flagsChanged didn't fire (e.g., due to secure input or focus quirks),
            // commit the selection as a fallback when Tab is released.
            if !hasCommand {
                if listener.enableDiagnostics { print("✅ Fallback commit on Tab keyUp (Command not held)") }
                let appState = listener.appState ?? (NSApp.delegate as? AppDelegate)?.appState
                if let appState = appState {
                    DispatchQueue.main.async {
                        appState.commitSelection()
                    }
                    listener.stopCommandReleasePoller()
                }
                // Ensure we clear our internal state
                listener.isCommandPressed = false
            } else {
                if listener.enableDiagnostics { print("🛑 Suppressing Cmd+Tab keyUp while Command still held") }
            }
            // Always suppress Tab keyUp to avoid system App Switcher glitches
            return nil
        }
    }

    // 4. KEYBOARD LOGIC - flagsChanged and command pressed logic remain unchanged
    if type == .flagsChanged {
        let flags = event.flags
        let isCmdNow = (flags.rawValue & CGEventFlags.maskCommand.rawValue) != 0
        
        if listener.enableDiagnostics {
            print("🎛️ flagsChanged: isCmdNow=\(isCmdNow) was=\(listener.isCommandPressed) flags=\(flags.rawValue)")
        }
        
        // Log current switcher visibility
        if let appDelegate = NSApp.delegate as? AppDelegate {
            let visible = appDelegate.appState.isSwitcherVisible
            if listener.enableDiagnostics {
                print("👁️ isSwitcherVisible at flagsChanged: \(visible)")
            }
        }
        
        listener.noteKeyboardEventReceived()
        
        if !isCmdNow {
            if let appState = listener.appState {
                if listener.enableDiagnostics {
                    print("✅ Committing selection on Command release (flagsChanged via listener.appState)")
                }
                DispatchQueue.main.async {
                    appState.commitSelection()
                }
                listener.stopCommandReleasePoller()
            } else if let appDelegate = NSApp.delegate as? AppDelegate {
                let appState = appDelegate.appState
                if listener.enableDiagnostics {
                    print("✅ Committing selection on Command release (flagsChanged via AppDelegate)")
                }
                DispatchQueue.main.async {
                    appState.commitSelection()
                }
                listener.stopCommandReleasePoller()
            } else {
                if listener.enableDiagnostics { print("❓ No AppState available on Command release") }
            }
        }
        listener.isCommandPressed = isCmdNow
    }
    
    return Unmanaged.passUnretained(event)
}

