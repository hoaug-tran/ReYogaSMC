import Foundation
import Combine

final class HardwareLightingManager: ObservableObject {
    @Published private(set) var rgbStatus = HardwareFeatureStatus(available: false, reason: "RGB discovery pending", backend: "USB HID")
    @Published private(set) var rgbApplying = false
    @Published private(set) var rgbMode = "Factory"
    @Published private(set) var logoState: Bool?
    private(set) var matchedProfileID: String?
    // Main-thread lifecycle and discovery snapshots; backend state stays on hardwareQueue.
    private var isShutdown = false
    private var discoveryGeneration: UInt64 = 0

    private let hardwareQueue: DispatchQueue
    private let rgbController = LegionRGBController()
    private var rgbLogoEnabled = true
    private var rgbEffectTimer: DispatchSourceTimer?
    private var rgbEffectStart = Date()
    private var rgbColors: [String: (UInt8, UInt8, UInt8)] = [:]
    private var rgbEffect = "Factory"
    private var rgbRestoredProfile: String?
    private var effectGeneration: UInt64 = 0
    private var hardwareStopped = false
    private var rgbPerKey: Data?

    func ownsLighting(_ key: String, settings: SavedRGBSettings?) -> Bool {
        rgbStatus.available && HardwareProfiles.lightingOwnedByRGB(key: key, settings: settings, activeProfileID: matchedProfileID)
    }

    private let feedback: (HardwareFeedback) -> Void
    init(queue: DispatchQueue, feedback: @escaping (HardwareFeedback) -> Void = { _ in }) {
        hardwareQueue = queue
        self.feedback = feedback
    }

    func detect(retry: Bool = false, completion: @escaping (String?) -> Void) {
        guard !isShutdown, !rgbApplying else { return }
        discoveryGeneration &+= 1
        let generation = discoveryGeneration
        rgbApplying = true
        if retry { rgbRestoredProfile = nil }
        hardwareQueue.async {
            guard !self.hardwareStopped else { return }
            if retry {
                self.stopRGBEffect()
                do { try self.rgbController.restoreHardwareMode() }
                catch { ReYogaDiagnostics.shared.record("rgb_restore_failed", ["error": error.localizedDescription]) }
            }
            self.rgbController.detect()
            let status = self.rgbController.status
            let profile = self.rgbController.matchedProfileID
            DispatchQueue.main.async {
                guard !self.isShutdown, generation == self.discoveryGeneration else { return }
                self.matchedProfileID = profile
                self.rgbStatus = status
                self.rgbApplying = false
                completion(profile)
                self.restoreSavedRGB()
                if retry { self.feedback(.rgbDiscovery(available: self.rgbStatus.available, reason: self.rgbStatus.reason)) }
            }
        }
    }

    // Called on main before the caller drains hardwareQueue.
    func beginShutdown() {
        isShutdown = true
        discoveryGeneration &+= 1
        rgbApplying = false
    }

    private func publish(_ update: @escaping () -> Void) {
        DispatchQueue.main.async {
            guard !self.isShutdown else { return }
            update()
        }
    }

    func setLogoEnabled(_ enabled: Bool) {
        rgbAction("Logo LED") {
            let color = enabled ? (self.rgbColors["Logo"] ?? (255, 255, 255)) : (0, 0, 0)
            try self.rgbController.setZone("Logo", red: color.0, green: color.1, blue: color.2)
            self.rgbLogoEnabled = enabled
            self.saveRGBSettings(mode: self.rgbPerKey != nil ? "Per-key" : self.rgbEffect == "Factory" ? "Static" : self.rgbEffect)
            self.publish { self.logoState = enabled }
        }
    }

    func releaseFactoryLighting() {
        guard !isShutdown else { return }
        hardwareQueue.async {
            guard !self.hardwareStopped else { return }
            do { try self.rgbController.restoreHardwareMode(force: true) }
            catch { ReYogaDiagnostics.shared.record("rgb_factory_release_failed", ["error": error.localizedDescription]) }
        }
    }

