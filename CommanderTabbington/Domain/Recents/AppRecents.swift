import Cocoa
import CoreGraphics
import Foundation

final class AppRecents {
    static let shared = AppRecents()

    // Most-recently-used list of PIDs, index 0 is most recent (frontmost)
    private var mruPIDs: [pid_t] = []
    private let queue = DispatchQueue(label: "AppRecents.queue")

    private init() {
        let nc = NSWorkspace.shared.notificationCenter
        nc.addObserver(self, selector: #selector(appActivated(_:)), name: NSWorkspace.didActivateApplicationNotification, object: nil)
        nc.addObserver(self, selector: #selector(appTerminated(_:)), name: NSWorkspace.didTerminateApplicationNotification, object: nil)
        nc.addObserver(self, selector: #selector(appLaunched(_:)), name: NSWorkspace.didLaunchApplicationNotification, object: nil)
        
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
            // Move to front if exists, otherwise insert at front
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

    @objc private func appLaunched(_ note: Notification) {
        guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
        let pid = app.processIdentifier
        queue.async { [weak self] in
            guard let self = self else { return }
            // Place newly launched apps behind the current frontmost if not already present
            if !self.mruPIDs.contains(pid) {
                self.mruPIDs.append(pid)
            }
        }
    }

    // Move a PID to most-recent position
    func bump(pid: pid_t) {
        queue.async { [weak self] in
            guard let self = self else { return }
            self.mruPIDs.removeAll { $0 == pid }
            self.mruPIDs.insert(pid, at: 0)
        }
    }

    // Returns a rank for the given PID: lower is more recent. Unknown PIDs get a large rank.
    func rank(for pid: pid_t) -> Int {
        var result = Int.max
        queue.sync {
            if let idx = mruPIDs.firstIndex(of: pid) { result = idx }
        }
        return result
    }

    // Convenience to sort SystemApp arrays by recency, with active-first and name tiebreaker
    func sortAppsByRecency(_ apps: inout [SystemApp]) {
        // Build initial rank map from stored MRU
        var rankMap: [pid_t: Int] = [:]
        var unknownCount = 0
        for app in apps {
            let r = rank(for: app.ownerPID)
            rankMap[app.ownerPID] = r
            if r == Int.max { unknownCount += 1 }
        }
        
        let knownCount = apps.count - unknownCount
        // If we have no MRU info yet, derive order from current on-screen window Z-order
        if unknownCount == apps.count {
            if let infoList = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] {
                var seen = Set<pid_t>()
                var order: [pid_t] = []
                for entry in infoList {
                    if let ownerPID = entry[kCGWindowOwnerPID as String] as? Int32 {
                        let pid = ownerPID
                        if !seen.contains(pid) {
                            seen.insert(pid)
                            order.append(pid)
                        }
                    }
                }
                for (idx, pid) in order.enumerated() {
                    rankMap[pid] = idx
                }
                // Persist the seeded order for future calls
                queue.async { [weak self] in
                    self?.mruPIDs = order
                }
            }
        } else if unknownCount > 0 {
            // If only a few apps are known (e.g., only the frontmost), seed unknowns by current CG z-order
            if let infoList = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] {
                var seen = Set<pid_t>()
                var order: [pid_t] = []
                for entry in infoList {
                    if let ownerPID = entry[kCGWindowOwnerPID as String] as? Int32 {
                        let pid = ownerPID
                        if !seen.contains(pid) {
                            seen.insert(pid)
                            order.append(pid)
                        }
                    }
                }
                // Determine base rank after existing known ranks so known apps stay ahead
                let maxKnownRank = rankMap.values.filter { $0 != Int.max }.max() ?? -1
                let base = maxKnownRank + 1
                var assigned = 0
                for pid in order {
                    if rankMap[pid] == Int.max {
                        rankMap[pid] = base + assigned
                        assigned += 1
                    }
                }
                // Do not persist here; FocusMonitor will refine MRU soon
            }
        }
        
        // Sort: active-first, then MRU rank, then name
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

    // Seed MRU order from current on-screen window Z-order if we don't have any recency data yet
    func seedFromCurrentZOrderIfEmpty() {
        queue.async { [weak self] in
            guard let self = self else { return }
            guard self.mruPIDs.isEmpty else { return }
            guard let infoList = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else { return }
            var seen = Set<pid_t>()
            var order: [pid_t] = []
            for entry in infoList {
                if let ownerPID = entry[kCGWindowOwnerPID as String] as? Int32 {
                    let pid = ownerPID
                    if !seen.contains(pid) {
                        seen.insert(pid)
                        order.append(pid)
                    }
                }
            }
            if !order.isEmpty {
                self.mruPIDs = order
            }
        }
    }
}
