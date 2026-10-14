import SwiftUI

// Functional macOS utility: semantic colors, an 8-point spacing grid, and
// explicit switch state. Hardware availability is supplied by the manager.
@available(macOS 11.0, *)
private enum ControlDesign {
    static let width: CGFloat = 420
    static let height: CGFloat = 640
    static let accent = adaptive(light: (0.78, 0.29, 0.16), dark: (0.96, 0.56, 0.36))
    static let surface = Color(NSColor.controlBackgroundColor)
    static let cpu = adaptive(light: (0.08, 0.55, 0.65), dark: (0.30, 0.76, 0.86))
    static let gpu = adaptive(light: (0.83, 0.38, 0.18), dark: (0.97, 0.63, 0.40))
    static let connected = adaptive(light: (0.10, 0.55, 0.33), dark: (0.30, 0.78, 0.52))
    private static func adaptive(light: (CGFloat, CGFloat, CGFloat), dark: (CGFloat, CGFloat, CGFloat)) -> Color {
        Color(NSColor(name: nil) { appearance in
            let rgb = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light
            return NSColor(srgbRed: rgb.0, green: rgb.1, blue: rgb.2, alpha: 1)
        })
    }
    static func profile(_ mode: Int) -> Color {
        switch mode {
        case 1: return Color(red: 0.06, green: 0.46, blue: 0.42)
        case 2: return Color(red: 0.24, green: 0.38, blue: 0.72)
        default: return Color(red: 0.79, green: 0.20, blue: 0.18)
        }
    }
    static func feature(_ icon: String) -> Color {
        if icon == "battery.75" || icon == "wind" { return cpu }
        if icon == "lightbulb" || icon == "powerplug" { return gpu }
        return accent
    }
}

@available(macOS 11.0, *)
private struct StateAnimation<Value: Equatable>: ViewModifier {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let value: Value
    func body(content: Content) -> some View {
        if #available(macOS 12.0, *) {
            content.animation(reduceMotion ? nil : .easeInOut(duration: 0.18), value: value)
        } else {
            content.animation(reduceMotion ? nil : .easeInOut(duration: 0.18))
        }
    }
}

@available(macOS 11.0, *)
private struct GentlePressStyle: ButtonStyle {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .opacity(configuration.isPressed ? 0.85 : 1)
            .scaleEffect(configuration.isPressed && !reduceMotion ? 0.98 : 1)
            .modifier(StateAnimation(value: configuration.isPressed))
    }
}

@available(macOS 11.0, *)
private struct ProfileSelector: View {
    @ObservedObject var manager: GamingManager
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private let modes = [(1, "Quiet", "leaf.fill"), (2, "Balanced", "speedometer"), (3, "Performance", "flame.fill")]
    var body: some View {
        HStack(spacing: 8) {
            ForEach(modes, id: \.0) { mode in
                Button(action: { manager.setPowerProfile(mode.0) }) {
                    VStack(spacing: 6) {
                        Image(systemName: mode.2).font(.system(size: 14, weight: .semibold))
                        Text(mode.1).font(.system(size: 11, weight: .semibold)).lineLimit(1)
                    }.padding(.horizontal, 6).frame(maxWidth: .infinity).frame(height: 56)
                        .foregroundColor(manager.powerProfile == mode.0 ? .white : .primary)
                        .background(background(mode.0))
                        .contentShape(RoundedRectangle(cornerRadius: 10))
                }.buttonStyle(GentlePressStyle())
                    .accessibilityLabel(mode.1)
                    .accessibilityValue(manager.powerProfile == mode.0 ? "Selected" : "Not selected")
            }
        }
            .disabled(!manager.hasPowerProfiles || manager.applyingControl == "SmartFanMode")
    }
    private func background(_ mode: Int) -> some View {
        RoundedRectangle(cornerRadius: 10)
            .fill(manager.powerProfile == mode ? ControlDesign.profile(mode) : Color.primary.opacity(0.035))
            .overlay(RoundedRectangle(cornerRadius: 10)
                .stroke(manager.powerProfile == mode ? ControlDesign.profile(mode) : Color.primary.opacity(0.12), lineWidth: 1))
            .modifier(StateAnimation(value: manager.powerProfile == mode))
    }
}

