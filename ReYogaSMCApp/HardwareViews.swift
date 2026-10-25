import SwiftUI
import AppKit

private extension Int {
    var formattedCapacity: String { NumberFormatter.localizedString(from: NSNumber(value: self), number: .decimal) }
}

private extension Date {
    var formattedBatteryDate: String { DateFormatter.localizedString(from: self, dateStyle: .medium, timeStyle: .medium) }
}



private struct ScrollViewConfigurator: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async {
            guard let scrollView = view.enclosingScrollView else { return }
            scrollView.hasVerticalScroller = false
            scrollView.hasHorizontalScroller = false
            scrollView.autohidesScrollers = true
            scrollView.scrollerStyle = .overlay
        }
        return view
    }
    func updateNSView(_ nsView: NSView, context: Context) {}
}

private extension View {
    func hideScrollIndicators() -> some View {
        self.background(ScrollViewConfigurator())
    }
}

private struct StateAnimation<Value: Equatable>: ViewModifier {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let value: Value
    func body(content: Content) -> some View {
        if #available(macOS 12.0, *) {
            content.animation(reduceMotion ? nil : .easeInOut(duration: 0.18), value: value)
        } else {
            content
        }
    }
}

private struct GentlePressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View { FeedbackButtonBody(configuration: configuration) }
}

private struct SymbolPressedKey: EnvironmentKey { static let defaultValue = false }
private extension EnvironmentValues {
    var symbolPressed: Bool {
        get { self[SymbolPressedKey.self] }
        set { self[SymbolPressedKey.self] = newValue }
    }
}

private struct AnimatedSymbol: View {
    let name: String
    @State private var hovering = false
    @Environment(\.symbolPressed) private var pressed
    @Environment(\.isEnabled) private var enabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    init(_ name: String) { self.name = name }
    var body: some View {
        Image(systemName: name)
            .scaleEffect(reduceMotion || !enabled ? 1 : pressed ? 0.90 : hovering ? 1.10 : 1)
            .opacity(enabled && hovering ? 0.85 : 1)
            .modifier(StateAnimation(value: hovering))
            .modifier(StateAnimation(value: pressed))
            .onHover { hovering = $0 }.accessibilityHidden(true)
    }
}

private struct SymbolLabel: View {
    let title: String
    let icon: String
    init(_ title: String, systemImage: String) { self.title = title; icon = systemImage }
    var body: some View {
        HStack(spacing: 6) { AnimatedSymbol(icon); Text(localizedMessage(title)) }
            .accessibilityElement(children: .combine)
    }
}

private struct FeedbackButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View { FeedbackButtonBody(configuration: configuration) }
}

private struct FeedbackButtonBody: View {
    let configuration: ButtonStyleConfiguration
    @State private var hovering = false
    @Environment(\.isEnabled) private var enabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var body: some View {
        configuration.label
            .environment(\.symbolPressed, configuration.isPressed)
            .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(enabled && hovering ? 0.045 : 0)))
            .opacity(configuration.isPressed ? 0.82 : 1)
            .scaleEffect(configuration.isPressed && !reduceMotion ? 0.985 : 1)
            .modifier(StateAnimation(value: configuration.isPressed))
            .modifier(StateAnimation(value: hovering))
            .onHover { hovering = $0 }
    }
}

private struct ProfileSelector: View {
    @ObservedObject var manager: HardwareManager
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private let modes: [(Int, LocalizedKey, String)] = [
        (1, .profileQuiet, "leaf.fill"),
        (2, .profileBalanced, "speedometer"),
        (3, .profilePerformance, "flame.fill")
    ]
    var body: some View {
        HStack(spacing: 8) {
            ForEach(modes, id: \.0) { mode in
                Button(action: { manager.setPowerProfile(mode.0) }) {
                    HStack(spacing: 6) {
                        AnimatedSymbol( mode.2).font(.system(size: 14, weight: .semibold))
                        Text(loc(mode.1)).font(.system(size: 11, weight: .semibold)).lineLimit(1)
                    }.padding(.horizontal, 6).frame(maxWidth: .infinity).frame(height: 38)
                        .foregroundColor(manager.powerProfile == mode.0 ? .white : .primary)
                        .background(background(mode.0))
                        .contentShape(RoundedRectangle(cornerRadius: 10))
                }.buttonStyle(GentlePressStyle())
                    .accessibilityLabel(loc(mode.1))
                    .accessibilityValue(localizedMessage(manager.powerProfile == mode.0 ? "Selected" : "Not selected"))
            }
        }
            .disabled(!manager.hasPowerProfiles || manager.applyingControl == "SmartFanMode")
    }
    private func background(_ mode: Int) -> some View {
        RoundedRectangle(cornerRadius: 10)
            .fill(manager.powerProfile == mode ? AppTheme.profile(mode) : Color.primary.opacity(0.035))
            .overlay(RoundedRectangle(cornerRadius: 10)
                .stroke(manager.powerProfile == mode ? AppTheme.profile(mode) : Color.primary.opacity(0.12), lineWidth: 1))
            .modifier(StateAnimation(value: manager.powerProfile == mode))
    }
}

private struct ControlSection<Content: View>: View {
    let title: String
    let content: Content
    let fillsRow: Bool
    init(_ title: String, fillsRow: Bool = false, @ViewBuilder content: () -> Content) {
        self.title = title; self.fillsRow = fillsRow; self.content = content()
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(localizedMessage(title)).font(.system(size: 12, weight: .semibold)).foregroundColor(.secondary).accessibilityAddTraits(.isHeader)
            VStack(alignment: .leading, spacing: 0) { content }
                .frame(maxWidth: .infinity, maxHeight: fillsRow ? .infinity : nil, alignment: .topLeading)
                .padding(10).background(AppTheme.surface)
                .cornerRadius(12)
                .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.primary.opacity(0.045), lineWidth: 1))
        }.frame(maxWidth: .infinity, maxHeight: fillsRow ? .infinity : nil, alignment: .topLeading)
    }
}

private struct BatteryReportWidth: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = nextValue() }
}

private struct BatteryReportColumns<A: View, B: View, C: View, D: View>: View {
    let capacity: A
    let electrical: B
    let charging: C
    let identity: D
    @State private var width: CGFloat = 0
    var body: some View {
        Group {
            if width >= 552 {
                VStack(spacing: 12) {
                    HStack(alignment: .top, spacing: 12) { capacity; electrical }
                        .fixedSize(horizontal: false, vertical: true)
                    HStack(alignment: .top, spacing: 12) { charging; identity }
                        .fixedSize(horizontal: false, vertical: true)
                }
            } else {
                VStack(alignment: .leading, spacing: 12) { capacity; electrical; charging; identity }
            }
        }.frame(maxWidth: .infinity)
            .background(GeometryReader { proxy in Color.clear.preference(key: BatteryReportWidth.self, value: proxy.size.width) })
            .onPreferenceChange(BatteryReportWidth.self) { width = $0 }
    }
}

private struct FanReadout: View {
    let title: String
    let rpm: Int
    let accentColor: Color
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                AnimatedSymbol( "wind").foregroundColor(accentColor)
                Text(localizedMessage(title)).font(.system(size: 12, weight: .medium))
            }
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(localizedMessage(rpm >= 0 ? String(rpm) : "—"))
                    .font(Font(NSFont.monospacedDigitSystemFont(ofSize: 23, weight: .semibold)))
                Text(localizedMessage("RPM")).font(.caption).foregroundColor(.secondary)
            }
        }.padding(10).frame(maxWidth: .infinity, alignment: .leading)
            .transaction { $0.animation = nil }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(localizedMessage(title))
            .accessibilityValue(localizedMessage(rpm >= 0 ? localizedMessage("%@ revolutions per minute", String(rpm)) : "Unavailable"))
            .background(AppTheme.surface)
            .overlay(RoundedRectangle(cornerRadius: 12).fill(accentColor.opacity(0.045)).allowsHitTesting(false))
            .cornerRadius(12)
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(accentColor.opacity(0.16), lineWidth: 1))
    }
}

