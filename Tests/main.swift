import Foundation
struct HardwareFeatureStatus: Equatable { let available: Bool; let reason: String; let backend: String }
final class ReYogaDiagnostics {
    static let shared = ReYogaDiagnostics()
    func record(_ event: String, _ details: [String: Any]) {}
}
func require(_ condition: @autoclosure () -> Bool, _ message: String) {
    if !condition() { fatalError(message) }
}
func rejects(_ name: String, _ action: () throws -> Void) {
    do { try action(); fatalError("Accepted invalid input: \(name)") }
    catch { print("PASS reject: \(name)") }
}
let profiles = HardwareProfiles.all()
require(!profiles.isEmpty, "Bundled profiles missing")
require(profiles.allSatisfy { $0["schema_version"] as? Int == 1 }, "Unsupported profile schema")
let legionIdentity = LaptopIdentity.resolve(strings: ["82N6CTO1WW"], pciIDs: [], lenovo: false)
require(legionIdentity.name == "Lenovo Legion 7 2021 16ACHg6", "Machine type identity failed")
require(LaptopIdentity.resolve(strings: ["MacBookPro16,3"], pciIDs: [], lenovo: false).name == "Unknown Laptop", "Spoofed SMBIOS leaked into identity")
require(LaptopIdentity.resolve(strings: [], pciIDs: ["17aa:ffff"], lenovo: false).name == "Lenovo Laptop", "Lenovo PCI fallback failed")
let identityProfiles: [[String: Any]] = [["kind": "acpi", "name": "Test Lenovo", "pci_subsystem_ids": ["17aa:1234"]]]
require(LaptopIdentity.resolve(strings: [], pciIDs: ["17aa:1234"], lenovo: false, profiles: identityProfiles).name == "Test Lenovo", "PCI subsystem lookup failed")
require(LaptopIdentity.resolve(strings: ["82N6", "82JQ"], pciIDs: [], lenovo: true).name == "Lenovo Laptop", "Ambiguous identity selected a model")
print("PASS laptop model lookup, PCI identity, ambiguity and fallbacks")
require(HardwareProfiles.normalizedDSDT("Name (X, \"a b//c\") /* comment */") == "Name(X,\"a b//c\")", "Quoted AML data changed during normalization")
require(HardwareProfiles.normalizedDSDT("Name (X, \"a b\")") != HardwareProfiles.normalizedDSDT("Name (X, \"ab\")"), "Distinct AML strings share a fingerprint")
require(LaptopIdentity.resolve(strings: ["MacBookPro16,2"], pciIDs: ["17aa:3a58"], lenovo: false).name == "Lenovo Legion 7 2021 16ACHg6", "Verified PCI identity did not survive SMBIOS spoofing")
require(HardwareSnapshot.fanRPM(0) == 0 && HardwareSnapshot.fanRPM(0xffff) == -1 && HardwareSnapshot.fanRPM(nil) == -1, "Fan availability or stopped-fan state is incorrect")
require(HardwareSnapshot.temperature(45) == 45 && HardwareSnapshot.temperature(0) == -1 && HardwareSnapshot.temperature(125) == -1, "Invalid temperatures were displayed as readings")
require(HardwareSnapshot.temperature(55.5) == 55.5, "Fractional firmware temperatures were rounded")
require(HardwareSnapshot.temperature(true) == -1 && HardwareSnapshot.temperature(Double.nan) == -1 && HardwareSnapshot.temperature(Double.infinity) == -1, "Invalid numeric temperature accepted")
require(HardwareSnapshot.providerPriority("ThinkVPC") > HardwareSnapshot.providerPriority("ReYogaHIDD"), "Generic HID must not hide ThinkPad controls")
require(!HardwareSnapshot.stale(["SensorSampleTimeMS": 99000, "TelemetryIntervalMS": 500], observedAge: 5, uptime: 100), "Fresh device timestamp was rejected")
require(HardwareSnapshot.stale(["SensorSampleTimeMS": 90000, "TelemetryIntervalMS": 500], observedAge: 0, uptime: 100), "Cached sample was incorrectly marked live on first connection")
require(HardwareSnapshot.stale(["SensorSampleTimeMS": -1], observedAge: 0, uptime: 100), "Invalid sample timestamp was accepted")
require(HardwareSnapshot.stale([:], observedAge: 3, uptime: 100), "Legacy stalled sequence was accepted")
require(!HardwareSnapshot.stale(["TelemetryIntervalMS": 5000], observedAge: 10, uptime: 100), "Device polling interval was ignored")
require(HardwareSnapshot.powerRange(["Min": 5, "Max": 65, "Step": 1], current: 45)?["Max"] == 65, "Reported power range was lost")
require(HardwareSnapshot.powerRange(["Min": 5, "Max": 65], current: 45) == nil, "Missing power step was invented")
require(HardwareSnapshot.powerRange(["Min": 5, "Max": 65, "Step": 1], current: nil) == nil, "Missing power limit became a measured zero")
let nativeFan = HardwareFeatureStatus(available: true, reason: "", backend: "WMI Fan")
require(HardwareSnapshot.manualFanFeature(nativeFan, key: "Fan1TargetRPM", bridgeVersion: 0, writesValidated: false).available, "A non-bridge fan backend inherited bridge restrictions")
let legacyFan = HardwareFeatureStatus(available: false, reason: "Install ACPI bridge v2", backend: "ACPI profile")
let fanNotice = HardwareSnapshot.manualFanFeature(legacyFan, key: "FanControlMode", bridgeVersion: 0, writesValidated: false)
require(!fanNotice.available && !fanNotice.reason.contains("Install") && !fanNotice.reason.contains("SSDT"), "Unsupported fan control prescribed an unverified installation")
print("PASS device identity, live timestamp validation, invalid readings and per-backend fan availability")
let modelHotkeys = HardwareProfiles.hotkeys(for: "legion7-16achg6-gkcn")
let usbHotkeys = HardwareProfiles.hotkeys(for: "ite-c968-gen6")
require(modelHotkeys?["id"] as? String == "legion7-gen6-hotkeys", "Embedded hotkeys missing for ACPI profile")
require(usbHotkeys?["id"] as? String == modelHotkeys?["id"] as? String, "RGB hotkey association changed")
require(HardwareProfiles.hotkeys(for: "unknown-device") == nil, "Unknown device inherited hotkeys")
let rgb = profiles.first { $0["kind"] as? String == "rgb" }!
let colors: [(Int, UInt8, UInt8, UInt8)] = (1...48).map { ($0, 10, 20, 30) }
let packets = try LegionRGBController.reports(profile: rgb, bank: 1, colors: colors)
require(packets.count == 2, "48 LEDs must be split into two reports")
require(packets.allSatisfy { $0.count == 192 }, "Wrong report size")
require(Array(packets[0][0..<8]) == [7, 0xa1, 47, 0, 1, 10, 20, 30], "Wrong first packet header or color ordering")
require(Array(packets[0][188..<192]) == [47, 10, 20, 30], "Last LED overflow")
require(Array(packets[1][0..<8]) == [7, 0xa1, 1, 0, 48, 10, 20, 30], "Wrong continuation")
print("PASS RGB 47/48-LED boundary and reference wire format")
rejects("invalid LED ID") { _ = try LegionRGBController.reports(profile: rgb, bank: 1, colors: [(-1, 0, 0, 0)]) }
rejects("invalid bank") { _ = try LegionRGBController.reports(profile: rgb, bank: 1000, colors: colors) }
var corrupt = rgb; corrupt["maxLEDsPerPacket"] = Int.max
rejects("oversized packet count") { _ = try LegionRGBController.reports(profile: corrupt, bank: 1, colors: colors) }
corrupt = rgb; corrupt["reportID"] = 256
rejects("invalid report ID") { _ = try LegionRGBController.reports(profile: corrupt, bank: 1, colors: colors) }
rejects("unknown DSDT") { _ = try HardwareProfiles.matchingDSDT("DefinitionBlock (\"\", \"DSDT\", 2, \"UNKNOWN\", \"UNKNOWN\", 1) {}") }
let inputPaths = CommandLine.arguments.dropFirst().filter { !$0.hasPrefix("--") }
if !inputPaths.isEmpty {
    let source = try String(contentsOfFile: inputPaths[0], encoding: .utf8)
    let match = try HardwareProfiles.matchingDSDT(source)
    require(match["id"] as? String == "legion7-16achg6-gkcn", "Wrong reviewed profile")
    let rendered = try HardwareProfiles.render(match)
    require(!rendered.contains("{{"), "Unresolved template")
    require(rendered.contains("0xFE00D400"), "Wrong physical base")
    require(rendered.contains("Method (RYFA"), "Missing restoration interface")
    require(rendered.contains("Local4 < Local2"), "Fan floor lost its factory minimum protection")
    rejects("same vendor but changed firmware") { _ = try HardwareProfiles.matchingDSDT(source.replacingOccurrences(of: "0xFE00D400", with: "0xFE00E400")) }
    print("PASS reviewed DSDT hash, profile selection, and complete source generation")
}
rejects("truncated AML") { _ = try HardwareProfiles.matchingAML(Data("DSDT".utf8)) }
rejects("unreviewed AML") { _ = try HardwareProfiles.matchingAML(Data("DSDT".utf8) + Data(repeating: 0, count: 64)) }
if inputPaths.count > 1 {
    let table = try Data(contentsOf: URL(fileURLWithPath: inputPaths[1]))
    let profile = try HardwareProfiles.matchingAML(table)
    require(profile["id"] as? String == "legion7-16achg6-gkcn", "Wrong binary DSDT profile")
    print("PASS raw DSDT hash and live-export profile contract")
}
require(LegionHotkeys.rawAction(keycode: 111, physicalFnDown: false, mapping: ["111": "calculator"]) == nil, "Ordinary F12 must remain F12")
require(LegionHotkeys.rawAction(keycode: 111, physicalFnDown: true, mapping: ["111": "calculator"]) == "calculator", "Physical Fn+F12 fallback missing")
print("PASS ordinary F12 preservation and physical-Fn fallback")
print("All support tests passed")

