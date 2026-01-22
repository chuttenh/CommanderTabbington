import Cocoa
import SwiftUI
import Combine
import CoreGraphics
import OSLog

class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    
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
    var appActivationObserver: NSObjectProtocol?
    
    var workspaceObservers: [NSObjectProtocol] = []
    private var lastMissingPermissions: [PermissionType] = []
    private var hasPresentedPermissionsAlert: Bool = false
    private var permissionsAlertTimer: DispatchSourceTimer?
    private var permissionsAccessibilityStatusLabel: NSTextField?
    private var permissionsAccessibilityActionButton: NSButton?
    private var permissionsWindow: NSWindow?
    private var permissionsLossTimer: DispatchSourceTimer?
    private var hasHandledPermissionsLoss: Bool = false
    
    func applicationDidFinishLaunching(_ notification: Notification) {
        let skipSingleInstanceCheck = UserDefaults.standard.bool(forKey: "SkipSingleInstanceCheck")
        if skipSingleInstanceCheck {
            UserDefaults.standard.removeObject(forKey: "SkipSingleInstanceCheck")
        }
        // Strict single-instance enforcement: if another instance is running, activate it and ask it to open Preferences, then quit.
        if let bundleID = Bundle.main.bundleIdentifier {
            if !skipSingleInstanceCheck {
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
        }
        
        // Register default for switcher open delay (milliseconds)
        UserDefaults.standard.register(defaults: ["switcherOpenDelayMS": 100])
        UserDefaults.standard.register(defaults: [
            "HiddenAppsPlacement": PlacementPreference.normal.rawValue,
            "MinimizedAppsPlacement": PlacementPreference.normal.rawValue
        ])
        
        // A. Check for Accessibility permissions immediately on launch.
        // Without these, the app cannot see or control other windows.
        checkRequiredPermissions()
        
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
                        self.overlayPanel.alphaValue = 1.0
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

        appActivationObserver = NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            guard let self = self, self.permissionsWindow != nil else { return }
            self.refreshPermissionsAlertUI(with: self.missingPermissions())
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

        startAccessibilityLossMonitor()
        
        // MRU seeding is gated on first activation to ensure ordering is ready before display.
        
        AppLog.app.info("🚀 Commander Tabbington started.")
    }
    
    func applicationWillTerminate(_ notification: Notification) {
        FocusMonitor.shared.stop()
        if let obs = distributedObserver {
            DistributedNotificationCenter.default().removeObserver(obs)
        }
        if let obs = appActivationObserver {
            NotificationCenter.default.removeObserver(obs)
        }
        for token in workspaceObservers { NSWorkspace.shared.notificationCenter.removeObserver(token) }
        workspaceObservers.removeAll()
        stopAccessibilityLossMonitor()
    }
    
    // MARK: - Setup Methods
    
    // Dynamically size the overlay to prefer width, then two rows, then vertical scroll
    private func updateOverlaySize() {
        guard let panel = overlayPanel else { return }
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
        let targetSize = overlaySize(for: count, screenFrame: screenFrame)
        
        // Apply new frame and keep it centered on the screen
        var newFrame = NSRect(x: 0, y: 0, width: targetSize.width, height: targetSize.height)
        let center = NSPoint(x: screenFrame.midX - newFrame.width / 2, y: screenFrame.midY - newFrame.height / 2)
        newFrame.origin = center
        panel.setFrame(newFrame, display: true)
    }

    private func overlaySize(for count: Int, screenFrame: NSRect) -> NSSize {
        // Match constants used by SwitcherView
        let itemWidth: CGFloat = SwitcherLayout.itemWidth
        let itemHeight: CGFloat = SwitcherLayout.itemHeight
        let spacing: CGFloat = SwitcherLayout.spacing
        let horizontalPadding: CGFloat = SwitcherLayout.horizontalPadding
        let verticalPadding: CGFloat = SwitcherLayout.verticalPadding
        
        // Screen constraints and user preferences
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
        
        return NSSize(width: selectedWidth, height: targetHeight)
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
    
    private enum PermissionType: String {
        case accessibility = "Accessibility"
    }

    private func checkRequiredPermissions() {
        let missing = missingPermissions()
        if missing.isEmpty {
            lastMissingPermissions = []
            hasPresentedPermissionsAlert = false
            closePermissionsWindowIfNeeded()
            hasHandledPermissionsLoss = false
            startAccessibilityLossMonitor()
            return
        }

        if hasPresentedPermissionsAlert && missing == lastMissingPermissions {
            return
        }
        lastMissingPermissions = missing

        logMissingPermissions(missing)
        presentPermissionsWindow(missing: missing)
        hasPresentedPermissionsAlert = true
    }

    private func missingPermissions() -> [PermissionType] {
        var missing: [PermissionType] = []
        if !isAccessibilityTrusted() {
            missing.append(.accessibility)
        }
        return missing
    }

    private func isAccessibilityTrusted() -> Bool {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: false]
        return AXIsProcessTrusted() || AXIsProcessTrustedWithOptions(options as CFDictionary)
    }

    private func logMissingPermissions(_ missing: [PermissionType]) {
        if missing.contains(.accessibility) {
            AppLog.app.log("⚠️ Warning: Accessibility permissions not granted. Window switching will not work.")
        }
    }

    private func presentPermissionsWindow(missing: [PermissionType]) {
        NSApp.activate(ignoringOtherApps: true)
        let window = permissionsWindow ?? buildPermissionsWindow()
        permissionsWindow = window
        updatePermissionsWindow()
        window.makeKeyAndOrderFront(nil)
        startPermissionsRefreshLoop()
    }

    private func buildPermissionsWindow() -> NSWindow {
        let content = NSStackView()
        content.orientation = .vertical
        content.alignment = .leading
        content.spacing = 12
        content.translatesAutoresizingMaskIntoConstraints = false

        let iconView = NSImageView(image: NSApp.applicationIconImage)
        iconView.translatesAutoresizingMaskIntoConstraints = false
        iconView.imageScaling = .scaleProportionallyUpOrDown
        NSLayoutConstraint.activate([
            iconView.widthAnchor.constraint(equalToConstant: 48),
            iconView.heightAnchor.constraint(equalToConstant: 48)
        ])

        let title = NSTextField(labelWithString: "Permissions Required")
        title.font = NSFont.boldSystemFont(ofSize: 15)

        let body = NSTextField(labelWithString: "Commander Tabbington needs Accessibility permission to function properly.")
        body.lineBreakMode = .byWordWrapping
        body.maximumNumberOfLines = 0

        let headerText = NSStackView()
        headerText.orientation = .vertical
        headerText.alignment = .leading
        headerText.spacing = 4
        headerText.addArrangedSubview(title)
        headerText.addArrangedSubview(body)

        let header = NSStackView()
        header.orientation = .horizontal
        header.alignment = .top
        header.spacing = 12
        header.addArrangedSubview(iconView)
        header.addArrangedSubview(headerText)

        let accessibilitySection = permissionSection(
            title: "Accessibility",
            isGranted: false,
            actionTitle: "Open Accessibility Settings",
            action: #selector(openAccessibilitySettings),
            permission: .accessibility
        )


        let buttons = NSStackView()
        buttons.orientation = .horizontal
        buttons.alignment = .centerY
        buttons.distribution = .gravityAreas

        let quitButton = NSButton(title: "Quit", target: self, action: #selector(permissionsQuitPressed))

        buttons.addArrangedSubview(NSView())
        buttons.addArrangedSubview(quitButton)

        content.addArrangedSubview(header)
        content.addArrangedSubview(accessibilitySection)
        content.addArrangedSubview(buttons)

        let container = NSView()
        container.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(content)
        NSLayoutConstraint.activate([
            content.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 20),
            content.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -20),
            content.topAnchor.constraint(equalTo: container.topAnchor, constant: 20),
            content.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -20)
        ])

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 420, height: 240),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "Permissions Required"
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.contentView = container
        window.center()
        return window
    }

    private func permissionSection(title: String, isGranted: Bool, actionTitle: String, action: Selector, permission: PermissionType) -> NSView {
        let container = NSStackView()
        container.orientation = .vertical
        container.alignment = .leading
        container.spacing = 4

        let header = NSTextField(labelWithString: title)
        header.font = NSFont.boldSystemFont(ofSize: NSFont.systemFontSize)

        let statusText = isGranted ? "Status: Granted" : "Status: Not granted"
        let status = NSTextField(labelWithString: statusText)

        let button = NSButton(title: actionTitle, target: self, action: action)
        button.isEnabled = !isGranted

        container.addArrangedSubview(header)
        container.addArrangedSubview(status)
        container.addArrangedSubview(button)

        permissionsAccessibilityStatusLabel = status
        permissionsAccessibilityActionButton = button

        return container
    }

    private func updatePermissionsWindow() {
        let isAccessibilityGranted = isAccessibilityTrusted()
        permissionsAccessibilityStatusLabel?.stringValue = isAccessibilityGranted ? "Status: Granted" : "Status: Not granted"
        permissionsAccessibilityActionButton?.isEnabled = !isAccessibilityGranted
        if isAccessibilityGranted {
            restartApplication()
        }
    }

    @objc private func permissionsQuitPressed() {
        NSApp.terminate(nil)
    }

    @objc private func openAccessibilitySettings() {
        openPrivacyPane(for: .accessibility)
    }

    private func openPrivacyPane(for permission: PermissionType) {
        let pane: String = "Privacy_Accessibility"
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane)") {
            NSWorkspace.shared.open(url)
        }
    }

    private func startPermissionsRefreshLoop() {
        stopPermissionsRefreshLoop()
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + .milliseconds(200), repeating: .milliseconds(500))
        timer.setEventHandler { [weak self] in
            guard let self = self else { return }
            self.refreshPermissionsAlertUI(with: self.missingPermissions())
        }
        permissionsAlertTimer = timer
        timer.resume()
    }

    private func stopPermissionsRefreshLoop() {
        permissionsAlertTimer?.cancel()
        permissionsAlertTimer = nil
    }

    private func refreshPermissionsAlertUI(with missing: [PermissionType]) {
        updatePermissionsWindow()
    }

    private func closePermissionsWindowIfNeeded() {
        permissionsWindow?.orderOut(nil)
        permissionsWindow = nil
        permissionsAccessibilityStatusLabel = nil
        permissionsAccessibilityActionButton = nil
        stopPermissionsRefreshLoop()
    }

    private func restartApplication() {
        closePermissionsWindowIfNeeded()
        UserDefaults.standard.set(true, forKey: "SkipSingleInstanceCheck")
        UserDefaults.standard.synchronize()
        let appURL = URL(fileURLWithPath: Bundle.main.bundlePath)
        launchViaOpen(appURL)
        DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(200)) {
            NSApp.terminate(nil)
        }
    }

    private func launchViaOpen(_ appURL: URL) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        process.arguments = ["-n", appURL.path]
        do {
            try process.run()
        } catch {
            AppLog.app.error("❌ Failed to relaunch via /usr/bin/open: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func startAccessibilityLossMonitor() {
        guard isAccessibilityTrusted() else { return }
        stopAccessibilityLossMonitor()
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + .seconds(1), repeating: .seconds(1))
        timer.setEventHandler { [weak self] in
            guard let self = self else { return }
            guard !self.hasHandledPermissionsLoss else { return }
            if !self.isAccessibilityTrusted() {
                self.hasHandledPermissionsLoss = true
                self.handleAccessibilityPermissionsLoss()
            }
        }
        permissionsLossTimer = timer
        timer.resume()
    }

    private func stopAccessibilityLossMonitor() {
        permissionsLossTimer?.cancel()
        permissionsLossTimer = nil
    }

    private func handleAccessibilityPermissionsLoss() {
        AppLog.app.error("🧯 Accessibility permission lost at runtime; stopping input hooks and exiting.")
        InputListener.shared.stop()
        FocusMonitor.shared.stop()

        let alert = NSAlert()
        alert.messageText = "Accessibility Permission Lost"
        alert.informativeText = "Commander Tabbington no longer has Accessibility permission. It will quit to avoid interfering with system input. You can re-enable permission in System Settings and relaunch."
        alert.addButton(withTitle: "Open Accessibility Settings")
        alert.addButton(withTitle: "Quit")
        let response = alert.runModal()
        if response == .alertFirstButtonReturn {
            openAccessibilitySettings()
        }
        NSApp.terminate(nil)
    }

    func windowWillClose(_ notification: Notification) {
        if let window = notification.object as? NSWindow, window == permissionsWindow {
            closePermissionsWindowIfNeeded()
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