private struct FeatureRow: View {
    let title: String
    let icon: String
    let isOn: Bool
    let available: Bool
    let reason: String
    let action: () -> Void
    private var color: Color { AppTheme.feature(icon) }
    var body: some View {
        HStack(spacing: 8) {
            Group {
                if icon == "fn" {
                    Text(localizedMessage("fn"))
                        .font(.system(size: 11, weight: .bold, design: .rounded))
                } else {
                    AnimatedSymbol( icon)
                        .font(.system(size: 12, weight: .medium))
                }
            }
            .frame(width: 28, height: 28)
            .foregroundColor(available && isOn ? color : .secondary)
            .background(
                RoundedRectangle(cornerRadius: 7)
                    .fill(available && isOn ? color.opacity(0.12) : Color.primary.opacity(0.04))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 7)
                    .stroke(available && isOn ? color.opacity(0.24) : Color.primary.opacity(0.08), lineWidth: 0.5)
            )
            VStack(alignment: .leading, spacing: 4) {
                Text(localizedMessage(title)).font(.system(size: 12, weight: .medium)).fixedSize(horizontal: false, vertical: true)
                if !available { Text(localizedMessage(reason)).font(.system(size: 11)).foregroundColor(.secondary).fixedSize(horizontal: false, vertical: true) }
            }
            Spacer(minLength: 8)
            Text(localizedMessage(available ? (isOn ? loc(.commonOn) : loc(.commonOff)) : loc(.commonUnavailable)))
                .font(.system(size: 11, weight: isOn && available ? .semibold : .regular))
                .foregroundColor(isOn && available ? color : .secondary)
                .padding(.horizontal, 6).padding(.vertical, 3)
                .background(isOn && available ? color.opacity(0.10) : Color.clear).cornerRadius(5)
            Toggle(title, isOn: Binding(get: { isOn }, set: { _ in action() }))
                .labelsHidden().toggleStyle(SwitchToggleStyle()).accentColor(color).disabled(!available)
                .accessibilityLabel(localizedMessage(title)).accessibilityHint(localizedMessage(available ? "" : reason))
        }.padding(.vertical, 5).frame(minHeight: 40)
    }
}

