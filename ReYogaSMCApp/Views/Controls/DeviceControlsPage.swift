import SwiftUI
import AppKit

struct DeviceControlsPage: View {
    @ObservedObject var manager: HardwareManager
    @ViewBuilder
    var body: some View {
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
                        ControlFeatureRow(manager, .deviceConservation, "ConservationMode", "battery.75", manager.isConservationOn, true) { manager.toggleConservation() }
                    }
                    if manager.hasRapidCharge {
                        if manager.hasConservation { Divider().padding(.vertical, 4) }
                        ControlFeatureRow(manager, .deviceRapidCharge, "RapidChargeMode", "bolt.fill", manager.isRapidChargeOn, true) { manager.toggleRapidCharge() }
                    }
                    if manager.hasOverDrive {
                        if manager.hasConservation || manager.hasRapidCharge { Divider().padding(.vertical, 4) }
                        ControlFeatureRow(manager, .deviceDisplayOverdrive, "DisplayOverDrive", "display", manager.isOverDriveOn, true) { manager.toggleOverDrive() }
                    }
                    if manager.hasTouchpadLock {
                        if manager.hasConservation || manager.hasRapidCharge || manager.hasOverDrive { Divider().padding(.vertical, 4) }
                        ControlFeatureRow(manager, .deviceTouchpadLock, "TouchpadLock", "hand.point.up", manager.isTouchpadLocked, true) { manager.toggleTouchpad() }
                    }
                }
            }

    }
    @ViewBuilder
    private var keyboardSection: some View {
        ControlSection(loc(.deviceSectionKeyboard)) {
            if manager.featureStatus["FnlockMode"]?.available == true {
                ControlFeatureRow(manager, .overviewShortcutFnLock, "FnlockMode", "fn", manager.isFnLocked, true) { manager.toggleFnLock() }
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
                            Button(loc(.permissionOpenSettings)) { HotkeyPermissionActions.openAccessibilitySettings() }
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
                            Button(loc(.permissionOpenSettings)) { HotkeyPermissionActions.openInputMonitoringSettings() }
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
                Text(localizedMessage(actual >= 0 ? "\(actual)%" : "-")).foregroundColor(.secondary)
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