if CommandLine.arguments.contains("--probe-rgb") {
    let controller = LegionRGBController()
    controller.detect()
    print("RGB discovery:", controller.status.available, controller.status.reason)
    if controller.status.available { print("RGB read-only layout query:", try controller.inspectLayout()) }
}

require(PowerLimitInput.digits("a-65.5 W") == "655", "Numeric editor allowed non-digits")
let wattRange = ["Min": 10, "Max": 70, "Step": 5]
require(PowerLimitInput.isValid("65", range: wattRange), "Valid watt value rejected")
for invalid in ["", "abc", "-10", "65W", "65.0", "9", "71", "11", "999999999999999999"] {
    require(!PowerLimitInput.isValid(invalid, range: wattRange), "Invalid watt input accepted: \(invalid)")
}
require(!PowerLimitInput.isValid("65", range: ["Min": 10, "Max": 70, "Step": 0]), "Zero firmware step accepted")
let red: (UInt8, UInt8, UInt8) = (255, 0, 0)
require(LegionRGBController.effectColor(mode: "Static", base: red, elapsed: 2).0 == 255, "Static color changed")
require(LegionRGBController.effectColor(mode: "Breathing", base: red, elapsed: 2).0 < 30, "Breathing minimum failed")
require(LegionRGBController.effectColor(mode: "Breathing", base: red, elapsed: 4).0 == 255, "Breathing cycle failed")
let green = LegionRGBController.effectColor(mode: "Spectrum", base: red, elapsed: 4)
require(green.1 > 250 && green.0 < 5 && green.2 < 5, "Spectrum cycle failed")
print("PASS numeric input bounds/steps and RGB animation cycles")
require(SMCTemperatureReader.decodeTemperature(type: "sp78", bytes: [80, 128]) == 80.5, "SMC sp78 fractional decode failed")
require(SMCTemperatureReader.decodeTemperature(type: "sp78", bytes: [0, 0]) == nil, "Zero SMC reading accepted")
require(SMCTemperatureReader.decodeTemperature(type: "sp78", bytes: [255, 0]) == nil, "Negative SMC sentinel accepted")
require(SMCTemperatureReader.decodeTemperature(type: "ui16", bytes: [80, 0]) == nil, "Unknown SMC encoding accepted")
if CommandLine.arguments.contains("--probe-smc") {
    let reader = SMCTemperatureReader()
    if let reading = reader.cpuTemperature() { print("LIVE SMC CPU:", reading.celsius, reading.source) }
    else { print("LIVE SMC CPU unavailable:", reader.cpuReason) }
    if let reading = reader.gpuTemperature() { print("LIVE SMC GPU:", reading.celsius, reading.source) }
    else { print("LIVE SMC GPU unavailable:", reader.reason) }
}