@available(macOS 11.0, *)
private struct ControlSection<Content: View>: View {
    let title: String
    let content: Content
    init(_ title: String, @ViewBuilder content: () -> Content) {
        self.title = title; self.content = content()
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.system(size: 12, weight: .semibold)).foregroundColor(.secondary)
            VStack(alignment: .leading, spacing: 0) { content }
                .padding(12).background(ControlDesign.surface)
                .cornerRadius(12)
                .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.primary.opacity(0.045), lineWidth: 1))
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
}

@available(macOS 11.0, *)
private struct FanReadout: View {
    let title: String
    let rpm: Int
    let accentColor: Color
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "wind").foregroundColor(accentColor)
                    .frame(width: 24, height: 24).background(accentColor.opacity(0.12)).cornerRadius(7)
                Text(title).font(.system(size: 12, weight: .medium))
            }
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(rpm >= 0 ? String(rpm) : "—")
                    .font(.system(size: 26, weight: .semibold, design: .rounded))
                Text("RPM").font(.caption).foregroundColor(.secondary)
            }
        }.padding(12).frame(maxWidth: .infinity, alignment: .leading)
            .background(ControlDesign.surface)
            .overlay(RoundedRectangle(cornerRadius: 12).fill(accentColor.opacity(0.045)).allowsHitTesting(false))
            .cornerRadius(12)
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(accentColor.opacity(0.16), lineWidth: 1))
    }
}

@available(macOS 11.0, *)
private struct FeatureRow: View {
    let title: String
    let icon: String
    let isOn: Bool
    let available: Bool
    let reason: String
    let action: () -> Void
    private var color: Color { ControlDesign.feature(icon) }
    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: icon).font(.system(size: 12, weight: .medium))
                .frame(width: 28, height: 28)
                .foregroundColor(available && isOn ? color : .secondary)
                .background(available && isOn ? color.opacity(0.12) : Color.primary.opacity(0.04)).cornerRadius(8)
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.system(size: 12, weight: .medium)).fixedSize(horizontal: false, vertical: true)
                if !available { Text(reason).font(.system(size: 11)).foregroundColor(.secondary).fixedSize(horizontal: false, vertical: true) }
            }
            Spacer(minLength: 8)
            Text(available ? (isOn ? "On" : "Off") : "Unavailable")
                .font(.system(size: 11, weight: isOn && available ? .semibold : .regular))
                .foregroundColor(isOn && available ? color : .secondary)
                .padding(.horizontal, 6).padding(.vertical, 3)
                .background(isOn && available ? color.opacity(0.10) : Color.clear).cornerRadius(5)
            Toggle(title, isOn: Binding(get: { isOn }, set: { _ in action() }))
                .labelsHidden().toggleStyle(SwitchToggleStyle()).accentColor(color).disabled(!available)
        }.frame(minHeight: 36).modifier(StateAnimation(value: isOn))
    }
}

