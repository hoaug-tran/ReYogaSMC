import SwiftUI
import AppKit

struct LightingControlsPage: View {
    @ObservedObject var manager: HardwareManager
    var body: some View {
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
                        ControlFeatureRow(manager, .lightingLogoLed, "YLogoStatus", "lightbulb", manager.isYLogoOn, true) { manager.toggleYLogo() }
                    }
                    if manager.hasPortLighting {
                        ControlFeatureRow(manager, .lightingPortIcons, "PortLighting", "powerplug", manager.isPortLightingOn, true) { manager.togglePortLighting() }
                    }
                }
            }
            RGBControls(manager: manager)
        }
    }
}
struct RGBControls: View {
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
                    Button(loc(.lightingApplyMode)) { manager.setRGBEffect(effect, colors: ["Keyboard": (SavedRGBSettings.bytes(keyboard) ?? (0, 0, 0)), "Logo": (SavedRGBSettings.bytes(logo) ?? (0, 0, 0)), "Vents": (SavedRGBSettings.bytes(vents) ?? (0, 0, 0)), "Neon strip": (SavedRGBSettings.bytes(strip) ?? (0, 0, 0))]) }
                        .disabled(manager.rgbApplying)
                }.padding(.top, 8)
                Divider().padding(.vertical, 8)
                Button(loc(.rgbImportColors)) { importColors() }.disabled(manager.rgbApplying)
                Text(localizedMessage(effect == "Factory" ? "Factory effects are selected with Fn+Space. The app releases RGB control." : "Applied colors and effects return when this app opens. Breathing and Spectrum run while it is open."))
                    .font(.system(size: 11)).foregroundColor(.secondary).fixedSize(horizontal: false, vertical: true).padding(.top, 8)
            } else {
                Text(localizedMessage(manager.rgbStatus.reason)).font(.system(size: 12)).foregroundColor(.secondary).fixedSize(horizontal: false, vertical: true)
                HStack {
                    Button(loc(.grantPermissions)) { HotkeyPermissionActions.openPrivacySettings() }
                    Button(loc(.coolingRetry)) { manager.retryRGBDiscovery() }.disabled(manager.rgbApplying)
                }.padding(.top, 8)
            }
        }
    }
    private func importColors() {
        let chooser = NSOpenPanel()
        chooser.allowedFileTypes = ["json"]
        chooser.message = localizedMessage("Select a zone/LED color map. Unknown LEDs are rejected.")
        guard chooser.runModal() == .OK, let file = chooser.url else { return }
        manager.importRGBColors(from: file)
    }

    private func colorRow(_ name: String, _ color: Binding<String>) -> some View {
        HStack {
            Text(localizedMessage(name)).font(.system(size: 12)).frame(width: 84, alignment: .leading)
            Spacer()
            PersistentColorWell(hex: color).frame(width: 36, height: 24).accessibilityLabel(localizedMessage(name))
            Button(loc(.coolingApply)) { manager.setRGBZone(name, color: (SavedRGBSettings.bytes(color.wrappedValue) ?? (0, 0, 0))) }.disabled(manager.rgbApplying)
        }.frame(minHeight: 32)
    }
}
