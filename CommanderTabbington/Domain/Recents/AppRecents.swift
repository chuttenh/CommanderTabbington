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
        
        // Perform an initial full Z-order scan to populate hidden/minimized apps
        seedFromCurrentZOrderIfEmpty()
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

    @objc private func appLaunched(_ note: Notification) {
        guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
        let pid = app.processIdentifier
        queue.async { [weak self] in
            guard let self = self else { return }
            if !self.mruPIDs.contains(pid) {
                self.mruPIDs.append(pid)
            }
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
        var rankMap: [pid_t: Int] = [:]
        var unknownCount = 0
        for app in apps {
            let r = rank(for: app.ownerPID)
            rankMap[app.ownerPID] = r
            if r == Int.max { unknownCount += 1 }
        }
        
        // If we have unknown apps (common at startup for hidden/minimized ones), 
        // perform a broader Z-order scan to resolve their relative positions.
        if unknownCount > 0 {
            // Drop .optionOnScreenOnly to include minimized and some hidden windows in the seed
            if let infoList = CGWindowListCopyWindowInfo([.excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] {
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
                
                // Determine base rank after existing known ranks
                let maxKnownRank = rankMap.values.filter { $0 != Int.max }.max() ?? -1
                let base = maxKnownRank + 1
                var assigned = 0
                
                for pid in order {
                    if rankMap[pid] == Int.max {
                        rankMap[pid] = base + assigned
                        assigned += 1
                    }
                }
                
                // Update internal MRU list with newly discovered order if we were empty
                if unknownCount == apps.count {
                    queue.async { [weak self] in self?.mruPIDs = order }
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

    func seedFromCurrentZOrderIfEmpty() {
        queue.async { [weak self] in
            guard let self = self else { return }
            // Seed if empty OR if we only have the frontmost app
            guard self.mruPIDs.count <= 1 else { return }
            
            // Drop .optionOnScreenOnly to capture minimized/off-screen windows for a complete initial MRU list
            guard let infoList = CGWindowListCopyWindowInfo([.excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else { return }
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
                // Preserve frontmost if already tracked
                var merged = self.mruPIDs
                for pid in order {
                    if !merged.contains(pid) { merged.append(pid) }
                }
                self.mruPIDs = merged
            }
        }
    }
}

extension Array where Element == SystemApp {
    mutating func sortByTierAndRecency() {
        let normal = self.filter { $0.tier == .normal }
        let hidden = self.filter { $0.tier == .hidden }
        let minimized = self.filter { $0.tier == .minimized }
        self = normal + hidden + minimized
    }
}