@available(macOS 11.0, *)
public struct GamingPopoverView: View {
    @ObservedObject var manager: GamingManager
    @AppStorage("ControlsPage") private var page = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    public init(manager: GamingManager, page: Int = 0) { self.manager = manager; if CommandLine.arguments.contains("--render-ui") { self.page = page } }
    public var body: some View {
        Group {
            if manager.driverState == .ready {
                dashboard
            } else {
                DriverUnavailableView(manager: manager)
            }
        }.frame(width: ControlDesign.width, height: ControlDesign.height)
    }
    private var dashboard: some View {
        VStack(spacing: 0) {
            header.padding(12)
            Picker("Controls", selection: $page) {
                Text("Device").tag(0); Text("Cooling & Power").tag(1)
            }.labelsHidden().pickerStyle(SegmentedPickerStyle()).padding(.horizontal, 16).padding(.bottom, 12)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    if page == 0 { deviceControls } else { coolingControls }
                }.padding(12).frame(maxWidth: .infinity, alignment: .leading)
            }.transaction { $0.animation = nil }
            Divider()
            HStack(spacing: 12) {
                Button(action: { (NSApp.delegate as? AppDelegate)?.showSettings() }) {
                    Label("Settings…", systemImage: "gearshape")
                }.keyboardShortcut(",", modifiers: .command)
                Spacer()
                Button("Quit ReYogaSMC") { NSApp.terminate(nil) }.keyboardShortcut("q", modifiers: .command)
            }.font(.system(size: 12)).padding(12)
        }.frame(width: ControlDesign.width, height: ControlDesign.height)
    }
    private var header: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(nsImage: ReYogaBrand.menuImage(size: 28)).renderingMode(.template).foregroundColor(.primary)
                .frame(width: 28, height: 28).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text("ReYogaSMC").font(.system(size: 10, weight: .semibold)).foregroundColor(ControlDesign.accent)
                Text(manager.modelName).font(.system(size: 15, weight: .semibold))
                    .fixedSize(horizontal: false, vertical: true)
                Label(manager.isConnected ? "Hardware driver ready" : "Hardware driver unavailable", systemImage: manager.isConnected ? "checkmark.circle.fill" : "exclamationmark.circle")
                    .font(.system(size: 11)).foregroundColor(manager.isConnected ? ControlDesign.connected : .red)
            }
            Spacer(minLength: 0)
            Button(action: { manager.refreshAll() }) { Image(systemName: "arrow.clockwise").frame(width: 28, height: 28) }
                .help("Refresh device state").accessibilityLabel("Refresh device state")
        }
    }
    private var sensors: some View {
        VStack(spacing: 8) {
            HStack(spacing: 8) {
                FanReadout(title: manager.fanLabels[0], rpm: manager.fan1RPM, accentColor: ControlDesign.cpu)
                if manager.hasDualFan { FanReadout(title: manager.fanLabels[1], rpm: manager.fan2RPM, accentColor: ControlDesign.gpu) }
            }
            HStack(spacing: 8) {
                temperature("CPU", value: manager.cpuTemp, source: manager.cpuTemperatureSource)
                temperature("GPU", value: manager.gpuTemp, source: manager.gpuTemperatureSource)
            }
        }
    }
    private func temperature(_ title: String, value: Int, source: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "thermometer").foregroundColor(.secondary)
            Text(title).font(.system(size: 11, weight: .medium))
            Spacer()
            Text(value > 0 ? "\(value)°C" : "—").font(.system(size: 12, weight: .semibold, design: .monospaced))
                .foregroundColor(value >= 80 ? .orange : .primary)
        }.padding(8).frame(maxWidth: .infinity).background(ControlDesign.surface).cornerRadius(8).help(source)
    }
    private var profile: some View {
        ControlSection("Power Profile") {
            ProfileSelector(manager: manager)
        }
    }
    private func row(_ title: String, _ key: String, _ icon: String, _ state: Bool, _ available: Bool, action: @escaping () -> Void) -> some View {
        FeatureRow(title: title, icon: icon, isOn: state, available: available,
                   reason: manager.featureStatus[key]?.reason ?? "No verified interface on this device", action: action)
            .disabled(manager.applyingControl == key)
    }
    private var deviceControls: some View {
        Group {
            sensors
            profile
            ControlSection("Battery & Device") {
                row("Conservation", "ConservationMode", "battery.75", manager.isConservationOn, manager.hasConservation) { manager.toggleConservation() }
                if !manager.batterySummary.isEmpty {
                    Text(manager.batterySummary).font(.system(size: 10)).foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true).padding(.leading, 36).padding(.top, 4)
                }
                Divider().padding(.vertical, 4)
                row("Rapid Charge", "RapidChargeMode", "bolt.fill", manager.isRapidChargeOn, manager.hasRapidCharge) { manager.toggleRapidCharge() }
                Divider().padding(.vertical, 4)
                row("Display Overdrive", "DisplayOverDrive", "display", manager.isOverDriveOn, manager.hasOverDrive) { manager.toggleOverDrive() }
                row("Touchpad Lock", "TouchpadLock", "hand.point.up", manager.isTouchpadLocked, manager.hasTouchpadLock) { manager.toggleTouchpad() }
            }
            ControlSection("Aesthetics & Ports") {
                row("Logo LED", "YLogoStatus", "lightbulb", manager.isYLogoOn, manager.hasYLogo) { manager.toggleYLogo() }
                row("Rear Port Icons", "PortLighting", "powerplug", manager.isPortLightingOn, manager.hasPortLighting) { manager.togglePortLighting() }
                Divider().padding(.vertical, 8)
                Text("Always-On USB Charging").font(.system(size: 12, weight: .medium)).padding(.bottom, 8)
                Picker("Always-On USB Charging", selection: Binding(get: { manager.alwaysOnUSBState }, set: { manager.setAlwaysOnUSBState($0) })) {
                    Text("Off").tag(0); Text("AC power").tag(1); Text("AC + battery").tag(2)
                }.labelsHidden().pickerStyle(SegmentedPickerStyle()).disabled(!manager.hasAlwaysOnUSB || manager.applyingControl == "AlwaysOnUSBState")
            }
            RGBControls(manager: manager)
        }
    }
    private var coolingControls: some View {
        Group {
            sensors
            profile
            if manager.featureStatus["Fan1TargetRPM"]?.available == true || manager.featureStatus["Fan2TargetRPM"]?.available == true {
                ManualFanControls(manager: manager)
            }
            CPUPowerControls(manager: manager)
        }
    }
}

