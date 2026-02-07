import SwiftUI
import Combine
import Cocoa
import CoreGraphics
import OSLog

class AppState: ObservableObject {
    
    // MARK: - Published Properties (UI Drivers)
    
    /// Controls the visibility of the switcher overlay.
    /// When true, the UI appears; when false, it vanishes.
    @Published var isSwitcherVisible: Bool = false
    
    /// The list of apps currently available to switch to.
    /// This is updated every time the switcher is invoked.
    @Published var visibleApps: [SystemApp] = []
    @Published var visibleWindows: [SystemWindow] = []
    
    enum SwitcherMode { case perApp, perWindow }
    @Published var mode: SwitcherMode = .perApp
    
    // Delayed open support
    private var pendingOpenWorkItem: DispatchWorkItem?
    private var pendingOpenGateToken: UUID?
    private var pendingCycleSteps: Int = 0
    private var commandReleaseWatchdog: DispatchSourceTimer?
    private let commandReleaseWatchdogQueue = DispatchQueue(label: "AppState.commandReleaseWatchdog")
    private var commandReleasedSince: CFAbsoluteTime?
    private var activationID: String?
    // UserInteractive to keep the switcher responsive during activation bursts.
    private let refreshQueue = DispatchQueue(label: "AppState.refreshQueue", qos: .userInteractive)
    private let commitQueue = DispatchQueue(label: "AppState.commitQueue", qos: .userInitiated)
    private var refreshToken: UUID?
    
    init() {
        // Initialize mode from user defaults (default: perApp)
        let perApp = UserDefaults.standard.object(forKey: "perAppMode") as? Bool ?? true
        self.mode = perApp ? .perApp : .perWindow
    }
    
    /// The index of the currently highlighted app in the `visibleApps` array.
    @Published var selectedAppID: pid_t? = nil
    @Published var selectedWindowID: CGWindowID? = nil

    @Published var selectedIndex: Int = 0
    
    // MARK: - Internal State
    
    /// A cache or handle to the previously active application,
    /// used if we need to "cancel" the switch and return to where we were.
    var previousApp: NSRunningApplication?
    
    // MARK: - Actions
    
