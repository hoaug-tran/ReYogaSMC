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
            if manager.hasFanFullSpeed {
                ControlSection(loc(.fanFullSpeed)) {
                    ControlFeatureRow(manager, .fanFullSpeed, "FanFullSpeed", "wind", manager.isFanFullSpeedOn, true) {
                        manager.toggleFanFullSpeed()
                    }
                }
            }
            if hasFanControls { ManualFanControls(manager: manager) }
            else if manager.providerClass != "ThinkVPC" && manager.fanHelper == nil && !manager.hasFanFullSpeed {
                unavailableCoolingCard(loc(.coolingSectionManualFan), icon: "wind",
                    detail: loc(.coolingManualFanCardDesc), tint: AppTheme.cpu)
            }
            if hasCPUPowerControls { CPUPowerControls(manager: manager) }
            else {
                unavailableCoolingCard(loc(.coolingSectionCpuPower), icon: "bolt.fill",
                    detail: loc(.coolingCpuPowerCardDesc), tint: AppTheme.gpu)
            }
            if manager.providerClass == "ThinkVPC" || manager.thinkFanCurveSupported || manager.fanHelper != nil {
                ThinkPadFanPanel(manager: manager)
            }
            let showFanUnavailable = !hasFanControls && manager.providerClass != "ThinkVPC" && manager.fanHelper == nil
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
        ControlSection(manager.providerClass == "ThinkVPC" ? loc(.thinkPadFans) : localizedMessage("Custom Fan Curve")) {
            VStack(alignment: .leading, spacing: 4) {
                Toggle(localizedMessage("Restore fan mode at startup"), isOn: $saveFanLevel)
                Text(localizedMessage("Auto, Manual, Custom Curve and Full Speed are restored automatically when valid thermal data is available."))
                    .font(.caption).foregroundColor(.secondary)
                    .padding(.top, 2)
            }
            if manager.thinkFanAuthorizationBusy {
                ProgressView(localizedMessage("Authorizing fan control…"))
            } else if !manager.thinkFanAuthorizationError.isEmpty {
                Text(localizedMessage(manager.thinkFanAuthorizationError)).font(.caption).foregroundColor(AppTheme.accent)
                Button(localizedMessage("Authorize Fan Control…")) { manager.authorizeThinkFanControls() }
            }
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
                        if manager.providerClass == "ThinkVPC" && manager.thinkFanECNeedsHelpers && !disabled {
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
    @State private var syncedCurvePoints = ThinkFanCurvePolicy.defaults
    @State private var lastCalculatedMode = 0
    @State private var selectedPointIndex = 0

    private var title: String { fan.main ? loc(.mainFan) : loc(.secondaryFan) }
    private var modeDescription: String {
        guard fan.enable else { return loc(.commonUnavailable) }
        if fan.curveEnabled || fan.pendingCurveResume { return localizedMessage("Custom Curve") }
        if fan.isFullSpeed { return loc(.fanFullSpeed) }
        if fan.isAutomatic { return localizedMessage("BIOS Auto") }
        return String(format: loc(.fanLevelFormat), fan.level)
    }

    private var calculatedMode: Int {
        if fan.curveEnabled || fan.pendingCurveResume { return 2 }
        if fan.isAutomatic { return 0 }
        if fan.isFullSpeed { return 3 }
        return 1
    }

    private func syncOnAppear() {
        level = Double(max(fan.minimumLevel, fan.level))
        let mode = calculatedMode
        selectedMode = mode
        lastCalculatedMode = mode
        let saved = fan.savedCurveDraft
        curveDraft = saved
        syncedCurvePoints = saved
    }

    private func syncModeFromDriver(forceCurveTransition: Bool = false) {
        let mode = calculatedMode
        if forceCurveTransition ? (mode == 2 || selectedMode == 2) : (mode != lastCalculatedMode && selectedMode == lastCalculatedMode) {
            selectedMode = mode
        }
        lastCalculatedMode = mode
    }

    private func syncCurveDraftFromHelper() {
        let saved = fan.savedCurveDraft
        if curveDraft == syncedCurvePoints {
            curveDraft = saved
        }
        syncedCurvePoints = saved
    }

    private func addCurvePoint() {
        guard curveDraft.count < 10 else { return }
        if curveDraft.isEmpty {
            curveDraft = ThinkFanCurvePolicy.defaults
            return
        }
        if curveDraft.count == 1 {
            let only = curveDraft[0]
            if only.temperature > 30 {
                let newTemp = max(30, only.temperature - 5)
                curveDraft.insert(ThinkFanCurvePoint(temperature: newTemp, level: min(only.level, 7)), at: 0)
            } else {
                curveDraft.append(ThinkFanCurvePoint(temperature: 95, level: 0x47))
            }
            return
        }
        var bestIndex = -1
        var largestGap = 1
        for i in 0..<(curveDraft.count - 1) {
            let gap = curveDraft[i + 1].temperature - curveDraft[i].temperature
            if gap > largestGap {
                largestGap = gap
                bestIndex = i
            }
        }
        if bestIndex >= 0 {
            let prev = curveDraft[bestIndex]
            let next = curveDraft[bestIndex + 1]
            let newTemp = min(94, max(30, (prev.temperature + next.temperature) / 2))
            let newLevel = prev.level == 0x47 ? 0x47 : min(max(prev.level, 1), min(next.level, 7))
            curveDraft.insert(ThinkFanCurvePoint(temperature: newTemp, level: newLevel), at: bestIndex + 1)
            return
        }
        // No internal gap >= 2°C: insert before the first point if > 30°C, else shift the last point up if < 95°C.
        if curveDraft[0].temperature > 30 {
            let first = curveDraft[0]
            let newTemp = max(30, first.temperature - 5)
            curveDraft.insert(ThinkFanCurvePoint(temperature: newTemp, level: min(first.level, 7)), at: 0)
            return
        }
        let lastIndex = curveDraft.count - 1
        let prev = curveDraft[lastIndex - 1]
        let last = curveDraft[lastIndex]
        if last.temperature < 95 && last.temperature > prev.temperature {
            let insertedTemp = last.temperature
            curveDraft[lastIndex].temperature = min(95, last.temperature + 1)
            let insertedLevel = prev.level == 0x47 ? 0x47 : min(max(prev.level, 1), 7)
            curveDraft.insert(ThinkFanCurvePoint(temperature: insertedTemp, level: insertedLevel), at: lastIndex)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(title).font(.system(size: 12, weight: .medium))
                Spacer()
                if manager.cpuTemp > 0 {
                    Text(String(format: localizedMessage("CPU: %.0f °C"), manager.cpuTemp))
                        .font(.system(size: 11, design: .monospaced)).foregroundColor(.secondary)
                }
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
                    Spacer()
                    Button(loc(.coolingApply)) {
                        command { fan.stopCurve(); fan.setManualLevel(Int(level)) }
                    }.disabled(!fan.enable)
                }
            }
            if selectedMode == 2 && manager.thinkFanCurveSupported {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        if (1...3).contains(manager.powerProfile) {
                            let profileName = [1: "Quiet", 2: "Balanced", 3: "Performance"][manager.powerProfile] ?? ""
                            SymbolLabel(String(format: localizedMessage("Power Profile: %@"), localizedMessage(profileName)), systemImage: "bolt.fill")
                                .font(.system(size: 11, weight: .medium)).foregroundColor(AppTheme.accent)
                        }
                        Spacer()
                        Text(String(format: localizedMessage("%d points"), curveDraft.count))
                            .font(.system(size: 11, weight: .medium, design: .monospaced)).foregroundColor(.secondary)
                    }

                    CurveGraphView(points: curveDraft, currentTemp: manager.cpuTemp, selectedIndex: $selectedPointIndex)

                    if curveDraft.indices.contains(selectedPointIndex) {
                        let index = selectedPointIndex
                        let lower = index == 0 ? 30 : curveDraft[index - 1].temperature + 1
                        let upper = index == curveDraft.count - 1 ? 95 : curveDraft[index + 1].temperature - 1
                        HStack(spacing: 10) {
                            HStack(spacing: 6) {
                                Button(action: { selectedPointIndex = max(0, selectedPointIndex - 1) }) {
                                    AnimatedSymbol("chevron.left").font(.system(size: 10, weight: .bold))
                                }
                                .buttonStyle(PlainButtonStyle())
                                .disabled(selectedPointIndex <= 0)

                                Text(String(format: localizedMessage("Point %d of %d"), selectedPointIndex + 1, curveDraft.count))
                                    .font(.system(size: 11, weight: .semibold, design: .monospaced))

                                Button(action: { selectedPointIndex = min(curveDraft.count - 1, selectedPointIndex + 1) }) {
                                    AnimatedSymbol("chevron.right").font(.system(size: 10, weight: .bold))
                                }
                                .buttonStyle(PlainButtonStyle())
                                .disabled(selectedPointIndex >= curveDraft.count - 1)
                            }

                            Spacer(minLength: 4)

                            if lower <= upper {
                                Stepper(value: $curveDraft[index].temperature, in: lower...upper) {
                                    Text("\(curveDraft[index].temperature) °C")
                                        .font(.system(size: 11, weight: .medium, design: .monospaced))
                                }
                            } else {
                                Text("\(curveDraft[index].temperature) °C")
                                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                            }

                            Picker(localizedMessage("Fan level"), selection: $curveDraft[index].level) {
                                ForEach(1...7, id: \.self) { value in
                                    Text(String(format: loc(.fanLevelFormat), value)).tag(value)
                                }
                                Text(loc(.fanFullSpeed)).tag(0x47)
                            }
                            .frame(maxWidth: 120)

                            if curveDraft.count > 2 && index < curveDraft.count - 1 {
                                Button(action: {
                                    curveDraft.remove(at: index)
                                    selectedPointIndex = max(0, index - 1)
                                }) {
                                    Image(systemName: "trash")
                                        .font(.system(size: 11))
                                        .foregroundColor(.secondary)
                                }
                                .buttonStyle(BorderlessButtonStyle())
                                .accessibilityLabel(localizedMessage("Remove Point"))
                            }
                        }
                        .padding(.horizontal, 10).padding(.vertical, 5)
                        .background(AppTheme.surface)
                        .cornerRadius(8)
                    }

                    HStack(spacing: 8) {
                        if curveDraft.count < 10 {
                            Button(action: {
                                addCurvePoint()
                                selectedPointIndex = min(selectedPointIndex + 1, curveDraft.count - 1)
                            }) {
                                HStack(spacing: 4) {
                                    AnimatedSymbol("plus.circle")
                                    Text(localizedMessage("Add Point"))
                                }
                                .font(.system(size: 11, weight: .medium))
                            }
                        }
                        Spacer()
                        Menu {
                            Button(localizedMessage("Reset (10 Points)")) {
                                curveDraft = ThinkFanCurvePolicy.legionDefaults
                                selectedPointIndex = 0
                            }
                            Button(localizedMessage("Reset (4 Points)")) {
                                curveDraft = ThinkFanCurvePolicy.defaults
                                selectedPointIndex = 0
                            }
                        } label: {
                            HStack(spacing: 3) {
                                AnimatedSymbol("arrow.counterclockwise")
                                Text(localizedMessage("Reset"))
                                AnimatedSymbol("chevron.down").font(.system(size: 7))
                            }
                            .font(.system(size: 11, weight: .medium))
                        }
                        .menuStyle(BorderlessButtonMenuStyle())

                        Button(loc(.coolingApply)) {
                            if !CommandLine.arguments.contains("--render-ui") {
                                manager.startThinkFanCurve(fan, points: curveDraft)
                            }
                        }
                        .font(.system(size: 11, weight: .semibold))
                        .disabled(!fan.enable || !manager.thinkFanCurveSupported || !ThinkFanCurvePolicy.valid(curveDraft))
                    }
                }
                if !ThinkFanCurvePolicy.valid(curveDraft) {
                    Text(localizedMessage("Use increasing temperatures and fan levels, ending in Full Speed by 95°C."))
                        .font(.caption).foregroundColor(AppTheme.accent)
                }
                if !fan.curveStatus.isEmpty {
                    Text(localizedMessage(fan.curveStatus)).font(.caption).foregroundColor(.secondary)
                }
            } else if selectedMode == 2 {
                Text(localizedMessage(manager.thinkFanCurveReason))
                    .font(.caption).foregroundColor(.secondary)
                if manager.providerClass == "ThinkVPC" && manager.thinkFanECNeedsHelpers {
                    Text(loc(.fanInterfaceRequired)).font(.caption).foregroundColor(.secondary)
                    Button(localizedMessage("Open Diagnostics")) { UserDefaults.standard.set(ControlsPage.diagnostics.rawValue, forKey: "ControlsPage") }
                }
            }
            if !fan.curveStopReason.isEmpty {
                HStack(alignment: .center, spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 13))
                        .foregroundColor(AppTheme.accent)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(localizedMessage("Fan Curve Fallback Active"))
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundColor(AppTheme.accent)
                        Text(localizedMessage(fan.curveStopReason))
                            .font(.system(size: 11))
                            .foregroundColor(.secondary)
                    }
                    Spacer()
                    if manager.thinkFanCurveSupported && fan.enable {
                        Button(localizedMessage("Resume Curve")) {
                            command {
                                manager.startThinkFanCurve(fan, points: curveDraft)
                            }
                        }.font(.system(size: 11))
                    }
                }
                .padding(8)
                .background(AppTheme.accent.opacity(0.08))
                .cornerRadius(8)
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(AppTheme.accent.opacity(0.25), lineWidth: 1))
            }
            if !fan.enable {
                Text(localizedMessage("Fan status is unavailable. Try Auto or reconnect the driver."))
                    .font(.caption).foregroundColor(.secondary)
            }
        }.padding(.vertical, 6)
            .onAppear {
                syncOnAppear()
            }
            .onChange(of: fan.curveEnabled) { _ in
                syncModeFromDriver(forceCurveTransition: true)
            }
            .onChange(of: fan.pendingCurveResume) { _ in
                syncModeFromDriver(forceCurveTransition: true)
            }
            .onChange(of: fan.savedLevel) { _ in
                syncModeFromDriver()
            }
            .onChange(of: fan.level) { newLevel in
                if selectedMode != 1 {
                    level = Double(max(fan.minimumLevel, newLevel))
                }
            }
            .onChange(of: fan.curvePoints) { _ in
                syncCurveDraftFromHelper()
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
            Text(String(format: localizedMessage("Current %d W - Range %d-%d W - Step %d W"), current, range["Min"] ?? 0, range["Max"] ?? 0, range["Step"] ?? 0))
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

private struct CurveGraphView: View {
    let points: [ThinkFanCurvePoint]
    let currentTemp: Double
    @Binding var selectedIndex: Int

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let h = geo.size.height
            let padX: CGFloat = 14
            let padY: CGFloat = 8
            let plotW = max(10, w - padX * 2)
            let plotH = max(10, h - padY * 2)

            let xForTemp: (Double) -> CGFloat = { temp in
                let clamped = min(95.0, max(30.0, temp))
                return padX + CGFloat((clamped - 30.0) / 65.0) * plotW
            }
            let yForLevel: (Int) -> CGFloat = { lvl in
                let norm = lvl == 0x47 ? 8.0 : Double(min(7, max(1, lvl)))
                return h - padY - CGFloat(norm / 8.0) * plotH
            }

            ZStack(alignment: .topLeading) {
                Path { p in
                    for t in [30.0, 50.0, 70.0, 85.0, 95.0] {
                        let x = xForTemp(t)
                        p.move(to: CGPoint(x: x, y: padY))
                        p.addLine(to: CGPoint(x: x, y: h - padY))
                    }
                }
                .stroke(Color.primary.opacity(0.05), style: StrokeStyle(lineWidth: 1, dash: [3, 3]))

                if points.count >= 2 {
                    Path { p in
                        let firstX = xForTemp(Double(points[0].temperature))
                        let firstY = yForLevel(points[0].level)
                        p.move(to: CGPoint(x: firstX, y: h - padY))
                        p.addLine(to: CGPoint(x: firstX, y: firstY))
                        for pt in points.dropFirst() {
                            p.addLine(to: CGPoint(x: xForTemp(Double(pt.temperature)), y: yForLevel(pt.level)))
                        }
                        let lastX = xForTemp(Double(points.last!.temperature))
                        p.addLine(to: CGPoint(x: lastX, y: h - padY))
                        p.closeSubpath()
                    }
                    .fill(LinearGradient(gradient: Gradient(colors: [AppTheme.accent.opacity(0.20), AppTheme.accent.opacity(0.01)]), startPoint: .top, endPoint: .bottom))

                    Path { p in
                        p.move(to: CGPoint(x: xForTemp(Double(points[0].temperature)), y: yForLevel(points[0].level)))
                        for pt in points.dropFirst() {
                            p.addLine(to: CGPoint(x: xForTemp(Double(pt.temperature)), y: yForLevel(pt.level)))
                        }
                    }
                    .stroke(AppTheme.accent, style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
                }

                if currentTemp >= 30 && currentTemp <= 105 {
                    let liveX = xForTemp(currentTemp)
                    Path { p in
                        p.move(to: CGPoint(x: liveX, y: padY))
                        p.addLine(to: CGPoint(x: liveX, y: h - padY))
                    }
                    .stroke(AppTheme.cpu, style: StrokeStyle(lineWidth: 1.5, dash: [4, 2]))

                    Circle()
                        .fill(AppTheme.cpu)
                        .frame(width: 6, height: 6)
                        .position(x: liveX, y: padY + 4)
                }

                ForEach(points.indices, id: \.self) { idx in
                    let pt = points[idx]
                    let x = xForTemp(Double(pt.temperature))
                    let y = yForLevel(pt.level)
                    let isSelected = idx == selectedIndex

                    Circle()
                        .fill(isSelected ? AppTheme.accent : Color.primary.opacity(0.7))
                        .frame(width: isSelected ? 8 : 4, height: isSelected ? 8 : 4)
                        .position(x: x, y: y)
                }
            }
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onEnded { value in
                        let tapX = value.location.x
                        var bestIdx = selectedIndex
                        var minDiff: CGFloat = 9999
                        for idx in points.indices {
                            let ptX = xForTemp(Double(points[idx].temperature))
                            let diff = abs(ptX - tapX)
                            if diff < minDiff {
                                minDiff = diff
                                bestIdx = idx
                            }
                        }
                        if minDiff < 35 {
                            selectedIndex = bestIdx
                        }
                    }
            )
        }
        .frame(height: 70)
        .background(AppTheme.surface.opacity(0.5))
        .cornerRadius(8)
    }
}
