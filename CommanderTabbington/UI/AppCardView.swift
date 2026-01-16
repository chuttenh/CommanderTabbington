import SwiftUI

struct AppCardView: View {
    let app: SystemApp
    let isSelected: Bool
    var subtitle: String? = nil

    var body: some View {
        ZStack(alignment: .topTrailing) {
            VStack(spacing: 4) {
                ZStack(alignment: .topTrailing) {
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
                    // Badge overlay using original positioning and size
                    if UserDefaults.standard.object(forKey: "showNotificationBadges") as? Bool ?? true, let badge = app.badgeCount {
                        BadgeView(count: badge)
                            .offset(x: 5, y: 3)
                    }
                }
                .shadow(color: Color.black.opacity(isSelected ? 0.55 : 0.0), radius: isSelected ? 8 : 0, x: 0, y: 4)
                .scaleEffect(isSelected ? 1.08 : 1.0, anchor: .top)
                .padding(.top, 6)
                .frame(height: 70, alignment: .top)
                
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
                    } else if app.windowCount > 1 { // Show only for more than one window
                        Text("\(app.windowCount) windows")
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .lineLimit(1)
                    }
                }
                .frame(height: 36, alignment: .top)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
        .contentShape(Rectangle())
    }
}

struct BadgeView: View {
    let count: Int
    
    private var fontSize: CGFloat {
        let digits = String(count).count
        switch digits {
        case 1: return 13
        case 2: return 12
        case 3: return 11
        default: return 10
        }
    }
    
    var body: some View {
        ZStack {
            Circle()
                .fill(Color.red)
                .frame(width: 22, height: 22)
            if count > 0 {
                // Limit set to 999 as requested
                Text("\(count > 999 ? "999+" : "\(count)")")
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

