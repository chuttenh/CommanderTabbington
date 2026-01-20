import Cocoa
import Foundation
import CoreGraphics

final class WindowRecents {
    static let shared = WindowRecents()

    private var mruIDs: [CGWindowID] = []
    private let queue = DispatchQueue(label: "WindowRecents.queue")

    private var hasSeeded: Bool = false
    private var seedInProgress: Bool = false
    private var seedCompletions: [() -> Void] = []

    private init() {}

    func bump(windowID: CGWindowID) {
        queue.async { [weak self] in
            guard let self = self else { return }
            self.mruIDs.removeAll { $0 == windowID }
            self.mruIDs.insert(windowID, at: 0)
        }
    }

    func prune(validIDs: Set<CGWindowID>) {
        queue.async { [weak self] in
            guard let self = self else { return }
            self.mruIDs.removeAll { !validIDs.contains($0) }
        }
    }

    func rank(for windowID: CGWindowID) -> Int {
        var r = Int.max
        queue.sync {
            if let idx = mruIDs.firstIndex(of: windowID) { r = idx }
        }
        return r
    }

    func sortWindowsByRecency(_ windows: inout [SystemWindow]) {
        var originalIndex: [CGWindowID: Int] = [:]
        var validIDs = Set<CGWindowID>()
        var rankMap: [CGWindowID: Int] = [:]
        var unknownCount = 0
        
        for (idx, w) in windows.enumerated() {
            originalIndex[w.windowID] = idx
            validIDs.insert(w.windowID)
            let r = rank(for: w.windowID)
            rankMap[w.windowID] = r
            if r == Int.max { unknownCount += 1 }
        }
        prune(validIDs: validIDs)
        
        // If ranks are missing (common for minimized windows at startup), fetch full Z-order
        if unknownCount > 0 {
            // Drop .optionOnScreenOnly to derive ranks for hidden/minimized windows
            if let infoList = CGWindowListCopyWindowInfo([.excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] {
                var order: [CGWindowID] = []
                for entry in infoList {
                    if let idNum = entry[kCGWindowNumber as String] as? Int {
                        order.append(CGWindowID(idNum))
                    }
                }
                
                let maxKnownRank = rankMap.values.filter { $0 != Int.max }.max() ?? -1
                let base = maxKnownRank + 1
                var assigned = 0
                
                for wid in order {
                    if rankMap[wid] == Int.max {
                        rankMap[wid] = base + assigned
                        assigned += 1
                    }
                }
                
                if unknownCount == windows.count {
                    queue.async { [weak self] in self?.mruIDs = order }
                }
            }
        }
        
        windows.sort { a, b in
            let ar = rankMap[a.windowID] ?? Int.max
            let br = rankMap[b.windowID] ?? Int.max
            if ar != br { return ar < br }
            let ai = originalIndex[a.windowID] ?? Int.max
            let bi = originalIndex[b.windowID] ?? Int.max
            if ai != bi { return ai < bi }
            if a.appName != b.appName {
                return a.appName.localizedCaseInsensitiveCompare(b.appName) == .orderedAscending
            }
            return a.title.localizedCaseInsensitiveCompare(b.title) == .orderedAscending
        }
    }

    func ensureSeeded(completion: @escaping () -> Void) {
        var alreadySeeded = false
        queue.sync {
            alreadySeeded = self.hasSeeded
        }
        if alreadySeeded {
            DispatchQueue.main.async { completion() }
            return
        }

        queue.async { [weak self] in
            guard let self = self else { return }
            if self.hasSeeded {
                DispatchQueue.main.async { completion() }
                return
            }

            self.seedCompletions.append(completion)
            if self.seedInProgress { return }
            self.seedInProgress = true

            if !self.mruIDs.isEmpty {
                self.hasSeeded = true
                self.seedInProgress = false
                let completions = self.seedCompletions
                self.seedCompletions.removeAll()
                DispatchQueue.main.async { completions.forEach { $0() } }
                return
            }

            guard let infoList = CGWindowListCopyWindowInfo([.excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else {
                self.hasSeeded = true
                self.seedInProgress = false
                let completions = self.seedCompletions
                self.seedCompletions.removeAll()
                DispatchQueue.main.async { completions.forEach { $0() } }
                return
            }

            var order: [CGWindowID] = []
            for entry in infoList {
                if let idNum = entry[kCGWindowNumber as String] as? Int {
                    order.append(CGWindowID(idNum))
                }
            }
            if !order.isEmpty {
                self.mruIDs = order
            }

            self.hasSeeded = true
            self.seedInProgress = false
            let completions = self.seedCompletions
            self.seedCompletions.removeAll()
            DispatchQueue.main.async { completions.forEach { $0() } }
        }
    }
}

extension Array where Element == SystemWindow {
    mutating func sortByTierAndRecency() {
        let normal = self.filter { $0.tier == .normal }
        let hidden = self.filter { $0.tier == .hidden }
        let minimized = self.filter { $0.tier == .minimized }
        self = normal + hidden + minimized
    }
}