var preferences = SavedHardwareSettings(identity: "reviewed-firmware-A")
preferences.record("ConservationMode", value: SavedControlValue(value: 1, boolean: true))
preferences.record("RapidChargeMode", value: SavedControlValue(value: 1, boolean: true))
require(preferences.values["ConservationMode"]?.value == 0, "Charging preferences must remain mutually exclusive")
preferences.record("CPUBoostPower", value: SavedControlValue(value: 40, boolean: false, powerProfile: 2))
preferences.record("CPUPowerReset", value: SavedControlValue(value: 0, boolean: false))
require(preferences.values["CPUBoostPower"] == nil, "Explicit reset must remove the persistent CPU edit")
preferences.record("Fan1TargetRPM", value: SavedControlValue(value: 3000, boolean: false, powerProfile: 2))
preferences.record("FanControlMode", value: SavedControlValue(value: 0, boolean: false))
require(preferences.values["Fan1TargetRPM"] == nil, "Auto must remove persistent fan overrides")
require(SavedHardwareSettings.storageKey("A") != SavedHardwareSettings.storageKey("B"), "Hardware preferences must be isolated")
let savedColors = SavedRGBSettings(profileID: "rgb-test", mode: "Per-key", colors: ["Logo": "#E82E38"], logoEnabled: false, perKey: Data("{\"Logo\":{\"0\":\"#112233\"}}".utf8))
require(savedColors.isValid, "Valid RGB preferences rejected")
let restoredColors = try JSONDecoder().decode(SavedRGBSettings.self, from: JSONEncoder().encode(savedColors))
require(restoredColors == savedColors, "RGB configuration must survive relaunch encoding")
var invalidColors = savedColors; invalidColors.colors["Logo"] = "#FF0"
require(!invalidColors.isValid, "Malformed color must not be replayed")
invalidColors = savedColors; invalidColors.version = 999
require(!invalidColors.isValid, "Unknown preference schema must not be replayed")
let menuGlyph = ReYogaBrand.menuImage()
require(menuGlyph.isTemplate && menuGlyph.size == NSSize(width: 18, height: 18), "Menu glyph must follow macOS template rendering")
print("PASS persistent RGB, reset semantics, hardware isolation and template glyph")