public struct HardwareControlsView: View {
    @ObservedObject var manager: HardwareManager
    @ObservedObject private var preferences = ReYogaPreferences.shared
    @AppStorage("ControlsPage") private var savedPage = 0
    @State private var reviewPage = 0
    private var page: Int {
        get { CommandLine.arguments.contains("--render-ui") ? reviewPage : savedPage }
        nonmutating set {
            if CommandLine.arguments.contains("--render-ui") { reviewPage = newValue }
            else { savedPage = newValue }
        }
    }
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    public init(manager: HardwareManager, page: Int = 0) { self.manager = manager; self._reviewPage = State(initialValue: page) }
    public var body: some View {
        dashboard
        .frame(minWidth: AppTheme.width, maxWidth: .infinity, minHeight: AppTheme.height, maxHeight: .infinity)

    }
    private let pages = [
        (loc(.sidebarTabOverview), "square.grid.2x2"),
        (loc(.sidebarTabDevice), "laptopcomputer"),
        (loc(.sidebarTabCooling), "wind"),
        (loc(.sidebarTabBattery), "battery.75"),
        (loc(.sidebarTabLighting), "lightbulb"),
        (loc(.sidebarTabDiagnostics), "waveform.path.ecg")
    ]
    private var dashboard: some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    Image(nsImage: ReYogaBrand.menuImage(size: 24)).renderingMode(.template)
                    Text(localizedMessage("ReYogaSMC")).font(.system(size: 15, weight: .semibold))
                }.padding(.bottom, 12).padding(.top, 4)
                ForEach(0..<pages.count, id: \.self) { index in
                    Button(action: { page = index }) {
                        HStack(spacing: 9) {
                            AnimatedSymbol( pages[index].1).frame(width: 18, height: 18)
                            Text(localizedMessage(pages[index].0)).lineLimit(1)
                        }
                            .font(.system(size: 12, weight: page == index ? .semibold : .regular))
                            .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 9).padding(.vertical, 8)
                            .foregroundColor(page == index ? AppTheme.accent : .primary)
                            .background(page == index ? AppTheme.accent.opacity(0.12) : Color.clear)
                            .cornerRadius(8).contentShape(Rectangle())
                    }.buttonStyle(FeedbackButtonStyle()).accessibilityAddTraits(page == index ? .isSelected : [])
                }
                Spacer()
                HStack(spacing: 9) {
                    Circle().fill(manager.isConnected ? AppTheme.connected : .gray)
                        .frame(width: 6, height: 6).frame(width: 18, height: 18)
                    Text(localizedMessage(manager.isConnected ? loc(.sidebarStatusKextLoaded) : loc(.sidebarStatusKextUnloaded)))
                        .font(.system(size: 11, weight: .medium))
                    Spacer(minLength: 0)
                }.foregroundColor(manager.isConnected ? AppTheme.connected : .secondary)
                    .padding(.horizontal, 9).padding(.vertical, 7)
                    .background((manager.isConnected ? AppTheme.connected : .gray).opacity(0.07))
                    .cornerRadius(8).accessibilityElement(children: .combine)

                Divider()
                HStack(spacing: 8) {
                    Button(action: { page = (page == -1 ? 0 : -1) }) {
                        AnimatedSymbol("gearshape").frame(width: 18, height: 18)
                            .padding(8)
                            .foregroundColor(page == -1 ? AppTheme.accent : .primary)
                            .background(page == -1 ? AppTheme.accent.opacity(0.12) : Color.clear)
                            .cornerRadius(8).contentShape(Rectangle())
                    }.keyboardShortcut(",", modifiers: .command).help(loc(.sidebarSettingsTooltip))
                    Spacer()
                    Menu {
                        Button(loc(.sidebarAboutApp)) { (NSApp.delegate as? AppDelegate)?.openAboutPanel(nil) }
                        Divider()
                        Button(loc(.sidebarQuitApp)) { NSApp.terminate(nil) }.keyboardShortcut("q", modifiers: .command)
                    } label: {
                        AnimatedSymbol( "ellipsis").frame(width: 22, height: 28)
                    }.menuStyle(BorderlessButtonMenuStyle()).fixedSize().help(loc(.sidebarAppMenuTooltip))
                }.foregroundColor(.secondary)
            }.buttonStyle(FeedbackButtonStyle()).padding(12).frame(width: 154)
                .background(Color(NSColor.controlBackgroundColor))
            Divider()
            VStack(spacing: 0) {
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(localizedMessage(page == -1 ? loc(.sidebarSettingsTooltip) : pages[min(max(page, 0), pages.count - 1)].0)).font(.system(size: 19, weight: .semibold))
                        Text(localizedMessage(pageSubtitle)).font(.system(size: 11)).foregroundColor(.secondary)
                    }
                    Spacer()
                    if page != -1 {
                        Button(action: { manager.refreshAll() }) { AnimatedSymbol("arrow.clockwise").frame(width: 28, height: 28) }.buttonStyle(FeedbackButtonStyle())
                            .help(loc(.commonRefresh)).accessibilityLabel(loc(.commonRefresh))
                    } else {
                        Button(action: { page = 0 }) {
                            HStack(spacing: 4) {
                                AnimatedSymbol("chevron.left").frame(width: 14, height: 14)
                                Text(loc(.commonBack))
                            }.font(.system(size: 12))
                        }.buttonStyle(FeedbackButtonStyle())
                    }
                }.padding(.horizontal, 16).padding(.vertical, 12)
                Divider()
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        if manager.driverState != .ready {
                            VStack(alignment: .leading, spacing: 8) {
                                SymbolLabel(manager.driverMessage, systemImage: "exclamationmark.triangle")
                                    .font(.system(size: 12)).foregroundColor(.orange)
                                Button(loc(.driverRetryConnection)) { (NSApp.delegate as? AppDelegate)?.attemptDriverConnection() }
                                    .disabled(manager.driverState == .checking)
                            }.padding(10).frame(maxWidth: .infinity, alignment: .leading)
                                .background(Color.orange.opacity(0.06)).cornerRadius(8)
                        }
                        if page == -1 { inAppSettings }
                        else if page == 0 { overview }
                        else if page == 1 { deviceControls }
                        else if page == 2 { coolingControls }
                        else if page == 3 { batteryControls }
                        else if page == 4 { lightingControls }
                        else { diagnosticsPage }
                    }.padding(14).frame(maxWidth: .infinity, alignment: .leading)
                }.frame(maxHeight: .infinity).layoutPriority(1)
            }
        }.frame(minWidth: AppTheme.width, maxWidth: .infinity, minHeight: AppTheme.height, maxHeight: .infinity)
            .background(Color(NSColor.windowBackgroundColor))
    }
    private var pageSubtitle: String {
        switch page {
        case -1: return loc(.subtitleSettings)
        case 1: return loc(.subtitleDevice)
        case 2: return loc(.subtitleCooling)
        case 3: return loc(.subtitleBattery)
        case 4: return loc(.subtitleLighting)
        case 5: return loc(.subtitleDiagnostics)
        default: return loc(.subtitleOverview)
        }
    }
    private var inAppSettings: some View {
        let prefs = preferences
        return VStack(alignment: .leading, spacing: 18) {
            ControlSection(loc(.settingsStartupHeader)) {
                VStack(alignment: .leading, spacing: 10) {
                    Toggle(loc(.settingsStartAtLogin), isOn: Binding(get: { prefs.startAtLogin }, set: { prefs.setStartAtLogin($0) }))
                        .font(.system(size: 12, weight: .medium))
                    VStack(alignment: .leading, spacing: 8) {
                        Text(loc(.settingsStartupDescription))
                        if !prefs.loginStatus.isEmpty { Text(localizedMessage(prefs.loginStatus)) }
                    }.font(.caption).foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true).padding(.leading, 20)
                }.padding(.vertical, 4)
            }
            ControlSection(loc(.settingsUpdatesHeader)) {
                VStack(alignment: .leading, spacing: 10) {
                    Toggle(loc(.settingsAutoUpdates), isOn: Binding(get: { prefs.automaticUpdates }, set: { prefs.setAutomaticUpdates($0) }))
                        .font(.system(size: 12, weight: .medium))
                    VStack(alignment: .leading, spacing: 12) {
                        Text(loc(.settingsAutoUpdatesDesc)).font(.caption).foregroundColor(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        HStack(spacing: 10) {
                            Button(loc(.settingsCheckNow)) { prefs.checkForUpdates(manual: true) }.disabled(prefs.checking)
                            if let url = prefs.releaseURL { Button(loc(.settingsViewRelease)) { NSWorkspace.shared.open(url) } }
                        }
                        if !prefs.updateStatus.isEmpty {
                            Text(localizedMessage(prefs.updateStatus)).font(.caption).foregroundColor(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }.padding(.leading, 20)
                }.padding(.vertical, 4)
            }
            ControlSection(loc(.settingsLoggingHeader)) {
                VStack(alignment: .leading, spacing: 10) {
                    Toggle(loc(.settingsDetailedLogging), isOn: Binding(get: { manager.detailedLogging }, set: { manager.setDetailedLogging($0) }))
                        .font(.system(size: 12, weight: .medium))
                    Text(loc(.settingsDetailedLoggingDesc)).font(.caption).foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true).padding(.leading, 20)
                }.padding(.vertical, 4)
            }
        }
    }
    private let columns = [GridItem(.adaptive(minimum: 270), spacing: 12, alignment: .top)]
    private var overview: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .firstTextBaseline) {
                    Text(verbatim: manager.localizedModelName).font(.system(size: 18, weight: .semibold))
                    Spacer(minLength: 8)
                    Text(localizedMessage(manager.modelSource)).font(.system(size: 10, weight: .medium)).foregroundColor(AppTheme.accent)
                }
                Text(localizedMessage(manager.cpuBrand)).font(.system(size: 11)).foregroundColor(.secondary)
                if !manager.modelWarning.isEmpty {
                    SymbolLabel(manager.modelWarning, systemImage: "exclamationmark.triangle")
                        .font(.system(size: 10)).foregroundColor(.orange).fixedSize(horizontal: false, vertical: true)
                }
            }.padding(10).frame(maxWidth: .infinity, alignment: .leading)
                .background(AppTheme.accent.opacity(0.06)).cornerRadius(10)
            ControlSection(loc(.overviewSectionTelemetry)) { sensors }
            if let live = manager.liveBattery {
                ControlSection(loc(.overviewSectionBattery)) {
                    HStack(spacing: 12) {
                        batteryHero(live)
                        Button(action: { page = 3 }) { AnimatedSymbol( "chevron.right") }
                            .buttonStyle(FeedbackButtonStyle()).help(loc(.overviewBatteryReportHelp)).accessibilityLabel(loc(.overviewBatteryOpenReport))
                    }
                    Divider().padding(.vertical, 6)
                    HStack {
                        Text(localizedMessage("\(capacityText(live.currentCapacity)) / \(capacityText(live.maximumCapacity))"))
                        Spacer()
                        Text(localizedMessage(live.healthPercent.map { String(format: loc(.retainedFormat), $0) } ?? loc(.commonUnavailable)))
                    }.font(.system(size: 10)).foregroundColor(.secondary)
                }
            }
            if manager.hasPowerProfiles { profile }
        }
    }
    private var diagnosticsPage: some View {
        VStack(alignment: .leading, spacing: 12) {
            ControlSection(loc(.diagnosticsIdentityHeader)) {
                batteryValue(loc(.diagnosticsFirmwareDevice), manager.localizedModelName)
                batteryValue(loc(.diagnosticsIdentitySource), localizedMessage(manager.modelSource))
                batteryValue(loc(.diagnosticsSmbiosModel), manager.smbiosModel)
                batteryValue(loc(.diagnosticsAppBuild), manager.appBuild)
                batteryValue(loc(.diagnosticsGitRevision), manager.appRevision)
                batteryValue(loc(.diagnosticsDriverBuild), manager.driverVersion == "Unavailable" ? loc(.commonUnavailable) : manager.driverVersion)
                batteryValue(loc(.diagnosticsProfileState), localizedMessage(manager.profileMatchState))
                if !manager.firmwareProfileID.isEmpty {
                    batteryValue(localizedMessage("Hardware profile"), manager.firmwareProfileID)
                }
                if !manager.modelWarning.isEmpty {
                    SymbolLabel(manager.modelWarning, systemImage: "exclamationmark.triangle")
                        .font(.caption).foregroundColor(.orange).padding(.top, 10)
                }
            }
            ControlSection(loc(.diagnosticsSectionTelemetrySources)) {
                batteryValue(loc(.diagnosticsStatus), localizedMessage(manager.telemetryStatus))
                batteryValue("CPU", localizedMessage(manager.cpuTemperatureSource))
                batteryValue("GPU", localizedMessage(manager.gpuTemperatureSource))
                Text(localizedMessage(manager.gpuTemperatureReason)).font(.caption).foregroundColor(.secondary)
            }
            ControlSection(loc(.diagnosticsSectionCapabilities)) {
                DisclosureGroup(loc(.diagnosticsSectionCapabilities)) {
                    ForEach(manager.featureStatus.keys.sorted(), id: \.self) { key in
                        if let feature = manager.featureStatus[key] {
                            HStack(alignment: .top, spacing: 10) {
                                AnimatedSymbol( feature.available ? "checkmark.circle.fill" : "minus.circle")
                                    .foregroundColor(feature.available ? AppTheme.connected : .secondary)
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(localizedMessage(HardwareFeatureStatus.catalog[key] ?? key)).font(.system(size: 12, weight: .medium))
                                    Text(localizedMessage(feature.available ? feature.backend : feature.reason)).font(.caption).foregroundColor(.secondary)
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                                Spacer()
                            }.padding(.vertical, 8)
                        }
                    }
                }.font(.system(size: 12))
            }
            ControlSection(loc(.diagnosticsSectionSupportTools)) {
                Text(loc(.diagnosticsToolsDesc))
                    .font(.system(size: 12)).foregroundColor(.secondary).padding(.bottom, 12)
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Button(loc(.diagnosticsExportDiagnostics)) { manager.exportDiagnostics() }
                        Button(loc(.diagnosticsOpenLogs)) { manager.openDiagnostics() }
                        if manager.canGenerateACPIBridge {
                            Button(loc(.diagnosticsGenerateBridge)) { manager.generateACPIBridge() }
                        }
                    }
                    if manager.canGenerateACPIBridge {
                        Text(loc(.diagnosticsBridgeDesc))
                            .font(.system(size: 11)).foregroundColor(.secondary)
                    }
                }
            }
        }
    }
    private var sensors: some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(minimum: 65), spacing: 8), count: manager.hasDualFan ? 4 : 3), spacing: 8) {
            thermalTile("CPU", value: manager.cpuTemp, source: manager.cpuTemperatureSource)
            thermalTile("GPU", value: manager.gpuTemp, source: manager.gpuTemperatureSource)
            FanReadout(title: manager.fanLabels[0], rpm: manager.fan1RPM, accentColor: AppTheme.cpu)
            if manager.hasDualFan { FanReadout(title: manager.fanLabels[1], rpm: manager.fan2RPM, accentColor: AppTheme.gpu) }
        }
    }
    private func thermalTile(_ title: String, value: Double, source: String) -> some View {
        let isGPU = title == "GPU"
        let unavailableText = isGPU ? "N/A" : "—"
        return VStack(alignment: .leading, spacing: 8) {
            SymbolLabel(title, systemImage: "thermometer").font(.system(size: 11)).foregroundColor(.secondary)
            HStack(alignment: .firstTextBaseline, spacing: 3) {
                Text(value > 0 ? String(format: "%.1f", value) : unavailableText).font(.system(size: value > 0 ? 23 : 18, weight: .semibold, design: .rounded))
                if value > 0 {
                    Text(localizedMessage("°C")).font(.system(size: 10)).foregroundColor(.secondary)
                } else if isGPU {
                    Text("iGPU").font(.system(size: 10)).foregroundColor(.secondary)
                }
            }.foregroundColor(value >= 80 ? .orange : .primary)
        }.frame(maxWidth: .infinity, alignment: .leading).padding(10)
            .background(Color.primary.opacity(0.025)).cornerRadius(8).help(localizedMessage(source))
            .accessibilityElement(children: .ignore).accessibilityLabel(localizedMessage(title))
            .accessibilityValue(localizedMessage(value > 0 ? localizedMessage("%@ degrees Celsius", String(format: "%.1f", value)) : "Unavailable"))
    }
    private var profile: some View {
        ControlSection(loc(.overviewSectionProfiles)) {
            ProfileSelector(manager: manager)
        }
    }
    private func row(_ titleKey: LocalizedKey, _ key: String, _ icon: String, _ state: Bool, _ available: Bool, action: @escaping () -> Void) -> some View {
        FeatureRow(title: loc(titleKey), icon: icon, isOn: state, available: available,
                   reason: manager.featureStatus[key]?.reason ?? "No verified interface on this device", action: action)
            .disabled(manager.applyingControl == key)
    }
    @ViewBuilder
    private var keyboardSection: some View {
        ControlSection(loc(.deviceSectionKeyboard)) {
            if manager.featureStatus["FnlockMode"]?.available == true {
                row(.overviewShortcutFnLock, "FnlockMode", "fn", manager.isFnLocked, true) { manager.toggleFnLock() }
                Divider().padding(.vertical, 4)
            }
            VStack(alignment: .leading, spacing: 8) {
                Toggle(loc(.overviewShortcutHotkeys), isOn: Binding(get: { manager.hotkeysEnabled }, set: { manager.setHotkeysEnabled($0) }))
                    .font(.system(size: 12, weight: .medium))

                Text(loc(.overviewShortcutHotkeysDesc))
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                VStack(alignment: .leading, spacing: 5) {
                    HStack(spacing: 8) {
                        Image(systemName: manager.hasAccessibilityPermission ? "checkmark.circle.fill" : "xmark.circle.fill")
                            .foregroundColor(manager.hasAccessibilityPermission ? AppTheme.connected : .secondary)
                            .font(.system(size: 12))
                        Text(loc(.permissionAccessibility))
                            .font(.system(size: 11))
                            .foregroundColor(.secondary)
                        Spacer()
                        if !manager.hasAccessibilityPermission {
                            Button(loc(.permissionOpenSettings)) { manager.openAccessibilitySettings() }
                                .font(.system(size: 10))
                        } else {
                            Text(loc(.permissionGranted)).font(.system(size: 10)).foregroundColor(AppTheme.connected)
                        }
                    }
                    HStack(spacing: 8) {
                        Image(systemName: manager.hasInputMonitoringPermission ? "checkmark.circle.fill" : "xmark.circle.fill")
                            .foregroundColor(manager.hasInputMonitoringPermission ? AppTheme.connected : .secondary)
                            .font(.system(size: 12))
                        Text(loc(.permissionInputMonitoring))
                            .font(.system(size: 11))
                            .foregroundColor(.secondary)
                        Spacer()
                        if !manager.hasInputMonitoringPermission {
                            Button(loc(.permissionOpenSettings)) { manager.openInputMonitoringSettings() }
                                .font(.system(size: 10))
                        } else {
                            Text(loc(.permissionGranted)).font(.system(size: 10)).foregroundColor(AppTheme.connected)
                        }
                    }
                }
                .padding(8)
                .background(Color.primary.opacity(0.03))
                .cornerRadius(6)
            }.padding(.vertical, 4)
        }
    }
    @ViewBuilder
    private var usbSection: some View {
        if manager.hasAlwaysOnUSB {
            ControlSection(loc(.deviceSectionUsbPower)) {
                HStack {
                    AnimatedSymbol("powerplug").font(.system(size: 13)).foregroundColor(AppTheme.gpu)
                    Text(loc(.deviceAlwaysOnUsb)).font(.system(size: 12, weight: .medium))
                    Spacer()
                    Picker("", selection: Binding(get: { manager.alwaysOnUSBState }, set: { manager.setAlwaysOnUSBState($0) })) {
                        Text(loc(.commonOff)).tag(0)
                        Text(loc(.deviceUsbAcOnly)).tag(1)
                        Text(loc(.deviceUsbAcBattery)).tag(2)
                    }
                    .labelsHidden()
                    .frame(width: 130)
                    .disabled(manager.applyingControl == "AlwaysOnUSBState")
                }
                .padding(.vertical, 3)
            }
        }
    }
    private var lightingControls: some View {
        VStack(alignment: .leading, spacing: 12) {
            if manager.featureStatus["BacklightLevel"]?.available == true && manager.keyboardBacklight >= 0 {
                ControlSection(loc(.lightingSectionKeyboard)) {
                    Picker(loc(.lightingBrightness), selection: Binding(get: { manager.keyboardBacklight }, set: { manager.setKeyboardBacklight($0) })) {
                        Text(loc(.commonOff)).tag(0)
                        Text(loc(.backlightLow)).tag(1)
                        Text(loc(.backlightHigh)).tag(2)
                    }.pickerStyle(SegmentedPickerStyle()).disabled(manager.isApplying)
                }
            }
            if manager.hasYLogo || manager.hasPortLighting {
                ControlSection(loc(.lightingSectionDevice)) {
                    if manager.hasYLogo {
                        row(.lightingLogoLed, "YLogoStatus", "lightbulb", manager.isYLogoOn, true) { manager.toggleYLogo() }
                    }
                    if manager.hasPortLighting {
                        row(.lightingPortIcons, "PortLighting", "powerplug", manager.isPortLightingOn, true) { manager.togglePortLighting() }
                    }
                }
            }
            RGBControls(manager: manager)
        }
    }
    @ViewBuilder
    private var deviceControls: some View {
        VStack(alignment: .leading, spacing: 12) {
        deviceChargeControls
        if manager.providerClass == "ThinkVPC" { ThinkPadBatteryControls(manager: manager) }
        keyboardSection
        usbSection
        }
    }
    @ViewBuilder
    private var deviceChargeControls: some View {
            if manager.hasConservation || manager.hasRapidCharge || manager.hasOverDrive || manager.hasTouchpadLock {
                ControlSection(loc(.deviceSectionBatteryDevice)) {
                    if manager.hasConservation {
                        row(.deviceConservation, "ConservationMode", "battery.75", manager.isConservationOn, true) { manager.toggleConservation() }
                    }
                    if manager.hasRapidCharge {
                        if manager.hasConservation { Divider().padding(.vertical, 4) }
                        row(.deviceRapidCharge, "RapidChargeMode", "bolt.fill", manager.isRapidChargeOn, true) { manager.toggleRapidCharge() }
                    }
                    if manager.hasOverDrive {
                        if manager.hasConservation || manager.hasRapidCharge { Divider().padding(.vertical, 4) }
                        row(.deviceDisplayOverdrive, "DisplayOverDrive", "display", manager.isOverDriveOn, true) { manager.toggleOverDrive() }
                    }
                    if manager.hasTouchpadLock {
                        if manager.hasConservation || manager.hasRapidCharge || manager.hasOverDrive { Divider().padding(.vertical, 4) }
                        row(.deviceTouchpadLock, "TouchpadLock", "hand.point.up", manager.isTouchpadLocked, true) { manager.toggleTouchpad() }
                    }
                }
            }

    }
    private func powerSource(_ live: LiveBatterySnapshot) -> String {
        live.externalPower == true ? loc(.batteryAcAdapter) : live.externalPower == false ? loc(.sidebarTabBattery) : loc(.commonUnavailable)
    }
    private func capacityText(_ value: Int?) -> String {
        value.map { localizedMessage("%@ mAh", String(describing: $0.formattedCapacity)) } ?? loc(.commonUnavailable)
    }
    private func minutesText(_ value: Int?) -> String {
        value.map { localizedMessage("%@ h %@ min", String(describing: $0 / 60), String(describing: $0 % 60)) } ?? loc(.commonUnavailable)
    }
    private func batteryStateIcon(_ live: LiveBatterySnapshot) -> String {
        if live.installed == false { return "battery.0" }
        if live.charging == true { return "bolt.fill" }
        if live.fullyCharged == true { return "checkmark.circle.fill" }
        if let current = live.milliamps, current < 0 { return "arrow.down.circle" }
        if live.externalPower == true && live.charging == false { return "pause.circle" }
        return "questionmark.circle"
    }
    private func batteryHero(_ live: LiveBatterySnapshot) -> some View {
        let barColor = AppTheme.batteryProgressColor(live.percent)
        return HStack(spacing: 20) {
            ZStack {
                Circle().stroke(barColor.opacity(0.12), lineWidth: 5)
                Circle().trim(from: 0, to: CGFloat(live.percent ?? 0) / 100)
                    .stroke(barColor, style: StrokeStyle(lineWidth: 5, lineCap: .round)).rotationEffect(.degrees(-90))
                Text(localizedMessage(live.percent.map { "\($0)%" } ?? "—")).font(.system(size: 18, weight: .semibold, design: .rounded))
            }.frame(width: 56, height: 56).accessibilityElement(children: .ignore)
                .accessibilityLabel(loc(.batteryCharge)).accessibilityValue(localizedMessage(live.percent.map { String(format: loc(.percentFormat), $0) } ?? loc(.commonUnavailable)))
            VStack(alignment: .leading, spacing: 6) {
                SymbolLabel(live.state, systemImage: batteryStateIcon(live))
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(live.charging == true ? AppTheme.connected : .primary)
                Text(localizedMessage(powerSource(live))).font(.system(size: 12)).foregroundColor(.secondary)
                Text(localizedMessage(live.deviceName ?? "System battery")).font(.caption).foregroundColor(.secondary)
            }
            Spacer(minLength: 0)
        }.padding(.vertical, 4)
    }
    @ViewBuilder
    private var batteryControls: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let live = manager.liveBattery {
                ControlSection(loc(.batteryOverviewHeader)) {
                    batteryHero(live)
                }
                BatteryReportColumns(
                    capacity: capacityReport(live), electrical: electricalReport(live),
                    charging: chargingReport(live), identity: identityReport(live))
            } else {
                ControlSection(loc(.batteryMacOS)) {
                    SymbolLabel(loc(.batteryDataUnavailable), systemImage: "battery.0")
                    Text(loc(.batteryDataUnavailableDesc))
                        .font(.caption).foregroundColor(.secondary).padding(.top, 8)
                }
            }

            if manager.batteryDetails.count == 1, let battery = manager.batteryDetails.first {
                ControlSection(String(format: loc(.batteryPackFormat), battery.id + 1)) {
                    batteryValue(loc(.diagnosticsStatus), battery.critical ? loc(.batteryStatusCritical) : loc(.batteryStatusPresent))
                    batteryValue(loc(.batteryCycleCount), battery.cycleCount.map(String.init) ?? loc(.commonUnavailable))
                    batteryValue(loc(.batteryTemperature), battery.temperature ?? loc(.commonUnavailable))
                    batteryValue(loc(.batteryManufactureDate), battery.manufactureDate ?? loc(.commonUnavailable))
                    batteryValue(loc(.batteryDeviceName), battery.identifier ?? loc(.commonUnavailable))
                    Text(localizedMessage(String(format: loc(.sourceFormat), battery.source))).font(.caption).foregroundColor(.secondary).padding(.top, 8)
                }
            } else if manager.batteryDetails.count > 1 {
                LazyVGrid(columns: columns, alignment: .leading, spacing: 12) {
                    ForEach(manager.batteryDetails) { battery in
                        ControlSection(String(format: loc(.batteryPackFormat), battery.id + 1)) {
                            batteryValue(loc(.diagnosticsStatus), battery.critical ? loc(.batteryStatusCritical) : loc(.batteryStatusPresent))
                            batteryValue(loc(.batteryCycleCount), battery.cycleCount.map(String.init) ?? loc(.commonUnavailable))
                            batteryValue(loc(.batteryTemperature), battery.temperature ?? loc(.commonUnavailable))
                            batteryValue(loc(.batteryManufactureDate), battery.manufactureDate ?? loc(.commonUnavailable))
                            batteryValue(loc(.batteryDeviceName), battery.identifier ?? loc(.commonUnavailable))
                            Text(localizedMessage(String(format: loc(.sourceFormat), battery.source))).font(.caption).foregroundColor(.secondary).padding(.top, 8)
                        }
                    }
                }
            }

            if let live = manager.liveBattery {
                ControlSection(loc(.batteryDetailsHeader)) {
                    DisclosureGroup(loc(.batteryAboutReadingsTitle)) {
                        VStack(alignment: .leading, spacing: 8) {
                            Text(loc(.batteryAboutReadingsText))
                                .font(.system(size: 11)).foregroundColor(.secondary).lineSpacing(3)
                        }.padding(.vertical, 8)
                    }.font(.system(size: 12)).padding(.bottom, 8)
                    DisclosureGroup("\(loc(.batteryRawFieldsTitle)) (\(live.rawFields.count))") {
                        ForEach(live.rawFields.keys.sorted(), id: \.self) { key in
                            batteryValue(key, live.rawFields[key] ?? loc(.commonUnavailable))
                        }
                    }.font(.system(size: 12))
                }
            }

            if manager.batteryDetails.isEmpty && manager.liveBattery == nil {
                Text(loc(.batteryNoAcpiPresence)).font(.caption).foregroundColor(.secondary)
            }
        }
    }
    private func capacityReport(_ live: LiveBatterySnapshot) -> some View {
        ControlSection(loc(.batteryCapacityWearHeader), fillsRow: true) {
            batteryValue(loc(.batteryCurrentCapacity), capacityText(live.currentCapacity))
            batteryValue(loc(.batteryFullCapacity), capacityText(live.maximumCapacity))
            batteryValue(loc(.batteryDesignCapacity), capacityText(live.designCapacity))
            batteryValue(loc(.batteryCapacityRetained), live.healthPercent.map { String(format: loc(.retainedFormat), $0) } ?? loc(.commonUnavailable))
            batteryValue(loc(.batteryCycleCount), live.cycleCount.map(String.init) ?? loc(.commonUnavailable))
            batteryValue(loc(.batteryCondition), live.health ?? loc(.batteryNotReported))
        }
    }
    private func electricalReport(_ live: LiveBatterySnapshot) -> some View {
        ControlSection(loc(.batteryElectricalHeader), fillsRow: true) {
            batteryValue(loc(.batteryVoltage), live.voltage.map { String(format: "%.3f V", $0) } ?? loc(.commonUnavailable))
            batteryValue(loc(.batteryCurrent), live.milliamps.map { localizedMessage("%@ mA", String(describing: $0)) } ?? loc(.commonUnavailable))
            batteryValue(loc(.batteryPower), live.watts.map { String(format: "%.2f W", $0) } ?? loc(.commonUnavailable))
            batteryValue(loc(.batteryTemperature), live.temperatureCelsius.map { String(format: "%.1f °C", $0) } ?? loc(.commonUnavailable))
            batteryValue(loc(.batteryPowerSource), powerSource(live))
            batteryValue(loc(.batteryChargingState), live.charging.map { $0 ? loc(.commonYes) : loc(.commonNo) } ?? loc(.commonUnavailable))
        }
    }
    private func chargingReport(_ live: LiveBatterySnapshot) -> some View {
        ControlSection(loc(.batteryChargingAdapterHeader), fillsRow: true) {
            batteryValue(loc(.batteryFullyCharged), live.fullyCharged.map { $0 ? loc(.commonYes) : loc(.commonNo) } ?? loc(.commonUnavailable))
            batteryValue(loc(.batteryAdapterRating), live.adapterWatts.map { String(format: "%.0f W", $0) } ?? loc(.commonUnavailable))
            batteryValue(loc(.batteryTimeToEmpty), live.externalPower == false ? minutesText(live.timeToEmpty) : loc(.batteryNotDischarging))
            batteryValue(loc(.batteryTimeToFull), live.charging == true ? minutesText(live.timeToFull) : loc(.batteryNotCharging))
        }
    }
    private func identityReport(_ live: LiveBatterySnapshot) -> some View {
        ControlSection(loc(.batteryPackIdentityHeader), fillsRow: true) {
            batteryValue(loc(.batteryInstalled), live.installed.map { $0 ? loc(.commonYes) : loc(.commonNo) } ?? loc(.commonUnavailable))
            batteryValue(loc(.batteryManufacturer), live.manufacturer ?? loc(.commonUnavailable))
            batteryValue(loc(.batteryDeviceName), live.deviceName ?? loc(.commonUnavailable))
            batteryValue(loc(.batterySerialNumber), live.serial ?? loc(.commonUnavailable))
        }
    }
    private func batteryValue(_ title: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(localizedMessage(title)).font(.system(size: 12, weight: .medium))
            Spacer()
            Text(verbatim: value).font(.system(size: 12, design: .monospaced)).foregroundColor(.secondary)
                .multilineTextAlignment(.trailing).fixedSize(horizontal: false, vertical: true)
        }.padding(.vertical, 6)
    }
    private var hasFanControls: Bool {
        manager.featureStatus["Fan1TargetRPM"]?.available == true || manager.featureStatus["Fan2TargetRPM"]?.available == true
    }
    private var hasCPUPowerControls: Bool {
        manager.featureStatus["CPUBoostPower"]?.available == true || manager.featureStatus["CPUSustainedPower"]?.available == true
    }
    private func unavailableCoolingCard(_ title: String, icon: String, detail: String, tint: Color) -> some View {
        HStack(alignment: .center, spacing: 12) {
            AnimatedSymbol( icon).font(.system(size: 18, weight: .medium))
                .foregroundColor(tint).frame(width: 40, height: 40)
                .background(tint.opacity(0.10)).cornerRadius(10).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 8) {
                    Text(localizedMessage(title)).font(.system(size: 13, weight: .semibold))
                    Spacer(minLength: 4)
                    SymbolLabel(loc(.commonUnavailable), systemImage: "lock.fill")
                        .font(.system(size: 9, weight: .medium)).foregroundColor(.secondary)
                        .padding(.horizontal, 7).padding(.vertical, 4)
                        .background(Color.primary.opacity(0.045)).cornerRadius(5)
                }
                Text(localizedMessage(detail)).font(.system(size: 11)).foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }.padding(12).frame(maxWidth: .infinity, alignment: .leading)
            .background(AppTheme.surface)
            .cornerRadius(12).overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.primary.opacity(0.045), lineWidth: 1))
    }
    private var coolingControls: some View {
        VStack(alignment: .leading, spacing: 12) {
            if hasFanControls { ManualFanControls(manager: manager) }
            else if manager.providerClass != "ThinkVPC" {
                unavailableCoolingCard(loc(.coolingSectionManualFan), icon: "wind",
                    detail: loc(.coolingManualFanCardDesc), tint: AppTheme.cpu)
            }
            if hasCPUPowerControls { CPUPowerControls(manager: manager) }
            else {
                unavailableCoolingCard(loc(.coolingSectionCpuPower), icon: "bolt.fill",
                    detail: loc(.coolingCpuPowerCardDesc), tint: AppTheme.gpu)
            }
            if manager.providerClass == "ThinkVPC" { ThinkPadFanPanel() }
            if !hasFanControls || !hasCPUPowerControls {
                DisclosureGroup {
                    VStack(alignment: .leading, spacing: 12) {
                        if !hasFanControls && manager.providerClass != "ThinkVPC" {
                            coolingReason(loc(.coolingSectionManualFan), reason: manager.featureStatus["Fan1TargetRPM"]?.reason ?? "No verified manual fan interface")
                        }
                        if !hasCPUPowerControls {
                            coolingReason(loc(.coolingSectionCpuPower), reason: manager.featureStatus["CPUBoostPower"]?.reason ?? "No verified CPU power interface")
                        }
                        Text(loc(.coolingLiveReadingsNotice))
                            .font(.system(size: 11)).foregroundColor(.secondary)
                    }.padding(.top, 10)
                } label: {
                    SymbolLabel(loc(.coolingWhyUnavailable), systemImage: "info.circle")
                        .font(.system(size: 11, weight: .medium)).foregroundColor(.secondary)
                }.padding(12).background(AppTheme.surface).cornerRadius(10)
            }
        }
    }
    private func coolingReason(_ title: String, reason: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(localizedMessage(title)).font(.system(size: 11, weight: .semibold))
            Text(localizedMessage(reason)).font(.system(size: 11)).foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

}

