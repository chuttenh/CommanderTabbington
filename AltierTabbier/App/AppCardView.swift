import SwiftUI

struct AppCardView: View {
    let app: SystemApp
    let isSelected: Bool
    var subtitle: String? = nil

    var body: some View {
        ZStack(alignment: .topTrailing) {
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
                .frame(height: 72, alignment: .bottom)
                
                VStack(spacing: 2) {
                    Text(app.appName)
                        .font(.headline)
                        .foregroundColor(.primary)
                        .lineLimit(1)
                        .frame(height: 20, alignment: .top)
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
                            .lineLimit(1)
                    }
                }
            }
            
            // Badge overlay (top-right)
            if UserDefaults.standard.object(forKey: "showNotificationBadges") as? Bool ?? true, let badge = app.badgeCount {
                BadgeView(count: badge)
                    .offset(x: 6, y: -6)
            }
        }
        .contentShape(Rectangle())
    }
}
struct BadgeView: View {
    let count: Int
    
    private var fontSize: CGFloat {
        let digits = String(count).count
        switch digits {
        case 1: return 12
        case 2: return 11
        case 3: return 10
        default: return 9
        }
    }
    
    var body: some View {
        ZStack {
            Circle()
                .fill(Color.red)
                .frame(width: 20, height: 20)
            if count > 0 {
                Text("\(count)")
                    .font(.system(size: fontSize, weight: .bold))
                    .foregroundColor(.white)
                    .minimumScaleFactor(0.6)
                    .lineLimit(1)
            }
        }
        .shadow(radius: 2)
        .accessibilityLabel(count > 0 ? "\(count) notifications" : "Has notifications")
    }
}

