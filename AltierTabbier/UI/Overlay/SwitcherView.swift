import SwiftUI

struct SwitcherView: View {
    @EnvironmentObject var appState: AppState
    
    // Aesthetic Constants
    let itemWidth: CGFloat = 90
    let itemHeight: CGFloat = 110
    let spacing: CGFloat = 12
    
    var body: some View {
        ZStack {
            // Background Blur (Glass Effect)
            VisualEffectView(material: .hudWindow, blendingMode: .withinWindow)
                .edgesIgnoringSafeArea(.all)
            
            VStack(spacing: 0) {
                // Header / Title (Optional, useful for debugging)
                // Text("AltierTabbier").font(.caption).opacity(0.5).padding(.top, 10)
                
                ScrollView(.vertical, showsIndicators: false) {
                    ScrollViewReader { proxy in
                        let columns = [GridItem(.adaptive(minimum: itemWidth), spacing: spacing, alignment: .center)]
                        LazyVGrid(columns: columns, alignment: .center, spacing: spacing) {
                            if appState.mode == .perApp {
                                ForEach(Array(appState.visibleApps.enumerated()), id: \.element.id) { index, app in
                                    AppCardView(
                                        app: app,
                                        isSelected: index == appState.selectedIndex
                                    )
                                    .frame(width: itemWidth, height: itemHeight)
                                    .id(index)
                                    .onTapGesture {
                                        appState.selectedIndex = index
                                        appState.commitSelection()
                                    }
                                }
                            } else {
                                ForEach(Array(appState.visibleWindows.enumerated()), id: \.element.id) { index, window in
                                    AppCardView(
                                        app: SystemApp(ownerPID: window.ownerPID,
                                                       appName: window.appName,
                                                       owningApplication: window.owningApplication,
                                                       appIcon: window.appIcon,
                                                       windowCount: 1),
                                        isSelected: index == appState.selectedIndex,
                                        subtitle: window.title
                                    )
                                    .frame(width: itemWidth, height: itemHeight)
                                    .id(index)
                                    .onTapGesture {
                                        appState.selectedIndex = index
                                        appState.commitSelection()
                                    }
                                }
                            }
                        }
                        .padding(.horizontal, 40)
                        .onChange(of: appState.selectedIndex) { newIndex in
                            withAnimation(.easeOut(duration: 0.15)) {
                                proxy.scrollTo(newIndex, anchor: .center)
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