private struct ThinkPadFanPanel: View {
    @State private var readings: [String] = ["Unavailable", "Unavailable"]
    @State private var enabled = [false, false]
    @State private var levels: [Double] = [4, 4]
    private let timer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()
    private func helper(_ index: Int) -> ThinkFanHelper? {
        let delegate = NSApp.delegate as? AppDelegate
        return index == 0 ? delegate?.fanHelper : delegate?.fanHelper2
    }
    var body: some View {
        ControlSection(loc(.thinkPadFans)) {
            ForEach(0..<(helper(1) == nil ? 1 : 2), id: \.self) { index in
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text(localizedMessage(index == 0 ? loc(.mainFan) : loc(.secondaryFan))).font(.system(size: 12, weight: .medium))
                        Spacer()
                        Text(localizedMessage(readings[index])).font(.system(size: 11, design: .monospaced)).foregroundColor(.secondary)
                    }
                    HStack {
                        Button(loc(.fanAuto)) { command(index) { $0.setAutomatic() } }
                        Button(loc(.fanFullSpeed)) { command(index) { $0.setFullSpeed() } }
                        Spacer()
                        Text(localizedMessage(String(format: loc(.fanLevelFormat), Int(levels[index])))).font(.caption)
                        Button(loc(.coolingApply)) {
                            command(index) { fan in
                                fan.setManualLevel(Int(levels[index]))
                            }
                        }
                    }.disabled(!enabled[index])
                    Slider(value: $levels[index], in: Double(helper(index)?.minimumLevel ?? 1)...7, step: 1)
                        .disabled(!enabled[index]).accessibilityLabel(localizedMessage(index == 0 ? "Main fan level" : "Secondary fan level"))
                    if !enabled[index] {
                        Text(loc(.fanInterfaceRequired))
                            .font(.caption).foregroundColor(.secondary)
                    }
                }.padding(.vertical, 6)
            }
        }.onAppear { refresh(readLevel: true) }
            .onReceive(timer) { _ in refresh(readLevel: false) }
    }
    private func command(_ index: Int, action: (ThinkFanHelper) -> Void) {
        guard !CommandLine.arguments.contains("--render-ui"), let fan = helper(index), fan.enable else { return }
        action(fan)
        refresh(readLevel: true)
    }
    private func refresh(readLevel: Bool) {
        guard !CommandLine.arguments.contains("--render-ui") else { return }
        for index in 0...1 {
            guard let fan = helper(index) else { enabled[index] = false; continue }
            fan.update(readLevel)
            enabled[index] = fan.enable
            readings[index] = fan.enable ? fan.rpm.map { localizedMessage("%@ RPM", String(describing: $0)) } ?? loc(.commonUnavailable) : loc(.commonUnavailable)
            if readLevel { levels[index] = Double(fan.level) }
        }
    }
}

