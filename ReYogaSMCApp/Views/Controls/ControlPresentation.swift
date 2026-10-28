import Foundation

// Raw values are persisted in ControlsPage and used by existing installations.
enum ControlsPage: Int {
    case settings = -1
    case overview = 0, device = 1, cooling = 2, battery = 3, lighting = 4, diagnostics = 5

    static let sidebar: [ControlsPage] = [.overview, .device, .cooling, .battery, .lighting, .diagnostics]

    var title: LocalizedKey {
        switch self {
        case .settings: return .sidebarSettingsTooltip
        case .overview: return .sidebarTabOverview
        case .device: return .sidebarTabDevice
        case .cooling: return .sidebarTabCooling
        case .battery: return .sidebarTabBattery
        case .lighting: return .sidebarTabLighting
        case .diagnostics: return .sidebarTabDiagnostics
        }
    }

    var symbol: String {
        switch self {
        case .settings: return "gearshape"
        case .overview: return "square.grid.2x2"
        case .device: return "laptopcomputer"
        case .cooling: return "wind"
        case .battery: return "battery.75"
        case .lighting: return "lightbulb"
        case .diagnostics: return "waveform.path.ecg"
        }
    }

    var subtitle: LocalizedKey {
        switch self {
        case .settings: return .subtitleSettings
        case .overview: return .subtitleOverview
        case .device: return .subtitleDevice
        case .cooling: return .subtitleCooling
        case .battery: return .subtitleBattery
        case .lighting: return .subtitleLighting
        case .diagnostics: return .subtitleDiagnostics
        }
    }
}

func powerDraftStorageKey(_ controlKey: String, titleKey: LocalizedKey,
                          defaults: UserDefaults = .standard, bundle: Bundle = .main) -> String {
    let key = "PowerDraft." + controlKey
    guard defaults.object(forKey: key) == nil else { return key }
    let currentTitle = bundle.localizedString(forKey: titleKey.rawValue, value: nil, table: nil)
    let legacyTitles = [currentTitle] + ["en", "vi"].compactMap { language -> String? in
        guard let path = bundle.path(forResource: language, ofType: "lproj"),
              let localizedBundle = Bundle(path: path) else { return nil }
        return localizedBundle.localizedString(forKey: titleKey.rawValue, value: nil, table: nil)
    }
    for title in legacyTitles {
        if let saved = defaults.string(forKey: "PowerDraft." + title) {
            defaults.set(saved, forKey: key)
            break
        }
    }
    return key
}

func controlValueLabel(_ key: String, target: Int) -> String {
    switch key {
    case "SmartFanMode": return [1: "Quiet", 2: "Balanced", 3: "Performance"][target] ?? localizedMessage("Unknown (%@)", String(target))
    case "AlwaysOnUSBState": return [0: "Off", 1: "AC power", 2: "AC + battery"][target] ?? localizedMessage("Unknown (%@)", String(target))
    case "ChargeStartThreshold", "ChargeStopThreshold": return "\(target)%"
    case "BatteryIndex": return target == 1 ? "Primary" : "Secondary"
    case "BacklightLevel": return String(target)
    case "CPUPowerReset": return "Restored"
    case "Fan1TargetRPM", "Fan2TargetRPM": return localizedMessage("%@ RPM minimum", String(target))
    case "CPUBoostPower", "CPUSustainedPower": return "\(target) W"
    default: return target == 0 ? "Off" : "On"
    }
}
