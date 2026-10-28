import Foundation

enum HardwareFeedbackPresenter {
    static func show(_ feedback: HardwareFeedback) {
        switch feedback {
        case let .fanMinimumNotReached(label, target, actual):
            showOSDRaw(localizedMessage("%@: requested %@ RPM, measured %@. The minimum has not been reached.",
                localizedMessage(label), String(target), String(actual)), duration: 4000)
        case .powerProfile(let mode):
            showOSDRaw(localizedMessage("Power Profile: %@", localizedMessage(controlValueLabel("SmartFanMode", target: mode))),
                symbol: ReYogaBrand.controlSymbol("SmartFanMode", value: mode))
        case .curveRejected(let reason):
            showOSDRaw(reason)
        case let .control(key, target, title, failure):
            let value = failure ?? controlValueLabel(key, target: target)
            showOSDRaw(localizedMessage("%@: %@", localizedMessage(title), localizedMessage(value)),
                duration: failure == nil ? 1500 : 3000, symbol: ReYogaBrand.controlSymbol(key, value: target))
        case .logoUnavailable(let reason):
            showOSDRaw(reason, symbol: "exclamationmark.triangle")
        case .detailedLogging(let enabled):
            showOSDRaw(localizedMessage("Detailed Logging: %@", localizedMessage(enabled ? "On" : "Off")))
        case let .message(message, duration):
            showOSDRaw(message, duration: duration)
        case let .rgbDiscovery(available, reason):
            showOSDRaw(available ? "RGB controller ready" : reason, duration: 3000)
        case .rgbStopped(let reason):
            showOSDRaw(localizedMessage("RGB effect stopped: %@", reason), duration: 3000, symbol: "exclamationmark.triangle")
        case .rgbUnavailable(let reason):
            showOSDRaw(localizedMessage("RGB: %@", localizedMessage(reason)))
        case let .rgbResult(title, failure):
            let message = failure.map { localizedMessage("%@: %@", localizedMessage(title), $0) } ??
                localizedMessage("%@: sent to controller", localizedMessage(title))
            showOSDRaw(message, duration: failure == nil ? 1500 : 3000, symbol: "lightbulb")
        case .hotkeysEnabled(let enabled):
            showOSDRaw(localizedMessage("Legion Hotkeys: %@", localizedMessage(enabled ? "On" : "Off")))
        case .fanAccessFailed(let failure):
            showOSDRaw(String(format: localizedMessage("ThinkPad fan access failed (0x%08x). Retry the driver connection."), failure))
        case .invalidFanLevel:
            showOSDRaw("Fan level is invalid; use Auto or a supported level")
        }
    }
}
