enum HardwareFeedback {
    case fanMinimumNotReached(label: String, targetRPM: Int, actualRPM: Int)
    case powerProfile(Int)
    case curveRejected(String)
    case control(key: String, target: Int, title: String, failure: String?)
    case logoUnavailable(String)
    case detailedLogging(Bool)
    case message(String, durationMilliseconds: UInt32)
    case rgbDiscovery(available: Bool, reason: String)
    case rgbStopped(String)
    case rgbUnavailable(String)
    case rgbResult(title: String, failure: String?)
    case hotkeysEnabled(Bool)
    case fanAccessFailed(Int32)
    case invalidFanLevel
}
