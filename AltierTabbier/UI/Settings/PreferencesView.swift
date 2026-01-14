import SwiftUI

struct PreferencesView: View {
    @EnvironmentObject var appState: AppState
    
    // Simple UserDefault storage for a setting
    @AppStorage("showDesktopWindows") private var showDesktopWindows: Bool = false
    
    var body: some View {
        Form {
            Section(header: Text("General")) {
                Toggle("Launch at Login", isOn: .constant(false))
                    .disabled(true)
                    .help("Not implemented in MVP")
                
                Toggle("Show Desktop Windows", isOn: $showDesktopWindows)
                    .onChange(of: showDesktopWindows) { _ in
                        // In the future, you'd pass this preference to WindowManager
                        print("Preference changed: Show Desktop = \(showDesktopWindows)")
                    }
            }
            
            Section(header: Text("About")) {
                HStack {
                    Text("Version")
                    Spacer()
                    Text("1.0.0 (Alpha)")
                        .foregroundColor(.secondary)
                }
                
                Button("Check Permissions") {
                    let trusted = AXIsProcessTrusted()
                    print("Accessibility Trusted: \(trusted)")
                }
            }
        }
        .padding(20)
        .frame(width: 350, height: 200)
    }
}
