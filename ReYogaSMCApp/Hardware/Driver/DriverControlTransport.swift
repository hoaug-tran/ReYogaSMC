import Foundation
import IOKit

struct DriverControlResult {
    let snapshot: NSDictionary?
    let confirmed: Bool
    let reason: String
}

enum DriverControlTransport {
    // The caller retains service and serializes this transaction on its hardware queue.
    static func perform(key: String, targetValue: Any, requestID: String, service handle: io_service_t) -> DriverControlResult {
        let request: NSDictionary = ["Property": key, "Value": targetValue, "RequestID": requestID]
        let transport = IORegistryEntrySetCFProperty(handle, "ControlRequest" as CFString, request)
        var snapshot = getProperties(handle)
        let result = (snapshot?["LastControlResult"] as? [String: Any]) ?? [:]
        var correlated = result["RequestID"] as? String == requestID
        let status = (result["Status"] as? NSNumber)?.uint32Value ?? UInt32.max
        let readbackPending = result["ReadbackPending"] as? Bool == true
        var confirmed = transport == kIOReturnSuccess && correlated && status == 0 && !readbackPending

        if transport == kIOReturnSuccess, correlated, readbackPending {
            for _ in 0..<10 {
                Thread.sleep(forTimeInterval: 0.1)
                _ = sendBoolean("Update", true, handle)
                snapshot = getProperties(handle)
                correlated = (snapshot?["LastControlResult"] as? [String: Any])?["RequestID"] as? String == requestID
                guard correlated else { break }
                if let actual = snapshot?[key] as? NSNumber, let requested = targetValue as? NSNumber, actual == requested {
                    confirmed = true
                    break
                }
            }
        }
        let reason: String
        if confirmed { reason = "Firmware readback matched" }
        else if transport != kIOReturnSuccess { reason = String(format: localizedMessage("IOKit transport failed (0x%08x)"), transport) }
        else if !correlated { reason = "Driver response missing or request ID mismatch" }
        else if readbackPending { reason = "Firmware readback did not match before the retry limit." }
        else { reason = (result["Reason"] as? String) ?? "Firmware error" }
        ReYogaDiagnostics.shared.record("control_result", ["id": requestID, "property": key, "transport": transport,
            "status": confirmed ? 0 : status, "initialStatus": status, "confirmed": confirmed, "reason": confirmed ? "Firmware readback matched" : reason, "requested": targetValue, "actual": snapshot?[key] ?? NSNull(), "code": result["Code"] ?? "unknown", "stage": result["Stage"] ?? "unknown", "initialCommandStatus": result["CommandStatus"] ?? NSNull()])
        return DriverControlResult(snapshot: snapshot, confirmed: confirmed, reason: reason)
    }
}
