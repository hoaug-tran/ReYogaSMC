// Exercise the production namespace analyzer without AppKit or a live ACPI interpreter.
enum SupportError: LocalizedError {
    case message(String)
    var errorDescription: String? { if case .message(let message) = self { return message }; return nil }
}
do {
    let input = try JSONSerialization.jsonObject(with: FileHandle.standardInput.readDataToEndOfFile()) as! [String: Any]
    if let localization = input["localize"] as? [String: String], let bundle = Bundle(path: localization["bundle"]!) {
        let value = renderLocalizedMessage(localization["key"]!, arguments: ["EC0"], bundle: bundle)
        print(String(data: try JSONSerialization.data(withJSONObject: ["text": value]), encoding: .utf8)!)
    } else if let check = input["verify"] as? [String: Any] {
        try ThinkPadACPI.verify(expectedDigest: check["expected"] as? String,
            loadedDigests: check["loaded"] as? [String] ?? [], live: check["live"] as? [String: Any] ?? [:])
        print("{\"valid\":true}")
    } else if let tables = input["normalize"] as? [String] {
        let result = tables.map { ThinkPadACPI.normalizedAML(Data(base64Encoded: $0)!).base64EncodedString() }
        print(String(data: try JSONSerialization.data(withJSONObject: ["normalized": result]), encoding: .utf8)!)
    } else if let tables = input["aml"] as? [String] {
        try ThinkPadACPI.validateTables(tables.map { Data(base64Encoded: $0)! })
        print("{\"valid\":true}")
    } else {
        var namespace = ThinkPadACPI()
        for table in input["tables"] as! [[String: String]] { try namespace.add(table["source"]!, table: table["name"]!) }
        let plan = try namespace.plan(ecPath: input["ec"] as! String, hkeyPath: input["hkey"] as! String,
            live: input["live"] as! [String: Bool], protocolLayout: input["protocolLayout"] as? [String: Int] ?? [:], template: input["template"] as! String)
        let result: [String: Any] = ["source": plan.source, "report": plan.report]
        print(String(data: try JSONSerialization.data(withJSONObject: result, options: .sortedKeys), encoding: .utf8)!)
    }
} catch {
    print(String(data: try! JSONSerialization.data(withJSONObject: ["error": error.localizedDescription]), encoding: .utf8)!)
}
