import SwiftUI
import AppKit

public enum AppTheme {
    public static let width: CGFloat = 680
    public static let height: CGFloat = 360
    public static let windowWidth: CGFloat = 680
    public static let windowHeight: CGFloat = 560

    public static var accent: Color { Colors.accent }
    public static var surface: Color { Colors.surface }
    public static var cpu: Color { Colors.cpu }
    public static var gpu: Color { Colors.gpu }
    public static var connected: Color { Colors.connected }

    public static func profile(_ mode: Int) -> Color { Colors.profile(mode) }
    public static func feature(_ icon: String) -> Color { Colors.feature(icon) }
    public static func batteryProgressColor(_ percent: Int?) -> Color { Colors.batteryProgressColor(percent) }

    public enum Colors {
        public static let accent = adaptive(light: (0.78, 0.29, 0.16), dark: (0.96, 0.56, 0.36))
        public static let surface = Color(NSColor.controlBackgroundColor)
        public static let windowBackground = Color(NSColor.windowBackgroundColor)

        public static let cpu = adaptive(light: (0.08, 0.55, 0.65), dark: (0.30, 0.76, 0.86))
        public static let gpu = adaptive(light: (0.83, 0.38, 0.18), dark: (0.97, 0.63, 0.40))
        public static let connected = adaptive(light: (0.10, 0.55, 0.33), dark: (0.30, 0.78, 0.52))

        public static func profile(_ mode: Int) -> Color {
            switch mode {
            case 1: return Color(red: 0.06, green: 0.46, blue: 0.42)
            case 2: return Color(red: 0.24, green: 0.38, blue: 0.72)
            default: return Color(red: 0.79, green: 0.20, blue: 0.18)
            }
        }

        public static func feature(_ icon: String) -> Color {
            if icon == "battery.75" || icon == "wind" { return cpu }
            if icon == "lightbulb" || icon == "powerplug" { return gpu }
            return accent
        }

        public static func batteryProgressColor(_ percent: Int?) -> Color {
            guard let p = percent else { return accent }
            if p >= 50 { return connected }
            if p >= 20 { return Color(red: 0.95, green: 0.70, blue: 0.15) }
            return Color(red: 0.85, green: 0.22, blue: 0.20)
        }

        public static func adaptive(light: (CGFloat, CGFloat, CGFloat), dark: (CGFloat, CGFloat, CGFloat)) -> Color {
            Color(NSColor(name: nil) { appearance in
                let rgb = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light
                return NSColor(srgbRed: rgb.0, green: rgb.1, blue: rgb.2, alpha: 1)
            })
        }
    }
}

public enum ReYogaConstants {
    public static let appName = "ReYogaSMC"
    public static let suiteName = "org.reyoga.ReYogaSMC"
    public static var repositoryURL: String {
        Bundle.main.object(forInfoDictionaryKey: "ReYogaRepositoryURL") as? String
            ?? "https://github.com/hoaug-tran/ReYogaSMC"
    }
    public static var hardwareDefaults: UserDefaults {
        UserDefaults(suiteName: suiteName) ?? .standard
    }
    public static var userDefaults: UserDefaults {
        .standard
    }
}

