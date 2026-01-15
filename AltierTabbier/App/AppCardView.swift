import SwiftUI

struct AppCardView: View {
    let app: SystemApp
    let isSelected: Bool

    var body: some View {
        VStack(spacing: 8) {
            ZStack {
                RoundedRectangle(cornerRadius: 10)
                    .fill(Color(nsColor: .controlBackgroundColor).opacity(0.3))
                
                if let nsIcon = app.appIcon {
                    Image(nsImage: nsIcon)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .padding(24)
                } else {
                    Image(systemName: "app")
                        .font(.largeTitle)
                        .foregroundColor(.secondary)
                        .opacity(0.4)
                        .padding(24)
                }
            }
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .stroke(isSelected ? Color.blue : Color.clear, lineWidth: 4)
            )
            .shadow(radius: isSelected ? 5 : 0)
            .scaleEffect(isSelected ? 1.05 : 1.0)
            
            VStack(spacing: 2) {
                Text(app.appName)
                    .font(.headline)
                    .foregroundColor(.primary)
                if app.windowCount > 1 {
                    Text("\(app.windowCount) windows")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
        }
        .contentShape(Rectangle())
    }
}
