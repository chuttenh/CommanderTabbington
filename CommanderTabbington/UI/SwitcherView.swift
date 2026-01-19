import SwiftUI

struct SwitcherView: View {
    @EnvironmentObject var appState: AppState
    
    // Aesthetic Constants
    let itemWidth: CGFloat = SwitcherLayout.itemWidth
    let itemHeight: CGFloat = SwitcherLayout.itemHeight
    let spacing: CGFloat = SwitcherLayout.spacing

    var body: some View {
        ZStack {
            // Background Blur (Glass Effect)
            VisualEffectView(material: .hudWindow, blendingMode: .withinWindow)
                .edgesIgnoringSafeArea(.all)
            
            VStack(spacing: 0) {
                ScrollView(.vertical, showsIndicators: false) {
                    ScrollViewReader { proxy in
                        let columns = [GridItem(.adaptive(minimum: itemWidth), spacing: spacing, alignment: .center)]
                        
                        LazyVGrid(columns: columns, alignment: .center, spacing: spacing) {
                            if appState.mode == .perApp {
                                let apps = appState.visibleApps
                                ForEach(Array(apps.enumerated()), id: \.element.id) { index, app in
                                    // Calculate if we need a tier separator divider
                                    let isLastInTier = (index + 1 < apps.count) && (app.tier != apps[index + 1].tier)
                                    
                                    AppCardView(
                                        app: app,
                                        isSelected: (appState.selectedAppID != nil && appState.selectedAppID == app.id)
                                    )
                                    .frame(width: itemWidth, height: itemHeight)
                                    .id(app.id)
                                    .overlay(alignment: .trailing) {
                                        if isLastInTier {
                                            Rectangle()
                                                .fill(Color.secondary.opacity(0.3))
                                                .frame(width: 1, height: itemHeight)
                                                .offset(x: spacing / 2)
                                        }
                                    }
                                    .onTapGesture {
                                        appState.selectedAppID = app.id
                                        appState.selectedIndex = index
                                        appState.commitSelection()
                                    }
                                }
                            } else {
                                let windows = appState.visibleWindows
                                ForEach(Array(windows.enumerated()), id: \.element.id) { index, window in
                                    let isLastInTier = (index + 1 < windows.count) && (window.tier != windows[index + 1].tier)
                                    
                                    AppCardView(
                                        app: SystemApp(ownerPID: window.ownerPID,
                                                       appName: window.appName,
                                                       owningApplication: window.owningApplication,
                                                       appIcon: window.appIcon,
                                                       windowCount: 1,
                                                       badgeCount: nil,
                                                       tier: window.tier),
                                        isSelected: (appState.selectedWindowID != nil && appState.selectedWindowID == window.id),
                                        subtitle: window.title
                                    )
                                    .frame(width: itemWidth, height: itemHeight)
                                    .id(window.id)
                                    .overlay(alignment: .trailing) {
                                        if isLastInTier {
                                            Rectangle()
                                                .fill(Color.secondary.opacity(0.3))
                                                .frame(width: 1, height: itemHeight)
                                                .offset(x: spacing / 2)
                                        }
                                    }
                                    .onTapGesture {
                                        appState.selectedWindowID = window.id
                                        appState.selectedIndex = index
                                        appState.commitSelection()
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
                
                // Spacer prevents the icon row from rendering too low on startup by filling bottom space
                Spacer(minLength: 0)
            }
        }
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