let conservedBattery = LiveBatterySnapshot(properties: ["AppleRawCurrentCapacity": 4694, "AppleRawMaxCapacity": 4694,
    "ExternalConnected": true, "IsCharging": false, "InstantAmperage": 0])
require(conservedBattery.percent == 100, "Conservation must not relabel full capacity as a lower percentage")
require(conservedBattery.summary.contains("Not charging") && conservedBattery.summary.contains("0 mA"), "Battery charge state missing")
require(LiveBatterySnapshot(properties: [:]).percent == nil, "Missing battery capacity treated as a percentage")
require(LiveBatterySnapshot(properties: ["CurrentCapacity": 10, "MaxCapacity": 0]).percent == nil, "Zero battery maximum accepted")
require(LiveBatterySnapshot(properties: ["Amperage": -900]).summary.contains("Discharging"), "Negative current not reported as discharge")
for visible in [NSRect(x: 0, y: 0, width: 1440, height: 875), NSRect(x: -1920, y: 100, width: 1920, height: 1080)] {
    for owner in [NSRect(x: visible.minX, y: visible.maxY-640, width: 420, height: 640),
                  NSRect(x: visible.maxX-420, y: visible.maxY-640, width: 420, height: 640)] {
        let size = NSSize(width: 260, height: 400)
        let origin = ColorPanelPlacement.origin(panelSize: size, anchor: owner.insetBy(dx: 12, dy: 20), owner: owner, visible: visible)
        require(visible.contains(NSRect(origin: origin, size: size)), "Color panel escaped the popover's display")
        require(!owner.intersects(NSRect(origin: origin, size: size)), "Color panel obscures controls despite available side space")
    }
}
print("PASS battery status and anchored color panel placement across displays")

require(LiveBatterySnapshot(properties: ["AppleRawCurrentCapacity": 4694, "CurrentCapacity": 47, "MaxCapacity": 100]).percent == 47,
        "Mixed raw mAh and percentage-based battery units")

