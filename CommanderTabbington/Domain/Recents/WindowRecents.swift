import Cocoa
import Foundation
import CoreGraphics

final class WindowRecents {
    static let shared = WindowRecents()

    // MRU list of window IDs, 0 is most recent
    private var mruIDs: [CGWindowID] = []
    private let queue = DispatchQueue(label: "WindowRecents.queue")

    private init() {
        // Seed with the current frontmost on-screen window if available
        if let infoList = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]],
           let first = infoList.first,
           let idNum = first[kCGWindowNumber as String] as? Int {
            mruIDs = [CGWindowID(idNum)]
        }
    }

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

    // Sort windows by MRU (lower rank first). Unknown windows retain original order as a tie-breaker.
    func sortWindowsByRecency(_ windows: inout [SystemWindow]) {
        // Build original order and rank map
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
        
        // If all ranks are unknown, derive from current on-screen Z-order
        if unknownCount == windows.count {
            if let infoList = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] {
                var order: [CGWindowID] = []
                for entry in infoList {
                    if let idNum = entry[kCGWindowNumber as String] as? Int {
                        order.append(CGWindowID(idNum))
                    }
                }
                for (idx, wid) in order.enumerated() {
                    rankMap[wid] = idx
                }
                // Persist seeded order
                queue.async { [weak self] in
                    self?.mruIDs = order
                }
            }
        }
        
        // Sort: MRU rank, then original order, then app name/title
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

    func seedFromCurrentZOrderIfEmpty() {
        queue.async { [weak self] in
            guard let self = self else { return }
            guard self.mruIDs.isEmpty else { return }
            guard let infoList = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else { return }
            var order: [CGWindowID] = []
            for entry in infoList {
                if let idNum = entry[kCGWindowNumber as String] as? Int {
                    order.append(CGWindowID(idNum))
                }
            }
            if !order.isEmpty {
                self.mruIDs = order
            }
        }
    }
}
extension Array where Element == SystemWindow {
    mutating func sortByTierAndRecency() {
        // Stable partition by tier while preserving original order (which is already MRU-sorted)
        let normal: [SystemWindow] = self.filter { $0.tier == VisibilityTier.normal }
        let hidden: [SystemWindow] = self.filter { $0.tier == VisibilityTier.hidden }
        let minimized: [SystemWindow] = self.filter { $0.tier == VisibilityTier.minimized }
        self = normal + hidden + minimized
    }
}

