import Foundation

// Static namespace evidence only: expressions are never executed or used to guess EC writes.
struct ThinkPadACPI {
    struct Object {
        let path: String
        let kind: String
        let arguments: Int?
        let table: String
        let line: Int
        let value: [String]
        let range: NSRange
        let bitOffset: Int?
        let bitWidth: Int?
        let region: String?
    }
    struct Token {
        let text: String
        let range: NSRange
        let line: Int
    }
    struct Plan {
        let source: String
        let report: [String: Any]
    }
    static let helpers = ["CSSI": 1, "RE1B": 1, "WE1B": 2, "RECB": 2, "WECB": 3]
    private(set) var objects: [Object] = []
    private(set) var warnings: [String] = []

    static func normalizedAML(_ table: Data) -> Data {
        var bytes = [UInt8](table)
        guard bytes.count >= 36 else { return table }
        bytes[9] = 0
        // Permit only the known OpenCore OSI rename when recognizing our installed table.
        for index in 0...(bytes.count - 4) where bytes[index] == 0x58 && bytes[index + 1] == 0x4f && bytes[index + 2] == 0x53 && bytes[index + 3] == 0x49 {
            bytes[index] = 0x5f
        }
        return Data(bytes)
    }

    static func verify(expectedDigest: String?, loadedDigests: [String], live: [String: Any]) throws {
        guard let expectedDigest = expectedDigest else { throw SupportError.message("No generated SSDT is recorded for this firmware.") }
        guard loadedDigests.contains(expectedDigest) else {
            throw SupportError.message("Generated SSDT is not loaded for this firmware. Check OpenCore ACPI Add and reboot.")
        }
        guard helpers.keys.allSatisfy({ live[$0] as? Bool == true }), live["ECCapability"] as? String == "RW" else {
            throw SupportError.message("SSDT is loaded but its helpers or EC write capability are unavailable. Export diagnostics.")
        }
    }

    static func validateTables(_ tables: [Data]) throws {
        guard !tables.isEmpty, tables.count <= 256, tables.reduce(0, { $0 + $1.count }) <= 16 * 1024 * 1024 else {
            throw SupportError.message("ACPI table capture is empty or exceeds the analysis limit")
        }
        for (index, table) in tables.enumerated() {
            let bytes = [UInt8](table)
            guard bytes.count >= 36, bytes.count <= 1024 * 1024,
                  table.prefix(4) == Data((index == 0 ? "DSDT" : "SSDT").utf8) else {
                throw SupportError.message("Unexpected ACPI table signature or size")
            }
            let length = (0..<4).reduce(UInt32(0)) { $0 | UInt32(bytes[4 + $1]) << (8 * $1) }
            guard Int(length) == bytes.count, bytes.reduce(UInt8(0), { $0 &+ $1 }) == 0 else {
                throw SupportError.message("ACPI table length or checksum is invalid")
            }
        }
    }

    static func path(_ name: String, scope: String) throws -> String {
        var parts = scope.split(separator: ".").map(String.init)
        var relative = name
        if relative.hasPrefix("\\") { parts = []; relative.removeFirst() }
        while relative.hasPrefix("^") {
            guard !parts.isEmpty else { throw SupportError.message("ACPI parent path escapes the root") }
            parts.removeLast(); relative.removeFirst()
        }
        for component in relative.split(separator: ".", omittingEmptySubsequences: false) {
            guard component.range(of: "^[A-Z_][A-Z0-9_]{0,3}$", options: .regularExpression) != nil else {
                throw SupportError.message(localizedMessage("Invalid ACPI namespace path: %@", name))
            }
            // AML pads NameSegs to four characters; EC and EC__ are the same name.
            let canonical = String(component).replacingOccurrences(of: "_+$", with: "", options: .regularExpression)
            parts.append(canonical.isEmpty ? String(component) : canonical)
        }
        return parts.joined(separator: ".")
    }

