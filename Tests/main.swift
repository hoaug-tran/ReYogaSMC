import Foundation
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

func testProfilesAndDSDTFiles() {
    let profiles = HardwareProfiles.all()
    require(!profiles.isEmpty, "Bundled profiles missing")
    do {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let executable = directory.appendingPathComponent("iasl-stable")
        try "#!/bin/sh\nexit 0\n".write(to: executable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
        require(IASLCompiler.installed(candidates: [nil, directory.appendingPathComponent("missing").path,
            directory.path, executable.path]) == executable, "Executable compiler fallback failed")
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: executable.path)
        require(IASLCompiler.installed(candidates: [executable.path]) == nil, "Non-executable compiler accepted")
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        var downloads = 0
        let cache = directory.appendingPathComponent("compiler-cache")
        let installed = try IASLCompiler.resolve(candidates: [executable.path], cache: cache) { _ in downloads += 1 }
        require(installed.path == executable.path && downloads == 0, "Existing compiler triggered a download")
        require(!FileManager.default.fileExists(atPath: cache.path), "Existing compiler created a cache")
        rejects("invalid iasl download") {
            _ = try IASLCompiler.resolve(candidates: [], cache: cache) { staged in
                downloads += 1
                try Data("untrusted compiler".utf8).write(to: staged)
            }
        }
        let cacheEntries = try FileManager.default.contentsOfDirectory(atPath: cache.path)
        require(downloads == 1 && cacheEntries.isEmpty,
            "Failed compiler download left executable or staging files")
        let cached = cache.appendingPathComponent("iasl")
        try Data("preserve existing cache".utf8).write(to: cached)
        rejects("corrupt iasl cache") {
            _ = try IASLCompiler.resolve(candidates: [], cache: cache) { _ in downloads += 1 }
        }
        let preservedCache = try Data(contentsOf: cached)
        require(downloads == 1 && preservedCache == Data("preserve existing cache".utf8), "Resolver overwrote an existing compiler")
        let input = directory.appendingPathComponent("DSDT.dsl")
        let source = "Name (X, \"a b//c\") /* comment */\n"
        try source.write(to: input, atomically: true, encoding: .utf8)
        let decoded = try HardwareProfiles.readDSDTSource(input)
        require(decoded == source, "DSDT file reader changed source data")
        let repeated = String(repeating: source, count: 4096)
        require(HardwareProfiles.normalizedDSDT(repeated) == String(repeating: "Name(X,\"a b//c\")", count: 4096), "Incremental normalization changed quoted data")
        try Data([0xff]).write(to: input)
        rejects("invalid UTF-8 DSL") { _ = try HardwareProfiles.readDSDTSource(input) }
        let handle = try FileHandle(forWritingTo: input)
        try handle.truncate(atOffset: UInt64(HardwareProfiles.maxDSDTFileSize + 1))
        try handle.close()
        rejects("oversized DSL file") { _ = try HardwareProfiles.readDSDTSource(input) }
        try source.write(to: input, atomically: true, encoding: .utf8)
        let previousCompiler = UserDefaults.standard.object(forKey: "IASLPath")
        defer { UserDefaults.standard.set(previousCompiler, forKey: "IASLPath") }
        UserDefaults.standard.set("/usr/bin/false", forKey: "IASLPath")
        rejects("failed SSDT compiler") { _ = try ACPIExport.compileSSDT(input) }
        require(FileManager.default.fileExists(atPath: input.deletingPathExtension().appendingPathExtension("compile.log").path), "Compiler failure log was lost")
        let preserved = try String(contentsOf: input, encoding: .utf8)
        require(preserved == source, "Compiler failure changed the saved source")
        let logURL = input.deletingPathExtension().appendingPathExtension("compile.log")
        try FileManager.default.removeItem(at: logURL)
        try FileManager.default.createDirectory(at: logURL, withIntermediateDirectories: true)
        rejects("unwritable compiler log") { _ = try ACPIExport.compileSSDT(input) }
        try FileManager.default.removeItem(at: logURL)
        let compiler = directory.appendingPathComponent("fixture-iasl")
        var fixtureAML = Data(repeating: 0, count: 36)
        fixtureAML.replaceSubrange(0..<4, with: Data("SSDT".utf8))
        fixtureAML[4] = 36
        fixtureAML[8] = 2
        fixtureAML[9] = 0 &- fixtureAML.reduce(UInt8(0), { $0 &+ $1 })
        try fixtureAML.write(to: directory.appendingPathComponent("expected.aml"))
        let successfulCompiler = #"""
        #!/bin/sh
        printf 'compiler stdout\n'
        printf 'compiler stderr\n' >&2
        cp "${0%/*}/expected.aml" "${2%.*}.aml"
        """#
        try successfulCompiler.write(to: compiler, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: compiler.path)
        UserDefaults.standard.set(compiler.path, forKey: "IASLPath")
        _ = try ACPIExport.compileSSDT(input)
        let log = try String(contentsOf: logURL, encoding: .utf8)
        require(log.contains("compiler stdout") && log.contains("compiler stderr"), "Compiler log lost stdout or stderr")
        require(log.utf8.count <= 8 * 1024 * 1024, "Merged compiler log exceeded both stream bounds")
        let aml = try Data(contentsOf: input.deletingPathExtension().appendingPathExtension("aml"))
        require(aml == fixtureAML, "Compiler output was not preserved")
        try "#!/bin/sh\nexit 0\n".write(to: compiler, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: compiler.path)
        rejects("compiler success without an AML artifact") { _ = try ACPIExport.compileSSDT(input) }
        let preservedAML = try Data(contentsOf: input.deletingPathExtension().appendingPathExtension("aml"))
        require(preservedAML == fixtureAML, "Failed compilation changed an existing AML")
        let oversizedCompiler = "#!/bin/sh\n/usr/bin/head -c 4194305 /dev/zero\n"
        try oversizedCompiler.write(to: compiler, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: compiler.path)
        rejects("truncated SSDT compiler output") { _ = try ACPIExport.compileSSDT(input) }
        let boundedLog = try Data(contentsOf: logURL)
        require(boundedLog.count == 4 * 1024 * 1024, "Compiler output limit or retained log changed")
        let unchangedSource = try String(contentsOf: input, encoding: .utf8)
        require(unchangedSource == source, "Compiler success or truncation changed saved source")
    } catch { fatalError("DSDT file fixture failed: \(error)") }
    require(profiles.allSatisfy { $0["schema_version"] as? Int == 1 }, "Unsupported profile schema")
    require(HardwareProfiles.normalizedDSDT("Name (X, \"a b//c\") /* comment */") == "Name(X,\"a b//c\")", "Quoted AML data changed during normalization")
    require(HardwareProfiles.normalizedDSDT("Name (X, \"a b\")") != HardwareProfiles.normalizedDSDT("Name (X, \"ab\")"), "Distinct AML strings share a fingerprint")
    require(HardwareProfiles.maxDSDTFileSize == 16 * 1024 * 1024, "DSDT file size bound mismatch")
}

func testLaptopIdentity() {
    let legionIdentity = LaptopIdentity.resolve(strings: ["82N6CTO1WW"], pciIDs: [], lenovo: false)
    require(legionIdentity.name == "Lenovo Legion 7 2021 16ACHg6", "Machine type identity failed")
    require(LaptopIdentity.resolve(strings: ["MacBookPro16,3"], pciIDs: [], lenovo: false).name == "Unknown Laptop", "Spoofed SMBIOS leaked into identity")
    require(LaptopIdentity.resolve(strings: [], pciIDs: ["17aa:ffff"], lenovo: false).name == "Lenovo Laptop", "Lenovo PCI fallback failed")
    let identityProfiles: [[String: Any]] = [["kind": "acpi", "name": "Test Lenovo", "pci_subsystem_ids": ["17aa:1234"]]]
    require(LaptopIdentity.resolve(strings: [], pciIDs: ["17aa:1234"], lenovo: false, profiles: identityProfiles).name == "Test Lenovo", "PCI subsystem lookup failed")
    require(LaptopIdentity.resolve(strings: ["82N6", "82JQ"], pciIDs: [], lenovo: true).name == "Lenovo Laptop", "Ambiguous identity selected a model")
    require(LaptopIdentity.resolve(strings: ["20R20000US"], pciIDs: [], lenovo: false).name == "ThinkPad X1 Carbon Gen 7", "ThinkPad machine type lookup failed")
    require(LaptopIdentity.resolve(strings: ["ThinkPad X1 Carbon 7th"], pciIDs: [], lenovo: false).name == "ThinkPad X1 Carbon 7th", "ThinkPad brand name extraction failed")
    require(LaptopIdentity.resolve(strings: ["IdeaPad 5 15ARE05"], pciIDs: [], lenovo: false).name == "IdeaPad 5 15ARE05", "IdeaPad brand name extraction failed")
    require(LaptopIdentity.resolve(strings: ["Yoga Slim 7 14ARE05"], pciIDs: [], lenovo: false).name == "Yoga Slim 7 14ARE05", "Yoga brand name extraction failed")
    require(LaptopIdentity.resolve(strings: [], pciIDs: ["17aa:2292"], lenovo: false).name == "ThinkPad X1 Carbon Gen 7", "PCI catalog lookup failed")
    require(LaptopIdentity.resolve(strings: ["20L5CTO1WW"], pciIDs: [], lenovo: false).name == "ThinkPad T480", "ThinkPad T480 lookup failed")
    require(LaptopIdentity.resolve(strings: ["20ZZ123456"], pciIDs: [], lenovo: false).name == "ThinkPad (20ZZ)", "Unknown ThinkPad fallback failed")
    require(LaptopIdentity.resolve(strings: ["82ZZ0046US"], pciIDs: [], lenovo: false).name == "Lenovo (82ZZ)", "Unknown Lenovo machine type fallback failed")
    require(LaptopIdentity.resolve(strings: ["82WK0046US"], pciIDs: [], lenovo: false).name == "Lenovo Legion Pro 5 16IRX8", "Legion machine type lookup failed")
    require(LaptopIdentity.resolve(strings: ["20R2CTO1WW"], pciIDs: ["17aa:2250"], lenovo: true).name == "Lenovo Laptop", "Conflicting catalog machine and PCI identities selected a model")
    require(LaptopIdentity.resolve(strings: [], pciIDs: ["17aa:2250", "17aa:2292"], lenovo: true).name == "Lenovo Laptop", "Conflicting PCI identities selected an arbitrary model")
    require(LaptopIdentity.resolve(strings: ["20L5CTO1WW", "20R2CTO1WW"], pciIDs: [], lenovo: true).name == "Lenovo Laptop", "Conflicting machine identities selected the first model")
    require(LaptopIdentity.resolve(strings: ["20R2CTO1WW"], pciIDs: ["17AA:2292"], lenovo: true).name == "ThinkPad X1 Carbon Gen 7", "Matching catalog evidence did not converge")
    require(LaptopIdentity.resolve(strings: ["82N6CTO1WW"], pciIDs: ["17aa:2250"], lenovo: true).name == "Lenovo Laptop", "Catalog conflict was hidden by a reviewed profile")
    var mockSMBIOS = Data([1, 8, 0, 0, 1, 2, 0, 3])
    mockSMBIOS.append(contentsOf: "ThinkPad T480\020L5CTO1WW\0SERIAL_SECRET_123\0\0".utf8)
    require(LaptopIdentity.parseSMBIOS(data: mockSMBIOS) == ["ThinkPad T480", "20L5CTO1WW"], "SMBIOS string parsing failed")
    require(!LaptopIdentity.parseSMBIOS(data: mockSMBIOS).contains("SERIAL_SECRET_123"), "Serial leaked from SMBIOS")
    require(LaptopIdentity.parseSMBIOS(data: Data([1, 4, 0, 0, 0, 0])).isEmpty, "Empty SMBIOS strings failed")
    print("PASS laptop model lookup, PCI identity, ambiguity and fallbacks")
    require(LaptopIdentity.resolve(strings: ["MacBookPro16,2"], pciIDs: ["17aa:3a58"], lenovo: false).name == "Lenovo Legion 7 2021 16ACHg6", "Verified PCI identity did not survive SMBIOS spoofing")
}

func testACPINamespaceAndMatching() throws {
    require(ACPIExport.acpiNamespacePath("IOACPIPlane:/_SB/PCI0@0/LPCB/EC/HKEY") == "\\_SB.PCI0.LPCB.EC.HKEY", "ACPI registry path conversion failed")
    require(ACPIExport.acpiNamespacePath("\\_SB.PC00.LPCB.H_EC") == "\\_SB.PC00.LPCB.H_EC", "Valid non-default ACPI path was rejected")
    for invalid in ["", "\\", "\\_SB..EC", "\\_SB.EC\n", "\\_SB.BADNAME.EC", "IOACPIPlane:/_SB//EC", "IOACPIPlane:/@/EC", "IOService:/EC", "\\_SB.EC) { Name (X, 1) }"] {
        require(ACPIExport.acpiNamespacePath(invalid) == nil, "Invalid ACPI path was accepted: \(invalid)")
    }
    do {
        var namespace = ThinkPadACPI()
        try namespace.add("Device (EC0) { Name (_HID, EisaId (\"PNP0C09\")) Device (HKEY) {} }", table: "test")
        rejects("unproven EC layout") {
            _ = try namespace.plan(ecPath: "\\EC0", hkeyPath: "\\EC0.HKEY",
                live: Dictionary(uniqueKeysWithValues: ThinkPadACPI.helpers.keys.map { ($0, false) }), protocolLayout: [:], template: "")
        }
    } catch { fatalError("ThinkPad namespace parsing failed: \(error)") }
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
    rejects("oversized DSDT in matchingDSDT") { _ = try HardwareProfiles.matchingDSDT(String(repeating: " ", count: HardwareProfiles.maxDSDTFileSize + 1)) }
    rejects("truncated AML") { _ = try HardwareProfiles.matchingAML(Data("DSDT".utf8)) }
    rejects("unreviewed AML") { _ = try HardwareProfiles.matchingAML(Data("DSDT".utf8) + Data(repeating: 0, count: 64)) }
    if inputPaths.count > 1 {
        let table = try Data(contentsOf: URL(fileURLWithPath: inputPaths[1]))
        let profile = try HardwareProfiles.matchingAML(table)
        require(profile["id"] as? String == "legion7-16achg6-gkcn", "Wrong binary DSDT profile")
        print("PASS raw DSDT hash and live-export profile contract")
    }
}

func testHardwareSnapshot() {
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
}

func testHotkeys() {
    let modelHotkeys = HardwareProfiles.hotkeys(for: "legion7-16achg6-gkcn")
    let usbHotkeys = HardwareProfiles.hotkeys(for: "ite-c968-gen6")
    require(modelHotkeys?["id"] as? String == "legion7-gen6-hotkeys", "Embedded hotkeys missing for ACPI profile")
    require(usbHotkeys?["id"] as? String == modelHotkeys?["id"] as? String, "RGB hotkey association changed")
    require(HardwareProfiles.hotkeys(for: "unknown-device") == nil, "Unknown device inherited hotkeys")
    require(LegionHotkeys.rawAction(keycode: 111, physicalFnDown: false, mapping: ["111": "calculator"]) == nil, "Ordinary F12 must remain F12")
    require(LegionHotkeys.rawAction(keycode: 111, physicalFnDown: true, mapping: ["111": "calculator"]) == "calculator", "Physical Fn+F12 fallback missing")
    print("PASS ordinary F12 preservation and physical-Fn fallback")
}

func testRGBMatching() {
    let profile: [String: Any] = ["id": "rgb-192", "vendorID": 0x048d,
        "productID": 0xc968, "usagePage": 0xff89, "usage": 7, "reportSize": 192]
    let candidate = RGBMatchProfile(profile)!
    require(candidate.matches(vendorID: 0x048d, productID: 0xc968, usagePage: 0xff89, usage: 7), "Valid RGB identity rejected")
    for key in ["vendorID", "productID", "usagePage", "usage"] {
        var missing = profile
        missing.removeValue(forKey: key)
        require(RGBMatchProfile(missing) == nil, "Incomplete RGB identity accepted: \(key)")
        var malformed = profile
        malformed[key] = "invalid"
        require(RGBMatchProfile(malformed) == nil, "Malformed RGB identity accepted: \(key)")
    }
    let invalidIdentities: [(Int?, Int?, Int?)] = [(nil, 0xc968, 0xff89), (0x048d, nil, 0xff89), (0x048d, 0xc968, nil),
        (0, 0xc968, 0xff89), (0x048d, 0, 0xff89), (0x048d, 0xc968, 0)]
    for identity in invalidIdentities {
        require(!candidate.matches(vendorID: identity.0, productID: identity.1, usagePage: identity.2, usage: 7),
                "Missing or mismatched live RGB identity accepted")
    }
    require(!candidate.matches(vendorID: 0x048d, productID: 0xc968, usagePage: 0xff89, usage: 8), "Wrong HID usage accepted")
    var missingSize = profile
    missingSize.removeValue(forKey: "reportSize")
    var differentSize = profile
    differentSize["id"] = "rgb-64"
    differentSize["reportSize"] = 64
    let candidates = [missingSize, differentSize, profile].compactMap(RGBMatchProfile.init)
    require(candidates.count == 3 && candidates.allSatisfy {
        $0.matches(vendorID: 0x048d, productID: 0xc968, usagePage: 0xff89, usage: 7)
    }, "Registry identity matching must not require report size")
    require(candidates[0].reportSize == nil && candidates[0].reportSize != 192 && candidates[1].reportSize != 192,
            "Missing or wrong report size passed final RGB matching")
    for (size, expectedID) in [(64, "rgb-64"), (192, "rgb-192")] {
        let selected = candidates.first {
            $0.matches(vendorID: 0x048d, productID: 0xc968, usagePage: 0xff89, usage: 7) && $0.reportSize == size
        }
        require(selected?.profile["id"] as? String == expectedID, "RGB candidate lost report size or original profile")
    }
}

func testRGBReports() throws {
    let profiles = HardwareProfiles.all()
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
}

func testPowerInputAndRGBEffects() {
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
}

func testSMCTemperatureDecoding() {
    require(SMCTemperatureReader.decodeTemperature(type: "sp78", bytes: [80, 128]) == 80.5, "SMC sp78 fractional decode failed")
    require(SMCTemperatureReader.decodeTemperature(type: "sp78", bytes: [0, 0]) == nil, "Zero SMC reading accepted")
    require(SMCTemperatureReader.decodeTemperature(type: "sp78", bytes: [255, 0]) == nil, "Negative SMC sentinel accepted")
    require(SMCTemperatureReader.decodeTemperature(type: "ui16", bytes: [80, 0]) == nil, "Unknown SMC encoding accepted")
    require(SMCTemperatureReader.cpuTemperatureKeys(available: ["TC0G", "TC0E", "TC0P", "TCGC"], amd: true) == ["TC0E", "TC0P"],
            "CPU reader selected a placeholder or firmware GPU key")
}

func testSavedSettingsAndRGBBounds() throws {
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
    var oversizedRGB = savedColors
    oversizedRGB.perKey = Data(repeating: 0, count: SavedRGBSettings.maximumImportBytes + 1)
    require(!oversizedRGB.isValid, "Oversized RGB preferences accepted")
    let boundedRGBController = LegionRGBController()
    rejects("oversized RGB parser input") {
        try boundedRGBController.importColors(Data(repeating: 0, count: SavedRGBSettings.maximumImportBytes + 1))
    }
}

func testRGBLightingOwnership() {
    let activeLogoSettings = SavedRGBSettings(profileID: "ite-c968-gen6", mode: "Static", colors: ["Logo": "#FFFFFF"], logoEnabled: true)
    require(HardwareProfiles.lightingOwnedByRGB(key: "YLogoStatus", settings: activeLogoSettings, activeProfileID: "ite-c968-gen6"), "Active USB RGB profile must own YLogoStatus")
    let factoryLogoSettings = SavedRGBSettings(profileID: "ite-c968-gen6", mode: "Factory", colors: ["Logo": "#FFFFFF"], logoEnabled: true)
    require(!HardwareProfiles.lightingOwnedByRGB(key: "YLogoStatus", settings: factoryLogoSettings, activeProfileID: "ite-c968-gen6"), "Factory mode must release YLogoStatus to WMI")
    var malformedRGBSettings = activeLogoSettings; malformedRGBSettings.colors["Logo"] = "#xyz"
    require(!HardwareProfiles.lightingOwnedByRGB(key: "YLogoStatus", settings: malformedRGBSettings, activeProfileID: "ite-c968-gen6"), "Invalid RGB settings must not own lighting")
    require(!HardwareProfiles.lightingOwnedByRGB(key: "YLogoStatus", settings: nil, activeProfileID: "ite-c968-gen6"), "Nil RGB settings must not own lighting")
    require(!HardwareProfiles.lightingOwnedByRGB(key: "YLogoStatus", settings: activeLogoSettings, activeProfileID: "other-profile"), "Mismatched RGB profile must not own lighting")
    require(!HardwareProfiles.lightingOwnedByRGB(key: "YLogoStatus", settings: activeLogoSettings, activeProfileID: nil), "Missing USB RGB hardware must not own lighting")
    require(!HardwareProfiles.lightingOwnedByRGB(key: "PortLighting", settings: activeLogoSettings, activeProfileID: "ite-c968-gen6"), "Shipped ITE profile without PortLighting zone must not own PortLighting")
    let noLogoProfile: [[String: Any]] = [["kind": "rgb", "id": "test-no-logo", "zones": ["Keyboard": [:]]]]
    let noLogoSettings = SavedRGBSettings(profileID: "test-no-logo", mode: "Static", colors: ["Keyboard": "#FFFFFF"], logoEnabled: true)
    require(!HardwareProfiles.lightingOwnedByRGB(key: "YLogoStatus", settings: noLogoSettings, activeProfileID: "test-no-logo", profiles: noLogoProfile), "Profile missing Logo zone must not own YLogoStatus")
    let portZoneProfile: [[String: Any]] = [["kind": "rgb", "id": "test-port-zone", "zones": ["PortLighting": [:]]]]
    let portZoneSettings = SavedRGBSettings(profileID: "test-port-zone", mode: "Static", colors: ["PortLighting": "#FFFFFF"], logoEnabled: true)
    require(HardwareProfiles.lightingOwnedByRGB(key: "PortLighting", settings: portZoneSettings, activeProfileID: "test-port-zone", profiles: portZoneProfile), "Profile with PortLighting zone must own PortLighting")
    require(!HardwareProfiles.lightingOwnedByRGB(key: "SmartFanMode", settings: activeLogoSettings, activeProfileID: "ite-c968-gen6"), "Non-lighting controls must never be owned by USB RGB")
    print("PASS RGB lighting ownership predicate for active, factory, invalid, differentprofile and missingzone cases")
}

func testBatteryAndPanelPlacement() {
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
}

func testLocalization() {
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
}

func testDiagnostics() throws {
    let diagnosticSanitized = DiagnosticSnapshot.value(["SerialNumber": "private", "raw": Data([1, 2]), "missing": NSNull()]) as! [String: Any]
    require(diagnosticSanitized["SerialNumber"] as? String == "redacted", "Diagnostic serial was not redacted")
    require((diagnosticSanitized["raw"] as? [String: Any])?["bytes"] as? Int == 2, "Diagnostic binary length lost")

    let collectorFolder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: collectorFolder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: collectorFolder) }
    let collectedEcho = try DiagnosticCollector.run("/bin/echo", ["diagnostic-check"], name: "echo", folder: collectorFolder)
    require(collectedEcho["state"] as? String == "completed", "Diagnostic collector did not capture success")
    require(collectedEcho["exitStatus"] as? Int == 0, "Successful process exit must satisfy the ZIP export guard")
    let collectedFailure = try DiagnosticCollector.run("/bin/sh", ["-c", "exit 7"], name: "failure", folder: collectorFolder)
    require(collectedFailure["exitStatus"] as? Int == 7 && collectedFailure["state"] as? String == "command_failed",
            "Failed process exit must retain its code")
    #if os(macOS)
    let archive = collectorFolder.appendingPathComponent("diagnostics.zip")
    let contents = collectorFolder.appendingPathComponent("report")
    try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
    try Data("diagnostic-check".utf8).write(to: contents.appendingPathComponent("report.txt"))
    let package = try DiagnosticCollector.run("/usr/bin/ditto", ["-c", "-k", "--keepParent", contents.path, archive.path],
        name: "package", folder: collectorFolder)
    require(package["state"] as? String == "completed" && package["exitStatus"] as? Int == 0,
            "A successful ditto ZIP must pass the production export guard")
    let unpack = try DiagnosticCollector.run("/usr/bin/unzip", ["-p", archive.path, "report/report.txt"],
        name: "unpack", folder: collectorFolder)
    let unpacked = try Data(contentsOf: collectorFolder.appendingPathComponent("unpack.txt"))
    require(unpack["exitStatus"] as? Int == 0 && unpacked == Data("diagnostic-check".utf8), "Diagnostic ZIP is not readable")
    #endif
    let collectedMissing = try DiagnosticCollector.run("/nonexistent/reyoga", [], name: "missing", folder: collectorFolder)
    require(collectedMissing["state"] as? String == "launch_failed", "Diagnostic launch failure was hidden")
    let collectedTimeout = try DiagnosticCollector.run("/bin/sleep", ["5"], name: "timeout", folder: collectorFolder, timeout: 0.1)
    require(collectedTimeout["state"] as? String == "timeout", "Diagnostic command timeout failed")
    let collectedLimited = try DiagnosticCollector.run("/bin/sh",
        ["-c", "printf '123456789'; printf 'abcdefghi' >&2; exec /bin/sleep 5"],
        name: "limited", folder: collectorFolder, timeout: 2, maximumBytes: 8)
    require(collectedLimited["state"] as? String == "output_limit", "Running diagnostic output limit was ignored")
    require(Set((collectedLimited["truncatedStreams"] as? [String]) ?? []) == Set(["limited.txt", "limited.stderr.txt"]),
            "Diagnostic truncation must identify both streams")
    let limitedOutput = try Data(contentsOf: collectorFolder.appendingPathComponent("limited.txt"))
    let limitedErrors = try Data(contentsOf: collectorFolder.appendingPathComponent("limited.stderr.txt"))
    require(limitedOutput == Data("12345678".utf8) && limitedErrors == Data("abcdefgh".utf8),
            "Diagnostic output must preserve each bounded stream")
    let exitedLimited = try DiagnosticCollector.run("/bin/sh", ["-c", "printf '123456789'"],
        name: "exited-limited", folder: collectorFolder, maximumBytes: 8)
    require(exitedLimited["state"] as? String == "output_limit", "Exited command hid oversized output")
    require(exitedLimited["truncatedStreams"] as? [String] == ["exited-limited.txt"],
            "Exited command truncation lost stream identity")
    let exactOutput = try DiagnosticCollector.run("/bin/sh", ["-c", "printf '12345678'"],
        name: "exact", folder: collectorFolder, maximumBytes: 8)
    require(exactOutput["state"] as? String == "completed", "Exact output limit was rejected")
    let nestedDiagnostic = DiagnosticSnapshot.value(["items": [["SerialNumber": "private"]]]) as! [String: Any]
    require((nestedDiagnostic["items"] as? [[String: Any]])?.first?["SerialNumber"] as? String == "redacted", "Nested diagnostic recursion failed")
}

func testControlsPages() {
    let persisted: [(ControlsPage, Int)] = [(.settings, -1), (.overview, 0), (.device, 1),
        (.cooling, 2), (.battery, 3), (.lighting, 4), (.diagnostics, 5)]
    for (page, rawValue) in persisted {
        require(page.rawValue == rawValue && ControlsPage(rawValue: rawValue) == page, "Persisted controls page ID changed")
    }
    require(ControlsPage.sidebar.map { $0.rawValue } == [0, 1, 2, 3, 4, 5], "Sidebar order changed or includes Settings")
    for rawValue in [Int.min, -2, 6, Int.max] {
        require(ControlsPage(rawValue: rawValue) == nil, "Unknown controls page ID accepted")
        require((ControlsPage(rawValue: rawValue) ?? .overview) == .overview, "Unknown controls page lost Overview fallback")
    }
}

func testControlValueLabels() {
    for (value, label) in [(1, "Quiet"), (2, "Balanced"), (3, "Performance")] {
        require(controlValueLabel("SmartFanMode", target: value) == label, "Power profile label changed")
    }
    for (value, label) in [(0, "Off"), (1, "AC power"), (2, "AC + battery")] {
        require(controlValueLabel("AlwaysOnUSBState", target: value) == label, "USB power label changed")
    }
    for (key, values) in [("SmartFanMode", [-1, 0, 4]), ("AlwaysOnUSBState", [-1, 3])] {
        for value in values {
            require(controlValueLabel(key, target: value) == localizedMessage("Unknown (%@)", String(value)),
                    "Unknown control state became a known mode")
        }
    }
    for key in ["ChargeStartThreshold", "ChargeStopThreshold"] {
        require(controlValueLabel(key, target: 65) == "65%", "Charge threshold lost percent units")
    }
    require(controlValueLabel("BatteryIndex", target: 1) == "Primary", "Primary battery label changed")
    require(controlValueLabel("BatteryIndex", target: 2) == "Secondary", "Secondary battery label changed")
    require(controlValueLabel("BacklightLevel", target: 2) == "2", "Backlight level became a Boolean label")
    require(controlValueLabel("CPUPowerReset", target: 0) == "Restored", "CPU reset label changed")
    for key in ["Fan1TargetRPM", "Fan2TargetRPM"] {
        require(controlValueLabel(key, target: 3200) == localizedMessage("%@ RPM minimum", "3200"), "Fan target lost RPM minimum units")
    }
    for key in ["CPUBoostPower", "CPUSustainedPower"] {
        require(controlValueLabel(key, target: 45) == "45 W", "CPU power lost watt units")
    }
    for key in ["ConservationMode", "RapidChargeMode", "FnLock"] {
        require(controlValueLabel(key, target: 0) == "Off" && controlValueLabel(key, target: 1) == "On",
                "Boolean control label changed")
    }
}

func testPowerDraftMigration() throws {
    let suiteName = "ReYogaPowerDraftTests-" + UUID().uuidString
    let defaults = UserDefaults(suiteName: suiteName)!
    defer { defaults.removePersistentDomain(forName: suiteName) }
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: folder) }
    let bundleURL = folder.appendingPathComponent("DraftTests.bundle")
    let contents = bundleURL.appendingPathComponent("Contents")
    let resources = contents.appendingPathComponent("Resources")
    try FileManager.default.createDirectory(at: resources, withIntermediateDirectories: true)
    let info: [String: Any] = ["CFBundleIdentifier": "org.reyogasmc.tests.power-drafts", "CFBundlePackageType": "BNDL",
        "CFBundleDevelopmentRegion": "en", "CFBundleLocalizations": ["en", "vi"]]
    try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
        .write(to: contents.appendingPathComponent("Info.plist"))
    for (language, boost, sustained) in [("en", "Boost", "Sustained"), ("vi", "Tăng tốc", "Duy trì")] {
        let localization = resources.appendingPathComponent(language + ".lproj")
        try FileManager.default.createDirectory(at: localization, withIntermediateDirectories: true)
        let strings = [LocalizedKey.powerBoost.rawValue: boost, LocalizedKey.powerSustained.rawValue: sustained]
        try PropertyListSerialization.data(fromPropertyList: strings, format: .xml, options: 0)
            .write(to: localization.appendingPathComponent("Localizable.strings"))
    }
    let bundle = Bundle(url: bundleURL)!
    for (control, titleKey, title) in [("CPUBoostPower", LocalizedKey.powerBoost, "Boost"),
        ("CPUBoostPower", .powerBoost, "Tăng tốc"), ("CPUSustainedPower", .powerSustained, "Sustained"),
        ("CPUSustainedPower", .powerSustained, "Duy trì")] {
        defaults.removePersistentDomain(forName: suiteName)
        let legacyKey = "PowerDraft." + title
        defaults.set("45", forKey: legacyKey)
        let key = powerDraftStorageKey(control, titleKey: titleKey, defaults: defaults, bundle: bundle)
        require(key == "PowerDraft." + control && defaults.string(forKey: key) == "45", "Localized power draft did not migrate")
        require(defaults.string(forKey: legacyKey) == "45", "Power draft migration removed legacy key")
    }
    defaults.removePersistentDomain(forName: suiteName)
    let vietnamese = Bundle(url: resources.appendingPathComponent("vi.lproj"))!
    defaults.set("52", forKey: "PowerDraft.Tăng tốc")
    let currentKey = powerDraftStorageKey("CPUBoostPower", titleKey: .powerBoost, defaults: defaults, bundle: vietnamese)
    require(defaults.string(forKey: currentKey) == "52", "Current localized power draft did not migrate")
    defaults.set("44", forKey: currentKey)
    defaults.set("66", forKey: "PowerDraft.Boost")
    defaults.set("77", forKey: "PowerDraft.Tăng tốc")
    let stableKey = powerDraftStorageKey("CPUBoostPower", titleKey: .powerBoost, defaults: defaults, bundle: bundle)
    require(stableKey == currentKey && defaults.string(forKey: stableKey) == "44", "Legacy draft overwrote stable control key")
    require(defaults.string(forKey: "PowerDraft.Boost") == "66" && defaults.string(forKey: "PowerDraft.Tăng tốc") == "77",
            "Stable-key lookup changed legacy drafts")
    defaults.set("", forKey: stableKey)
    _ = powerDraftStorageKey("CPUBoostPower", titleKey: .powerBoost, defaults: defaults, bundle: bundle)
    require(defaults.string(forKey: stableKey) == "", "Empty stable draft was replaced by legacy draft")
    for (legacyTitle, control, titleKey) in [("Boost", "CPUSustainedPower", LocalizedKey.powerSustained),
        ("Sustained", "CPUBoostPower", .powerBoost)] {
        defaults.removePersistentDomain(forName: suiteName)
        defaults.set("60", forKey: "PowerDraft." + legacyTitle)
        let key = powerDraftStorageKey(control, titleKey: titleKey, defaults: defaults, bundle: bundle)
        require(defaults.object(forKey: key) == nil, "Power draft migrated across different controls")
    }
    defaults.removePersistentDomain(forName: suiteName)
    defaults.set("", forKey: "PowerDraft.Boost")
    let emptyKey = powerDraftStorageKey("CPUBoostPower", titleKey: .powerBoost, defaults: defaults, bundle: bundle)
    require(defaults.string(forKey: emptyKey) == "" && defaults.string(forKey: "PowerDraft.Boost") == "",
            "Empty legacy power draft was lost")
}

func testEventPersistence() {
    let suiteName = "ReYogaEventTests-" + UUID().uuidString
    let defaults = UserDefaults(suiteName: suiteName)!
    defer { defaults.removePersistentDomain(forName: suiteName) }
    func requireSameEvents(_ actual: [UInt32: [UInt32: EventDescriptor]], _ expected: [UInt32: [UInt32: EventDescriptor]]) {
        require(Set(actual.keys) == Set(expected.keys), "Event family keys changed")
        for (id, entries) in expected {
            require(Set(actual[id]?.keys.map { $0 } ?? []) == Set(entries.keys), "Event data keys changed")
            for (data, event) in entries {
                let restored = actual[id]?[data]
                require(restored?.name == event.name && restored?.action == event.action && restored?.display == event.display
                        && restored?.option == event.option && restored?.image == event.image, "Event descriptor changed during persistence")
            }
        }
    }
    let original: [UInt32: [UInt32: EventDescriptor]] = [0xabcd: [0x10:
        EventDescriptor("Fixture script", "/fixture/event.pdf", act: .script, display: false, opt: "return 1")],
        0x42: [0: EventDescriptor("Fixture calculator", act: .calculator)]]
    saveEvents(original, defaults: defaults)
    let serialized = defaults.dictionary(forKey: "Events")!
    require(Set(serialized.keys) == Set(["abcd", "42"]), "Event IDs must serialize as hexadecimal")
    let serializedEntries = serialized["abcd"] as! [String: Any]
    require(Set(serializedEntries.keys) == Set(["10"]), "Event data IDs must serialize as hexadecimal")
    let serializedEvent = serializedEntries["10"] as! [String: Any]
    require(serializedEvent["action"] as? String == "script" && serializedEvent["option"] as? String == "return 1"
            && serializedEvent["display"] as? Bool == false && serializedEvent["image"] as? String == "/fixture/event.pdf",
            "Serialized event lost action, option, display or external image path")
    var restored: [UInt32: [UInt32: EventDescriptor]] = [:]
    loadEvents(&restored, defaults: defaults)
    requireSameEvents(restored, original)

    let settingID = TP_HKEY_EV_SETTING.rawValue
    defaults.set([
        String(settingID, radix: 16): ["0": ["name": "Legacy settings", "action": "settings"]],
        "abcd": ["10": ["name": "Unknown placeholder", "action": "nothing", "option": "Unknown"],
                 "11": ["name": "Event 0xABCD", "action": "nothing"]],
        "ffff": ["0": ["name": "Future action", "action": "future_action"],
                 "1": ["name": "Event 0xFFFF", "action": "nothing", "option": "Unknown"]],
        "invalid": ["0": ["name": "Invalid ID", "action": "script"]],
        "1234": ["invalid": ["name": "Invalid data", "action": "script"], "0": ["name": "Missing action"]]
    ], forKey: "Events")
    let known: [UInt32: EventDescriptor] = [0x10: EventDescriptor("Known calculator", act: .calculator),
        0x11: EventDescriptor("Known spotlight", act: .spotlight)]
    restored = [0xabcd: known]
    loadEvents(&restored, defaults: defaults)
    require(restored[settingID]?[0]?.action == .systemsettings, "Legacy Settings event did not migrate to System Settings")
    requireSameEvents([0xabcd: restored[0xabcd]!], [0xabcd: known])
    require(restored[0xffff]?[0]?.action == .nothing && restored[0xffff]?[0]?.display == true,
            "Unknown action lost safe fallback or default display")
    require(restored[0xffff]?[1]?.option == "Unknown", "Unmapped unknown event was discarded")
    require(restored[0x1234]?.isEmpty == true && restored.count == 4, "Malformed event identifiers or missing action were accepted")

    for (family, expected) in [("IdeaVPC", ideaEvents), ("ThinkVPC", thinkEvents), ("ReYogaHIDD", HIDDEvents)] {
        saveEvents(original, defaults: defaults)
        resetDefaultEvents(&restored, ioClass: family, defaults: defaults)
        require(defaults.object(forKey: "Events") == nil, "Default reset left persisted event overrides")
        requireSameEvents(restored, expected)
        loadEvents(&restored, defaults: defaults)
        requireSameEvents(restored, expected)
    }
    saveEvents(original, defaults: defaults)
    restored = original
    resetDefaultEvents(&restored, ioClass: "UnknownVPC", defaults: defaults)
    requireSameEvents(restored, original)
    require(defaults.object(forKey: "Events") == nil, "Unknown family reset left persisted event overrides")
    defaults.set("invalid event dictionary", forKey: "Events")
    loadEvents(&restored, defaults: defaults)
    requireSameEvents(restored, original)
}

func probeRGB() throws {
    if CommandLine.arguments.contains("--probe-rgb") {
        let controller = LegionRGBController()
        controller.detect()
        print("RGB discovery:", controller.status.available, controller.status.reason)
        if controller.status.available { print("RGB read-only layout query:", try controller.inspectLayout()) }
    }
}

func probeSMC() {
    if CommandLine.arguments.contains("--probe-smc") {
        let reader = SMCTemperatureReader()
        if let reading = reader.cpuTemperature() { print("LIVE SMC CPU:", reading.celsius, reading.source) }
        else { print("LIVE SMC CPU unavailable:", reader.cpuReason) }
        if let reading = reader.gpuTemperature() { print("LIVE SMC GPU:", reading.celsius, reading.source) }
        else { print("LIVE SMC GPU unavailable:", reader.reason) }
    }
}

func probeIdentity() {
    if CommandLine.arguments.contains("--probe-identity") {
        let identity = LaptopIdentity.read()
        print("Live identity: \(identity.name) [\(identity.source)]")
    }
}

func testCapabilityBoundaries() {
    let unavailableRGB = HardwareFeatureStatus(available: false, reason: "Fixture", backend: "USB HID")
    let availableRGB = HardwareFeatureStatus(available: true, reason: "Fixture", backend: "USB HID")
    let profiles: [[String: Any]] = [["id": "fixture", "battery_conservation_mask": 32, "battery_rapidcharge_mask": 4]]
    var props: [String: Any] = [
        "IOClass": "IdeaVPC", "ControlProtocolVersion": 1, "HardwareProfile": "fixture",
        "FeatureStatus": ["CPUBoostPower": ["Available": true, "Backend": "WMI"],
                          "Fan1TargetRPM": ["Available": true, "Backend": "ACPI profile"],
                          "ConservationMode": ["Available": true, "Backend": "ACPI profile"]],
        "CPUBoostPower": 30, "PowerLimitRanges": ["CPUBoostPower": ["Min": 10, "Max": 50, "Step": 5]],
        "Fan1TargetRPM": 900, "Fan1MaxRPM": 3000, "Fan1TargetRPMStep": 100,
        "ACPIBridgeVersion": 2, "FanWritesValidated": true, "ConservationMode": true,
        "BatteryStateSchemaVersion": 4, "ConservationStateMask": 32, "RapidChargeStateMask": 4, "BatteryModeRaw": 32
    ]
    func capabilities(stale: Bool = false, rgb: HardwareFeatureStatus? = nil) -> HardwareCapabilities {
        HardwareCapabilities(props as NSDictionary, rgbStatus: rgb ?? unavailableRGB,
                             rgbMode: "Static", sampleIsStale: stale, profiles: profiles)
    }
    let valid = capabilities()
    require(valid.features["CPUBoostPower"]?.available == true, "Valid power range rejected")
    require(valid.features["Fan1TargetRPM"]?.available == true, "Validated fan range rejected")
    require(valid.conservationState == true && valid.rapidChargeState == false, "Battery masks changed")
    props["FanWritesValidated"] = false
    require(capabilities().features["Fan1TargetRPM"]?.available == false, "Unvalidated fan writes enabled")
    props["ConservationStateMask"] = 4
    require(capabilities().features["ConservationMode"]?.available == false, "Mismatched battery mapping accepted")
    require(capabilities().conservationState == nil, "Mismatched battery mapping fabricated state")
    props.removeValue(forKey: "CPUBoostPower")
    require(capabilities().features["CPUBoostPower"]?.available == false, "Missing current power value accepted")
    props["CPUBoostPower"] = 30
    props["PowerLimitRanges"] = ["CPUBoostPower": ["Min": 10, "Max": 50, "Step": 0]]
    require(capabilities().features["CPUBoostPower"]?.available == false, "Zero power step accepted")
    let stale = capabilities(stale: true, rgb: availableRGB)
    require(stale.features["CPUBoostPower"]?.available == false, "Stale firmware controls enabled")
    require(stale.features["YLogoStatus"]?.available == true, "Independent USB lighting lost to stale firmware")
}

testCapabilityBoundaries()
testProfilesAndDSDTFiles()
testLaptopIdentity()
try testACPINamespaceAndMatching()
testHardwareSnapshot()
testHotkeys()
testRGBMatching()
try testRGBReports()
testPowerInputAndRGBEffects()
testSMCTemperatureDecoding()
try testSavedSettingsAndRGBBounds()
testRGBLightingOwnership()
testBatteryAndPanelPlacement()
testLocalization()
try testDiagnostics()
testControlsPages()
testControlValueLabels()
try testPowerDraftMigration()
testEventPersistence()
print("All support tests passed")

try probeRGB()
probeSMC()
probeIdentity()
