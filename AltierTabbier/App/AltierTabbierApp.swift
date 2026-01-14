import SwiftUI

@main
struct AltierTabbierApp: App {
    // 1. Connect the AppDelegate
    // In a utility app, the AppDelegate is the "Brain" that manages the
    // global hotkeys and the lifecycle, rather than the SwiftUI App struct.
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    
    var body: some Scene {
        // We can leave this empty or use a Settings block as a fallback,
        // but for an Agent app, an empty Settings scene is fine.
        Settings {
            EmptyView()
        }
    }
}