@available(macOS 11.0, *)
private struct DriverUnavailableView: View {
    @ObservedObject var manager: GamingManager
    var previewMissing = false
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("ReYogaSMC").font(.title2).fontWeight(.semibold).foregroundColor(ControlDesign.accent)
            Spacer()
            Image(systemName: "exclamationmark.triangle").font(.system(size: 32)).foregroundColor(.orange)
            Text(previewMissing || manager.driverState == .missing ? "Hardware driver required" : "Hardware driver unavailable")
                .font(.system(size: 20, weight: .semibold))
            Text(previewMissing ? "Install ReYogaSMC.kext and its required dependencies in your bootloader, then restart macOS." : manager.driverMessage)
                .font(.system(size: 13)).foregroundColor(.secondary).fixedSize(horizontal: false, vertical: true)
            Text("Device controls remain unavailable until a compatible driver connection is established.")
                .font(.system(size: 12)).foregroundColor(.secondary)
            if manager.driverState == .checking && !previewMissing { ProgressView() }
            HStack {
                Button("Retry Connection") { (NSApp.delegate as? AppDelegate)?.attemptDriverConnection() }
                    .disabled(manager.driverState == .checking && !previewMissing)
                Button("Open Logs") { manager.openDiagnostics() }
            }
            Spacer()
            Divider()
            HStack {
                Button("Settings…") { (NSApp.delegate as? AppDelegate)?.showSettings() }
                Spacer()
                Button("Quit") { NSApp.terminate(nil) }
            }
        }.padding(20).frame(width: ControlDesign.width, height: ControlDesign.height)
    }
}

@available(macOS 11.0, *)
private struct ManualFanControls: View {
    @ObservedObject var manager: GamingManager
    @AppStorage("FanDraft1") private var fan1Floor: Double = 0
    @AppStorage("FanDraft2") private var fan2Floor: Double = 0
    var body: some View {
        ControlSection("Manual Fan Minimum") {
            HStack {
                Text(manager.manualFanMode ? "Minimum active" : "Automatic cooling").font(.system(size: 12, weight: .medium))
                Spacer()
                Button("Restore Auto") { manager.restoreAutomaticFans() }.disabled(!manager.manualFanMode || manager.isApplying)
            }
            Text("Raise the minimum speed, then Apply. A value below the current automatic speed will not slow the fan down.")
                .font(.system(size: 11)).foregroundColor(.secondary).fixedSize(horizontal: false, vertical: true).padding(.vertical, 8)
            fan(manager.fanLabels[0], value: $fan1Floor, maxRPM: manager.fan1MaxRPM, applied: manager.fan1TargetRPM, index: 0)
            Divider().padding(.vertical, 8)
            fan(manager.fanLabels[1], value: $fan2Floor, maxRPM: manager.fan2MaxRPM, applied: manager.fan2TargetRPM, index: 1)
        }
    }
    private func fan(_ name: String, value: Binding<Double>, maxRPM: Int, applied: Int, index: Int) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(name).font(.system(size: 12, weight: .medium))
                Spacer()
                Text("\(Int(value.wrappedValue)) RPM").font(.system(size: 12, design: .monospaced))
                Button("Apply") { manager.setFanMinimum(index, rpm: Int(value.wrappedValue)) }
                    .disabled(manager.isApplying || manager.featureStatus[index == 0 ? "Fan1TargetRPM" : "Fan2TargetRPM"]?.available != true || maxRPM <= 0 || value.wrappedValue < 0 || value.wrappedValue > Double(maxRPM) || Int(value.wrappedValue) == applied)
            }
            if manager.featureStatus[index == 0 ? "Fan1TargetRPM" : "Fan2TargetRPM"]?.available == true {
                if maxRPM > 0 { Slider(value: value, in: 0...Double(maxRPM), step: 100).disabled(manager.isApplying) }
            } else {
                Text(manager.featureStatus[index == 0 ? "Fan1TargetRPM" : "Fan2TargetRPM"]?.reason ?? "Fan writes have not been validated for this firmware.")
                    .font(.system(size: 11)).foregroundColor(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Text("Applied minimum: \(applied) RPM").font(.system(size: 11)).foregroundColor(.secondary)
        }
    }
}

