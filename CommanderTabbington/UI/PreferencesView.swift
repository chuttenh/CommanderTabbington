import SwiftUI

struct PreferencesView: View {
    @EnvironmentObject var appState: AppState
    
    // Simple UserDefault storage for a setting
    @AppStorage("showDesktopWindows") private var showDesktopWindows: Bool = false
    @AppStorage("maxWidthFraction") private var maxWidthFraction: Double = 0.9
    @AppStorage("maxVisibleRows") private var maxVisibleRows: Int = 2
    @AppStorage("showNotificationBadges") private var showNotificationBadges: Bool = true
//    @AppStorage("IncludeHiddenApps") private var includeHiddenApps: Bool = true
//    @AppStorage("IncludeMinimizedApps") private var includeMinimizedApps: Bool = true
    @AppStorage("HiddenAppsPlacement") private var hiddenPlacementRaw: Int = PlacementPreference.normal.rawValue
    @AppStorage("MinimizedAppsPlacement") private var minimizedPlacementRaw: Int = PlacementPreference.normal.rawValue
    @AppStorage("switcherOpenDelayMS") private var switcherOpenDelayMS: Int = 100
    
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
                
                Picker("Switcher Mode", selection: Binding(get: {
                    appState.mode == .perApp
                }, set: { newValue in
                    appState.mode = newValue ? .perApp : .perWindow
                    UserDefaults.standard.set(newValue, forKey: "perAppMode")
                })) {
                    Text("Per App").tag(true)
                    Text("Per Window").tag(false)
                }
                .pickerStyle(.segmented)
                .padding(.top, 8)
                
                VStack(alignment: .leading, spacing: 8) {
                    Text("Switcher open delay (milliseconds)")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    HStack(spacing: 8) {
                        TextField("Delay (ms)", value: $switcherOpenDelayMS, formatter: NumberFormatter())
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 120)
                            .onChange(of: switcherOpenDelayMS) { newVal in
                                if newVal < 0 { switcherOpenDelayMS = 0 }
                            }
                        Text("ms")
                            .foregroundStyle(.secondary)
                    }
                    .help("Delay before the switcher overlay becomes visible after pressing Command+Tab. Prevents flicker on quick switches.")
                }
                
                Toggle("Show Notification Badges", isOn: $showNotificationBadges)
                    .onChange(of: showNotificationBadges) { _ in
                        print("Preference changed: Show Badges = \(showNotificationBadges)")
                    }
                
                Picker("Hidden apps", selection: $hiddenPlacementRaw) {
                    Text("Normal").tag(PlacementPreference.normal.rawValue)
                    Text("At the end").tag(PlacementPreference.atEnd.rawValue)
                    Text("Exclude").tag(PlacementPreference.exclude.rawValue)
                }
                .pickerStyle(.segmented)
                .onChange(of: hiddenPlacementRaw) { _ in print("Preference changed: HiddenAppsPlacement = \(hiddenPlacementRaw)") }

                Picker("Minimized windows", selection: $minimizedPlacementRaw) {
                    Text("Normal").tag(PlacementPreference.normal.rawValue)
                    Text("At the end").tag(PlacementPreference.atEnd.rawValue)
                    Text("Exclude").tag(PlacementPreference.exclude.rawValue)
                }
                .pickerStyle(.segmented)
                .onChange(of: minimizedPlacementRaw) { _ in print("Preference changed: MinimizedAppsPlacement = \(minimizedPlacementRaw)") }
            }
            
            Section(header: Text("Layout")) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Maximum overlay width")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    HStack {
                        Slider(value: $maxWidthFraction, in: 0.6...0.98, step: 0.02)
                        Text("\(Int(maxWidthFraction * 100))%")
                            .monospacedDigit()
                            .frame(width: 50, alignment: .trailing)
                    }
                    .help("The switcher will expand up to this fraction of the screen width before wrapping to multiple rows.")
                }
                
                Stepper(value: $maxVisibleRows, in: 1...6) {
                    Text("Max visible rows: \(maxVisibleRows)")
                }
                .help("The switcher will show up to this many rows before enabling vertical scrolling.")
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
        .frame(width: 350, height: 260)
    }
}