    // Called after draining the shared hardware queue during app shutdown.
    func shutdownOnHardwareQueue() {
        hardwareStopped = true
        stopRGBEffect()
        do { try rgbController.restoreHardwareMode() }
        catch { ReYogaDiagnostics.shared.record("rgb_restore_failed", ["error": error.localizedDescription]) }
    }

    func setRGBZone(_ zone: String, color: RGBBytes) {
        let (red, green, blue) = color
        rgbAction(localizedMessage("%@ RGB", localizedMessage(zone))) {
            var colors = self.rgbColors
            colors[zone] = (red, green, blue)
            let logoEnabled = zone == "Logo" ? red != 0 || green != 0 || blue != 0 : self.rgbLogoEnabled
            try self.configureRGB(mode: "Static", colors: colors, logoEnabled: logoEnabled)
            self.saveRGBSettings(mode: "Static")
        }
    }

    func restoreRGBHardwareMode() {
        rgbAction("RGB factory effects") {
            self.stopRGBEffect()
            try self.rgbController.restoreHardwareMode(force: true)
            self.rgbPerKey = nil
            self.saveRGBSettings(mode: "Factory")
            self.publish { self.rgbMode = "Factory" }
        }
    }
    private func stopRGBEffect() {
        effectGeneration &+= 1
        rgbEffectTimer?.cancel(); rgbEffectTimer = nil; rgbEffect = "Factory"
    }
    func setRGBEffect(_ mode: String, colors: [String: RGBBytes]) {
        guard ["Static", "Breathing", "Spectrum", "Factory"].contains(mode) else { return }
        if mode == "Factory" { restoreRGBHardwareMode(); return }
        rgbAction(localizedMessage("RGB %@", localizedMessage(mode))) {
            try self.configureRGB(mode: mode, colors: colors, logoEnabled: true)
            self.saveRGBSettings(mode: mode)
        }
    }
    private func configureRGB(mode: String, colors: [String: (UInt8, UInt8, UInt8)], logoEnabled: Bool) throws {
        stopRGBEffect()
        rgbEffect = mode; rgbColors = colors; rgbLogoEnabled = logoEnabled; rgbPerKey = nil; rgbEffectStart = Date()
        try writeRGBFrame()
        if mode != "Static" {
            let timer = DispatchSource.makeTimerSource(queue: hardwareQueue)
            timer.schedule(deadline: .now() + 0.1, repeating: 0.1, leeway: .milliseconds(10))
            let generation = effectGeneration
            timer.setEventHandler { [weak self] in
                guard let self = self, !self.hardwareStopped, generation == self.effectGeneration else { return }
                do { try self.writeRGBFrame() }
                catch {
                    self.stopRGBEffect()
                    try? self.rgbController.restoreHardwareMode()
                    ReYogaDiagnostics.shared.record("rgb_effect_failed", ["error": error.localizedDescription])
                    self.publish {
                        self.rgbMode = "Stopped - error"
                        self.rgbStatus = HardwareFeatureStatus(available: false, reason: error.localizedDescription, backend: "USB HID")
                        self.feedback(.rgbStopped(error.localizedDescription))
                    }
                }
            }
            rgbEffectTimer = timer; timer.resume()
        }
        self.publish { self.rgbMode = mode; self.logoState = logoEnabled }
    }
    private func saveRGBSettings(mode: String) {
        guard let profile = rgbController.matchedProfileID else { return }
        let colors = rgbColors.mapValues { String(format: "#%02X%02X%02X", $0.0, $0.1, $0.2) }
        let value = SavedRGBSettings(profileID: profile, mode: mode, colors: colors, logoEnabled: rgbLogoEnabled, perKey: rgbPerKey)
        if value.isValid, let data = try? JSONEncoder().encode(value), data.count <= SavedRGBSettings.maximumSavedBytes {
            UserDefaults.standard.set(data, forKey: "AppliedRGBSettings")
            publish { self.rgbRestoredProfile = profile }
        }
    }
    private func restoreSavedRGB() {
        guard !isShutdown, rgbStatus.available, !rgbApplying,
              let profile = matchedProfileID, rgbRestoredProfile != profile,
              let data = UserDefaults.standard.data(forKey: "AppliedRGBSettings"),
              data.count <= SavedRGBSettings.maximumSavedBytes,
               let saved = try? JSONDecoder().decode(SavedRGBSettings.self, from: data), saved.isValid else { return }
        guard saved.profileID == profile else {
            ReYogaDiagnostics.shared.record("rgb_restore_skipped", ["reason": "Saved RGB device profile differs", "saved": saved.profileID, "current": profile])
            return
        }
        if saved.mode == "Factory" { rgbRestoredProfile = profile; return }
        rgbAction("Restore RGB preferences") {
            if saved.mode == "Per-key", let perKey = saved.perKey {
                self.stopRGBEffect()
                try self.rgbController.importColors(perKey)
                self.rgbPerKey = perKey
                self.rgbLogoEnabled = saved.logoEnabled
                if !saved.logoEnabled { try self.rgbController.setZone("Logo", red: 0, green: 0, blue: 0) }
                self.publish { self.rgbMode = "Per-key" }
            } else {
                try self.configureRGB(mode: saved.mode, colors: saved.colors.mapValues { SavedRGBSettings.bytes($0)! }, logoEnabled: saved.logoEnabled)
            }
            self.publish { self.rgbRestoredProfile = profile }
            ReYogaDiagnostics.shared.record("rgb_preferences_restored", ["mode": saved.mode, "profile": profile])
        }
    }
    private func writeRGBFrame() throws {
        let elapsed = Date().timeIntervalSince(rgbEffectStart)
        for (zone, base) in rgbColors {
            let color = zone == "Logo" && !rgbLogoEnabled ? (UInt8(0), UInt8(0), UInt8(0)) : LegionRGBController.effectColor(mode: rgbEffect, base: base, elapsed: elapsed)
            try rgbController.setZone(zone, red: color.0, green: color.1, blue: color.2)
        }
    }
    func importRGBColors(from file: URL) {
        guard !isShutdown else { return }
        rgbAction("Per-key RGB") {
            let handle = try FileHandle(forReadingFrom: file)
            defer { try? handle.close() }
            let data = try handle.read(upToCount: SavedRGBSettings.maximumImportBytes + 1) ?? Data()
            guard data.count <= SavedRGBSettings.maximumImportBytes else { throw SupportError.message("RGB JSON exceeds 256 KiB") }
            self.stopRGBEffect()
            try self.rgbController.importColors(data)
            self.rgbPerKey = data
            self.rgbLogoEnabled = true
            self.saveRGBSettings(mode: "Per-key")
            self.publish { self.rgbMode = "Per-key" }
        }
    }
    private func rgbAction(_ title: String, action: @escaping () throws -> Void) {
        guard !isShutdown else { return }
        guard rgbStatus.available, !rgbApplying else { feedback(.rgbUnavailable(rgbStatus.reason)); return }
        rgbApplying = true
        hardwareQueue.async {
            guard !self.hardwareStopped else { return }
            var errorText: String?
            do { try action() }
            catch {
                errorText = error.localizedDescription
                self.stopRGBEffect()
                do { try self.rgbController.restoreHardwareMode() }
                catch { errorText = localizedMessage("%@; factory-mode restoration also failed: %@", localizedMessage(errorText ?? "RGB error"), error.localizedDescription) }
            }
            ReYogaDiagnostics.shared.record("rgb_result", ["action": title, "error": errorText ?? "none", "acknowledgement": "USB report transport only"])
            self.publish {
                self.rgbApplying = false
                self.feedback(.rgbResult(title: title, failure: errorText))
            }
        }
    }
}
