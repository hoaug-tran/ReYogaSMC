import Foundation
import IOKit
import Security
import CryptoKit
import Darwin

enum FanAuthorization {
    private static let label = "org.reyoga.ReYogaSMC.FanAuthorization"

    // No password or bearer token is stored. The root-owned launch job pins this app build and user.
    static func authorize(service: io_service_t, completion: @escaping (Result<Void, Error>) -> Void) {
        var identity: UInt64 = 0
        guard IORegistryEntryGetRegistryEntryID(service, &identity) == kIOReturnSuccess else {
            completion(.failure(SupportError.message("Driver unavailable"))); return
        }
        ReYogaAuthorizeFan(identity) { status in
            if status == kIOReturnSuccess {
                DispatchQueue.main.async { completion(.success(())) }
                return
            }
            DispatchQueue.main.async {
                do {
                    try install()
                    // launchd starts on demand; one bounded retry follows installation.
                    ReYogaAuthorizeFan(identity) { retry in
                        DispatchQueue.main.async {
                            if retry == kIOReturnSuccess { completion(.success(())) }
                            else { completion(.failure(SupportError.message(localizedMessage(
                                "Fan authorization failed (0x%08x). Reconnect the driver and retry authorization.", retry)))) }
                        }
                    }
                } catch { completion(.failure(error)) }
            }
        }
    }

    private static func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    private static func install() throws {
        let helper = Bundle.main.bundleURL.appendingPathComponent("Contents/Library/LaunchServices/" + label)
        let descriptor = open(helper.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
        guard descriptor >= 0 else {
            throw SupportError.message("The fan authorization helper is missing or invalid. Reinstall the app.")
        }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer { try? handle.close() }
        var attributes = stat()
        guard fstat(descriptor, &attributes) == 0, attributes.st_mode & S_IFMT == S_IFREG,
              attributes.st_size > 0, attributes.st_size <= 16 * 1024 * 1024,
              let helperData = try handle.read(upToCount: 16 * 1024 * 1024 + 1),
              helperData.count == Int(attributes.st_size) else {
            throw SupportError.message("The fan authorization helper is missing or invalid. Reinstall the app.")
        }
        let digest = SHA256.hash(data: helperData).map { String(format: "%02x", $0) }.joined()
        var code: SecCode?
        var staticCode: SecStaticCode?
        var signing: CFDictionary?
        guard SecCodeCopySelf([], &code) == errSecSuccess, let code = code,
              SecCodeCheckValidity(code, SecCSFlags(rawValue: kSecCSStrictValidate), nil) == errSecSuccess,
              SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode = staticCode,
              SecCodeCopySigningInformation(staticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &signing) == errSecSuccess,
              let info = signing as? [String: Any], let hash = info[kSecCodeInfoUnique as String] as? Data,
              hash.count == 20 else {
            throw SupportError.message("Fan authorization requires a valid app signature. Reinstall a signed app build.")
        }
        let requirement = "cdhash H\"" + hash.map { String(format: "%02x", $0) }.joined() + "\""
        let binary = "/Library/PrivilegedHelperTools/" + label
        let plist = "/Library/LaunchDaemons/" + label + ".plist"
        let job: [String: Any] = ["Label": label, "ProgramArguments": [binary, requirement, String(getuid())],
                                  "MachServices": [label: true], "UserName": "root", "ProcessType": "Interactive",
                                  "ExitTimeOut": 5]
        let encoded = try PropertyListSerialization.data(fromPropertyList: job, format: .xml, options: 0).base64EncodedString()
        // Copy into a root-only staging directory, then verify bytes before executing anything.
        let command = """
        set -eu
        for parent in /Library/PrivilegedHelperTools /Library/LaunchDaemons; do
            test ! -L "$parent"
            if test ! -d "$parent"; then /usr/bin/install -d -o root -g wheel -m 755 "$parent"; fi
            case "$(/usr/bin/stat -f '%u:%Lp' "$parent")" in 0:755|0:700) ;; *) exit 1 ;; esac
        done
        test ! -L \(shellQuote(binary))
        test ! -d \(shellQuote(binary))
        test ! -L \(shellQuote(plist))
        test ! -d \(shellQuote(plist))
        stage=$(/usr/bin/mktemp -d /Library/PrivilegedHelperTools/.reyoga-fan.XXXXXXXX)
        trap '/bin/rm -rf "$stage"' EXIT
        /usr/bin/install -o root -g wheel -m 755 \(shellQuote(helper.path)) "$stage/helper"
        test "$(/usr/bin/shasum -a 256 "$stage/helper" | /usr/bin/awk '{print $1}')" = \(shellQuote(digest))
        /usr/bin/codesign --verify --strict "$stage/helper"
        /usr/bin/printf '%s' \(shellQuote(encoded)) | /usr/bin/base64 -D > "$stage/job.plist"
        /usr/bin/plutil -lint "$stage/job.plist" > /dev/null
        /bin/chmod 644 "$stage/job.plist"
        /bin/launchctl bootout \(shellQuote("system/" + label)) 2>/dev/null || true
        /bin/mv -f "$stage/helper" \(shellQuote(binary))
        /bin/mv -f "$stage/job.plist" \(shellQuote(plist))
        /bin/launchctl bootstrap system \(shellQuote(plist))
        """
        let literal = command.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        guard let script = NSAppleScript(source: "do shell script \"" + literal + "\" with administrator privileges") else {
            throw SupportError.message("Could not request administrator authorization.")
        }
        var error: NSDictionary?
        _ = script.executeAndReturnError(&error)
        if let error = error {
            let number = error[NSAppleScript.errorNumber] as? Int ?? 0
            if number == -128 { throw SupportError.message("Fan authorization was cancelled. Fan controls remain unavailable.") }
            let detail = String((error[NSAppleScript.errorMessage] as? String ?? "").prefix(4096))
            throw SupportError.message(localizedMessage("Could not install the fan authorization helper (%@): %@", String(number), detail))
        }
    }
}