// Digits only while editing; applying also checks the firmware range and step.
@available(macOS 11.0, *)
private struct PowerLimitRow: View {
    let title: String
    let current: Int
    let range: [String: Int]
    let busy: Bool
    let apply: (Int) -> Void
    @AppStorage private var text: String
    init(title: String, current: Int, range: [String: Int], busy: Bool, apply: @escaping (Int) -> Void) {
        self.title = title; self.current = current; self.range = range; self.busy = busy; self.apply = apply
        self._text = AppStorage(wrappedValue: "", "PowerDraft." + title)
    }
    private var valid: Bool {
        PowerLimitInput.isValid(text, range: range)
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(title).font(.system(size: 12, weight: .medium)); Spacer()
                TextField("Watts", text: Binding(get: { text }, set: { text = PowerLimitInput.digits($0) }))
                    .textFieldStyle(RoundedBorderTextFieldStyle()).frame(width: 64)
                    .accessibilityLabel("\(title) in watts")
                Text("W").font(.caption).foregroundColor(.secondary)
                Button("Apply") { if valid, let watts = Int(text) { apply(watts) } }.disabled(busy || !valid || Int(text) == current)
            }
            Text("Current \(current) W · Range \(range["Min"] ?? 0)–\(range["Max"] ?? 0) W · Step \(range["Step"] ?? 0) W")
                .font(.system(size: 11)).foregroundColor(.secondary)
            if !text.isEmpty && !valid { Text("Enter a value within this range and step.").font(.system(size: 11)).foregroundColor(.red) }
        }.onAppear { if text.isEmpty { text = String(current) } }
    }
}

@available(macOS 11.0, *)
private struct CPUPowerControls: View {
    @ObservedObject var manager: GamingManager
    var body: some View {
        ControlSection("CPU Power Limits") {
            HStack {
                Label("Advanced control", systemImage: "exclamationmark.triangle").font(.system(size: 11)).foregroundColor(.orange)
                Spacer()
                Button("Reset Changes") { manager.resetPowerLimits() }
                    .disabled(manager.applyingControl == "CPUPowerReset" || !manager.cpuPowerModified || manager.featureStatus["CPUPowerReset"]?.available != true)
                    .help(manager.featureStatus["CPUPowerReset"]?.available == true ? "Restore the values saved before your edits in this power profile" : "The loaded driver does not expose reset. Boot the matching updated driver.")
            }.padding(.bottom, 8)
            if let range = manager.powerRanges["CPUBoostPower"], manager.featureStatus["CPUBoostPower"]?.available == true {
                PowerLimitRow(title: "Boost", current: manager.cpuBoostWatts, range: range, busy: manager.applyingControl == "CPUBoostPower") { manager.setPowerLimit("CPUBoostPower", watts: $0) }
                Divider().padding(.vertical, 8)
            }
            if let range = manager.powerRanges["CPUSustainedPower"], manager.featureStatus["CPUSustainedPower"]?.available == true {
                PowerLimitRow(title: "Sustained", current: manager.cpuSustainedWatts, range: range, busy: manager.applyingControl == "CPUSustainedPower") { manager.setPowerLimit("CPUSustainedPower", watts: $0) }
            }
            Text("Higher limits can increase heat and power use; lower limits can reduce performance. Reset Changes restores the pre-edit profile values. These are limits, not measured power.")
                .font(.system(size: 11)).foregroundColor(.secondary).padding(.top, 8)
        }
    }
}

