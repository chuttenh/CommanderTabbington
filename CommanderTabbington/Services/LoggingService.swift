import Foundation
import OSLog

enum AppLog {
    static let subsystem = Bundle.main.bundleIdentifier ?? "CommanderTabbington"

    static let app = Logger(subsystem: subsystem, category: "App")
    static let appState = Logger(subsystem: subsystem, category: "AppState")
    static let input = Logger(subsystem: subsystem, category: "Input")
    static let focus = Logger(subsystem: subsystem, category: "Focus")
    static let preferences = Logger(subsystem: subsystem, category: "Preferences")
}
