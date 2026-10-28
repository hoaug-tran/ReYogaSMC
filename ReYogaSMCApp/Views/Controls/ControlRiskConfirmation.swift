import AppKit

enum ControlRiskConfirmation {
    static func fanMinimum() -> Bool {
        confirm("Change fan minimum?", message: "This raises the minimum over the factory cooling curve; it does not set an unrestricted fixed speed. Higher minima increase fan noise and power use. Restore Auto returns control to the factory curve.", preference: "AcknowledgedFanMinimumRisk")
    }

    static func cpuPower() -> Bool {
        confirm("Change CPU power limits?", message: "Higher limits can increase heat, fan noise and battery drain. Lower limits can reduce performance. Only firmware-supported values are accepted. Reset restores the values saved before your edits in this power profile.", preference: "AcknowledgedCPUPowerRisk")
    }

    static func confirm(_ title: String, message: String, preference: String) -> Bool {
        if UserDefaults.standard.bool(forKey: preference) { return true }
        let alert = NSAlert()
        alert.alertStyle = .warning; alert.messageText = localizedMessage(title); alert.informativeText = localizedMessage(message)
        alert.addButton(withTitle: localizedMessage("Continue")); alert.addButton(withTitle: localizedMessage("Cancel"))
        alert.showsSuppressionButton = true
        alert.suppressionButton?.title = localizedMessage("Don’t show this explanation again")
        guard alert.runModal() == .alertFirstButtonReturn else { return false }
        if alert.suppressionButton?.state == .on { UserDefaults.standard.set(true, forKey: preference) }
        return true
    }
}
