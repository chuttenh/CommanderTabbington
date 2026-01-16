import SwiftUI

struct SwitcherView: View {
    @EnvironmentObject var appState: AppState
    
    // Aesthetic Constants
    let itemWidth: CGFloat = 90
    let itemHeight: CGFloat = 110
    let spacing: CGFloat = 12

    private var hasSecondTier: Bool {
        switch appState.mode {
        case .perApp:
            return appState.visibleApps.contains { $0.tier != .normal }
        case .perWindow:
            return appState.visibleWindows.contains { $0.tier != .normal }
        }
    }
    
    var body: some View {
        ZStack {
            // Background Blur (Glass Effect)
            VisualEffectView(material: .hudWindow, blendingMode: .withinWindow)
                .edgesIgnoringSafeArea(.all)
            
            VStack(spacing: 0) {
                // Header / Title (Optional, useful for debugging)
                // Text("Commander Tabbington").font(.caption).opacity(0.5).padding(.top, 10)
                
                ScrollView(.vertical, showsIndicators: false) {
                    ScrollViewReader { proxy in
                        let columns = [GridItem(.adaptive(minimum: itemWidth), spacing: spacing, alignment: .center)]
                        LazyVGrid(columns: columns, alignment: .center, spacing: spacing) {
                            if appState.mode == .perApp {
                                let enumeratedApps = Array(appState.visibleApps.enumerated())
                                let mainApps = enumeratedApps.filter { $0.element.tier == .normal }
                                let hiddenApps = enumeratedApps.filter { $0.element.tier == .hidden }
                                let minimizedApps = enumeratedApps.filter { $0.element.tier == .minimized }

                                let tiers: [[(offset: Int, element: SystemApp)]] = [mainApps, hiddenApps, minimizedApps]
                                ForEach(Array(tiers.enumerated()), id: \.offset) { tIndex, tierApps in
                                    if tIndex > 0, hasSecondTier, !tierApps.isEmpty {
                                        Rectangle()
                                            .fill(Color.secondary.opacity(0.3))
                                            .frame(width: 1)
                                            .frame(height: itemHeight)
                                            .padding(.horizontal, 6)
                                    }
                                    ForEach(tierApps, id: \.element.id) { pair in
                                        let globalIndex = pair.offset
                                        let app = pair.element
                                        AppCardView(
                                            app: app,
                                            isSelected: globalIndex == appState.selectedIndex
                                        )
                                        .frame(width: itemWidth, height: itemHeight)
                                        .id(app.id)
                                        .onTapGesture {
                                            appState.selectedIndex = globalIndex
                                            appState.commitSelection()
                                        }
                                    }
                                }
                            } else {
                                let enumeratedWins = Array(appState.visibleWindows.enumerated())
                                let mainWins = enumeratedWins.filter { $0.element.tier == .normal }
                                let hiddenWins = enumeratedWins.filter { $0.element.tier == .hidden }
                                let minimizedWins = enumeratedWins.filter { $0.element.tier == .minimized }

                                let tiersW: [[(offset: Int, element: SystemWindow)]] = [mainWins, hiddenWins, minimizedWins]
                                ForEach(Array(tiersW.enumerated()), id: \.offset) { tIndex, tierWins in
                                    if tIndex > 0, hasSecondTier, !tierWins.isEmpty {
                                        Rectangle()
                                            .fill(Color.secondary.opacity(0.3))
                                            .frame(width: 1)
                                            .frame(height: itemHeight)
                                            .padding(.horizontal, 6)
                                    }
                                    ForEach(tierWins, id: \.element.id) { pair in
                                        let globalIndex = pair.offset
                                        let window = pair.element
                                        AppCardView(
                                            app: SystemApp(ownerPID: window.ownerPID,
                                                           appName: window.appName,
                                                           owningApplication: window.owningApplication,
                                                           appIcon: window.appIcon,
                                                           windowCount: 1,
                                                           badgeCount: nil,
                                                           tier: window.tier),
                                            isSelected: globalIndex == appState.selectedIndex,
                                            subtitle: window.title
                                        )
                                        .frame(width: itemWidth, height: itemHeight)
                                        .id(window.windowID)
                                        .onTapGesture {
                                            appState.selectedIndex = globalIndex
                                            appState.commitSelection()
                                        }
                                    }
                                }
                            }
                        }
                        .padding(.horizontal, 40)
                        .onChange(of: appState.selectedIndex) { newIndex in
                            withAnimation(.easeOut(duration: 0.15)) {
                                if appState.mode == .perApp {
                                    if appState.visibleApps.indices.contains(newIndex) {
                                        let id = appState.visibleApps[newIndex].id
                                        proxy.scrollTo(id, anchor: .center)
                                    }
                                } else {
                                    if appState.visibleWindows.indices.contains(newIndex) {
                                        let id = appState.visibleWindows[newIndex].id
                                        proxy.scrollTo(id, anchor: .center)
                                    }
                                }
                            }
                        }
                    }
                }
                .padding(.vertical, 20)
            }
        }
        // Force the size of the window to fit content if you want,
        // or just let the panel size set in AppDelegate dictate it.
    }
}

// Helper for the "Glass" background
struct VisualEffectView: NSViewRepresentable {
    let material: NSVisualEffectView.Material
    let blendingMode: NSVisualEffectView.BlendingMode
    
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = material
        view.blendingMode = blendingMode
        view.state = .active
        return view
    }
    
    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {
        nsView.material = material
        nsView.blendingMode = blendingMode
    }
}

