import SwiftUI
import AppKit

struct DiagnosticsPage: View {
    @ObservedObject var manager: HardwareManager
    @State private var reviewExpanded = CommandLine.arguments.contains("--render-ui") && ProcessInfo.processInfo.environment["REYOGA_UI_EXPANDED"] == "1"
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ControlSection(loc(.diagnosticsIdentityHeader)) {
                ReportValueRow(loc(.diagnosticsFirmwareDevice), manager.localizedModelName)
                ReportValueRow(loc(.diagnosticsIdentitySource), localizedMessage(manager.modelSource))
                ReportValueRow(loc(.diagnosticsSmbiosModel), manager.smbiosModel)
                ReportValueRow(loc(.diagnosticsAppBuild), manager.appBuild)
                ReportValueRow(loc(.diagnosticsGitRevision), manager.appRevision)
                ReportValueRow(loc(.diagnosticsDriverBuild), manager.driverVersion == "Unavailable" ? loc(.commonUnavailable) : manager.driverVersion)
                ReportValueRow(loc(.diagnosticsProfileState), localizedMessage(manager.profileMatchState))
                if !manager.firmwareProfileID.isEmpty {
                    ReportValueRow(localizedMessage("Hardware profile"), manager.firmwareProfileID)
                }
                if !manager.modelWarning.isEmpty {
                    SymbolLabel(manager.modelWarning, systemImage: "exclamationmark.triangle")
                        .font(.caption).foregroundColor(.orange).padding(.top, 10)
                }
            }
            ControlSection(loc(.diagnosticsSectionTelemetrySources)) {
                ReportValueRow(loc(.diagnosticsStatus), localizedMessage(manager.telemetryStatus))
                ReportValueRow("CPU", localizedMessage(manager.cpuTemperatureSource))
                ReportValueRow("GPU", localizedMessage(manager.gpuTemperatureSource))
                Text(localizedMessage(manager.gpuTemperatureReason)).font(.caption).foregroundColor(.secondary)
            }
            ControlSection(loc(.diagnosticsSectionCapabilities)) {
                DisclosureGroup(loc(.diagnosticsSectionCapabilities), isExpanded: $reviewExpanded) {
                    ForEach(manager.featureStatus.keys.sorted(), id: \.self) { key in
                        if let feature = manager.featureStatus[key] {
                            HStack(alignment: .top, spacing: 10) {
                                AnimatedSymbol( feature.available ? "checkmark.circle.fill" : "minus.circle")
                                    .foregroundColor(feature.available ? AppTheme.connected : .secondary)
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(localizedMessage(HardwareFeatureStatus.catalog[key] ?? key)).font(.system(size: 12, weight: .medium))
                                    Text(localizedMessage(feature.available ? feature.backend : feature.reason)).font(.caption).foregroundColor(.secondary)
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                                Spacer()
                            }.padding(.vertical, 8)
                        }
                    }
                }.font(.system(size: 12))
            }
            ControlSection(loc(.diagnosticsSectionSupportTools)) {
                Text(loc(.diagnosticsToolsDesc))
                    .font(.system(size: 12)).foregroundColor(.secondary).padding(.bottom, 12)
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Button(loc(.diagnosticsExportDiagnostics)) { exportDiagnostics() }
                        Button(loc(.diagnosticsOpenLogs)) { NSWorkspace.shared.open(ReYogaDiagnostics.shared.directory) }
                        if manager.canGenerateACPIBridge {
                            Button(loc(.diagnosticsGenerateBridge)) { ACPIExportActions.generateBridge(manager: manager) }
                        }
                        if manager.isThinkPadDevice {
                            Button(loc(.diagnosticsGenerateThinkPadSSDT)) { ACPIExportActions.generateThinkPadSSDT(manager: manager) }
                                .disabled(!manager.canGenerateThinkPadSSDT)
                        }
                    }
                    if manager.canGenerateACPIBridge {
                        Text(loc(.diagnosticsBridgeDesc))
                            .font(.system(size: 11)).foregroundColor(.secondary)
                    }
                    if manager.isThinkPadDevice {
                        HStack {
                            Button(localizedMessage("Verify ThinkPad SSDT")) { manager.verifyThinkPadSSDT() }
                                .disabled(!manager.canGenerateThinkPadSSDT)
                            if manager.acpiAnalysisBusy { ProgressView() }
                        }
                        if !manager.acpiAnalysisStatus.isEmpty {
                            Text(localizedMessage(manager.acpiAnalysisStatus)).font(.caption).foregroundColor(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        Text(loc(.diagnosticsThinkPadSSDTDesc))
                            .font(.system(size: 11)).foregroundColor(.secondary)
                        if !manager.canGenerateThinkPadSSDT && !manager.acpiAnalysisBusy {
                            Text(localizedMessage("Connect a matching driver with ACPI analysis support and valid EC/HKEY paths. Safe Mode must be off."))
                                .font(.caption).foregroundColor(.secondary)
                        }
                    }
                }
            }
        }
    }
    private func exportDiagnostics() {
        let save = NSSavePanel()
        save.allowedFileTypes = ["zip"]
        save.nameFieldStringValue = "ReYoga-diagnostics.zip"
        save.message = localizedMessage("Export hardware status and recent app logs locally. Review the archive before attaching it to an issue.")
        guard save.runModal() == .OK, let output = save.url else { return }
        manager.exportDiagnostics(to: output) { result in
            switch result {
            case .success(let archive):
                NSWorkspace.shared.activateFileViewerSelecting([archive])
                showOSDRaw("Diagnostic report saved locally", duration: 2500)
            case .failure(let error):
                showOSDRaw(localizedMessage("Report export: %@", error.localizedDescription), duration: 3500)
            }
        }
    }

}