private struct ThinkPadBatteryControls: View {
    @ObservedObject var manager: HardwareManager
    @State private var start = ""
    @State private var stop = ""
    var body: some View {
        ControlSection(loc(.chargeThresholds)) {
            if manager.batteryIndividualAddressing && manager.featureStatus["BatteryIndex"]?.available == true {
                Picker(loc(.sidebarTabBattery), selection: Binding(get: { manager.batteryIndex }, set: { manager.selectBattery($0) })) {
                    Text(loc(.batteryPrimary)).tag(1); Text(loc(.batterySecondary)).tag(2)
                }.disabled(manager.isApplying)
            }
            threshold(loc(.chargeStart), key: "ChargeStartThreshold", text: $start, actual: manager.chargeStartThreshold)
            threshold(loc(.chargeStop), key: "ChargeStopThreshold", text: $stop, actual: manager.chargeStopThreshold)
        }
    }
    private func threshold(_ title: String, key: String, text: Binding<String>, actual: Int) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(localizedMessage(title))
                Spacer()
                Text(localizedMessage(actual >= 0 ? "\(actual)%" : "—")).foregroundColor(.secondary)
                TextField("%", text: text).frame(width: 48)
                Button(loc(.coolingApply)) { if let value = Int(text.wrappedValue) { manager.setChargeThreshold(key, percent: value) } }
                    .disabled(manager.isApplying || manager.featureStatus[key]?.available != true || !valid(key, text.wrappedValue))
            }
            if let status = manager.featureStatus[key], !status.available {
                Text(localizedMessage(status.reason)).font(.system(size: 10)).foregroundColor(.secondary)
            }
        }
    }
    private func valid(_ key: String, _ text: String) -> Bool {
        guard !text.isEmpty, text.utf8.allSatisfy({ (48...57).contains($0) }), let value = Int(text) else { return false }
        return key == "ChargeStartThreshold" ? (0...99).contains(value) && value <= manager.chargeStopThreshold :
            (1...100).contains(value) && manager.chargeStartThreshold >= 0 && value >= manager.chargeStartThreshold
    }
}

