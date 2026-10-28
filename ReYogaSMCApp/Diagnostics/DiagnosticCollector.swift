import Foundation
import Darwin

enum DiagnosticSnapshot {
    static func value(_ value: Any) -> Any {
        if let data = value as? Data {
            guard data.count <= 1024 * 1024 else { return ["bytes": data.count, "omitted": "Binary exceeds diagnostic field limit"] }
            return ["encoding": "base64", "bytes": data.count, "data": data.base64EncodedString()]
        }
        if let dictionary = value as? NSDictionary {
            var result: [String: Any] = [:]
            for (key, item) in dictionary {
                guard let name = key as? String else { continue }
                if name == "ExportedDSDT" { continue }
                if name.localizedCaseInsensitiveContains("serial") || name == "IOPlatformUUID" {
                    result[name] = "redacted"
                } else { result[name] = Self.value(item) }
            }
            return result
        }
        if let array = value as? [Any] { return array.map(Self.value) }
        if value is String || value is NSNumber { return value }
        return ["unsupportedType": String(describing: type(of: value))]
    }
}

enum DiagnosticCollector {
    static func run(_ executable: String, _ arguments: [String], name: String, folder: URL,
                    timeout: TimeInterval = 15, maximumBytes: Int = 4 * 1024 * 1024) throws -> [String: Any] {
        let output = folder.appendingPathComponent(name + ".txt")
        let errors = folder.appendingPathComponent(name + ".stderr.txt")
        guard FileManager.default.createFile(atPath: output.path, contents: nil),
              FileManager.default.createFile(atPath: errors.path, contents: nil) else {
            throw CocoaError(.fileWriteUnknown)
        }
        let stdout = try FileHandle(forWritingTo: output)
        defer { try? stdout.close() }
        let stderr = try FileHandle(forWritingTo: errors)
        defer { try? stderr.close() }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = stdout
        process.standardError = stderr
        let start = ProcessInfo.processInfo.systemUptime
        var result: [String: Any] = ["executable": executable, "arguments": arguments,
            "startedAt": ISO8601DateFormatter().string(from: Date()), "timeoutSeconds": timeout,
            "maximumBytesPerStream": maximumBytes, "privileged": false]
        do { try process.run() }
        catch {
            result["state"] = "launch_failed"
            result["error"] = error.localizedDescription
            return result
        }
        var stopped: String?
        while process.isRunning {
            let elapsed = ProcessInfo.processInfo.systemUptime - start
            let outputSize = (try? FileManager.default.attributesOfItem(atPath: output.path)[.size] as? NSNumber)?.intValue ?? 0
            let errorSize = (try? FileManager.default.attributesOfItem(atPath: errors.path)[.size] as? NSNumber)?.intValue ?? 0
            if elapsed >= timeout || max(outputSize, errorSize) > maximumBytes {
                stopped = elapsed >= timeout ? "timeout" : "output_limit"
                process.terminate()
                let deadline = ProcessInfo.processInfo.systemUptime + 1
                while process.isRunning && ProcessInfo.processInfo.systemUptime < deadline {
                    Thread.sleep(forTimeInterval: 0.02)
                }
                if process.isRunning { kill(process.processIdentifier, SIGKILL) }
                break
            }
            Thread.sleep(forTimeInterval: 0.05)
        }
        process.waitUntilExit()
        var truncatedStreams: [String] = []
        for file in [output, errors] {
            let handle = try FileHandle(forWritingTo: file)
            defer { try? handle.close() }
            if try handle.seekToEnd() > UInt64(maximumBytes) {
                try handle.truncate(atOffset: UInt64(maximumBytes))
                truncatedStreams.append(file.lastPathComponent)
            }
        }
        result["state"] = stopped ?? (!truncatedStreams.isEmpty ? "output_limit" :
            process.terminationStatus == 0 ? "completed" : "command_failed")
        result["truncatedStreams"] = truncatedStreams
        result["exitStatus"] = process.terminationStatus
        result["terminationReason"] = process.terminationReason.rawValue
        result["elapsedSeconds"] = ProcessInfo.processInfo.systemUptime - start
        result["stdout"] = output.lastPathComponent
        result["stderr"] = errors.lastPathComponent
        return result
    }
    static func collectPrivileged(to folder: URL) throws -> [String: Any] {
        let commands: [(String, String)] = [
            ("dmesg", "/sbin/dmesg"),
            ("kernel-reyoga", "/usr/bin/log show --last 30m --style compact --info --debug --predicate 'process == \"kernel\" AND eventMessage CONTAINS[c] \"RYSMC\"'"),
            ("loaded-kexts", "/usr/bin/kmutil showloaded"),
            ("thermal", "/usr/bin/pmset -g therm"),
            ("cpu-power", "/usr/bin/powermetrics --samplers cpu_power -i 1000 -n 5")
        ]
        let command = commands.map { name, executable in
            "printf '\\n=== " + name + " ===\\n'; " + executable + " 2>&1; result=$?; printf '\\nexitStatus=%s\\n' \"$result\""
        }.joined(separator: "; ")
        let escaped = command.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        let script = "do shell script \"" + escaped + "\" with administrator privileges"
        var result = try run("/usr/bin/osascript", ["-e", script], name: "administrator-collection",
            folder: folder, timeout: 180, maximumBytes: 8 * 1024 * 1024)
        result["privileged"] = true
        result["authorization"] = "macOS administrator dialog; password never read or stored by app"
        result["scope"] = commands.map { $0.0 }
        result["limitations"] = "powermetrics is a five-second export-time sample, not a benchmark trace. Individual command failures are retained in output. Cancellation or authorization failure leaves unprivileged diagnostics available."
        return result
    }
    static func collect(to folder: URL) throws {
        let commands: [(String, String, [String])] = [
            ("kernel-reyoga", "/usr/bin/log", ["show", "--last", "30m", "--style", "compact", "--info", "--debug", "--predicate", "process == \"kernel\" AND eventMessage CONTAINS[c] \"RYSMC\""]),
            ("dmesg", "/sbin/dmesg", []),
            ("boot-args", "/usr/sbin/sysctl", ["kern.bootargs"]),
            ("system", "/usr/sbin/sysctl", ["kern.osrelease", "kern.osversion", "hw.model", "hw.memsize", "hw.ncpu", "machdep.cpu.brand_string"]),
            ("loaded-kexts", "/usr/bin/kmutil", ["showloaded"]),
            ("power-settings", "/usr/bin/pmset", ["-g", "custom"]),
            ("power-assertions", "/usr/bin/pmset", ["-g", "assertions"]),
            ("sip", "/usr/bin/csrutil", ["status"])
        ]
        var manifest: [[String: Any]] = []
        for (name, executable, arguments) in commands {
            manifest.append(try run(executable, arguments, name: name, folder: folder))
        }
        for provider in ["ThinkVPC", "IdeaVPC", "DYVPC", "ReYogaHIDD", "ReYogaSMC"] {
            manifest.append(try run("/usr/sbin/ioreg", ["-a", "-r", "-c", provider],
                name: "registry-" + provider, folder: folder))
        }
        manifest.append(try collectPrivileged(to: folder))
        let data = try PropertyListSerialization.data(fromPropertyList: ["schemaVersion": 2,
            "policy": "Fixed read-only commands. Administrator collection requires macOS authorization. No user-provided executable or output path is passed to root. Review output for identifiers before sharing. Empty registry output can mean provider absent.",
            "commands": manifest], format: .xml, options: 0)
        try data.write(to: folder.appendingPathComponent("collection-manifest.plist"))
    }
}