    static func tokens(_ source: String) throws -> [Token] {
        guard source.utf8.count <= 16 * 1024 * 1024 else { throw SupportError.message("ACPI source exceeds 16 MiB") }
        let pattern = #""(?:\\.|[^"\\])*"|/\*.*?\*/|//[^\n]*|[\\^A-Za-z_][\\^A-Za-z_0-9.]*|0[xX][0-9A-Fa-f]+|[0-9]+|[^\s]"#
        let expression = try NSRegularExpression(pattern: pattern, options: .dotMatchesLineSeparators)
        let text = source as NSString
        var result: [Token] = [], line = 1, previous = 0
        for match in expression.matches(in: source, range: NSRange(location: 0, length: text.length)) {
            let token = text.substring(with: match.range)
            line += text.substring(with: NSRange(location: previous, length: match.range.location - previous)).filter { $0 == "\n" }.count
            if token == "\"" || token == "/" && NSMaxRange(match.range) < text.length && text.substring(with: NSRange(location: NSMaxRange(match.range), length: 1)) == "*" {
                throw SupportError.message("Unterminated ACPI string or comment")
            }
            if !token.hasPrefix("/*") && !token.hasPrefix("//") { result.append(Token(text: token, range: match.range, line: line)) }
            guard result.count <= 1_000_000 else { throw SupportError.message("ACPI token count exceeds the analysis limit") }
            line += token.filter { $0 == "\n" }.count
            previous = NSMaxRange(match.range)
        }
        return result
    }

    mutating func add(_ source: String, table: String) throws {
        let tokens = try Self.tokens(source)
        var pairs: [Int: Int] = [:], stack: [Int] = []
        for index in tokens.indices {
            let value = tokens[index].text
            if value == "(" || value == "{" { stack.append(index) }
            else if value == ")" || value == "}" {
                guard let opening = stack.popLast(), tokens[opening].text == (value == ")" ? "(" : "{") else {
                    throw SupportError.message(localizedMessage("Unbalanced ACPI source: %@", table))
                }
                pairs[opening] = index
            }
        }
        guard stack.isEmpty else { throw SupportError.message(localizedMessage("Unbalanced ACPI source: %@", table)) }
        func arguments(_ start: Int, _ end: Int) -> [[String]] {
            var result: [[String]] = [[]], index = start
            while index < end {
                if tokens[index].text == "," { result.append([]); index += 1; continue }
                if let closing = pairs[index] {
                    result[result.count - 1] += tokens[index...closing].map { $0.text }
                    index = closing + 1
                } else { result[result.count - 1].append(tokens[index].text); index += 1 }
            }
            return result
        }
        func number(_ value: String?) -> Int? {
            guard let value = value else { return nil }
            if value == "Zero" { return 0 }; if value == "One" { return 1 }
            return value.lowercased().hasPrefix("0x") ? Int(value.dropFirst(2), radix: 16) : Int(value)
        }
        var found: [Object] = []
        func walk(_ start: Int, _ end: Int, scope: String, depth: Int) throws {
            guard depth < 128 else { throw SupportError.message("ACPI scope nesting exceeds the analysis limit") }
            var index = start
            while index < end {
                let kind = tokens[index].text
                guard index + 1 < end, tokens[index + 1].text == "(", let close = pairs[index + 1] else {
                    if tokens[index].text == "{", let closing = pairs[index] {
                        try walk(index + 1, closing, scope: scope, depth: depth + 1); index = closing + 1
                    } else { index += 1 }
                    continue
                }
                let args = arguments(index + 2, close)
                let body = close + 1 < end && tokens[close + 1].text == "{" ? close + 1 : nil
                let finish = body.flatMap { pairs[$0] } ?? close
                let named = ["Device", "Processor", "ThermalZone", "PowerResource", "Method", "Name", "OperationRegion", "Mutex", "Event", "Alias"]
                if kind == "Scope" || named.contains(kind) {
                    let name = kind == "Alias" ? args.last?.first : args.first?.first
                    guard let name = name else { throw SupportError.message("Missing ACPI declaration name") }
                    let resolved = name == "\\" ? "" : try Self.path(name, scope: scope)
                    if kind != "Scope" {
                        let range = NSRange(location: tokens[index].range.location, length: NSMaxRange(tokens[finish].range) - tokens[index].range.location)
                        found.append(Object(path: resolved, kind: kind, arguments: kind == "Method" && args.count > 1 ? number(args[1].first) : nil,
                            table: table, line: tokens[index].line, value: args.dropFirst().flatMap { $0 }, range: range,
                            bitOffset: nil, bitWidth: nil, region: nil))
                    }
                    if let body = body, kind != "Method" && kind != "Name" {
                        try walk(body + 1, finish, scope: resolved, depth: depth + 1)
                    }
                } else if let body = body, kind != "Buffer" && kind != "Package" && kind != "Field" && kind != "BankField" && kind != "IndexField" {
                    try walk(body + 1, finish, scope: scope, depth: depth + 1)
                } else if ["Field", "BankField", "IndexField"].contains(kind), let body = body {
                    var field = body + 1
                    var offset: Int? = 0
                    func advance(_ width: Int?) {
                        if let width = width, let previous = offset, width >= 0, width <= 8 * 1024 * 1024,
                           previous <= 8 * 1024 * 1024 - width { offset = previous + width }
                        else { offset = nil }
                    }
                    while field < finish {
                        if field + 1 < finish, tokens[field + 1].text == "(", let closing = pairs[field + 1] {
                            if tokens[field].text == "Offset" {
                                let literal = closing == field + 3 ? number(tokens[field + 2].text) : nil
                                offset = literal.flatMap { (0...1024 * 1024).contains($0) ? $0 * 8 : nil }
                            }
                            field = closing + 1; continue
                        }
                        if tokens[field].text == ",", field + 1 < finish, let width = number(tokens[field + 1].text) {
                            advance(width); field += 2; continue
                        }
                        if field + 2 < finish, tokens[field + 1].text == ",",
                           let resolved = try? Self.path(tokens[field].text, scope: scope) {
                            let width = number(tokens[field + 2].text)
                            found.append(Object(path: resolved, kind: kind, arguments: nil, table: table, line: tokens[field].line,
                                value: args.flatMap { $0 }, range: tokens[field].range, bitOffset: offset, bitWidth: width, region: args.first?.first))
                            advance(width); field += 3; continue
                        }
                        field += 1
                    }
                }
                index = finish + 1
            }
        }
        try walk(0, tokens.count, scope: "", depth: 0)
        objects += found
        if tokens.contains(where: { $0.text == "XOSI" || $0.text == "\\XOSI" }) { warnings.append(table + ": XOSI references require reviewing OpenCore ACPI patch filters.") }
    }

