import SwiftUI
import AppKit

struct CoolingControlsPage: View {
    @ObservedObject var manager: HardwareManager
    @State private var reviewExpanded = CommandLine.arguments.contains("--render-ui") && ProcessInfo.processInfo.environment["REYOGA_UI_EXPANDED"] == "1"
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
    var body: some View {
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
            if manager.providerClass == "ThinkVPC" { ThinkPadFanPanel(manager: manager) }
            let showFanUnavailable = !hasFanControls && manager.providerClass != "ThinkVPC"
            let showPowerUnavailable = !hasCPUPowerControls
            if showFanUnavailable || showPowerUnavailable {
                let whyTitle: LocalizedKey = (showFanUnavailable && showPowerUnavailable)
                    ? .coolingWhyUnavailable
                    : (showFanUnavailable ? .coolingWhyFanUnavailable : .coolingWhyPowerUnavailable)
                DisclosureGroup(isExpanded: $reviewExpanded) {
                    VStack(alignment: .leading, spacing: 12) {
                        if showFanUnavailable {
                            coolingReason(loc(.coolingSectionManualFan), reason: manager.featureStatus["Fan1TargetRPM"]?.reason ?? "No verified manual fan interface")
                        }
                        if showPowerUnavailable {
                            coolingReason(loc(.coolingSectionCpuPower), reason: manager.featureStatus["CPUBoostPower"]?.reason ?? "No verified CPU power interface")
                        }
                        Text(loc(.coolingLiveReadingsNotice))
                            .font(.system(size: 11)).foregroundColor(.secondary)
                    }.padding(.top, 10)
                } label: {
                    SymbolLabel(loc(whyTitle), systemImage: "info.circle")
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
    @ObservedObject var manager: HardwareManager
    @AppStorage("SaveFanLevel") private var saveFanLevel = false

    private func helper(_ index: Int) -> ThinkFanHelper? {
        index == 0 ? manager.fanHelper : manager.fanHelper2
    }

    var body: some View {
        ControlSection(loc(.thinkPadFans)) {
            Toggle(localizedMessage("Restore fan mode at startup"), isOn: $saveFanLevel)
            ForEach(0..<(manager.hasDualFan || helper(1) != nil ? 2 : 1), id: \.self) { index in
                if let fan = helper(index) {
                    ThinkPadFanControl(manager: manager, fan: fan)
                } else {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text(index == 0 ? loc(.mainFan) : loc(.secondaryFan))
                            Spacer()
                            let rpm = index == 0 ? manager.fan1RPM : manager.fan2RPM
                            Text(rpm >= 0 ? localizedMessage("%@ RPM", String(rpm)) : loc(.commonUnavailable))
                                .font(.system(size: 11, design: .monospaced)).foregroundColor(.secondary)
                        }
                        let disabled = ReYogaConstants.userDefaults.bool(forKey: "DisableFan")
                        Text(localizedMessage(disabled ? "Fan controls are disabled by saved app preferences." :
                            manager.thinkFanCurveReason.isEmpty ? "Reconnect the driver to initialize fan controls." : manager.thinkFanCurveReason))
                            .font(.caption).foregroundColor(.secondary)
                        if manager.thinkFanECNeedsHelpers && !disabled {
                            Text(loc(.fanInterfaceRequired)).font(.caption).foregroundColor(.secondary)
                            Button(localizedMessage("Open Diagnostics")) { UserDefaults.standard.set(ControlsPage.diagnostics.rawValue, forKey: "ControlsPage") }
                        }
                    }.padding(.vertical, 6)
                }
            }
        }
    }
}

private struct ThinkPadFanControl: View {
    @ObservedObject var manager: HardwareManager
    @ObservedObject var fan: ThinkFanHelper
    @State private var level: Double = 4
    @State private var selectedMode = 0
    @State private var curveDraft = ThinkFanCurvePolicy.defaults

