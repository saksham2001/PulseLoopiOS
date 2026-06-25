import SwiftUI

enum AppRoute: Hashable {
    case activityDetail(UUID)
    case recordSelect
    case recordLive(UUID)
    case recordSummary(UUID)
    case settings
    // Settings detail screens (the top-level `settings` route is the category list).
    case settingsProfile
    case settingsNotifications
    case settingsCoach
    case settingsWearable
    case settingsMeasurement
    case settingsActivityTracking
    case settingsGoals
    case settingsVitals
    case settingsPrivacyData
    case settingsHealth
    case settingsAbout
    case pairing
    case debug
    case componentGallery
}

enum MainTab: String, CaseIterable, Identifiable {
    case today = "Today"
    case vitals = "Vitals"
    case activity = "Activity"
    case sleep = "Sleep"
    case coach = "Coach"
    
    var id: String { rawValue }
    
    var symbol: String {
        switch self {
        case .today: return "circle.circle"
        case .vitals: return "heart"
        case .activity: return "waveform.path.ecg"
        case .sleep: return "moon"
        case .coach: return "sparkles"
        }
    }
}

enum PulseColors {
    static let background = Color(hex: "#080A0F")
    static let secondaryBackground = Color(hex: "#0E1118")
    static let card = Color(hex: "#151A23")
    static let cardSoft = Color(hex: "#1B2230")
    static let elevated = Color(hex: "#202838")
    static let textPrimary = Color(hex: "#F5F7FA")
    static let textSecondary = Color(hex: "#AAB3C2")
    static let textMuted = Color(hex: "#6F7A8C")
    static let accent = Color(hex: "#7C5CFF")
    static let accentSoft = Color(hex: "#7C5CFF").opacity(0.18)
    static let success = Color(hex: "#35E0A1")
    static let warning = Color(hex: "#FFB86B")
    static let danger = Color(hex: "#FF4D6D")
    static let info = Color(hex: "#4DDCFF")
    static let steps = Color(hex: "#35E0A1")
    static let heartRate = Color(hex: "#FF4D6D")
    static let spo2 = Color(hex: "#4DDCFF")
    static let sleep = Color(hex: "#8B7CFF")
    static let calories = Color(hex: "#FF8A4C")
    static let distance = Color(hex: "#4DA3FF")
    static let readiness = Color(hex: "#D6FF65")
    static let battery = Color(hex: "#A7F3D0")
    // Colmi R02 metrics
    static let stress = Color(hex: "#FF8A4C")
    static let hrv = Color(hex: "#9D7CFF")
    static let temperature = Color(hex: "#2DD4D8")
    static let borderSubtle = Color.white.opacity(0.08)
    static let borderStrong = Color.white.opacity(0.16)
}

extension Color {
    init(hex: String) {
        let trimmed = hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        var value: UInt64 = 0
        Scanner(string: trimmed).scanHexInt64(&value)
        
        let red: UInt64
        let green: UInt64
        let blue: UInt64
        let alpha: UInt64
        
        switch trimmed.count {
        case 3:
            red = (value >> 8) * 17
            green = (value >> 4 & 0xF) * 17
            blue = (value & 0xF) * 17
            alpha = 255
        case 6:
            red = value >> 16
            green = value >> 8 & 0xFF
            blue = value & 0xFF
            alpha = 255
        case 8:
            red = value >> 24
            green = value >> 16 & 0xFF
            blue = value >> 8 & 0xFF
            alpha = value & 0xFF
        default:
            red = 255
            green = 255
            blue = 255
            alpha = 255
        }
        
        self.init(
            .sRGB,
            red: Double(red) / 255,
            green: Double(green) / 255,
            blue: Double(blue) / 255,
            opacity: Double(alpha) / 255
        )
    }
}

struct PulseCard<Content: View>: View {
    var padding: CGFloat = 16
    @ViewBuilder var content: Content
    
    var body: some View {
        content
            .padding(padding)
            .background(PulseColors.card)
            .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .stroke(PulseColors.borderSubtle, lineWidth: 1)
            }
    }
}

struct MetricTile: View {
    let title: String
    let value: String
    var unit: String?
    var color: Color
    var trend: [Double] = []
    
    var body: some View {
        PulseCard {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 8) {
                    Circle().fill(color).frame(width: 8, height: 8)
                    Text(title.uppercased())
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(PulseColors.textMuted)
                        .lineLimit(1)
                }
                
                HStack(alignment: .firstTextBaseline, spacing: 5) {
                    Text(value)
                        .font(.system(size: 30, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(PulseColors.textPrimary)
                        .minimumScaleFactor(0.75)
                        .lineLimit(1)
                    if let unit {
                        Text(unit)
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(PulseColors.textMuted)
                    }
                }
                
                MiniSparkline(values: trend, color: color)
                    .frame(height: 34)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

struct MiniSparkline: View {
    let values: [Double]
    let color: Color
    
    var body: some View {
        GeometryReader { proxy in
            Path { path in
                guard values.count > 1, let minValue = values.min(), let maxValue = values.max() else { return }
                let range = max(maxValue - minValue, 1)
                for index in values.indices {
                    let x = proxy.size.width * CGFloat(index) / CGFloat(values.count - 1)
                    let yRatio = (values[index] - minValue) / range
                    let y = proxy.size.height - proxy.size.height * CGFloat(yRatio)
                    if index == values.startIndex {
                        path.move(to: CGPoint(x: x, y: y))
                    } else {
                        path.addLine(to: CGPoint(x: x, y: y))
                    }
                }
            }
            .stroke(color.opacity(values.count > 1 ? 0.9 : 0.2), style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
        }
    }
}

struct PrimaryButton: View {
    let title: String
    var systemImage: String?
    let action: () -> Void
    
    var body: some View {
        Button(action: action) {
            Label(title, systemImage: systemImage ?? "arrow.right")
                .labelStyle(.titleAndIcon)
                .font(.system(size: 16, weight: .semibold))
                .frame(maxWidth: .infinity)
                .frame(height: 56)
                .foregroundStyle(.white)
                .background(PulseColors.accent)
                .clipShape(Capsule())
        }
    }
}

struct SecondaryButton: View {
    let title: String
    var systemImage: String?
    let action: () -> Void
    
    var body: some View {
        Button(action: action) {
            Label(title, systemImage: systemImage ?? "circle")
                .font(.system(size: 15, weight: .semibold))
                .frame(maxWidth: .infinity)
                .frame(height: 52)
                .foregroundStyle(PulseColors.textPrimary)
                .background(PulseColors.card)
                .clipShape(Capsule())
                .overlay {
                    Capsule().stroke(PulseColors.borderSubtle, lineWidth: 1)
                }
        }
    }
}