    func plan(ecPath: String, hkeyPath: String, live: [String: Bool], protocolLayout: [String: Int], template: String) throws -> Plan {
        let ec = try Self.path(ecPath, scope: ""), hkey = try Self.path(hkeyPath, scope: "")
        guard hkey.hasPrefix(ec + "."), objects.filter({ $0.path == ec && $0.kind == "Device" }).count == 1,
              objects.filter({ $0.path == hkey && $0.kind == "Device" }).count == 1 else {
            throw SupportError.message("No unique EC/HKEY relationship matches the running driver")
        }
        guard objects.contains(where: { $0.path == ec + "._HID" && $0.value.contains("\"PNP0C09\"") }) else {
            throw SupportError.message("Selected EC is not identified as PNP0C09 in the captured tables")
        }
        var preserve: [String] = [], missing: [String] = [], evidence: [[String: Any]] = []
        for name in Self.helpers.keys.sorted() {
            let path = (name == "CSSI" ? hkey : ec) + "." + name
            let definitions = objects.filter { $0.path == path }
            guard let exists = live[name] else { throw SupportError.message(localizedMessage("Live namespace evidence is missing for %@", name)) }
            guard definitions.count <= 1, definitions.allSatisfy({ $0.kind == "Method" && $0.arguments == Self.helpers[name] }) else {
                throw SupportError.message(localizedMessage("Conflicting object or method argument count at %@", path))
            }
            if exists {
                guard !definitions.isEmpty else { throw SupportError.message(localizedMessage("Live helper is absent from captured tables: %@", path)) }
                preserve.append(name)
            } else {
                guard definitions.isEmpty else { throw SupportError.message(localizedMessage("Inactive helper already exists in an ACPI table; review its condition and replace only the superseded helper table: %@", path)) }
                missing.append(name)
            }
            evidence.append(["path": "\\" + path, "live": exists, "action": exists ? "preserve" : "add",
                "definitions": definitions.map { ["table": $0.table, "line": $0.line, "kind": $0.kind, "arguments": $0.arguments ?? -1] }])
        }
        guard !missing.isEmpty else { throw SupportError.message("All ThinkPad helpers already exist; no SSDT is needed. Export diagnostics if fan access still fails.") }
        let fields = objects.filter { ["Field", "BankField", "IndexField"].contains($0.kind) && $0.path.hasPrefix(ec + ".") }
        func fieldEvidence(_ name: String, width: Int, expectedOffset: Int?) -> [String: Any] {
            let candidates = fields.filter { $0.path == ec + "." + name }
            guard candidates.count == 1, let field = candidates.first, field.kind == "Field", field.bitWidth == width,
                  let bitOffset = field.bitOffset, bitOffset % 8 == 0, let region = field.region,
                  let regionPath = try? Self.path(region, scope: ec) else { return ["verified": false] }
            let regions = objects.filter { $0.kind == "OperationRegion" && $0.path == regionPath }
            guard regions.count == 1, let declaration = regions.first, declaration.value.count == 3,
                  declaration.value[0] == "EmbeddedControl" else { return ["verified": false] }
            func literal(_ value: String) -> Int? {
                if value == "Zero" { return 0 }; if value == "One" { return 1 }
                return value.lowercased().hasPrefix("0x") ? Int(value.dropFirst(2), radix: 16) : Int(value)
            }
            guard let base = literal(declaration.value[1]), let length = literal(declaration.value[2]),
                  base >= 0, base <= 0xff, length >= bitOffset / 8 + width / 8, length <= 256 - base,
                  let expectedOffset = expectedOffset, base + bitOffset / 8 == expectedOffset else { return ["verified": false] }
            return ["verified": true, "field": "\\" + field.path, "region": "\\" + regionPath,
                "byteOffset": expectedOffset, "width": width, "table": field.table, "line": field.line]
        }
        let control = fieldEvidence("HFSP", width: 8, expectedOffset: protocolLayout["FanControlOffset"])
        let rpm = fieldEvidence("HSPD", width: 16, expectedOffset: protocolLayout["FanRPMOffset"])
        let layout: [String: Any] = ["verified": control["verified"] as? Bool == true && rpm["verified"] as? Bool == true,
            "control": control, "rpm": rpm, "driverProtocol": protocolLayout]
        if missing.contains("RE1B") || missing.contains("WE1B") {
            guard layout["verified"] as? Bool == true else {
                throw SupportError.message("Native HFSP/HSPD fields do not match the fan-control and RPM layout reported by the driver. Export diagnostics for firmware review.")
            }
        }
        var rendered = template.replacingOccurrences(of: "{{ EC_PATH }}", with: "\\" + ec)
            .replacingOccurrences(of: "{{ HKEY_PATH }}", with: "\\" + hkey)
        var parsedTemplate = ThinkPadACPI()
        try parsedTemplate.add(rendered, table: "template")
        let remove = parsedTemplate.objects.filter { object in preserve.contains(object.path.components(separatedBy: ".").last ?? "") && object.kind == "Method" }
        let text = NSMutableString(string: rendered)
        for object in remove.sorted(by: { $0.range.location > $1.range.location }) { text.deleteCharacters(in: object.range) }
        rendered = (text as String).replacingOccurrences(of: #"If\s*\(!CondRefOf\s*\([A-Z0-9_]+\)\)\s*\{\s*\}"#, with: "", options: .regularExpression)
        let report: [String: Any] = ["schemaVersion": 1, "ecPath": "\\" + ec, "hkeyPath": "\\" + hkey,
            "helpers": evidence, "added": missing, "preserved": preserve, "warnings": warnings, "fanLayout": layout,
            "validation": "Static namespace and live existence checked; compilation and post-reboot readback still required.",
            "regions": objects.filter { $0.kind == "OperationRegion" && $0.path.hasPrefix(ec + ".") }.map {
                ["path": "\\" + $0.path, "table": $0.table, "line": $0.line, "declaration": $0.value.joined(separator: " ")]
            }, "fields": fields.map { ["path": "\\" + $0.path, "kind": $0.kind, "region": $0.region ?? "",
                "bitOffset": $0.bitOffset ?? -1, "bitWidth": $0.bitWidth ?? -1, "table": $0.table, "line": $0.line] }]
        return Plan(source: "// Generated from captured DSDT/SSDT and live helper evidence. No sensor offsets are inferred.\n" + rendered, report: report)
    }
}