    private var title: String { fan.main ? loc(.mainFan) : loc(.secondaryFan) }
    private var mode: String {
        guard fan.enable else { return loc(.commonUnavailable) }
        if fan.curveEnabled { return localizedMessage("Custom Curve") }
        if fan.isFullSpeed { return loc(.fanFullSpeed) }
        if fan.isAutomatic { return loc(.fanAuto) }
        return String(format: loc(.fanLevelFormat), fan.level)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(title).font(.system(size: 12, weight: .medium))
                Spacer()
                let rpm = fan.main ? manager.fan1RPM : manager.fan2RPM
                Text(rpm >= 0 ? localizedMessage("%@ RPM", String(rpm)) : loc(.commonUnavailable))
                    .font(.system(size: 11, design: .monospaced)).foregroundColor(.secondary)
            }
            Picker(localizedMessage("Fan control mode"), selection: Binding(
                get: { selectedMode },
                set: { value in
                    selectedMode = value
                    if value == 0 { command { fan.setAutomatic() } }
                    else if value == 3 { command { fan.setFullSpeed() } }
                })) {
                Text(localizedMessage("BIOS Auto")).tag(0)
                Text(localizedMessage("Manual")).tag(1)
                Text(localizedMessage("Custom Curve")).tag(2)
                Text(loc(.fanFullSpeed)).tag(3)
            }.pickerStyle(SegmentedPickerStyle())
            Text(mode).font(.caption).foregroundColor(.secondary)
            if selectedMode == 0 && !fan.enable {
                Button(loc(.fanAuto)) { command { fan.setAutomatic() } }
                    .disabled(!fan.canRecoverAutomatic)
            }
            if selectedMode == 1 {
                HStack {
                Slider(value: $level, in: Double(fan.minimumLevel)...7, step: 1)
                    .disabled(!fan.enable)
                    .accessibilityLabel(localizedMessage(fan.main ? "Main fan level" : "Secondary fan level"))
                Text(String(format: loc(.fanLevelFormat), Int(level))).font(.caption)
                }
            }
            if selectedMode == 2 && manager.thinkFanCurveSupported {
                Divider()
                VStack(alignment: .leading, spacing: 6) {
                    Text(localizedMessage("CPU temperature curve")).font(.caption).bold()
                    ForEach(curveDraft.indices, id: \.self) { index in
                        HStack {
                            Stepper(value: $curveDraft[index].temperature, in: 30...95) {
                                Text("\(curveDraft[index].temperature) °C").font(.caption)
                            }
                            Picker(localizedMessage("Fan level"), selection: $curveDraft[index].level) {
                                ForEach(1...7, id: \.self) { value in
                                    Text(String(format: loc(.fanLevelFormat), value)).tag(value)
                                }
                                Text(loc(.fanFullSpeed)).tag(0x47)
                            }
                        }
                    }
                }
                if !ThinkFanCurvePolicy.valid(curveDraft) {
                    Text(localizedMessage("Use increasing temperatures and fan levels, ending in Full Speed by 95°C."))
                        .font(.caption).foregroundColor(AppTheme.accent)
                }
                Text(localizedMessage("Curve is experimental. Full Speed uses disengaged mode; calibrate on your laptop. Restart after sleep or reconnect."))
                    .font(.caption).foregroundColor(.secondary)
                Text(localizedMessage(manager.cpuTemperatureSource) + " · " +
                     (manager.cpuTemp > 0 ? String(format: "%.1f °C", manager.cpuTemp) : loc(.commonUnavailable)))
                    .font(.caption).foregroundColor(.secondary)
                if !fan.curveStatus.isEmpty {
                    Text(localizedMessage(fan.curveStatus)).font(.caption).foregroundColor(.secondary)
                }
            } else if selectedMode == 2 {
                Text(localizedMessage(manager.thinkFanCurveReason))
                    .font(.caption).foregroundColor(.secondary)
                if manager.thinkFanECNeedsHelpers {
                    Text(loc(.fanInterfaceRequired)).font(.caption).foregroundColor(.secondary)
                    Button(localizedMessage("Open Diagnostics")) { UserDefaults.standard.set(ControlsPage.diagnostics.rawValue, forKey: "ControlsPage") }
                }
            }
            if !fan.curveStopReason.isEmpty {
                Text(localizedMessage(fan.curveStopReason)).font(.caption).foregroundColor(AppTheme.accent)
            }
            if !fan.enable {
                Text(localizedMessage("Fan status is unavailable. Try Auto or reconnect the driver."))
                    .font(.caption).foregroundColor(.secondary)
            }
            if selectedMode == 1 || selectedMode == 2 {
                HStack {
                    Spacer()
                    Button(loc(.coolingApply)) {
                        if selectedMode == 1 { command { fan.stopCurve(); fan.setManualLevel(Int(level)) } }
                        else if !CommandLine.arguments.contains("--render-ui") {
                            manager.startThinkFanCurve(fan, points: curveDraft)
                        }
                    }.disabled(!fan.enable || (selectedMode == 2 &&
                        (!manager.thinkFanCurveSupported || !ThinkFanCurvePolicy.valid(curveDraft))))
                }
            }
        }.padding(.vertical, 6)
            .onAppear {
                level = Double(max(fan.minimumLevel, fan.level))
                selectedMode = fan.curveEnabled ? 2 : fan.isAutomatic ? 0 : fan.isFullSpeed ? 3 : 1
                curveDraft = fan.savedCurveDraft
            }
            .onChange(of: curveDraft) {
                if !CommandLine.arguments.contains("--render-ui") { fan.saveCurveDraft($0) }
            }
    }

    private func command(_ action: () -> Void) {
        guard !CommandLine.arguments.contains("--render-ui") else { return }
        manager.performThinkFanCommand(fan, action: action)
    }
}

private struct ManualFanControls: View {
    @ObservedObject var manager: HardwareManager
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
                Button(loc(.coolingApply)) {
                    guard ControlRiskConfirmation.fanMinimum() else { return }
                    manager.setFanMinimum(index, rpm: Int(value.wrappedValue))
                }
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
            Text(localizedMessage(applied >= 0 ? String(format: localizedMessage("Applied minimum: %d RPM"), applied) : "Applied minimum: -"))
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
    init(controlKey: String, title: String, current: Int, range: [String: Int], busy: Bool, apply: @escaping (Int) -> Void) {
        self.title = title; self.current = current; self.range = range; self.busy = busy; self.apply = apply
        let titleKey: LocalizedKey = controlKey == "CPUBoostPower" ? .powerBoost : .powerSustained
        self._text = AppStorage(wrappedValue: "", powerDraftStorageKey(controlKey, titleKey: titleKey))
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
                PowerLimitRow(controlKey: "CPUBoostPower", title: loc(.powerBoost), current: manager.cpuBoostWatts, range: range, busy: manager.applyingControl == "CPUBoostPower") {
                    guard ControlRiskConfirmation.cpuPower() else { return }
                    manager.setPowerLimit("CPUBoostPower", watts: $0)
                }
                Divider().padding(.vertical, 8)
            }
            if let range = manager.powerRanges["CPUSustainedPower"], manager.featureStatus["CPUSustainedPower"]?.available == true {
                PowerLimitRow(controlKey: "CPUSustainedPower", title: loc(.powerSustained), current: manager.cpuSustainedWatts, range: range, busy: manager.applyingControl == "CPUSustainedPower") {
                    guard ControlRiskConfirmation.cpuPower() else { return }
                    manager.setPowerLimit("CPUSustainedPower", watts: $0)
                }
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
