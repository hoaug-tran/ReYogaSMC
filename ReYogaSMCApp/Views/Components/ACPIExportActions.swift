import AppKit

enum ACPIExportActions {
    static func generateBridge(manager: HardwareManager) {
        guard manager.canGenerateACPIBridge else { return }
        let service = manager.service
        let identity = manager.connectionIdentity
        let live = service != 0 && getNumber("ACPIExportVersion", service) == 1
        var input: URL?
        if !live {
            let chooser = NSOpenPanel()
            chooser.allowedFileTypes = ["dsl"]
            chooser.message = localizedMessage("Select a disassembled DSDT. A bridge is generated only when a reviewed profile matches.")
            guard chooser.runModal() == .OK, let selected = chooser.url else { return }
            input = selected
        }
        let profile = HardwareProfiles.all().first { $0["id"] as? String == manager.firmwareProfileID }
        let save = NSSavePanel()
        save.allowedFileTypes = ["dsl"]
        save.nameFieldStringValue = HardwareProfiles.bridgeFilename(profile ?? [:])
        save.message = localizedMessage("The driver exports DSDT locally. Only a reviewed profile can generate an SSDT; it is never installed automatically.")
        guard save.runModal() == .OK, let output = save.url else { return }
        // Modal panels run a nested event loop; recheck the connection before retaining its service.
        guard manager.connectionIdentity == identity, manager.service == service, !manager.isShuttingDown else { return }
        let completion: (Result<URL, Error>) -> Void = showResult
        if let input = input { ACPIExport.exportBridge(input: input, output: output, completion: completion) }
        else { ACPIExport.exportLiveBridge(service: service, output: output, completion: completion) }
    }

    static func generateThinkPadSSDT(manager: HardwareManager) {
        guard manager.canGenerateThinkPadSSDT else { return }
        let identity = manager.connectionIdentity
        let save = NSSavePanel()
        save.allowedFileTypes = ["dsl"]
        save.nameFieldStringValue = "SSDT-ThinkPad.dsl"
        save.message = localizedMessage("Analyze running ACPI tables and save only missing ThinkPad helpers. Requires iasl. Keep existing EC and battery patches.")
        guard save.runModal() == .OK, let output = save.url else { return }
        guard manager.connectionIdentity == identity, !manager.isShuttingDown else { return }
        manager.generateThinkPadSSDT(to: output, completion: showResult)
    }

    private static func showResult(_ result: Result<URL, Error>) {
        switch result {
        case .success(let output):
            NSWorkspace.shared.activateFileViewerSelecting([output])
            showOSDRaw("SSDT compiled - review it and add it to OpenCore before rebooting", duration: 4000)
        case .failure(let error):
            showOSDRaw(error.localizedDescription, duration: 4000)
        }
    }
}
