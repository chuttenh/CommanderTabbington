import SwiftUI

struct SwitcherView: View {
    @EnvironmentObject var appState: AppState
    
    // Aesthetic Constants
    let itemWidth: CGFloat = 160
    let itemHeight: CGFloat = 180
    let spacing: CGFloat = 20
    
    var body: some View {
        ZStack {
            // Background Blur (Glass Effect)
            VisualEffectView(material: .hudWindow, blendingMode: .withinWindow)
                .edgesIgnoringSafeArea(.all)
            
            VStack(spacing: 0) {
                // Header / Title (Optional, useful for debugging)
                // Text("AltierTabbier").font(.caption).opacity(0.5).padding(.top, 10)
                
                ScrollView(.horizontal, showsIndicators: false) {
                    ScrollViewReader { proxy in
                        HStack(spacing: spacing) {
                            ForEach(Array(appState.visibleWindows.enumerated()), id: \.element.id) { index, window in
                                WindowCardView(
                                    window: window,
                                    isSelected: index == appState.selectedIndex
                                )
                                .frame(width: itemWidth, height: itemHeight)
                                .id(index) // Important for ScrollViewReader
                                .onTapGesture {
                                    // Allow clicking to select
                                    appState.selectedIndex = index
                                    appState.commitSelection()
                                }
                            }
                        }
                        .padding(.horizontal, 40) // Padding at ends of list
                        // Listen for changes in selection to auto-scroll
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
