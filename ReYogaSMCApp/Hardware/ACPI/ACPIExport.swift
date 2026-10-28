import Foundation
import IOKit
import CryptoKit

enum ACPIExport {
    static func compileSSDT(_ output: URL, compiler existingCompiler: URL? = nil) throws -> [String: Any] {
        let compiler = try existingCompiler ?? IASLCompiler.resolve()
        let logURL = output.deletingPathExtension().appendingPathExtension("compile.log")
        guard FileManager.default.createFile(atPath: logURL.path, contents: nil) else {
            throw CocoaError(.fileWriteUnknown)
        }
        let handle = try FileHandle(forWritingTo: logURL)
        defer { try? handle.close() }
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("ReYogaCompile-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let stagedSource = folder.appendingPathComponent(output.lastPathComponent)
        try HardwareProfiles.readDSDTSource(output).write(to: stagedSource, atomically: true, encoding: .utf8)
        let maximumBytesPerStream = 4 * 1024 * 1024
        let compilation = Result {
            try DiagnosticCollector.run(compiler.path, ["-tc", stagedSource.path],
                name: "compile", folder: folder, timeout: 30, maximumBytes: maximumBytesPerStream)
        }
        var logTruncated = false
        for suffix in [".txt", ".stderr.txt"] {
            let stream = folder.appendingPathComponent("compile" + suffix)
            if FileManager.default.fileExists(atPath: stream.path) {
                let input = try FileHandle(forReadingFrom: stream)
                defer { try? input.close() }
                // Runner cleanup can throw before truncation; bound copied logs independently.
                let data = try input.read(upToCount: maximumBytesPerStream + 1) ?? Data()
                logTruncated = logTruncated || data.count > maximumBytesPerStream
                try handle.write(contentsOf: data.prefix(maximumBytesPerStream))
            }
        }
        let result = try compilation.get()
        if result["state"] as? String == "launch_failed", let error = result["error"] as? String {
            throw SupportError.message(error)
        }
        guard !logTruncated, result["state"] as? String == "completed",
              (result["truncatedStreams"] as? [String])?.isEmpty == true else {
            throw SupportError.message("SSDT compilation failed. The source and compile.log are saved for inspection.")
        }
        let artifact = try FileHandle(forReadingFrom: stagedSource.deletingPathExtension().appendingPathExtension("aml"))
        defer { try? artifact.close() }
        let aml = try artifact.read(upToCount: 1024 * 1024 + 1) ?? Data()
        try ThinkPadACPI.validateTable(aml, signature: "SSDT")
        try aml.write(to: output.deletingPathExtension().appendingPathExtension("aml"), options: .atomic)
        return result
    }
    static func exportLiveBridge(service: io_service_t, output: URL, completion: @escaping (Result<URL, Error>) -> Void) {
        guard service != 0, IOObjectRetain(service) == kIOReturnSuccess else {
            completion(.failure(SupportError.message("Driver unavailable"))); return
        }
        DispatchQueue.global(qos: .utility).async {
            defer { IOObjectRelease(service) }
            do {
                let transport = IORegistryEntrySetCFProperty(service, "ExportDSDT" as CFString, kCFBooleanTrue)
                let data = IORegistryEntryCreateCFProperty(service, "ExportedDSDT" as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? Data
                _ = IORegistryEntrySetCFProperty(service, "ExportDSDT" as CFString, kCFBooleanFalse)
                guard transport == kIOReturnSuccess, let table = data else { throw SupportError.message("The driver could not export DSDT. Check ACPIExportStatus and the kernel log.") }
                let profile = try HardwareProfiles.matchingAML(table)
                let source = try HardwareProfiles.render(profile)
                try source.write(to: output, atomically: true, encoding: .utf8)
                _ = try compileSSDT(output)
                ReYogaDiagnostics.shared.record("live_acpi_generated", ["profile": profile["id"] ?? "unknown", "compiled": true])
                DispatchQueue.main.async { completion(.success(output)) }
            } catch {
                ReYogaDiagnostics.shared.record("live_acpi_generation_failed", ["error": error.localizedDescription])
                DispatchQueue.main.async { completion(.failure(error)) }
            }
        }
    }
    static func acpiNamespacePath(_ path: String) -> String? {
        let components: [String]
        if path.hasPrefix("IOACPIPlane:/") {
            components = path.dropFirst("IOACPIPlane:/".count).split(separator: "/", omittingEmptySubsequences: false)
                .map { String($0.prefix { $0 != "@" }) }
        } else if path.hasPrefix("\\") {
            components = path.dropFirst().components(separatedBy: ".")
        } else { return nil }
        guard !components.isEmpty, components.allSatisfy({
            $0.range(of: "^[A-Z_][A-Z0-9_]{0,3}\\z", options: .regularExpression) != nil
        }) else { return nil }
        return "\\" + components.joined(separator: ".")
    }
    static func captureThinkPadACPI(service: io_service_t) throws -> (tables: [Data], evidence: [String: Any]) {
        guard getNumber("ThinkPadACPIAnalysisVersion", service) == 1 else {
            throw SupportError.message("Update the driver to capture the running ACPI tables and namespace evidence.")
        }
        let status = IORegistryEntrySetCFProperty(service, "ExportACPITables" as CFString, kCFBooleanTrue)
        defer {
            let cleanup = IORegistryEntrySetCFProperty(service, "ExportACPITables" as CFString, kCFBooleanFalse)
            if cleanup != kIOReturnSuccess { ReYogaDiagnostics.shared.record("acpi_capture_cleanup_failed", ["status": cleanup]) }
        }
        guard status == kIOReturnSuccess,
              let tables = IORegistryEntryCreateCFProperty(service, "ExportedACPITables" as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? [Data],
              let evidence = IORegistryEntryCreateCFProperty(service, "ThinkPadACPIEvidence" as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? [String: Any] else {
            ReYogaDiagnostics.shared.record("acpi_capture_failed", ["transportStatus": status,
                "driverStatus": getNumber("ACPIExportStatus", service), "safeMode": getBoolean("SafeMode", service)])
            throw SupportError.message("ACPI capture failed. Check driver permissions, Safe Mode and ACPIExportStatus.")
        }
        try ThinkPadACPI.validateTables(tables)
        return (tables, evidence)
    }
    static func acpiDigest(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
    static func exportThinkPadSSDT(service: io_service_t, output: URL, completion: @escaping (Result<URL, Error>) -> Void) {
        guard service != 0, IOObjectRetain(service) == kIOReturnSuccess else {
            completion(.failure(SupportError.message("Driver unavailable"))); return
        }
        DispatchQueue.global(qos: .utility).async {
            defer { IOObjectRelease(service) }
            let folder = FileManager.default.temporaryDirectory.appendingPathComponent("ReYogaACPI-" + UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: folder) }
            var report: [String: Any] = ["schemaVersion": 1, "stage": "capture"]
            let reportURL = output.deletingPathExtension().appendingPathExtension("analysis.json")
            do {
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                let captured = try captureThinkPadACPI(service: service)
                guard let ec = captured.evidence["ECPath"] as? String, let hkey = captured.evidence["HKEYPath"] as? String,
                      let ecPath = acpiNamespacePath(ec), let hkeyPath = acpiNamespacePath(hkey) else {
                    throw SupportError.message("The driver did not report valid EC and HKEY ACPI paths. Reconnect with a matching driver before generating an SSDT.")
                }
                report["liveEvidence"] = captured.evidence
                report["tables"] = captured.tables.enumerated().map { ["index": $0.offset, "sha256": acpiDigest($0.element), "bytes": $0.element.count] }
                var inputs: [String] = []
                for (index, table) in captured.tables.enumerated() {
                    let input = folder.appendingPathComponent(String(format: "table-%03d.aml", index))
                    try table.write(to: input); inputs.append(input.path)
                }
                report["stage"] = "compiler"
                let compiler = try IASLCompiler.resolve()
                report["stage"] = "disassembly"
                var namespace = ThinkPadACPI(), totalSource = 0
                var disassemblies: [[String: Any]] = []
                let disassemblyStarted = ProcessInfo.processInfo.systemUptime
                for (index, input) in inputs.enumerated() {
                    let remaining = 60 - (ProcessInfo.processInfo.systemUptime - disassemblyStarted)
                    guard remaining > 0 else { throw SupportError.message("ACPI disassembly failed or timed out. Review the analysis report.") }
                    let context = inputs.filter { $0 != input }
                    let arguments = ["-dl"] + (context.isEmpty ? [] : ["-e"] + context) + ["-d", input]
                    let name = String(format: "disassembly-%03d", index)
                    var disassembly = try DiagnosticCollector.run(compiler.path, arguments,
                        name: name, folder: folder, timeout: min(15, remaining), maximumBytes: 256 * 1024)
                    disassembly["stdoutText"] = (try? String(contentsOf: folder.appendingPathComponent(name + ".txt"), encoding: .utf8)) ?? ""
                    disassembly["stderrText"] = (try? String(contentsOf: folder.appendingPathComponent(name + ".stderr.txt"), encoding: .utf8)) ?? ""
                    disassemblies.append(disassembly); report["disassembly"] = disassemblies
                    guard disassembly["state"] as? String == "completed" else { throw SupportError.message("ACPI disassembly failed or timed out. Review the analysis report.") }
                    let source = try HardwareProfiles.readDSDTSource(URL(fileURLWithPath: input).deletingPathExtension().appendingPathExtension("dsl"))
                    totalSource += source.utf8.count
                    guard totalSource <= 64 * 1024 * 1024 else { throw SupportError.message("Combined ACPI source exceeds the analysis limit") }
                    try namespace.add(source, table: URL(fileURLWithPath: input).lastPathComponent)
                }
                report["stage"] = "namespace"
                report["namespace"] = namespace.objects.map { ["path": "\\" + $0.path, "kind": $0.kind,
                    "table": $0.table, "line": $0.line, "arguments": $0.arguments ?? -1] }
                let template = try String(contentsOf: (HardwareProfiles.directory ?? URL(fileURLWithPath: "HardwareProfiles"))
                    .appendingPathComponent("SSDT-ThinkPad.template.dsl"), encoding: .utf8)
                let live = captured.evidence.compactMapValues { $0 as? Bool }
                let protocolLayout = captured.evidence.compactMapValues { $0 as? Int }
                let plan = try namespace.plan(ecPath: ecPath, hkeyPath: hkeyPath, live: live, protocolLayout: protocolLayout, template: template)
                report.merge(plan.report) { _, new in new }
                let sourceURL = folder.appendingPathComponent("SSDT-ThinkPad.dsl")
                try plan.source.write(to: sourceURL, atomically: true, encoding: .utf8)
                report["stage"] = "compile"
                report["compilation"] = try compileSSDT(sourceURL, compiler: compiler)
                report["compileLog"] = try String(contentsOf: sourceURL.deletingPathExtension().appendingPathExtension("compile.log"), encoding: .utf8)
                let aml = try Data(contentsOf: sourceURL.deletingPathExtension().appendingPathExtension("aml"))
                try ThinkPadACPI.validateTables([captured.tables[0], aml])
                report["stage"] = "compiled_not_installed"
                report["generatedSHA256"] = acpiDigest(aml)
                report["normalizedSHA256"] = acpiDigest(ThinkPadACPI.normalizedAML(aml))
                try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]).write(to: reportURL, options: .atomic)
                try plan.source.write(to: output, atomically: true, encoding: .utf8)
                try aml.write(to: output.deletingPathExtension().appendingPathExtension("aml"), options: .atomic)
                ReYogaConstants.hardwareDefaults.set(["amlSHA256": acpiDigest(aml), "normalizedSHA256": acpiDigest(ThinkPadACPI.normalizedAML(aml)), "helpers": plan.report["added"] ?? []],
                    forKey: "ThinkPadACPI." + acpiDigest(captured.tables[0]))
                ReYogaDiagnostics.shared.record("thinkpad_acpi_generated", report)
                DispatchQueue.main.async {
                    completion(.success(output))
                }
            } catch {
                report["error"] = error.localizedDescription
                report["compileLog"] = (try? String(contentsOf: folder.appendingPathComponent("SSDT-ThinkPad.compile.log"), encoding: .utf8)) ?? ""
                try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]).write(to: reportURL, options: .atomic)
                ReYogaDiagnostics.shared.record("thinkpad_acpi_generation_failed", report)
                DispatchQueue.main.async { completion(.failure(error)) }
            }
        }
    }
    static func verifyThinkPadSSDT(service: io_service_t, completion: @escaping (String) -> Void) {
        guard service != 0, IOObjectRetain(service) == kIOReturnSuccess else {
            completion(localizedMessage("Driver unavailable")); return
        }
        DispatchQueue.global(qos: .utility).async {
            defer { IOObjectRelease(service) }
            do {
                let captured = try captureThinkPadACPI(service: service)
                let expected = ReYogaConstants.hardwareDefaults.dictionary(forKey: "ThinkPadACPI." + acpiDigest(captured.tables[0]))
                let hashes = captured.tables.dropFirst().map { acpiDigest(ThinkPadACPI.normalizedAML($0)) }
                try ThinkPadACPI.verify(expectedDigest: expected?["normalizedSHA256"] as? String, loadedDigests: hashes, live: captured.evidence)
                let refresh = IORegistryEntrySetCFProperty(service, "UpdateFans" as CFString, kCFBooleanTrue)
                guard refresh == kIOReturnSuccess else {
                    ReYogaDiagnostics.shared.record("acpi_verification_readback_denied", ["transportStatus": refresh])
                    throw SupportError.message("SSDT helpers are loaded but fan readback is unavailable. Export diagnostics and inspect ThinkFanStatus.")
                }
                let telemetry = IORegistryEntryCreateCFProperty(service, "ThinkFanTelemetry" as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? [String: Any]
                guard let sample = ThinkFanSnapshot(telemetry), sample.isCurrent(at: ProcessInfo.processInfo.systemUptime, after: 0),
                      sample.main.control != nil, sample.main.rpm != nil else {
                    throw SupportError.message("SSDT helpers are loaded but fan readback is unavailable. Export diagnostics and inspect ThinkFanStatus.")
                }
                ReYogaDiagnostics.shared.record("thinkpad_acpi_verified", ["expected": expected ?? [:], "evidence": captured.evidence,
                    "fanControl": sample.main.control ?? 0xff, "rpm": sample.main.rpm ?? -1])
                DispatchQueue.main.async { completion("SSDT loaded, EC helpers and fan readback confirmed. Fan writes still require a hardware test.") }
            } catch {
                ReYogaDiagnostics.shared.record("thinkpad_acpi_verification_failed", ["error": error.localizedDescription])
                DispatchQueue.main.async { completion(error.localizedDescription) }
            }
        }
    }
    static func exportBridge(input: URL, output: URL, completion: @escaping (Result<URL, Error>) -> Void) {
        DispatchQueue.global(qos: .utility).async {
            do {
                guard input.resolvingSymlinksInPath().standardizedFileURL != output.resolvingSymlinksInPath().standardizedFileURL else {
                    throw SupportError.message("Choose a different output file to preserve the original DSDT source.")
                }
                let source = try HardwareProfiles.readDSDTSource(input)
                let profile = try HardwareProfiles.matchingDSDT(source)
                let generated = try HardwareProfiles.render(profile)
                try generated.write(to: output, atomically: true, encoding: .utf8)
                _ = try compileSSDT(output)
                ReYogaDiagnostics.shared.record("acpi_generated", ["profile": profile["id"] ?? "unknown",
                    "validation": profile["validation"] ?? "unknown", "compiled": true])
                DispatchQueue.main.async { completion(.success(output)) }
            } catch {
                ReYogaDiagnostics.shared.record("acpi_generation_failed", ["error": error.localizedDescription])
                DispatchQueue.main.async { completion(.failure(error)) }
            }
        }
    }
}
