// SystemApp.swift
// Represents a single running application entry for the switcher (one per app)

import Cocoa

struct SystemApp: Identifiable, Hashable {
    // Identity: use the owning process ID
    let ownerPID: pid_t
    var id: pid_t { ownerPID }

    // Metadata
    let appName: String
    let owningApplication: NSRunningApplication?

    // Visuals
    let appIcon: NSImage?

    // Aggregates
    var windowCount: Int
    var badgeCount: Int? = nil
    var tier: VisibilityTier = .normal

    static func == (lhs: SystemApp, rhs: SystemApp) -> Bool {
        // Essential to include tier and windowCount so SwiftUI updates when state changes
        lhs.ownerPID == rhs.ownerPID && 
        lhs.tier == rhs.tier && 
        lhs.windowCount == rhs.windowCount &&
        lhs.badgeCount == rhs.badgeCount &&
        lhs.appName == rhs.appName
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(ownerPID)
        hasher.combine(tier)
    }
}