private struct ManualFanControls: View {
    @ObservedObject var manager: HardwareManager
    @ObservedObject private var preferences = ReYogaPreferences.shared
    @AppStorage("FanDraft1") private var fan1Floor: Double = 0
    @AppStorage("FanDraft2") private var fan2Floor: Double = 0
    var body: some View {
        ControlSection(loc(.coolingSectionManualFan)) {
            HStack {
                Text(localizedMessage(manager.manualFanMode ? loc(.coolingMinActive) : loc(.coolingAutoCooling))).font(.system(size: 12, weight: .medium))
                Spacer()
                Button(loc(.coolingRestoreAuto)) { manager.restoreAutomaticFans() }.disabled(!manager.manualFanMode || manager.isApplying)
            }
            Text(loc(.coolingManualFanDesc))
                .font(.system(size: 11)).foregroundColor(.secondary).fixedSize(horizontal: false, vertical: true).padding(.vertical, 8)
            fan(manager.fanLabels[0], value: $fan1Floor, maxRPM: manager.fan1MaxRPM, applied: manager.fan1TargetRPM, index: 0)
            if manager.hasDualFan {
                Divider().padding(.vertical, 8)
                fan(manager.fanLabels[1], value: $fan2Floor, maxRPM: manager.fan2MaxRPM, applied: manager.fan2TargetRPM, index: 1)
            }
        }
    }
    private func fan(_ name: String, value: Binding<Double>, maxRPM: Int, applied: Int, index: Int) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(localizedMessage(name)).font(.system(size: 12, weight: .medium))
                Spacer()
                Text(localizedMessage("%@ RPM", String(Int(value.wrappedValue)))).font(.system(size: 12, design: .monospaced))
                Button(loc(.coolingApply)) { manager.setFanMinimum(index, rpm: Int(value.wrappedValue)) }
                    .disabled(manager.isApplying || manager.featureStatus[index == 0 ? "Fan1TargetRPM" : "Fan2TargetRPM"]?.available != true || maxRPM <= 0 || value.wrappedValue < 0 || value.wrappedValue > Double(maxRPM) || Int(value.wrappedValue) == applied)
            }
            if manager.featureStatus[index == 0 ? "Fan1TargetRPM" : "Fan2TargetRPM"]?.available == true {
                if maxRPM > 0, manager.fanStepsRPM[index] > 0 {
                    Slider(value: value, in: 0...Double(maxRPM), step: Double(manager.fanStepsRPM[index])).disabled(manager.isApplying)
                }
            } else {
                Text(localizedMessage(manager.featureStatus[index == 0 ? "Fan1TargetRPM" : "Fan2TargetRPM"]?.reason ?? "Fan writes have not been validated for this firmware."))
                    .font(.system(size: 11)).foregroundColor(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Text(localizedMessage(applied >= 0 ? String(format: localizedMessage("Applied minimum: %d RPM"), applied) : "Applied minimum: —"))
                .font(.system(size: 11)).foregroundColor(.secondary)
        }
    }
}

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
                Text(localizedMessage(title)).font(.system(size: 12, weight: .medium)); Spacer()
                TextField(loc(.coolingPowerWatts), text: Binding(get: { text }, set: { text = PowerLimitInput.digits($0) }))
                    .textFieldStyle(RoundedBorderTextFieldStyle()).frame(width: 64)
                    .accessibilityLabel(localizedMessage("%@ in watts", localizedMessage(title)))
                Text(localizedMessage("W")).font(.caption).foregroundColor(.secondary)
                Button(loc(.coolingApply)) { if valid, let watts = Int(text) { apply(watts) } }.disabled(busy || !valid || Int(text) == current)
            }
            Text(localizedMessage(String(format: localizedMessage("Current %d W - Range %d–%d W - Step %d W"), current, range["Min"] ?? 0, range["Max"] ?? 0, range["Step"] ?? 0)))
                .font(.system(size: 11)).foregroundColor(.secondary)
            if !text.isEmpty && !valid { Text(loc(.coolingPowerEnterValid)).font(.system(size: 11)).foregroundColor(.red) }
        }.onAppear { if text.isEmpty { text = String(current) } }
    }
}

