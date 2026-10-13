// Exercise production profile matching/rendering and USB wire encoding without
// opening a device, installing ACPI tables, or changing hardware state.
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
if CommandLine.arguments.count > 1 {
    let source = try String(contentsOfFile: CommandLine.arguments[1])
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
if CommandLine.arguments.count > 2, CommandLine.arguments[2] != "--probe-rgb" {
    let table = try Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[2]))
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
