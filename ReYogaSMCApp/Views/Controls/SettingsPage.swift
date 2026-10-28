import SwiftUI
import AppKit

struct SettingsPage: View {
    @ObservedObject var manager: HardwareManager
    @ObservedObject private var preferences = ReYogaPreferences.shared
    let actions: HardwareControlsActions
    init(manager: HardwareManager, actions: HardwareControlsActions) {
        self.manager = manager; self.actions = actions
    }
    var body: some View {
        let prefs = preferences
        return VStack(alignment: .leading, spacing: 18) {
            ControlSection(loc(.settingsStartupHeader)) {
                VStack(alignment: .leading, spacing: 10) {
                    Toggle(loc(.settingsStartAtLogin), isOn: Binding(get: { prefs.startAtLogin }, set: { prefs.setStartAtLogin($0) }))
                        .font(.system(size: 12, weight: .medium))
                    VStack(alignment: .leading, spacing: 8) {
                        Text(loc(.settingsStartupDescription))
                        if !prefs.loginStatus.isEmpty { Text(localizedMessage(prefs.loginStatus)) }
                    }.font(.caption).foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true).padding(.leading, 20)
                }.padding(.vertical, 4)
            }
            ControlSection(loc(.settingsUpdatesHeader)) {
                VStack(alignment: .leading, spacing: 10) {
                    Toggle(loc(.settingsAutoUpdates), isOn: Binding(get: { prefs.automaticUpdates }, set: { prefs.setAutomaticUpdates($0) }))
                        .font(.system(size: 12, weight: .medium))
                    VStack(alignment: .leading, spacing: 12) {
                        Text(loc(.settingsAutoUpdatesDesc)).font(.caption).foregroundColor(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        HStack(spacing: 10) {
                            Button(loc(.settingsCheckNow)) { prefs.checkForUpdates(manual: true) }.disabled(prefs.checking)
                            if let url = prefs.releaseURL { Button(loc(.settingsViewRelease)) { NSWorkspace.shared.open(url) } }
                        }
                        if !prefs.updateStatus.isEmpty {
                            Text(localizedMessage(prefs.updateStatus)).font(.caption).foregroundColor(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }.padding(.leading, 20)
                }.padding(.vertical, 4)
            }
            ControlSection(loc(.settingsLoggingHeader)) {
                VStack(alignment: .leading, spacing: 10) {
                    Toggle(loc(.settingsDetailedLogging), isOn: Binding(get: { manager.detailedLogging }, set: { manager.setDetailedLogging($0) }))
                        .font(.system(size: 12, weight: .medium))
                    Text(loc(.settingsDetailedLoggingDesc)).font(.caption).foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true).padding(.leading, 20)
                }.padding(.vertical, 4)
            }
            ControlSection(loc(.settingsShortcutsHeader)) {
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(loc(.settingsResetShortcutsTitle)).font(.system(size: 12, weight: .medium))
                        Text(loc(.settingsResetShortcutsDesc)).font(.caption).foregroundColor(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer()
                    Button(loc(.settingsResetShortcutsButton)) {
                        actions.resetShortcuts()
                        showOSDRaw(localizedMessage("Shortcuts reset to defaults"))
                    }
                }.padding(.vertical, 4)
            }
        }
    }
}
