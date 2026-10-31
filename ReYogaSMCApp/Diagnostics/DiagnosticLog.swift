import Foundation
import os.log

final class ReYogaDiagnostics {
    static let shared = ReYogaDiagnostics()
    let directory = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/ReYogaSMC", isDirectory: true)
    private let queue = DispatchQueue(label: "org.reyogasmc.diagnostics", qos: .utility)
    private let sessionID = UUID().uuidString
    private let log = OSLog(subsystem: "org.reyogasmc", category: "hardware")
    func export(_ report: [String: Any], to output: URL, completion: @escaping (Result<URL, Error>) -> Void) {
        queue.async {
            let folder = FileManager.default.temporaryDirectory.appendingPathComponent("ReYoga-" + UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: folder) }
            do {
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                var metadata = report
                if let table = metadata.removeValue(forKey: "DSDT") as? Data {
                    try table.write(to: folder.appendingPathComponent("DSDT.aml"))
                }
                let data = try PropertyListSerialization.data(fromPropertyList: DiagnosticSnapshot.value(metadata), format: .xml, options: 0)
                try data.write(to: folder.appendingPathComponent("report.plist"))
                for name in ["events.jsonl", "events.1.jsonl", "events.2.jsonl", "events.3.jsonl"] {
                    let source = self.directory.appendingPathComponent(name)
                    if FileManager.default.fileExists(atPath: source.path) {
                        try FileManager.default.copyItem(at: source, to: folder.appendingPathComponent(name))
                    }
                }
                try DiagnosticCollector.collect(to: folder)
                let signing = try DiagnosticCollector.run("/usr/bin/codesign", ["-d", "-r-", "--verbose=4", Bundle.main.bundlePath],
                    name: "signing", folder: folder, timeout: 15, maximumBytes: 1024 * 1024)
                try String(describing: signing["exitStatus"] ?? signing["state"] ?? "unknown")
                    .write(to: folder.appendingPathComponent("signing-status.txt"), atomically: true, encoding: .utf8)
                let temporaryArchive = folder.appendingPathExtension("zip")
                defer { try? FileManager.default.removeItem(at: temporaryArchive) }
                let packageLogs = FileManager.default.temporaryDirectory.appendingPathComponent("ReYogaPackage-" + UUID().uuidString)
                try FileManager.default.createDirectory(at: packageLogs, withIntermediateDirectories: true)
                defer { try? FileManager.default.removeItem(at: packageLogs) }
                let zip = try DiagnosticCollector.run("/usr/bin/ditto", ["-c", "-k", "--keepParent", folder.path, temporaryArchive.path],
                    name: "package", folder: packageLogs, timeout: 30)
                guard zip["state"] as? String == "completed", zip["exitStatus"] as? Int == 0 else {
                    self.record("diagnostic_package_failed", zip)
                    throw SupportError.message("Could not package diagnostics. Open Logs to inspect the local files.")
                }
                let archive = try Data(contentsOf: temporaryArchive)
                try archive.write(to: output, options: .atomic)
                DispatchQueue.main.async { completion(.success(output)) }
            } catch {
                self.record("diagnostic_export_failed", ["error": error.localizedDescription])
                DispatchQueue.main.async { completion(.failure(error)) }
            }
        }
    }
    func record(_ event: String, _ details: [String: Any]) {
        let captured = Date()
        let uptime = ProcessInfo.processInfo.systemUptime
        os_log("%{public}@", log: log, type: .info, event)
        queue.async {
            do {
                try FileManager.default.createDirectory(at: self.directory, withIntermediateDirectories: true)
                let file = self.directory.appendingPathComponent("events.jsonl")
                let size = (try? FileManager.default.attributesOfItem(atPath: file.path)[.size] as? NSNumber)?.intValue ?? 0
                if size > 2 * 1024 * 1024 {
                    for index in stride(from: 3, through: 1, by: -1) {
                        let source = self.directory.appendingPathComponent(index == 1 ? "events.jsonl" : "events.\(index - 1).jsonl")
                        let target = self.directory.appendingPathComponent("events.\(index).jsonl")
                        try? FileManager.default.removeItem(at: target)
                        if FileManager.default.fileExists(atPath: source.path) { try FileManager.default.moveItem(at: source, to: target) }
                    }
                }
                let record: [String: Any] = ["schemaVersion": 2, "sessionID": self.sessionID, "time": ISO8601DateFormatter().string(from: captured), "uptimeSeconds": uptime, "event": event, "details": DiagnosticSnapshot.value(details)]
                var data = try JSONSerialization.data(withJSONObject: record, options: [.sortedKeys])
                if data.count > 1024 * 1024 {
                    data = try JSONSerialization.data(withJSONObject: ["event": event, "sessionID": self.sessionID,
                        "time": ISO8601DateFormatter().string(from: captured), "uptimeSeconds": uptime,
                        "omitted": "Event exceeds 1 MiB; export registry snapshot", "originalBytes": data.count])
                }
                data.append(0x0a)
                if !FileManager.default.fileExists(atPath: file.path) { FileManager.default.createFile(atPath: file.path, contents: nil) }
                let handle = try FileHandle(forWritingTo: file)
                defer { try? handle.close() }
                try handle.seekToEnd()
                try handle.write(contentsOf: data)
            } catch {
                os_log("Diagnostic write failed: %{public}@", log: self.log, type: .error, error.localizedDescription)
            }
        }
    }
}
