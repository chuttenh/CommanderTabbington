import Cocoa
import CoreGraphics
import Foundation

final class AppRecents {
    static let shared = AppRecents()

    // Most-recently-used list of PIDs, index 0 is most recent (frontmost)
    private var mruPIDs: [pid_t] = []
    private let queue = DispatchQueue(label: "AppRecents.queue")
    private var hasSeeded: Bool = false

    private init() {
        let nc = NSWorkspace.shared.notificationCenter
        nc.addObserver(self, selector: #selector(appActivated(_:)), name: NSWorkspace.didActivateApplicationNotification, object: nil)
        nc.addObserver(self, selector: #selector(appTerminated(_:)), name: NSWorkspace.didTerminateApplicationNotification, object: nil)
        
        // Seed with current frontmost app if available
        if let front = NSWorkspace.shared.frontmostApplication {
            let pid = front.processIdentifier
            mruPIDs = [pid]
        }
        
    }

    @objc private func appActivated(_ note: Notification) {
        guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
        let pid = app.processIdentifier
        queue.async { [weak self] in
            guard let self = self else { return }
            self.mruPIDs.removeAll { $0 == pid }
            self.mruPIDs.insert(pid, at: 0)
        }
    }

    @objc private func appTerminated(_ note: Notification) {
        guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
        let pid = app.processIdentifier
        queue.async { [weak self] in
            self?.mruPIDs.removeAll { $0 == pid }
        }
    }

    func bump(pid: pid_t) {
        queue.async { [weak self] in
            guard let self = self else { return }
            self.mruPIDs.removeAll { $0 == pid }
            self.mruPIDs.insert(pid, at: 0)
        }
    }

    func rank(for pid: pid_t) -> Int {
        var result = Int.max
        queue.sync {
            if let idx = mruPIDs.firstIndex(of: pid) { result = idx }
        }
        return result
    }

    func sortAppsByRecency(_ apps: inout [SystemApp]) {
        // Snapshot MRU once for performance and consistency
        let mruSnapshot: [pid_t] = queue.sync { self.mruPIDs }
        var rankMap: [pid_t: Int] = Dictionary(uniqueKeysWithValues: mruSnapshot.enumerated().map { ($0.element, $0.offset) })

        var unknownCount = 0
        for app in apps {
            if rankMap[app.ownerPID] == nil {
                rankMap[app.ownerPID] = Int.max
                unknownCount += 1
            }
        }
        
        // If we have unknown apps (common at startup), derive order from window lists.
        if unknownCount > 0 {
            let appPIDs = Set(apps.map { $0.ownerPID })
            var onScreenOrder: [pid_t] = []
            var remainingPIDs = Set<pid_t>()

            let onScreenOptions: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
            if let onScreenList = CGWindowListCopyWindowInfo(onScreenOptions, kCGNullWindowID) as? [[String: Any]] {
                var seen = Set<pid_t>()
                for entry in onScreenList {
                    if let ownerPID = entry[kCGWindowOwnerPID as String] as? Int32 {
                        let pid = ownerPID
                        guard appPIDs.contains(pid) else { continue }
                        guard let running = NSRunningApplication(processIdentifier: pid),
                              running.activationPolicy == .regular else { continue }
                        if seen.insert(pid).inserted {
                            onScreenOrder.append(pid)
                        }
                    }
                }
            }

            remainingPIDs = appPIDs
            for pid in onScreenOrder {
                remainingPIDs.remove(pid)
            }

            var fullOrder: [pid_t] = []
            if !remainingPIDs.isEmpty {
                if let fullList = CGWindowListCopyWindowInfo([.excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] {
                    var seen = Set<pid_t>()
                    for entry in fullList {
                        if let ownerPID = entry[kCGWindowOwnerPID as String] as? Int32 {
                            let pid = ownerPID
                            guard remainingPIDs.contains(pid) else { continue }
                            guard let running = NSRunningApplication(processIdentifier: pid),
                                  running.activationPolicy == .regular else { continue }
                            if seen.insert(pid).inserted {
                                fullOrder.append(pid)
                            }
                        }
                    }
                }
            }

            // Determine base rank after existing known ranks
            let maxKnownRank = rankMap.values.filter { $0 != Int.max }.max() ?? -1
            var nextRank = maxKnownRank + 1

            for pid in onScreenOrder {
                if rankMap[pid] == Int.max {
                    rankMap[pid] = nextRank
                    nextRank += 1
                }
            }
            for pid in fullOrder {
                if rankMap[pid] == Int.max {
                    rankMap[pid] = nextRank
                    nextRank += 1
                }
            }
        }
        
        apps.sort { a, b in
            let aActive = a.owningApplication?.isActive == true
            let bActive = b.owningApplication?.isActive == true
            if aActive != bActive { return aActive && !bActive }
            let ar = rankMap[a.ownerPID] ?? Int.max
            let br = rankMap[b.ownerPID] ?? Int.max
            if ar != br { return ar < br }
            return a.appName.localizedCaseInsensitiveCompare(b.appName) == .orderedAscending
        }
    }

    func ensureSeeded(completion: @escaping () -> Void) {
        // Mark seeded once; callers can invoke this multiple times.
        queue.sync {
            if !self.hasSeeded { self.hasSeeded = true }
        }

        // At app startup we only know the frontmost app for MRU purposes.
        // Initial ordering of other apps is handled by `sortAppsByRecency` using CGWindowList heuristics.
        DispatchQueue.main.async { completion() }
    }

}

extension Array where Element == SystemApp {
    
    // Groups apps by tier (normal → hidden → minimized) while preserving the existing order within each tier.
    // Note: This does *not* compute recency; callers should sort by MRU first (e.g., via `AppRecents.sortAppsByRecency`) if desired.
    mutating func groupByTierPreservingOrder() {
        let normal = self.filter { $0.tier == .normal }
        let hidden = self.filter { $0.tier == .hidden }
        let minimized = self.filter { $0.tier == .minimized }
        self = normal + hidden + minimized
    }
}