private struct CPUPowerControls: View {
    @ObservedObject var manager: HardwareManager
    var body: some View {
        ControlSection(loc(.coolingSectionCpuPower)) {
            HStack {
                SymbolLabel(loc(.coolingPowerAdvanced), systemImage: "exclamationmark.triangle").font(.system(size: 11)).foregroundColor(.orange)
                Spacer()
                Button(loc(.coolingResetChanges)) { manager.resetPowerLimits() }
                    .disabled(manager.applyingControl == "CPUPowerReset" || !manager.cpuPowerModified || manager.featureStatus["CPUPowerReset"]?.available != true)
                    .help(localizedMessage(manager.featureStatus["CPUPowerReset"]?.available == true ? loc(.powerRestore) : "Not supported"))
            }.padding(.bottom, 8)
            if let range = manager.powerRanges["CPUBoostPower"], manager.featureStatus["CPUBoostPower"]?.available == true {
                PowerLimitRow(title: loc(.powerBoost), current: manager.cpuBoostWatts, range: range, busy: manager.applyingControl == "CPUBoostPower") { manager.setPowerLimit("CPUBoostPower", watts: $0) }
                Divider().padding(.vertical, 8)
            }
            if let range = manager.powerRanges["CPUSustainedPower"], manager.featureStatus["CPUSustainedPower"]?.available == true {
                PowerLimitRow(title: loc(.powerSustained), current: manager.cpuSustainedWatts, range: range, busy: manager.applyingControl == "CPUSustainedPower") { manager.setPowerLimit("CPUSustainedPower", watts: $0) }
            }
            if manager.featureStatus["CPUBoostPower"]?.available != true && manager.featureStatus["CPUSustainedPower"]?.available != true {
                Text(localizedMessage(manager.featureStatus["CPUBoostPower"]?.reason ?? "CPU power controls require boot-arg -reycpupower to permit firmware registers."))
                    .font(.system(size: 11)).foregroundColor(.secondary).fixedSize(horizontal: false, vertical: true).padding(.vertical, 4)
            }
            Text(loc(.coolingPowerHigherWarning))
                .font(.system(size: 11)).foregroundColor(.secondary).padding(.top, 8)
        }
    }
}

