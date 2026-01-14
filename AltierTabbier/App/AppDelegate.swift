import Cocoa
import SwiftUI
import Combine

class AppDelegate: NSObject, NSApplicationDelegate {
    
    // 1. The Central State
    // This object will drive the UI. When we update this (e.g., select next window),
    // the SwiftUI view will react automatically.
    var appState = AppState()
    var cancellables = Set<AnyCancellable>()
    
    // 2. The Overlay Window
    // We use NSPanel instead of NSWindow because panels are better suited
    // for auxiliary interfaces (floating, non-activating).
    var overlayPanel: NSPanel!
    
    // 3. Menu Bar Item
    var statusItem: NSStatusItem?
    
    var preferencesWindow: NSWindow?
    
    func applicationDidFinishLaunching(_ notification: Notification) {
        // A. Check for Accessibility Permissions immediately on launch.
        // Without this, the app cannot see or control other windows.
        checkAccessibilityPermissions()
        
        // B. Setup the Menu Bar Icon (Tray Icon)
        setupStatusBar()
        
        // C. specific setup for the Switcher UI
        setupOverlayWindow()
        
        // E. Bind UI Visibility to State
        appState.$isSwitcherVisible
            .receive(on: RunLoop.main)
            .sink { [weak self] isVisible in
                guard let self = self, let panel = self.overlayPanel else { return }
                
                if isVisible {
                    if self.overlayPanel.isVisible == false {
                        if self.overlayPanel.canBecomeVisibleWithoutLogin {
                            // no-op, but keep for future checks
                        }
                        self.overlayPanel.orderFrontRegardless()
                        if self.overlayPanel.isKeyWindow {
                            // Avoid stealing key status
                            NSApp.preventWindowOrdering()
                        }
                    }
                } else {
                    self.overlayPanel.orderOut(nil)
                }
            }
            .store(in: &cancellables)
        // Start keyboard hooks after UI bindings are ready
        InputListener.shared.start()
        InputListener.shared.appState = appState
        
        print("AltierTabbier started.")
    }
    
    // MARK: - Setup Methods
    
    private func setupOverlayWindow() {
        // Create the SwiftUI view that represents the switcher interface
        // We inject the appState so the view knows what to display.
        let contentView = SwitcherView()
            .environmentObject(appState)
        
        // Create the Panel
        // We make it large enough to cover the screen or just center it later.
        // .nonactivatingPanel is CRITICAL: It allows the window to appear
        // without stealing focus from the app the user is currently working in.
        overlayPanel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 800, height: 250),
            styleMask: [.borderless, .nonactivatingPanel, .hudWindow],
            backing: .buffered,
            defer: false
        )
        
        // Visual configuration
        overlayPanel.level = .statusBar // Above most content, without stealing focus
        overlayPanel.collectionBehavior = [.canJoinAllSpaces, .transient, .fullScreenAuxiliary]
        overlayPanel.backgroundColor = .clear
        overlayPanel.isOpaque = false
        overlayPanel.hasShadow = false // SwiftUI will handle the shadow
        overlayPanel.center()
        
        overlayPanel.ignoresMouseEvents = true
        overlayPanel.hidesOnDeactivate = false
        
        // Embed the SwiftUI view into the AppKit panel
        overlayPanel.contentView = NSHostingView(rootView: contentView)
        
        // Keep it hidden initially
        overlayPanel.orderOut(nil)
    }
    
    private func setupStatusBar() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        
        if let button = statusItem?.button {
            // Use a system symbol for now (SF Symbols)
            button.image = NSImage(systemSymbolName: "macwindow.on.rectangle", accessibilityDescription: "AltierTabbier")
        }
        
        let menu = NSMenu()
        menu.addItem(NSMenuItem(title: "Preferences...", action: #selector(openPreferences), keyEquivalent: ","))
        menu.addItem(NSMenuItem.separator())
        menu.addItem(NSMenuItem(title: "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        
        statusItem?.menu = menu
    }
    
    private func checkAccessibilityPermissions() {
        // AXIsProcessTrusted returns true if the user has granted permission.
        let trusted = AXIsProcessTrusted()
        
        if !trusted {
            // In a real app, we would show an alert dialog here prompting the user
            // and providing a button to open System Settings.
            // For now, we just print a warning.
            print("WARNING: Accessibility permissions not granted. Window switching will not work.")
            
            // This options dictionary helps deep-link to the privacy settings
            let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true]
            AXIsProcessTrustedWithOptions(options as CFDictionary)
        }
    }
    
    // MARK: - Actions
    
    @objc func openPreferences() {
        // 1. Force the app to become active (critical for menu bar apps)
        NSApp.activate(ignoringOtherApps: true)
        
        // 2. Create the window if it doesn't exist yet
        if preferencesWindow == nil {
            let contentView = PreferencesView()
                .environmentObject(appState)
                .frame(minWidth: 300, minHeight: 200) // Ensure it has size
            
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 400, height: 300),
                styleMask: [.titled, .closable, .miniaturizable], // Standard window style
                backing: .buffered,
                defer: false
            )
            window.title = "AltierTabbier Preferences"
            window.center()
            window.isReleasedWhenClosed = false // Keep it in memory when closed
            window.contentView = NSHostingView(rootView: contentView)
            
            preferencesWindow = window
        }
        
        // 3. Show it
        preferencesWindow?.makeKeyAndOrderFront(nil)
    }
}

