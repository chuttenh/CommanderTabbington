import SwiftUI

struct AppCardView: View {
    let app: SystemApp
    let isSelected: Bool
    var subtitle: String? = nil

    var body: some View {
        VStack(spacing: 8) {
            Group {
                if let nsIcon = app.appIcon {
                    Image(nsImage: nsIcon)
                        .resizable()
                        .interpolation(.high)
                        .antialiased(true)
                        .aspectRatio(contentMode: .fit)
                        .frame(width: 64, height: 64)
                } else {
                    Image(systemName: "app")
                        .font(.system(size: 48))
                        .foregroundColor(.secondary)
                        .opacity(0.7)
                        .frame(width: 64, height: 64)
                }
            }
            .shadow(radius: isSelected ? 6 : 0)
            .scaleEffect(isSelected ? 1.08 : 1.0)
            
            VStack(spacing: 2) {
                Text(app.appName)
                    .font(.headline)
                    .foregroundColor(.primary)
                if let subtitle = subtitle, !subtitle.isEmpty {
                    Text(subtitle)
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                } else if app.windowCount > 1 {
                    Text("\(app.windowCount) windows")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
        }
        .contentShape(Rectangle())
    }
}