@available(macOS 11.0, *)
private struct RGBControls: View {
    @ObservedObject var manager: GamingManager
    @AppStorage("RGBDraftKeyboard") private var keyboard = "#E82E38"
    @AppStorage("RGBDraftLogo") private var logo = "#E82E38"
    @AppStorage("RGBDraftVents") private var vents = "#E82E38"
    @AppStorage("RGBDraftStrip") private var strip = "#E82E38"
    @AppStorage("RGBDraftEffect") private var effect = "Static"
    var body: some View {
        ControlSection("RGB Lighting") {
            if manager.rgbStatus.available {
                HStack {
                    Text("Mode").font(.system(size: 12, weight: .medium))
                    Spacer()
                    Picker("RGB mode", selection: $effect) {
                        Text("Static").tag("Static"); Text("Breathing").tag("Breathing")
                        Text("Spectrum").tag("Spectrum"); Text("Factory / Fn+Space").tag("Factory")
                    }.labelsHidden().frame(width: 190)
                }.padding(.bottom, 8)
                if effect != "Factory" {
                    colorRow("Keyboard", $keyboard); colorRow("Logo", $logo)
                    colorRow("Vents", $vents); colorRow("Neon strip", $strip)
                }
                HStack {
                    Text(manager.rgbMode).font(.system(size: 11)).foregroundColor(.secondary)
                    Spacer()
                    Button("Apply Mode") { manager.setRGBEffect(effect, colors: ["Keyboard": SavedRGBSettings.color(keyboard), "Logo": SavedRGBSettings.color(logo), "Vents": SavedRGBSettings.color(vents), "Neon strip": SavedRGBSettings.color(strip)]) }
                        .disabled(manager.rgbApplying)
                }.padding(.top, 8)
                Divider().padding(.vertical, 8)
                Button("Import Per-Key Colors…") { manager.importRGBColors() }.disabled(manager.rgbApplying)
                Text(effect == "Factory" ? "Factory effects are selected with Fn+Space. The app releases RGB control." : "Applied colors and effects return when this app opens. Breathing and Spectrum run while it is open.")
                    .font(.system(size: 11)).foregroundColor(.secondary).fixedSize(horizontal: false, vertical: true).padding(.top, 8)
            } else {
                Text(manager.rgbStatus.reason).font(.system(size: 12)).foregroundColor(.secondary).fixedSize(horizontal: false, vertical: true)
                HStack {
                    Button("Grant Permissions…") { manager.openPrivacySettings() }
                    Button("Retry") { manager.retryRGBDiscovery() }.disabled(manager.rgbApplying)
                }.padding(.top, 8)
            }
        }
    }
    private func colorRow(_ name: String, _ color: Binding<String>) -> some View {
        HStack {
            Text(name).font(.system(size: 12)).frame(width: 84, alignment: .leading)
            Spacer()
            PersistentColorWell(hex: color).frame(width: 36, height: 24).accessibilityLabel(name)
            Button("Apply") { manager.setRGBZone(name, color: SavedRGBSettings.color(color.wrappedValue)) }.disabled(manager.rgbApplying)
        }.frame(minHeight: 32)
    }
}

