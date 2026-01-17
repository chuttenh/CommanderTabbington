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
    var distributedObserver: NSObjectProtocol?
    var defaultsObserver: NSObjectProtocol?
    
    var workspaceObservers: [NSObjectProtocol] = []
    
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Strict single-instance enforcement: if another instance is running, activate it and ask it to open Preferences, then quit.
        if let bundleID = Bundle.main.bundleIdentifier {
            let instances = NSWorkspace.shared.runningApplications.filter { $0.bundleIdentifier == bundleID }
            let currentPID = ProcessInfo.processInfo.processIdentifier
            if instances.count > 1 {
                if let other = instances.first(where: { $0.processIdentifier != currentPID }) ?? instances.first {
                    other.activate(options: .activateIgnoringOtherApps)
                }
                DistributedNotificationCenter.default().post(name: Notification.Name("CommanderTabbingtonOpenPreferences"), object: bundleID)
                NSApp.terminate(nil)
                return
            }
        }
        
        // Register default for switcher open delay (milliseconds)
        UserDefaults.standard.register(defaults: ["switcherOpenDelayMS": 100])
        UserDefaults.standard.register(defaults: [
            "HiddenAppsPlacement": PlacementPreference.normal.rawValue,
            "MinimizedAppsPlacement": PlacementPreference.normal.rawValue
        ])
        
        // A. Check for Accessibility Permissions immediately on launch.
        // Without this, the app cannot see or control other windows.
        checkAccessibilityPermissions()
        
        // B. Setup the Menu Bar Icon (Tray Icon)
        setupStatusBar()
        
        // C. specific setup for the Switcher UI
        setupOverlayWindow()
        
        // Listen for requests from secondary instances to open Preferences
        distributedObserver = DistributedNotificationCenter.default().addObserver(forName: Notification.Name("CommanderTabbingtonOpenPreferences"), object: nil, queue: .main) { [weak self] _ in
            guard let self = self else { return }
            NSApp.activate(ignoringOtherApps: true)
            self.openPreferences()
        }
        
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
                        self.updateOverlaySize()
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
        
        // Recompute size when the data set or mode changes
        appState.$visibleApps
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                self?.updateOverlaySize()
            }
            .store(in: &cancellables)
        
        appState.$visibleWindows
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                self?.updateOverlaySize()
            }
            .store(in: &cancellables)
        
        appState.$mode
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                self?.updateOverlaySize()
            }
            .store(in: &cancellables)
        
        // Observe UserDefaults changes to react to preference updates
        defaultsObserver = NotificationCenter.default.addObserver(forName: UserDefaults.didChangeNotification, object: nil, queue: .main) { [weak self] _ in
            self?.updateOverlaySize()
        }
        
        // Observe workspace app visibility and lifecycle to keep list in sync
        let center = NSWorkspace.shared.notificationCenter
        let handlers: [(Notification.Name, (Notification) -> Void)] = [
            (NSWorkspace.didHideApplicationNotification, { [weak self] _ in self?.refreshIfVisible() }),
            (NSWorkspace.didUnhideApplicationNotification, { [weak self] _ in self?.refreshIfVisible() }),
            (NSWorkspace.didActivateApplicationNotification, { [weak self] _ in self?.refreshIfVisible() }),
            (NSWorkspace.didLaunchApplicationNotification, { [weak self] _ in self?.refreshIfVisible() }),
            (NSWorkspace.didTerminateApplicationNotification, { [weak self] _ in self?.refreshIfVisible() })
        ]
        for (name, handler) in handlers {
            let token = center.addObserver(forName: name, object: nil, queue: .main, using: handler)
            workspaceObservers.append(token)
        }

        // Observe our preferences changes and refresh if needed
        NotificationCenter.default.addObserver(forName: .dockBadgePreferencesDidChange, object: nil, queue: .main) { [weak self] _ in
            self?.refreshIfVisible()
        }
        
        NotificationCenter.default.addObserver(forName: .windowVisibilityDidChange, object: nil, queue: .main) { [weak self] _ in
            self?.refreshIfVisible()
        }
        
        // Start keyboard hooks after UI bindings are ready
        InputListener.shared.appState = appState
        InputListener.shared.start()
        FocusMonitor.shared.start()
        
        // Seed MRU orders from current z-order for first activation
        AppRecents.shared.seedFromCurrentZOrderIfEmpty()
        WindowRecents.shared.seedFromCurrentZOrderIfEmpty()
        
        print("Commander Tabbington started.")
    }
    
    func applicationWillTerminate(_ notification: Notification) {
        FocusMonitor.shared.stop()
        if let obs = distributedObserver {
            DistributedNotificationCenter.default().removeObserver(obs)
        }
        for token in workspaceObservers { NSWorkspace.shared.notificationCenter.removeObserver(token) }
        workspaceObservers.removeAll()
    }
    
    // MARK: - Setup Methods
    
    // Dynamically size the overlay to prefer width, then two rows, then vertical scroll
    private func updateOverlaySize() {
        guard let panel = overlayPanel else { return }
        // Match constants used by SwitcherView
        let itemWidth: CGFloat = 90
        let itemHeight: CGFloat = 110
        let spacing: CGFloat = 12
        let horizontalPadding: CGFloat = 40
        let verticalPadding: CGFloat = 20
        
        // Determine item count based on mode
        let count: Int
        switch appState.mode {
        case .perApp: count = appState.visibleApps.count
        case .perWindow: count = appState.visibleWindows.count
        }
        
        // Early fallback size if nothing to show
        if count == 0 {
            let fallbackSize = NSSize(width: 480, height: 200)
            var frame = panel.frame
            frame.size = fallbackSize
            if let screen = panel.screen?.visibleFrame ?? NSScreen.main?.visibleFrame {
                let origin = NSPoint(x: screen.midX - fallbackSize.width / 2, y: screen.midY - fallbackSize.height / 2)
                frame.origin = origin
            }
            panel.setFrame(frame, display: true)
            return
        }
        
        // Screen constraints and user preferences
        let screenFrame = panel.screen?.visibleFrame ?? NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let widthFraction = UserDefaults.standard.object(forKey: "maxWidthFraction") as? Double ?? 0.9
        let maxRowsPref = UserDefaults.standard.object(forKey: "maxVisibleRows") as? Int ?? 2
        let maxRows = max(1, min(6, maxRowsPref))
        let maxWidth = screenFrame.width * CGFloat(widthFraction)
        
        // Helper to compute total width for a given number of columns
        func widthFor(columns: Int) -> CGFloat {
            let cols = max(1, columns)
            let contentWidth = CGFloat(cols) * itemWidth + CGFloat(max(0, cols - 1)) * spacing
            return contentWidth + horizontalPadding * 2
        }
        // Helper to compute total height for a given number of rows
        func heightFor(rows: Int) -> CGFloat {
            let r = max(1, rows)
            let contentHeight = CGFloat(r) * itemHeight + CGFloat(max(0, r - 1)) * spacing
            return contentHeight + verticalPadding * 2
        }
        
        // Prefer width: try to fit items into 1..maxRows rows within maxWidth
        var selectedRows = 1
        var selectedWidth = min(widthFor(columns: count), maxWidth)
        
        var foundFit = false
        for rows in 1...maxRows {
            let columns = Int(ceil(Double(count) / Double(rows)))
            let requiredWidth = widthFor(columns: columns)
            if requiredWidth <= maxWidth {
                selectedRows = rows
                selectedWidth = requiredWidth
                foundFit = true
                break
            }
        }
        
        if !foundFit {
            // Could not fit within maxWidth even using maxRows; cap width and allow vertical scroll
            selectedRows = maxRows
            selectedWidth = maxWidth
        }
        
        // Cap height to the selected number of rows; additional items will scroll vertically
        let targetHeight = heightFor(rows: selectedRows)
        
        // Apply new frame and keep it centered on the screen
        var newFrame = NSRect(x: 0, y: 0, width: selectedWidth, height: targetHeight)
        let center = NSPoint(x: screenFrame.midX - newFrame.width / 2, y: screenFrame.midY - newFrame.height / 2)
        newFrame.origin = center
        panel.setFrame(newFrame, display: true)
    }
    
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
        
        // Size initially based on current data
        updateOverlaySize()
        
        // Keep it hidden initially
        overlayPanel.orderOut(nil)
    }
    
    private func setupStatusBar() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        
        if let button = statusItem?.button {
            let img = NSImage(named: "StatusBarIcon")
            img?.isTemplate = true
            button.image = img
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
            window.title = "Commander Tabbington Preferences"
            window.center()
            window.isReleasedWhenClosed = false // Keep it in memory when closed
            window.contentView = NSHostingView(rootView: contentView)
            
            preferencesWindow = window
        }
        
        // 3. Show it
        preferencesWindow?.makeKeyAndOrderFront(nil)
    }
    
    private func refreshIfVisible() {
        appState.refreshNow()
    }
}

