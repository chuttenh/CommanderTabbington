import Cocoa
import Foundation
import CoreGraphics

final class WindowRecents {
    static let shared = WindowRecents()

    private var mruIDs: [CGWindowID] = []
    private let queue = DispatchQueue(label: "WindowRecents.queue")

    private var hasSeeded: Bool = false

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
        let mruSnapshot: [CGWindowID] = queue.sync { self.mruIDs }
        var mruRank: [CGWindowID: Int] = [:]
        mruRank.reserveCapacity(mruSnapshot.count)
        for (i, wid) in mruSnapshot.enumerated() { mruRank[wid] = i }

        var originalIndex: [CGWindowID: Int] = [:]
        var validIDs = Set<CGWindowID>()
        var rankMap: [CGWindowID: Int] = [:]
        var unknownCount = 0
        
        for (idx, w) in windows.enumerated() {
            originalIndex[w.windowID] = idx
            validIDs.insert(w.windowID)
            let r = mruRank[w.windowID] ?? Int.max
            rankMap[w.windowID] = r
            if r == Int.max { unknownCount += 1 }
        }
        prune(validIDs: validIDs)
        
        // If ranks are missing (common at startup), derive best-effort ordering from WindowServer lists.
        // We intentionally do NOT seed mruIDs here; true MRU is learned while running via `bump(windowID:)`.
        if unknownCount > 0 {
            // Phase 1: on-screen z-order (best proxy for "frontmost" ordering)
            var onScreenOrder: [CGWindowID] = []
            if let infoList = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] {
                var seen = Set<CGWindowID>()
                for entry in infoList {
                    guard let idNum = entry[kCGWindowNumber as String] as? Int else { continue }
                    let wid = CGWindowID(idNum)
                    guard validIDs.contains(wid) else { continue }
                    if seen.insert(wid).inserted {
                        onScreenOrder.append(wid)
                    }
                }
            }

            // Phase 2: full list for remaining windows (covers minimized/off-screen/etc.; ordering is best-effort)
            let remaining = validIDs.subtracting(onScreenOrder)
            var fullOrder: [CGWindowID] = []
            if !remaining.isEmpty,
               let infoList = CGWindowListCopyWindowInfo([.excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] {
                var seen = Set<CGWindowID>()
                for entry in infoList {
                    guard let idNum = entry[kCGWindowNumber as String] as? Int else { continue }
                    let wid = CGWindowID(idNum)
                    guard remaining.contains(wid) else { continue }
                    if seen.insert(wid).inserted {
                        fullOrder.append(wid)
                    }
                }
            }

            let maxKnownRank = rankMap.values.filter { $0 != Int.max }.max() ?? -1
            var nextRank = maxKnownRank + 1

            for wid in onScreenOrder where rankMap[wid] == Int.max {
                rankMap[wid] = nextRank
                nextRank += 1
            }
            for wid in fullOrder where rankMap[wid] == Int.max {
                rankMap[wid] = nextRank
                nextRank += 1
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
        // Mark seeded once; callers can invoke this multiple times.
        queue.sync {
            if !self.hasSeeded { self.hasSeeded = true }
        }

        // We intentionally do not seed mruIDs from a full WindowServer listing; initial
        // display ordering is handled in `sortWindowsByRecency(_:)` when ranks are unknown.
        // Always invoke the completion on the main queue.
        DispatchQueue.main.async { completion() }
    }
}

extension Array where Element == SystemWindow {
    /// Groups windows by visibility tier (normal, atEnd) while preserving
    /// the current order within each tier.
    mutating func groupByTierPreservingOrder() {
        let normal = self.filter { $0.tier == .normal }
        let atEnd = self.filter { $0.tier == .atEnd }
        self = normal + atEnd
    }
}