require(SMCTemperatureReader.cpuTemperatureKeys(available: ["TC0G", "TC0E", "TC0P", "TCGC"], amd: true) == ["TC0E", "TC0P"],
        "CPU reader selected a placeholder or firmware GPU key")

let normalizedPack = LiveBatterySnapshot(properties: ["CurrentCapacity": 60, "MaxCapacity": 100])
require(normalizedPack.percent == 60 && normalizedPack.maximumCapacity == nil && normalizedPack.currentCapacity == nil,
        "Normalized percent was mislabeled as mAh")
let partialPack = LiveBatterySnapshot(properties: ["AppleRawMaxCapacity": 4694, "DesignCapacity": 5208])
require(partialPack.maximumCapacity == 4694 && partialPack.currentCapacity == nil && partialPack.percent == nil,
        "Maximum capacity must survive missing current capacity")
let realPack = LiveBatterySnapshot(properties: ["AppleRawCurrentCapacity": 2817, "AppleRawMaxCapacity": 4694,
    "DesignCapacity": 5208, "Temperature": 2931, "Voltage": 15692, "InstantAmperage": 0,
    "CycleCount": 61, "AvgTimeToFull": 65535, "TimeRemaining": 65535,
    "BatteryData": ["DeviceName": "L20D4PC1"], "AdapterDetails": ["Watts": 60]])
require(realPack.percent == 60 && realPack.designCapacity == 5208, "Live pack capacity decode")
require(abs((realPack.healthPercent ?? 0) - 90.13) < 0.02, "Retained capacity calculation")
require(abs((realPack.temperatureCelsius ?? 0) - 19.95) < 0.01, "Temperature must use tenths kelvin")
require(realPack.timeToFull == nil && realPack.timeToEmpty == nil, "Unknown time sentinel shown as duration")
require(realPack.deviceName == "L20D4PC1" && realPack.adapterWatts == 60, "Nested pack/adapter metadata missing")
require(LiveBatterySnapshot(properties: ["InstantAmperage": 65536 - 900]).milliamps == -900,
        "Unsigned current register was not sign extended")
require(LiveBatterySnapshot(properties: ["Temperature": 0, "DesignCapacity": -1, "Voltage": 0]).temperatureCelsius == nil,
        "Invalid temperature was shown as real")
require(!BatteryDetail(index: 1, properties: ["ID": "0000 0000", "Cycle count": "0", "Manufacture date": "2021/06/05"]).present,
        "Empty slot became a real battery")
print("PASS battery capacity, units, nested metadata, time sentinels and absent slot")

if CommandLine.arguments.contains("--probe-identity") {
    let identity = LaptopIdentity.read()
    print("Live identity: \(identity.name) [\(identity.source)]")
}

if let languageRoot = ProcessInfo.processInfo.environment["REYOGA_LOCALIZATION_ROOT"],
   let vietnamese = Bundle(path: languageRoot + "/vi.lproj"), let english = Bundle(path: languageRoot + "/en.lproj") {
    let source = "The active driver has no validated manual fan control for this firmware."
    require(renderLocalizedMessage(source, arguments: [], bundle: vietnamese).hasPrefix("Driver đang nạp"), "Firmware reason was not localized")
    require(renderLocalizedMessage(source, arguments: [], bundle: english) == source, "English message fallback changed")
    let sample = renderLocalizedMessage("%@: requested %@ RPM, measured %@. The minimum has not been reached.",
        arguments: ["Quạt 1", "3200", "2900"], bundle: vietnamese)
    require(sample.contains("3200") && sample.contains("2900") && sample.contains("Chưa đạt"), "Localized telemetry message lost its runtime values")
    let transport = renderLocalizedMessage("IOKit transport failed (0x%08x)", arguments: [UInt32(42)], bundle: vietnamese)
    require(transport.contains("0x0000002a") && transport.hasPrefix("Truyền lệnh"), "Localized error code was corrupted")
    let rawName = renderLocalizedMessage("Could not open %@: %@", arguments: ["Off", "0x1234"], bundle: vietnamese)
    require(rawName.contains("Off") && rawName.contains("0x1234"), "Localization altered a runtime identifier")
    print("PASS English/Vietnamese firmware reasons, runtime values and error-code formatting")
}
