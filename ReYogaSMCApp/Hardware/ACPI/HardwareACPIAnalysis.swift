import Foundation
import IOKit
import Combine

// Requests, connection invalidation and ACPIExport completions run on main.
final class HardwareACPIAnalysis: ObservableObject {
    @Published private(set) var busy = false
    @Published private(set) var status = ""
    private var connectionGeneration: UInt64 = 0

    func connectionChanged() {
        connectionGeneration &+= 1
        busy = false
        status = ""
    }

    func generateThinkPadSSDT(service: io_service_t, output: URL, completion: @escaping (Result<URL, Error>) -> Void) {
        guard !busy else { return }
        busy = true
        status = "Analyzing running ACPI tables…"
        let generation = connectionGeneration
        ACPIExport.exportThinkPadSSDT(service: service, output: output) { [weak self] result in
            let message: String
            switch result {
            case .success: message = "SSDT compiled. Review the analysis, install in OpenCore, reboot, then verify."
            case .failure(let error): message = error.localizedDescription
            }
            if self?.finish(message, generation: generation) == true { completion(result) }
        }
    }

    func verifyThinkPadSSDT(service: io_service_t) {
        guard !busy else { return }
        busy = true
        status = "Checking loaded SSDT and EC helpers…"
        let generation = connectionGeneration
        ACPIExport.verifyThinkPadSSDT(service: service) { [weak self] message in
            _ = self?.finish(message, generation: generation)
        }
    }

    private func finish(_ message: String, generation: UInt64) -> Bool {
        guard connectionGeneration == generation else { return false }
        busy = false
        status = message
        return true
    }
}