    /// Called when the user presses the hotkey (e.g., Cmd+Tab).
    /// If the switcher is hidden, it opens it and captures the current state.
    /// If open, it cycles to the next app.
    func handleUserActivation(direction: SelectionDirection = .next) {
        let activationID = String(UUID().uuidString.prefix(8))
        self.activationID = activationID
        let activationStart = CFAbsoluteTimeGetCurrent()
        AppLog.appState.info("🧭 CmdTab activation id=\(activationID, privacy: .public) direction=\(String(describing: direction), privacy: .public) isVisible=\(self.isSwitcherVisible, privacy: .public) pending=\(self.pendingOpenWorkItem != nil, privacy: .public)")
        if !self.isSwitcherVisible {
            // If no pending open, capture current state and schedule UI appearance after a small delay
            if self.pendingOpenWorkItem == nil {
                let gateToken = UUID()
                self.pendingOpenGateToken = gateToken
                self.pendingCycleSteps = 0

                let scheduleOpenIfNeeded: (_ appsCount: Int, _ windowsCount: Int) -> Void = { [weak self] appsCount, windowsCount in
                    guard let self = self else { return }
                    guard self.pendingOpenGateToken == gateToken else { return }
                    guard self.pendingOpenWorkItem == nil else { return }

                    let count: Int = (self.mode == .perApp) ? appsCount : windowsCount
                    guard count > 0 else { return }
                    self.applyDefaultSelectionForPendingActivation()
                    self.applyPendingCycleStepsIfNeeded(count: count)

                    let delayMS = UserDefaults.standard.object(forKey: "switcherOpenDelayMS") as? Int ?? 100
                    let openDeadline = activationStart + (Double(delayMS) / 1000.0)
                    let remainingMS = max(0, Int((openDeadline - CFAbsoluteTimeGetCurrent()) * 1000.0))
                    var workItem: DispatchWorkItem?
                    workItem = DispatchWorkItem { [weak self] in
                        guard let self = self else { return }
                        // Ensure this is still the active pending item; if it was canceled or superseded, do nothing
                        guard self.pendingOpenWorkItem === workItem else { return }
                        self.isSwitcherVisible = true
                        self.startCommandReleaseWatchdog()
                        self.pendingOpenWorkItem = nil
                        self.pendingOpenGateToken = nil
                        AppLog.appState.info("🔎 Switcher opened (delayed). apps=\(self.visibleApps.count, privacy: .public) windows=\(self.visibleWindows.count, privacy: .public) selectedIndex=\(self.selectedIndex, privacy: .public)")
                    }
                    if let wi = workItem {
                        self.pendingOpenWorkItem = wi
                        DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(remainingMS), execute: wi)
                    }
                }

                let prepareFastThenFull = { [weak self] in
                    guard let self = self else { return }
                    guard self.pendingOpenGateToken == gateToken else { return }
                    let refreshStart = CFAbsoluteTimeGetCurrent()
                    self.refreshCurrentList(skipAX: true) { [weak self] appsCount, windowsCount in
                        guard let self = self else { return }
                        guard self.pendingOpenGateToken == gateToken else { return }
                        let refreshElapsedMS = (CFAbsoluteTimeGetCurrent() - refreshStart) * 1000.0
                        let totalElapsedMS = (CFAbsoluteTimeGetCurrent() - activationStart) * 1000.0
                        AppLog.appState.info("🧭 CmdTab prepare fast id=\(activationID, privacy: .public) refreshMs=\(refreshElapsedMS, privacy: .public) totalMs=\(totalElapsedMS, privacy: .public) apps=\(appsCount, privacy: .public) windows=\(windowsCount, privacy: .public)")

                        if appsCount == 0 && windowsCount == 0 {
                            // If fast path yields nothing, fall back to full refresh for correctness.
                            self.refreshCurrentList(skipAX: false) { [weak self] fullApps, fullWindows in
                                guard let self = self else { return }
                                guard self.pendingOpenGateToken == gateToken else { return }
                                if fullApps == 0 && fullWindows == 0 {
                                    AppLog.appState.log("⚠️ No apps or windows available to show in switcher.")
                                }
                                scheduleOpenIfNeeded(fullApps, fullWindows)
                            }
                            return
                        }

                        scheduleOpenIfNeeded(appsCount, windowsCount)

                        // Kick a full refresh in the background to refine hidden/minimized/no-window info.
                        self.refreshCurrentList(skipAX: false, preserveSelection: true, completion: nil)
                    }
                }

                let fallbackDelay: DispatchTimeInterval = .milliseconds(300)
                var didPrepare = false

                let runOnce: () -> Void = { [weak self] in
                    guard let self = self, !didPrepare else { return }
                    guard self.pendingOpenGateToken == gateToken else { return }
                    guard !self.isSwitcherVisible else { return }
                    didPrepare = true
                    prepareFastThenFull()
                }

                AppRecents.shared.ensureSeeded {
                    WindowRecents.shared.ensureSeeded {
                        runOnce()
                    }
                }

                DispatchQueue.main.asyncAfter(deadline: .now() + fallbackDelay) {
                    runOnce()
                }
            } else {
                // Already pending; allow cycling before the UI becomes visible
                if self.hasItemsForCurrentMode() {
                    cycleSelection(direction: direction)
                } else {
                    pendingCycleSteps += (direction == .next) ? 1 : -1
                }
            }
        } else {
            // UI is visible; normal cycling
            cycleSelection(direction: direction)
        }
    }
    
    /// Moves the selection index, wrapping around the array bounds.
    func cycleSelection(direction: SelectionDirection) {
        guard !self.visibleApps.isEmpty || !self.visibleWindows.isEmpty else { return }
        let count: Int = (self.mode == .perApp) ? self.visibleApps.count : self.visibleWindows.count
        guard count > 0 else { return }
        
        switch direction {
        case .next:
            self.selectedIndex = (self.selectedIndex + 1) % count
        case .previous:
            self.selectedIndex = (self.selectedIndex - 1 + count) % count
        }
        
        applySelectionForCurrentMode()
    }
    
    /// Called when the user releases the modifier key (Cmd).
    /// Commits the selection and hides the UI.
    func commitSelection() {
        AppLog.appState.info("🧭 CmdTab commit id=\(self.activationID ?? "unknown", privacy: .public) mode=\(String(describing: self.mode), privacy: .public) selectedIndex=\(self.selectedIndex, privacy: .public) isVisible=\(self.isSwitcherVisible, privacy: .public) pending=\(self.pendingOpenWorkItem != nil, privacy: .public)")
        // Diagnostics: entry log
        AppLog.appState.info("🧭 commitSelection invoked. mode=\(String(describing: self.mode), privacy: .public) selectedIndex=\(self.selectedIndex, privacy: .public) isVisible=\(self.isSwitcherVisible, privacy: .public) apps=\(self.visibleApps.count, privacy: .public) windows=\(self.visibleWindows.count, privacy: .public)")
        
        // Allow commit even if the UI hasn't appeared yet, as long as an open is pending
        let hadPendingOpen = (self.pendingOpenWorkItem != nil) || (self.pendingOpenGateToken != nil)
        if hadPendingOpen {
            self.pendingOpenWorkItem?.cancel()
            self.pendingOpenWorkItem = nil
            self.pendingOpenGateToken = nil
        }
        
        guard self.isSwitcherVisible || hadPendingOpen else {
            AppLog.appState.log("⚠️ commitSelection ignored: switcher not visible and no pending open")
            return
        }

        if !self.isSwitcherVisible && hadPendingOpen && !hasItemsForCurrentMode() {
            AppLog.appState.debug("⏳ Deferred commit: refreshing list before activation")
            refreshCurrentList { [weak self] _, _ in
                guard let self = self else { return }
                guard !self.isSwitcherVisible else { return }
                self.applyDefaultSelectionForPendingActivation()
                if let target = self.resolveCommitTarget() {
                    self.dispatchCommitSelection(target)
                }
            }
            return
        }

        if self.isSwitcherVisible { self.isSwitcherVisible = false }
        self.stopCommandReleaseWatchdog()
        AppLog.appState.debug("🫥 Hiding switcher overlay before activation")
        if !self.isSwitcherVisible && hadPendingOpen {
            self.applyDefaultSelectionForPendingActivation()
        }
        if let target = resolveCommitTarget() {
            dispatchCommitSelection(target)
        }
    }
    
    func cancelSelection() {
        self.isSwitcherVisible = false
        if let w = self.pendingOpenWorkItem { w.cancel(); self.pendingOpenWorkItem = nil }
        self.pendingOpenGateToken = nil
        self.activationID = nil
        self.stopCommandReleaseWatchdog()
        // Optional: Return focus to previousApp if needed
    }
    
    /// Public trigger to refresh the currently visible list (apps or windows),
    /// respecting the current switcher mode.
    func refreshNow() {
        refreshCurrentList()
    }
    
    // MARK: - Private Helpers
    
    private func refreshCurrentList(completion: ((_ appsCount: Int, _ windowsCount: Int) -> Void)? = nil) {
        refreshCurrentList(skipAX: false, completion: completion)
    }

    private func refreshCurrentList(skipAX: Bool, preserveSelection: Bool = false, completion: ((_ appsCount: Int, _ windowsCount: Int) -> Void)? = nil) {
        let token = UUID()
        self.refreshToken = token
        let mode = self.mode
        let selectedIndex = self.selectedIndex
        let prevAppID = self.selectedAppID
        let prevWindowID = self.selectedWindowID

        refreshQueue.async { [weak self] in
            guard let self = self else { return }
            switch mode {
            case .perApp:
                var apps = WindowManager.shared.getOpenApps(skipAX: skipAX)
                // getOpenApps() returns MRU-sorted and tiered; group tiers while preserving MRU within each tier
                apps.groupByTierPreservingOrder()

                let newSelectedID: pid_t? = {
                    if let prev = prevAppID, apps.contains(where: { $0.id == prev }) { return prev }
                    let count = apps.count
                    if count == 0 { return nil }
                    let fallbackIndex = min(selectedIndex, count - 1)
                    return apps[fallbackIndex].id
                }()
                let newIndex: Int = {
                    if let sel = newSelectedID, let idx = apps.firstIndex(where: { $0.id == sel }) { return idx }
                    return 0
                }()

                DispatchQueue.main.async { [weak self] in
                    guard let self = self else { return }
                    guard self.refreshToken == token else { return }
                    let currentSelectedID: pid_t? = preserveSelection ? self.selectedAppID : prevAppID
                    self.visibleApps = apps
                    let resolvedSelectedID: pid_t? = {
                        if let current = currentSelectedID, apps.contains(where: { $0.id == current }) { return current }
                        return newSelectedID
                    }()
                    if let sel = resolvedSelectedID, let idx = apps.firstIndex(where: { $0.id == sel }) {
                        self.selectedAppID = sel
                        self.selectedIndex = idx
                    } else {
                        self.selectedAppID = newSelectedID
                        self.selectedIndex = newIndex
                    }
                    completion?(apps.count, 0)
                }
            case .perWindow:
                var windows = WindowManager.shared.getOpenWindows(skipAXMerge: skipAX)
                // getOpenWindows() returns MRU-sorted and tiered; group tiers while preserving MRU within each tier
                windows.groupByTierPreservingOrder()

                let newSelectedID: CGWindowID? = {
                    if let prev = prevWindowID, windows.contains(where: { $0.id == prev }) { return prev }
                    let count = windows.count
                    if count == 0 { return nil }
                    let fallbackIndex = min(selectedIndex, count - 1)
                    return windows[fallbackIndex].id
                }()
                let newIndex: Int = {
                    if let sel = newSelectedID, let idx = windows.firstIndex(where: { $0.id == sel }) { return idx }
                    return 0
                }()

                DispatchQueue.main.async { [weak self] in
                    guard let self = self else { return }
                    guard self.refreshToken == token else { return }
                    let currentSelectedID: CGWindowID? = preserveSelection ? self.selectedWindowID : prevWindowID
                    self.visibleWindows = windows
                    let resolvedSelectedID: CGWindowID? = {
                        if let current = currentSelectedID, windows.contains(where: { $0.id == current }) { return current }
                        return newSelectedID
                    }()
                    if let sel = resolvedSelectedID, let idx = windows.firstIndex(where: { $0.id == sel }) {
                        self.selectedWindowID = sel
                        self.selectedIndex = idx
                    } else {
                        self.selectedWindowID = newSelectedID
                        self.selectedIndex = newIndex
                    }
                    completion?(0, windows.count)
                }
            }
        }
    }

    private func applySelectionForCurrentMode() {
        switch self.mode {
        case .perApp:
            if self.visibleApps.indices.contains(self.selectedIndex) {
                self.selectedAppID = self.visibleApps[self.selectedIndex].id
            } else {
                self.selectedAppID = nil
            }
            self.selectedWindowID = nil
        case .perWindow:
            if self.visibleWindows.indices.contains(self.selectedIndex) {
                self.selectedWindowID = self.visibleWindows[self.selectedIndex].id
            } else {
                self.selectedWindowID = nil
            }
            self.selectedAppID = nil
        }
    }

    private func hasItemsForCurrentMode() -> Bool {
        switch mode {
        case .perApp:
            return !visibleApps.isEmpty
        case .perWindow:
            return !visibleWindows.isEmpty
        }
    }

    private func applyDefaultSelectionForPendingActivation() {
        let count: Int = (mode == .perApp) ? visibleApps.count : visibleWindows.count
        selectedIndex = (count > 1) ? 1 : 0
        applySelectionForCurrentMode()
    }

    private func applyPendingCycleStepsIfNeeded(count: Int) {
        guard count > 0 else {
            pendingCycleSteps = 0
            return
        }
        let steps = pendingCycleSteps % count
        if steps != 0 {
            selectedIndex = (selectedIndex + steps + count) % count
            applySelectionForCurrentMode()
        }
        pendingCycleSteps = 0
    }

    private enum CommitTarget {
        case app(SystemApp)
        case window(SystemWindow)
    }

    private func resolveCommitTarget() -> CommitTarget? {
        switch self.mode {
        case .perApp:
            guard self.visibleApps.indices.contains(self.selectedIndex) else {
                AppLog.appState.error("❌ Selection index out of range for visibleApps: index=\(self.selectedIndex, privacy: .public) count=\(self.visibleApps.count, privacy: .public)")
                return nil
            }
            return .app(self.visibleApps[self.selectedIndex])
        case .perWindow:
            guard self.visibleWindows.indices.contains(self.selectedIndex) else {
                AppLog.appState.error("❌ Selection index out of range for visibleWindows: index=\(self.selectedIndex, privacy: .public) count=\(self.visibleWindows.count, privacy: .public)")
                return nil
            }
            return .window(self.visibleWindows[self.selectedIndex])
        }
    }

    private func dispatchCommitSelection(_ target: CommitTarget) {
        self.activationID = nil
        commitQueue.async { [target] in
            switch target {
            case .app(let app):
                self.commitAppSelection(app)
            case .window(let window):
                self.commitWindowSelection(window)
            }
        }
    }

    private func startCommandReleaseWatchdog() {
        stopCommandReleaseWatchdog()
        let timer = DispatchSource.makeTimerSource(queue: commandReleaseWatchdogQueue)
        timer.schedule(deadline: .now(), repeating: .milliseconds(50), leeway: .milliseconds(20))
        timer.setEventHandler { [weak self] in
            guard let self = self else { return }
            guard self.isSwitcherVisible else {
                self.stopCommandReleaseWatchdog()
                return
            }
            let flags = CGEventSource.flagsState(.combinedSessionState)
            let commandDown = flags.contains(.maskCommand)
            if commandDown {
                self.commandReleasedSince = nil
                return
            }
            let now = CFAbsoluteTimeGetCurrent()
            if let since = self.commandReleasedSince {
                if now - since >= 0.25 {
                    DispatchQueue.main.async { [weak self] in
                        self?.commitSelection()
                    }
                    self.stopCommandReleaseWatchdog()
                }
            } else {
                self.commandReleasedSince = now
            }
        }
        commandReleaseWatchdog = timer
        timer.resume()
    }

    private func stopCommandReleaseWatchdog() {
        if let timer = commandReleaseWatchdog {
            timer.cancel()
            commandReleaseWatchdog = nil
        }
        commandReleasedSince = nil
    }

    private func commitAppSelection(_ selectedApp: SystemApp) {
        AppLog.appState.info("🚀 Switching to app: \(selectedApp.appName, privacy: .public) (PID: \(selectedApp.ownerPID, privacy: .public))")

        // Prefer the stored NSRunningApplication, but fall back to resolving by PID if needed
        let targetApp = selectedApp.owningApplication ?? NSRunningApplication(processIdentifier: selectedApp.ownerPID)

        guard let app = targetApp else {
            AppLog.appState.error("❓ No NSRunningApplication for selected app; cannot activate directly")
            return
        }

        // Try high-level activation first
        let activated = app.activate(options: [.activateIgnoringOtherApps])
        if activated {
            AppLog.appState.info("✅ App activation requested successfully")
        } else {
            AppLog.appState.log("⚠️ App activation returned false; attempting AX-based bring-to-front fallback")
        }

        // Use AccessibilityService to ensure the app is unhidden and all windows are raised/focused.
        AccessibilityService.shared.bringAllWindowsToFront(for: app)
    }

    private func commitWindowSelection(_ selectedWindow: SystemWindow) {
        AppLog.appState.info("🚀 Switching to window: \(selectedWindow.title, privacy: .public) (ID: \(selectedWindow.windowID, privacy: .public)) of app \(selectedWindow.appName, privacy: .public) (PID: \(selectedWindow.ownerPID, privacy: .public))")
        AppLog.appState.debug("➡️ Bumping window recency and requesting focus")
        WindowRecents.shared.bump(windowID: selectedWindow.windowID)
        AccessibilityService.shared.focus(window: selectedWindow)
        AppLog.appState.debug("📣 Focus request sent to AccessibilityService")
    }
}

// Helper Enum for cycling direction
enum SelectionDirection {
    case next      // Tab
    case previous  // Shift + Tab
}