@available(macOS 11.0, *)
struct ReYogaSettingsView: View {
    @ObservedObject var manager: GamingManager
    @ObservedObject var preferences: ReYogaPreferences
    var body: some View {
        VStack(spacing: 12) {
            HStack {
                Button(action: { (NSApp.delegate as? AppDelegate)?.returnToControls() }) {
                    Label("Back to Controls", systemImage: "chevron.left")
                }.keyboardShortcut("[", modifiers: .command)
                Spacer()
                Text("ReYogaSMC").font(.system(size: 12, weight: .semibold)).foregroundColor(ControlDesign.accent)
            }.padding(.horizontal, 16)
            Picker("Settings section", selection: $preferences.selectedTab) {
                Text("General").tag(0); Text("Keyboard").tag(1); Text("Diagnostics").tag(2)
            }.labelsHidden().pickerStyle(SegmentedPickerStyle()).padding(.horizontal, 16)
            Divider()
            if preferences.selectedTab == 0 { general }
            else if preferences.selectedTab == 1 { keyboard }
            else { diagnostics }
        }.padding(16).frame(width: 560, height: 480).background(Color(NSColor.windowBackgroundColor))
    }
    private var general: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("ReYogaSMC Settings").font(.title2).fontWeight(.semibold)
            Toggle("Start with macOS", isOn: Binding(get: { preferences.startAtLogin }, set: { preferences.setStartAtLogin($0) }))
            if !preferences.loginStatus.isEmpty { Text(preferences.loginStatus).font(.caption).foregroundColor(.secondary) }
            Toggle("Automatically check for updates", isOn: Binding(get: { preferences.automaticUpdates }, set: { preferences.setAutomaticUpdates($0) }))
            Text("Checks GitHub releases once a day. App and kext packages are installed manually.")
                .font(.caption).foregroundColor(.secondary)
            HStack {
                Button("Check Now") { preferences.checkForUpdates(manual: true) }.disabled(preferences.checking)
                if let url = preferences.releaseURL { Button("View Release…") { NSWorkspace.shared.open(url) } }
            }
            Text(preferences.updateStatus).font(.caption).foregroundColor(.secondary).fixedSize(horizontal: false, vertical: true)
            Spacer()
            Text("Original ReYogaSMC by Zhen · ReYogaSMC maintained by Hoaug").font(.caption).foregroundColor(.secondary)
        }.padding(16).frame(maxWidth: .infinity, alignment: .leading)
    }
    private var keyboard: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Legion Keyboard Mapping").font(.title2).fontWeight(.semibold)
            Toggle("Map Legion shortcut keys to macOS actions", isOn: Binding(get: { manager.hotkeysEnabled }, set: { manager.setHotkeysEnabled($0) }))
            Text(manager.permissionStatus).font(.caption).foregroundColor(.secondary)
            Text(manager.hotkeyStatus).font(.system(size: 12)).foregroundColor(.secondary).fixedSize(horizontal: false, vertical: true)
            Text("Maps raw Fn shortcuts, Calculator and Print Screen when macOS receives them. Native volume, brightness and firmware Fn+Q keep working with this switch off. Fn keys intercepted by firmware cannot be remapped by an app.")
                .font(.system(size: 12)).fixedSize(horizontal: false, vertical: true)
            Button("Accessibility & Input Monitoring…") { manager.openPrivacySettings() }
            Text("If macOS requires a restart after granting Input Monitoring, quit and reopen ReYogaSMC. Accessibility is checked again when enabling the mapper.")
                .font(.caption).foregroundColor(.secondary)
            Spacer()
        }.padding(16).frame(maxWidth: .infinity, alignment: .leading)
    }
    private var diagnostics: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("Compatibility & Diagnostics").font(.title2).fontWeight(.semibold)
                Text("Sensor status: \(manager.telemetryStatus)").font(.caption).foregroundColor(.secondary)
                Text("GPU source: \(manager.gpuTemperatureSource) · \(manager.gpuTemperatureReason)").font(.caption).foregroundColor(.secondary).fixedSize(horizontal: false, vertical: true)
                Toggle("Detailed logging", isOn: Binding(get: { manager.detailedLogging }, set: { manager.setDetailedLogging($0) }))
                HStack { Button("Export Report…") { manager.exportDiagnostics() }; Button("Open Logs") { manager.openDiagnostics() }; Button("Generate ACPI Bridge…") { manager.generateACPIBridge() } }
                Text("An SSDT is optional for native ACPI/WMI features. This Legion profile uses one for precise fan readings and fan minimums. Other devices need a reviewed profile only when their firmware lacks the required interface. Never reuse another model’s SSDT.")
                    .font(.system(size: 12)).fixedSize(horizontal: false, vertical: true)
                Divider()
                ForEach(manager.featureStatus.keys.sorted(), id: \.self) { key in
                    if let status = manager.featureStatus[key] {
                        HStack(alignment: .top, spacing: 8) {
                            Image(systemName: status.available ? "checkmark.circle" : "exclamationmark.circle").foregroundColor(status.available ? .green : .secondary)
                            VStack(alignment: .leading, spacing: 4) {
                                Text(HardwareFeatureStatus.catalog[key] ?? key).font(.system(size: 12, weight: .medium))
                                Text(status.available ? status.backend : status.reason).font(.system(size: 11)).foregroundColor(.secondary).fixedSize(horizontal: false, vertical: true)
                            }
                            Spacer()
                        }
                    }
                }
            }.padding(16).frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