private struct RGBControls: View {
    @ObservedObject var manager: HardwareManager
    @AppStorage("RGBDraftKeyboard") private var keyboard = "#E82E38"
    @AppStorage("RGBDraftLogo") private var logo = "#E82E38"
    @AppStorage("RGBDraftVents") private var vents = "#E82E38"
    @AppStorage("RGBDraftStrip") private var strip = "#E82E38"
    @AppStorage("RGBDraftEffect") private var effect = "Static"
    var body: some View {
        ControlSection(loc(.lightingSectionRgb)) {
            if manager.rgbStatus.available {
                HStack {
                    Text(loc(.lightingMode)).font(.system(size: 12, weight: .medium))
                    Spacer()
                    Picker(loc(.lightingMode), selection: $effect) {
                        Text(loc(.lightingModeStatic)).tag("Static")
                        Text(loc(.lightingModeBreathing)).tag("Breathing")
                        Text(loc(.lightingModeSpectrum)).tag("Spectrum")
                        Text(loc(.lightingModeFactory)).tag("Factory")
                    }.labelsHidden().frame(width: 190)
                }.padding(.bottom, 8)
                if effect != "Factory" {
                    colorRow("Keyboard", $keyboard); colorRow("Logo", $logo)
                    colorRow("Vents", $vents); colorRow("Neon strip", $strip)
                }
                HStack {
                    Text(localizedMessage(manager.rgbMode)).font(.system(size: 11)).foregroundColor(.secondary)
                    Spacer()
                    Button(loc(.lightingApplyMode)) { manager.setRGBEffect(effect, colors: ["Keyboard": SavedRGBSettings.color(keyboard), "Logo": SavedRGBSettings.color(logo), "Vents": SavedRGBSettings.color(vents), "Neon strip": SavedRGBSettings.color(strip)]) }
                        .disabled(manager.rgbApplying)
                }.padding(.top, 8)
                Divider().padding(.vertical, 8)
                Button(loc(.rgbImportColors)) { manager.importRGBColors() }.disabled(manager.rgbApplying)
                Text(localizedMessage(effect == "Factory" ? "Factory effects are selected with Fn+Space. The app releases RGB control." : "Applied colors and effects return when this app opens. Breathing and Spectrum run while it is open."))
                    .font(.system(size: 11)).foregroundColor(.secondary).fixedSize(horizontal: false, vertical: true).padding(.top, 8)
            } else {
                Text(localizedMessage(manager.rgbStatus.reason)).font(.system(size: 12)).foregroundColor(.secondary).fixedSize(horizontal: false, vertical: true)
                HStack {
                    Button(loc(.grantPermissions)) { manager.openPrivacySettings() }
                    Button(loc(.coolingRetry)) { manager.retryRGBDiscovery() }.disabled(manager.rgbApplying)
                }.padding(.top, 8)
            }
        }
    }
    private func colorRow(_ name: String, _ color: Binding<String>) -> some View {
        HStack {
            Text(localizedMessage(name)).font(.system(size: 12)).frame(width: 84, alignment: .leading)
            Spacer()
            PersistentColorWell(hex: color).frame(width: 36, height: 24).accessibilityLabel(localizedMessage(name))
            Button(loc(.coolingApply)) { manager.setRGBZone(name, color: SavedRGBSettings.color(color.wrappedValue)) }.disabled(manager.rgbApplying)
        }.frame(minHeight: 32)
    }
}

#if DEBUG
struct ReYogaReviewView: View {
    let mode: String
    @ObservedObject var manager: HardwareManager
    var body: some View {
        if mode == "missing-driver" { HardwareControlsView(manager: manager) }
        else if mode == "rgb" { RGBControls(manager: manager).padding(16).frame(width: 420, height: 360, alignment: .top).background(Color(NSColor.windowBackgroundColor)) }
        else if mode == "settings" { HardwareControlsView(manager: manager, page: -1) }
        else { HardwareControlsView(manager: manager, page: mode == "device" ? 1 : mode == "cooling" ? 2 : mode.hasPrefix("battery") ? 3 : mode == "lighting" ? 4 : mode == "diagnostics" ? 5 : 0) }
    }
}

#endif

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

final class ReYogaColorPanel: NSObject, NSWindowDelegate {
    static let shared = ReYogaColorPanel()
    private weak var activeWell: NSColorWell?
    private weak var owner: NSWindow?
    private var isDismissing = false

    private override init() {
        super.init()
        NotificationCenter.default.addObserver(self, selector: #selector(applicationResigned),
                                               name: NSApplication.didResignActiveNotification, object: nil)
    }

    func present(from well: NSColorWell) {
        guard let window = well.window, let screen = window.screen else { return }
        owner = window
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
        let window = owner
        activeWell?.deactivate()
        activeWell = nil
        NSColorPanel.shared.orderOut(nil)
        if !closeControls, window?.isVisible == true { window?.makeKey() }
        owner = nil
        isDismissing = false
    }

    func windowWillClose(_ notification: Notification) { dismiss() }
    @objc private func applicationResigned() { dismiss(closeControls: true) }
}
