import Foundation
import CryptoKit

enum IASLCompiler {
    // SSDTTime's macOS distribution, pinned to its universal, signed binary revision.
    static let downloadURL = "https://raw.githubusercontent.com/acidanthera/MaciASL/97ed950d2811b0b4cc802abc337316e16dd6aeeb/Dist/iasl-stable"
    static let sha256 = "93f1f48e6f1ea26b14b45f4a0b6e65a660c1cc6f14969348ec9411ae6b969c12"
    private static let lock = NSLock()
    private static let maximumBytes = 16 * 1024 * 1024

    static func installed(candidates: [String?]? = nil) -> URL? {
        let environment = ProcessInfo.processInfo.environment
        let pathCandidates = (environment["PATH"] ?? "").split(separator: ":").map { String($0) + "/iasl" }
        let defaults: [String?] = [UserDefaults.standard.string(forKey: "IASLPath"),
            FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("bin/iasl").path,
            "/opt/homebrew/bin/iasl", "/usr/local/bin/iasl"]
        let paths = candidates ?? (defaults + pathCandidates + ["/Applications/MaciASL.app/Contents/MacOS/iasl-stable"])
        return paths.compactMap { $0 }.first(where: {
            var directory: ObjCBool = false
            return FileManager.default.fileExists(atPath: $0, isDirectory: &directory) && !directory.boolValue &&
                FileManager.default.isExecutableFile(atPath: $0)
        }).map { URL(fileURLWithPath: $0) }
    }

    // Blocking work: callers run on a utility queue. Lock prevents competing cache installs.
    static func resolve(candidates: [String?]? = nil, cache: URL? = nil,
                        download: ((URL) throws -> Void)? = nil) throws -> URL {
        if let existing = installed(candidates: candidates) { return existing }
        lock.lock()
        defer { lock.unlock() }
        let files = FileManager.default
        let directory = try cache ?? files.url(for: .applicationSupportDirectory, in: .userDomainMask,
            appropriateFor: nil, create: true).appendingPathComponent("ReYogaSMC/Tools/iasl-97ed950d")
        try files.createDirectory(at: directory, withIntermediateDirectories: true)
        let executable = directory.appendingPathComponent("iasl")
        if files.fileExists(atPath: executable.path) {
            try validate(executable)
            guard files.isExecutableFile(atPath: executable.path) else {
                throw SupportError.message("Cached iasl is not executable. Remove the app's iasl cache and retry.")
            }
            return executable
        }
        let temporary = directory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try files.createDirectory(at: temporary, withIntermediateDirectories: false)
        defer { try? files.removeItem(at: temporary) }
        let staged = temporary.appendingPathComponent("iasl")
        if let download = download { try download(staged) }
        else {
            let result = try DiagnosticCollector.run("/usr/bin/curl", ["--fail", "--location",
                "--proto", "=https", "--proto-redir", "=https", "--connect-timeout", "15",
                "--max-time", "90", "--max-filesize", String(maximumBytes), "--output", staged.path,
                downloadURL], name: "download", folder: temporary, timeout: 100, maximumBytes: 64 * 1024)
            guard result["state"] as? String == "completed" else {
                let details = (try? String(contentsOf: temporary.appendingPathComponent("download.stderr.txt"), encoding: .utf8)) ?? ""
                ReYogaDiagnostics.shared.record("iasl_download_failed", ["result": result, "stderr": details])
                throw SupportError.message("Could not download iasl. Check your connection or set IASLPath to an existing compiler, then retry.")
            }
        }
        try validate(staged)
        try files.setAttributes([.posixPermissions: 0o700], ofItemAtPath: staged.path)
        // moveItem refuses replacement; never overwrite an existing compiler.
        try files.moveItem(at: staged, to: executable)
        return executable
    }

    private static func validate(_ executable: URL) throws {
        let input = try FileHandle(forReadingFrom: executable)
        defer { try? input.close() }
        let data = try input.read(upToCount: maximumBytes + 1) ?? Data()
        guard data.count <= maximumBytes,
              SHA256.hash(data: data).map({ String(format: "%02x", $0) }).joined() == sha256 else {
            throw SupportError.message("iasl checksum or size validation failed. The compiler was not installed or executed.")
        }
    }
}
