import SwiftUI

struct WindowCardView: View {
    let window: SystemWindow
    let isSelected: Bool
    
    // NEW: Local state to hold the async loaded image
    @State private var asyncImage: CGImage?
    
    var body: some View {
        VStack(spacing: 8) {
            ZStack {
                RoundedRectangle(cornerRadius: 10)
                    .fill(Color(nsColor: .controlBackgroundColor).opacity(0.3))
                
                // DECISION LOGIC:
                // 1. If we have the async image, show it.
                // 2. If not, fallback to the window struct's preview (likely nil now).
                // 3. If both nil, show the generic icon.
                if let image = asyncImage ?? window.windowPreview {
                    Image(decorative: image, scale: 1.0)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .padding(12)
                } else {
                    // Placeholder while loading
                    Image(systemName: "photo")
                        .font(.largeTitle)
                        .foregroundColor(.secondary)
                        .opacity(0.3)
                }
                
                if let nsIcon = window.appIcon {
                    Image(nsImage: nsIcon)
                        .resizable()
                        .frame(width: 32, height: 32)
                        .position(x: 32, y: 32)
                        .shadow(radius: 2)
                }
            }
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .stroke(isSelected ? Color.blue : Color.clear, lineWidth: 4)
            )
            .shadow(radius: isSelected ? 5 : 0)
            .scaleEffect(isSelected ? 1.05 : 1.0)
            
            VStack(spacing: 2) {
                Text(window.appName)
                    .font(.headline)
                    .foregroundColor(.primary)
                Text(window.title)
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        }
        .contentShape(Rectangle())
        // NEW: Trigger the async fetch when this specific card appears
        .task {
            // If we already have an image, don't re-fetch
            guard asyncImage == nil else { return }
            
            // Call the async manager
            asyncImage = await WindowManager.shared.fetchThumbnail(for: window.windowID)
        }
    }
}