// Offscreen review uses the production views and read-only registry snapshots.
@available(macOS 11.0, *)
struct ReYogaReviewView: View {
    let mode: String
    @ObservedObject var manager: GamingManager
    var body: some View {
        if mode == "missing-driver" { DriverUnavailableView(manager: manager, previewMissing: true) }
        else if mode == "rgb" { RGBControls(manager: manager).padding(16).frame(width: 420, height: 360, alignment: .top).background(Color(NSColor.windowBackgroundColor)) }
        else if mode == "settings" { ReYogaSettingsView(manager: manager, preferences: ReYogaPreferences.shared) }
        else { GamingPopoverView(manager: manager, page: mode == "cooling" ? 1 : 0) }
    }
}

@available(macOS 11.0, *)
private struct PersistentColorWell: NSViewRepresentable {
    @Binding var hex: String
    final class Well: NSColorWell {
        override func mouseDown(with event: NSEvent) {
            ReYogaColorPanel.shared.present(from: self)
        }
    }
    final class Coordinator: NSObject {
        var binding: Binding<String>
        init(_ binding: Binding<String>) { self.binding = binding }
        @objc func changed(_ sender: NSColorWell) { binding.wrappedValue = SavedRGBSettings.hex(sender.color) }
    }
    func makeCoordinator() -> Coordinator { Coordinator($hex) }
    func makeNSView(context: Context) -> Well {
        let view = Well(frame: .zero)
        view.target = context.coordinator; view.action = #selector(Coordinator.changed(_:))
        view.isBordered = true
        return view
    }
    func updateNSView(_ view: Well, context: Context) {
        context.coordinator.binding = $hex
        if SavedRGBSettings.hex(view.color) != hex { view.color = SavedRGBSettings.color(hex) }
    }
    static func dismantleNSView(_ view: Well, coordinator: Coordinator) {
        ReYogaColorPanel.shared.dismiss(ifEditing: view)
        view.deactivate()
    }
}

@available(macOS 11.0, *)
final class ReYogaColorPanel: NSObject, NSWindowDelegate {
    static let shared = ReYogaColorPanel()
    private weak var activeWell: NSColorWell?
    private weak var owner: NSPopover?
    private var previousBehavior: NSPopover.Behavior = .transient
    private var isDismissing = false

    private override init() {
        super.init()
        NotificationCenter.default.addObserver(self, selector: #selector(applicationResigned),
                                               name: NSApplication.didResignActiveNotification, object: nil)
    }

    func present(from well: NSColorWell) {
        guard let window = well.window, let screen = window.screen else { return }
        let popover = (NSApp.delegate as? AppDelegate)?.gamingPopover
        if owner == nil {
            owner = popover
            previousBehavior = popover?.behavior ?? .transient
        }
        // Keep the controls open while the native panel owns keyboard focus.
        popover?.behavior = .applicationDefined
        activeWell = well
        NSApp.activate(ignoringOtherApps: true)
        let panel = NSColorPanel.shared
        panel.delegate = self
        panel.showsAlpha = false
        panel.isContinuous = true
        panel.level = NSWindow.Level(rawValue: max(NSWindow.Level.floating.rawValue, window.level.rawValue + 1))
        well.activate(true)
        let anchor = window.convertToScreen(well.convert(well.bounds, to: nil))
        panel.setFrameOrigin(ColorPanelPlacement.origin(panelSize: panel.frame.size, anchor: anchor,
                                                       owner: window.frame, visible: screen.visibleFrame))
        panel.makeKeyAndOrderFront(nil)
    }

    func dismiss(ifEditing well: NSColorWell) {
        if activeWell === well { dismiss() }
    }

    func dismiss(closeControls: Bool = false) {
        guard !isDismissing else { return }
        isDismissing = true
        let popover = owner
        activeWell?.deactivate()
        activeWell = nil
        NSColorPanel.shared.orderOut(nil)
        if closeControls { popover?.performClose(nil) }
        else if popover?.isShown == true { popover?.contentViewController?.view.window?.makeKey() }
        popover?.behavior = previousBehavior
        owner = nil
        isDismissing = false
    }

    func windowWillClose(_ notification: Notification) { dismiss() }
    @objc private func applicationResigned() { dismiss(closeControls: true) }
}
