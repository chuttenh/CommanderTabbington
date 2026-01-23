import Cocoa
import CoreGraphics
import Carbon
import OSLog

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
    private var commandReleasePoller: DispatchSourceTimer?
    private let commandReleaseQueue = DispatchQueue(label: "InputListener.commandReleasePoller")
    private var commandReleaseWatchdog: DispatchSourceTimer?
    private let commandReleaseWatchdogQueue = DispatchQueue(label: "InputListener.commandReleaseWatchdog")
    private var commandReleasedSince: CFAbsoluteTime?
    
    #if DEBUG
        var enableDiagnostics: Bool = true
    #else
        let enableDiagnostics: Bool = false
    #endif
    
    // Diagnostics and monitoring
    private var globalKeyMonitor: Any?
    private var secureInputTimer: Timer?
    private var postStartDiagnosticTimer: Timer?
    private var hasShownInputMonitoringAlert: Bool = false
    
    private init() {}

    fileprivate enum AppStateSource {
        case listener
        case delegate
    }

    fileprivate func resolveAppState() -> AppState? {
        return self.appState ?? (NSApp.delegate as? AppDelegate)?.appState
    }

    fileprivate func resolveAppStateWithSource() -> (AppState, AppStateSource)? {
        if let appState = self.appState {
            return (appState, .listener)
        }
        if let appDelegate = NSApp.delegate as? AppDelegate {
            return (appDelegate.appState, .delegate)
        }
        return nil
    }

    fileprivate func commitSelection(stopPoller: Bool = true) {
        guard let appState = resolveAppState() else { return }
        DispatchQueue.main.async {
            appState.commitSelection()
        }
        if stopPoller {
            stopCommandReleasePoller()
            stopCommandReleaseWatchdog()
        }
    }

    fileprivate func handleTapDisabled() {
        stopCommandReleasePoller()
        stopCommandReleaseWatchdog()
        isCommandPressed = false
        DispatchQueue.main.async { [weak self] in
            self?.resolveAppState()?.cancelSelection()
        }
    }

    
    func start() {
        AppLog.input.info("🎛️ Attempting to start Input Listener (Session Tap).")
        let trusted = AXIsProcessTrusted()
        AppLog.input.info("🔒 AXIsProcessTrusted: \(trusted, privacy: .public)")
        
        // Check for Secure Input (can block session taps, sometimes affects HID taps)
        if IsSecureEventInputEnabled() {
            AppLog.input.log("⚠️ Warning: Secure Input is enabled. Keyboard events may be suppressed.")
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
                        AppLog.input.debug("🔐 Secure Input is ON; keyboard taps will be blocked.")
                    }
                }
                // Add a global NSEvent monitor to help trigger Input Monitoring prompt and verify key events
                self.globalKeyMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.keyDown, .flagsChanged]) { e in
                    AppLog.input.debug("🛰️ NSEvent global key: \(e.keyCode, privacy: .public) flags: \(e.modifierFlags.rawValue, privacy: .public)")
                }
                
                // Local monitor fallback: works when our app is key and a text field has focus
                self.localEventMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .flagsChanged, .keyUp]) { [weak self] e in
                    guard let self = self else { return e }
                    let keyCode = e.keyCode
                    let hasCommand = e.modifierFlags.contains(.command)

                    switch e.type {
                    case .keyDown:
                        if hasCommand && keyCode == UInt16(self.kVK_Tab) {
                            if self.enableDiagnostics { AppLog.input.debug("🧩 Local monitor detected Cmd+Tab (fallback).") }
                            // Avoid double-trigger if HID tap already handled
                            if !self.receivedKeyboardEvent {
                                DispatchQueue.main.async { [weak self] in
                                    guard let self = self else { return }
                                    self.resolveAppState()?.handleUserActivation(direction: e.modifierFlags.contains(.shift) ? .previous : .next)
                                }
                            }
                            return nil // suppress in our app
                        }
                    case .flagsChanged:
                        let isCmdNow = hasCommand
                        if !isCmdNow {
                            if let _ = self.resolveAppState() {
                                if self.enableDiagnostics { AppLog.input.debug("✅ Local monitor committing on Command release (fallback).") }
                                self.commitSelection()
                                return nil
                            }
                        }
                    case .keyUp:
                        if keyCode == UInt16(self.kVK_Tab) {
                            if !hasCommand {
                                if let _ = self.resolveAppState() {
                                    if self.enableDiagnostics { AppLog.input.debug("✅ Local monitor committing on Tab keyUp (fallback).") }
                                    self.commitSelection()
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
                    AppLog.input.debug("\(self.suppressionEnabled ? "🧲 Using HID-level event tap (suppression enabled)." : "👂 Using HID-level event tap (listen-only, no suppression).")")
                }
            } else {
                AppLog.input.log("ℹ️ HID-level tap failed. Falling back to Session-level tap.")
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
                    AppLog.input.debug("\(self.suppressionEnabled ? "🧭 Using Session-level event tap (suppression enabled)." : "👂 Using Session-level event tap (listen-only, no suppression).")")
                }
            }
            
            guard let tap = createdTap else {
                AppLog.input.fault("❌ Could not create event tap. Check Accessibility and Input Monitoring permissions. If running under Xcode, add Xcode to Input Monitoring.")
                if AXIsProcessTrusted() && !CGPreflightListenEventAccess() {
                    self.presentInputMonitoringAlertIfNeeded()
                }
                return
            }
            
            self.eventTap = tap
            
            // 3. ATTACH TO MAIN RUNLOOP
            let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
            self.runLoopSource = source
            CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
            
            // 4. ENABLE
            CGEvent.tapEnable(tap: tap, enable: true)
            AppLog.input.info("✅ Input Listener attached (Session Level). Waiting for events...")
        }
    }

    private func presentInputMonitoringAlertIfNeeded() {
        guard !hasShownInputMonitoringAlert else { return }
        hasShownInputMonitoringAlert = true
        DispatchQueue.main.async {
            let alert = NSAlert()
            alert.messageText = "Input Monitoring Permission Needed"
            alert.informativeText = "Commander Tabbington could not create a global keyboard event tap. Grant Input Monitoring permission in System Settings to enable global shortcuts, then relaunch the app."
            alert.addButton(withTitle: "Open Input Monitoring Settings")
            alert.addButton(withTitle: "Quit")
            let response = alert.runModal()
            if response == .alertFirstButtonReturn {
                if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent") {
                    NSWorkspace.shared.open(url)
                }
            } else {
                NSApp.terminate(nil)
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
        if let m = localEventMonitor { NSEvent.removeMonitor(m); localEventMonitor = nil }
        secureInputTimer?.invalidate(); secureInputTimer = nil
        postStartDiagnosticTimer?.invalidate(); postStartDiagnosticTimer = nil
        stopCommandReleasePoller()
        stopCommandReleaseWatchdog()
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
        // Poll for Command key release independent of event delivery.
        let timer = DispatchSource.makeTimerSource(queue: commandReleaseQueue)
        timer.schedule(deadline: .now(), repeating: .milliseconds(30), leeway: .milliseconds(5))
        timer.setEventHandler { [weak self] in
            guard let self = self else { return }
            // If switcher not visible, stop polling
            guard let appState = self.resolveAppState(), appState.isSwitcherVisible else {
                self.stopCommandReleasePoller()
                return
            }
            // Check current flags state for Command key
            let flags = CGEventSource.flagsState(.combinedSessionState)
            let commandDown = flags.contains(.maskCommand)
            if !commandDown {
                if self.enableDiagnostics { AppLog.input.debug("🕵️‍♂️ Poller detected Command release; committing selection.") }
                self.commitSelection()
            }
        }
        commandReleasePoller = timer
        timer.resume()
    }

    fileprivate func stopCommandReleasePoller() {
        if let timer = commandReleasePoller {
            timer.cancel()
            commandReleasePoller = nil
        }
    }

    fileprivate func startCommandReleaseWatchdog() {
        stopCommandReleaseWatchdog()
        let timer = DispatchSource.makeTimerSource(queue: commandReleaseWatchdogQueue)
        timer.schedule(deadline: .now(), repeating: .milliseconds(50), leeway: .milliseconds(20))
        timer.setEventHandler { [weak self] in
            guard let self = self else { return }
            let flags = CGEventSource.flagsState(.combinedSessionState)
            let commandDown = flags.contains(.maskCommand)
            if commandDown {
                self.commandReleasedSince = nil
                return
            }
            let now = CFAbsoluteTimeGetCurrent()
            if let since = self.commandReleasedSince {
                if now - since >= 0.25 {
                    if self.enableDiagnostics { AppLog.input.debug("🧯 Watchdog detected Command release; committing selection.") }
                    self.commitSelection()
                }
            } else {
                self.commandReleasedSince = now
            }
        }
        commandReleaseWatchdog = timer
        timer.resume()
    }

    fileprivate func resetCommandReleaseWatchdogState() {
        commandReleasedSince = nil
    }

    fileprivate func stopCommandReleaseWatchdog() {
        if let timer = commandReleaseWatchdog {
            timer.cancel()
            commandReleaseWatchdog = nil
        }
        commandReleasedSince = nil
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
        AppLog.input.log("⚠️ Warning: Event Tap disabled (Type: \(type.rawValue, privacy: .public)). Re-enabling...")
        if let tap = listener.eventTap {
            CGEvent.tapEnable(tap: tap, enable: true)
        }
        listener.handleTapDisabled()
        return Unmanaged.passUnretained(event)
    }

    if type == .keyDown {
        let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
        listener.noteKeyboardEventReceived()
        
        let flags = event.flags
        let hasCommand = (flags.rawValue & CGEventFlags.maskCommand.rawValue) != 0
        let cmdActive = hasCommand || listener.isCommandPressed
        if cmdActive {
            listener.resetCommandReleaseWatchdogState()
        }
        
        // Check for Cmd+Tab (or Cmd+Shift+Tab) and suppress
        if cmdActive && keyCode == listener.kVK_Tab {
            if listener.enableDiagnostics {
                AppLog.input.debug("🚀 Detected Cmd+Tab (suppressing, HID tap: \(listener.usingHIDTap, privacy: .public)).")
                AppLog.input.debug("📣 Invoking appState.handleUserActivation from InputListener.")
            }
            let direction: SelectionDirection = flags.contains(.maskShift) ? .previous : .next
            
            DispatchQueue.main.async {
                if let appState = listener.resolveAppState() {
                    if listener.enableDiagnostics {
                        AppLog.input.debug("🧩 InputListener will call handleUserActivation on AppState: \(String(describing: Unmanaged.passUnretained(appState).toOpaque()), privacy: .public)")
                    }
                    appState.handleUserActivation(direction: direction)
                    // Start release poller to handle cases where flagsChanged/keyUp are suppressed
                    listener.startCommandReleasePoller()
                    listener.startCommandReleaseWatchdog()
                } else {
                    AppLog.input.error("❓ No AppState available to handle activation.")
                }
            }
            
            // Return nil to suppress the event (prevent system App Switcher)
            return nil
        }
        
        AppLog.input.debug("⌨️ Key Down: \(keyCode, privacy: .public)")
    }
    
    if type == .keyUp {
        let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
        let flags = event.flags
        let hasCommand = (flags.rawValue & CGEventFlags.maskCommand.rawValue) != 0

        // Diagnostic logging
        if listener.enableDiagnostics {
            AppLog.input.debug("⬆️ keyUp: keyCode=\(keyCode, privacy: .public) hasCommand=\(hasCommand, privacy: .public) isCmdPressed=\(listener.isCommandPressed, privacy: .public)")
        }

        if keyCode == listener.kVK_Tab {
            // If Command is no longer held, but our flagsChanged didn't fire (e.g., due to secure input or focus quirks),
            // commit the selection as a fallback when Tab is released.
            if !hasCommand {
                if listener.enableDiagnostics { AppLog.input.debug("✅ Fallback commit on Tab keyUp (Command not held).") }
                if listener.resolveAppState() != nil {
                    listener.commitSelection()
                }
                // Ensure we clear our internal state
                listener.isCommandPressed = false
            } else {
                if listener.enableDiagnostics { AppLog.input.debug("🛑 Suppressing Cmd+Tab keyUp while Command still held.") }
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
            AppLog.input.debug("🎛️ flagsChanged: isCmdNow=\(isCmdNow, privacy: .public) was=\(listener.isCommandPressed, privacy: .public) flags=\(flags.rawValue, privacy: .public)")
        }
        
        // Log current switcher visibility
        if let appDelegate = NSApp.delegate as? AppDelegate {
            let visible = appDelegate.appState.isSwitcherVisible
            if listener.enableDiagnostics {
                AppLog.input.debug("👁️ isSwitcherVisible at flagsChanged: \(visible, privacy: .public)")
            }
        }
        
        listener.noteKeyboardEventReceived()
        
        if !isCmdNow {
            if let (appState, source) = listener.resolveAppStateWithSource() {
                if listener.enableDiagnostics {
                    let sourceLabel = source == .listener ? "listener.appState" : "AppDelegate"
                    AppLog.input.debug("✅ Committing selection on Command release (flagsChanged via \(sourceLabel)).")
                }
                DispatchQueue.main.async {
                    appState.commitSelection()
                }
                listener.stopCommandReleasePoller()
            } else {
                if listener.enableDiagnostics { AppLog.input.debug("❓ No AppState available on Command release.") }
            }
        } else {
            listener.resetCommandReleaseWatchdogState()
        }
        listener.isCommandPressed = isCmdNow
    }
    
    return Unmanaged.passUnretained(event)
}
