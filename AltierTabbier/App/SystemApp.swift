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

    static func == (lhs: SystemApp, rhs: SystemApp) -> Bool {
        lhs.ownerPID == rhs.ownerPID
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(ownerPID)
    }
}
