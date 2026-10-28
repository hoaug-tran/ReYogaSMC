import Foundation
import Combine
import ServiceManagement

final class ReYogaPreferences: ObservableObject {
    static let shared = ReYogaPreferences()
    private let defaults = ReYogaConstants.userDefaults
    @Published private(set) var startAtLogin = false
    @Published private(set) var loginStatus = ""
    @Published private(set) var automaticUpdates = false
    @Published private(set) var checking = false
    @Published private(set) var updateStatus = ""
    @Published private(set) var releaseURL: URL?
    private var timer: Timer?
    private var updateTask: URLSessionDataTask?
    private var updateGeneration: UInt64 = 0
    private var stopped = false

    func migrateLegacySettings() {
        // Copy existing settings once when moving to the community bundle identity.
        let standard = UserDefaults.standard
        guard !standard.bool(forKey: "ReYogaIdentityMigration") else { return }
        for (old, destination) in [("org.zhen.YogaSMCNC", standard), ("org.zhen.YogaSMC", defaults)] {
            for (key, value) in standard.persistentDomain(forName: old) ?? [:] {
                if destination.object(forKey: key) == nil { destination.set(value, forKey: key) }
            }
        }
        standard.set(true, forKey: "ReYogaIdentityMigration")
    }

    func stop() {
        stopped = true; updateGeneration &+= 1
        updateTask?.cancel(); updateTask = nil; checking = false
        timer?.invalidate(); timer = nil
    }
    func begin() {
        stop()
        stopped = false
        automaticUpdates = defaults.bool(forKey: "AutomaticUpdateChecks")
        refreshLoginStatus()
        checkIfDue()
        timer = Timer.scheduledTimer(withTimeInterval: 3600, repeats: true) { [weak self] _ in self?.checkIfDue() }
    }
    func refreshLoginStatus() {
        if #available(macOS 13.0, *) {
            let status = SMAppService.mainApp.status
            startAtLogin = status == .enabled || status == .requiresApproval
            loginStatus = status == .requiresApproval ? "Approve ReYogaSMC in System Settings → Login Items." : ""
        } else {
            startAtLogin = defaults.bool(forKey: "StartAtLogin")
        }
    }
    func setStartAtLogin(_ enabled: Bool) {
        do {
            if #available(macOS 13.0, *) {
                if enabled { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
                refreshLoginStatus()
            } else {
                guard let id = Bundle.main.bundleIdentifier, SMLoginItemSetEnabled((id + "Helper") as CFString, enabled) else {
                    throw SupportError.message("macOS could not change the login item. Install the app in Applications and retry.")
                }
                startAtLogin = enabled
                loginStatus = ""
            }
            defaults.set(startAtLogin, forKey: "StartAtLogin")
            showOSDRaw(loginStatus.isEmpty ? localizedMessage("Start with macOS: %@", localizedMessage(startAtLogin ? "On" : "Off")) : loginStatus)
        } catch {
            refreshLoginStatus()
            loginStatus = error.localizedDescription
            showOSDRaw(localizedMessage("Login item: %@", error.localizedDescription), duration: 3000)
        }
    }
    func setAutomaticUpdates(_ enabled: Bool) {
        automaticUpdates = enabled
        defaults.set(enabled, forKey: "AutomaticUpdateChecks")
        if !enabled {
            updateGeneration &+= 1
            updateTask?.cancel(); updateTask = nil; checking = false
        }
        showOSDRaw(localizedMessage("Automatic update checks: %@", localizedMessage(enabled ? "On" : "Off")))
        if enabled { checkIfDue() }
    }
    private func checkIfDue() {
        let last = defaults.object(forKey: "LastUpdateCheck") as? Date ?? .distantPast
        let attempt = defaults.object(forKey: "LastUpdateAttempt") as? Date ?? .distantPast
        if automaticUpdates && Date().timeIntervalSince(last) >= 86400 && Date().timeIntervalSince(attempt) >= 3600 {
            checkForUpdates(manual: false)
        }
    }
    func checkForUpdates(manual: Bool) {
        guard !stopped, !checking else { return }
        guard let request = ReleaseService.request(repository: Bundle.main.object(forInfoDictionaryKey: "ReYogaRepositoryID") as? String) else {
            updateStatus = "The release repository is not configured in this app build."
            return
        }
        checking = true; updateStatus = "Checking published releases…"; releaseURL = nil
        defaults.set(Date(), forKey: "LastUpdateAttempt")
        let generation = updateGeneration
        let current = (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String) ?? "0"
        updateTask = ReleaseService.check(request: request, currentVersion: current) { [weak self] result in
            DispatchQueue.main.async {
                guard let self = self, !self.stopped, generation == self.updateGeneration else { return }
                let message: String
                var release: URL?
                switch result {
                case .transportFailure(let error): message = localizedMessage("Update check failed: %@", error)
                case .noPublicRelease: message = "No public release is available for this fork yet."
                case .httpFailure(let code): message = localizedMessage("GitHub update service returned HTTP %@.", String(code))
                case .available(let tag, let url): message = localizedMessage("Update available: %@.", tag); release = url
                case .upToDate: message = localizedMessage("No newer published version. Installed: %@.", current)
                case .unversioned(let tag, let url): message = localizedMessage("Published release: %@. Review its compatibility before installing.", tag); release = url
                case .invalidResponse: message = "Invalid release response from GitHub."
                }
                ReYogaDiagnostics.shared.record("update_check", ["result": message, "manual": manual])
                self.checking = false; self.updateStatus = message; self.releaseURL = release
                self.updateTask = nil
                if result.succeeded { self.defaults.set(Date(), forKey: "LastUpdateCheck") }
                if manual || release != nil { showOSDRaw(message, duration: 3000) }
            }
        }
    }
}
