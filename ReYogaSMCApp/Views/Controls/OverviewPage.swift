import SwiftUI
import AppKit

struct OverviewPage: View {
    @ObservedObject var manager: HardwareManager
    let openBatteryReport: () -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .firstTextBaseline) {
                    Text(verbatim: manager.localizedModelName).font(.system(size: 18, weight: .semibold))
                    Spacer(minLength: 8)
                    Text(localizedMessage(manager.modelSource)).font(.system(size: 10, weight: .medium)).foregroundColor(AppTheme.accent)
                }
                Text(localizedMessage(manager.cpuBrand)).font(.system(size: 11)).foregroundColor(.secondary)
                if !manager.modelWarning.isEmpty {
                    SymbolLabel(manager.modelWarning, systemImage: "exclamationmark.triangle")
                        .font(.system(size: 10)).foregroundColor(.orange).fixedSize(horizontal: false, vertical: true)
                }
            }.padding(10).frame(maxWidth: .infinity, alignment: .leading)
                .background(AppTheme.accent.opacity(0.06)).cornerRadius(10)
            ControlSection(loc(.overviewSectionTelemetry)) { TelemetrySummary(manager: manager) }
            if let live = manager.liveBattery {
                ControlSection(loc(.overviewSectionBattery)) {
                    HStack(spacing: 12) {
                        BatteryHero(live: live)
                        Button(action: { openBatteryReport() }) { AnimatedSymbol( "chevron.right") }
                            .buttonStyle(FeedbackButtonStyle()).help(loc(.overviewBatteryReportHelp)).accessibilityLabel(loc(.overviewBatteryOpenReport))
                    }
                    Divider().padding(.vertical, 6)
                    HStack {
                        Text(localizedMessage("\(BatteryValueFormat.capacityText(live.currentCapacity)) / \(BatteryValueFormat.capacityText(live.maximumCapacity))"))
                        Spacer()
                        Text(localizedMessage(live.healthPercent.map { String(format: loc(.retainedFormat), $0) } ?? loc(.commonUnavailable)))
                    }.font(.system(size: 10)).foregroundColor(.secondary)
                }
            }
            if manager.hasPowerProfiles {
                profile
                if !manager.powerProfileError.isEmpty {
                    Text(localizedMessage(manager.powerProfileError)).font(.caption).foregroundColor(.orange)
                }
                if !manager.powerProfilesReady || manager.powerProfile == 0 || !manager.powerProfileError.isEmpty {
                    Text(localizedMessage("Power profile readback unavailable. Refresh to retry."))
                        .font(.caption).foregroundColor(.secondary)
                    Button(localizedMessage("Retry")) { manager.refreshAll() }
                }
            }
        }
    }
    private var profile: some View {
        ControlSection(loc(.overviewSectionProfiles)) {
            ProfileSelector(manager: manager)
        }
    }
}
private struct ProfileSelector: View {
    @ObservedObject var manager: HardwareManager
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private let modes: [(Int, LocalizedKey, String)] = [
        (1, .profileQuiet, "leaf.fill"),
        (2, .profileBalanced, "speedometer"),
        (3, .profilePerformance, "flame.fill")
    ]
    var body: some View {
        HStack(spacing: 8) {
            ForEach(modes, id: \.0) { mode in
                Button(action: { manager.setPowerProfile(mode.0) }) {
                    HStack(spacing: 6) {
                        AnimatedSymbol( mode.2).font(.system(size: 14, weight: .semibold))
                        Text(loc(mode.1)).font(.system(size: 11, weight: .semibold)).lineLimit(1)
                    }.padding(.horizontal, 6).frame(maxWidth: .infinity).frame(height: 38)
                        .foregroundColor(manager.powerProfile == mode.0 ? .white : .primary)
                        .background(background(mode.0))
                        .contentShape(RoundedRectangle(cornerRadius: 10))
                }.buttonStyle(FeedbackButtonStyle())
                    .accessibilityLabel(loc(mode.1))
                    .accessibilityValue(localizedMessage(manager.powerProfile == mode.0 ? "Selected" : "Not selected"))
            }
        }
            .disabled(!manager.powerProfilesReady || manager.applyingControl == "SmartFanMode")
    }
    private func background(_ mode: Int) -> some View {
        RoundedRectangle(cornerRadius: 10)
            .fill(manager.powerProfile == mode ? AppTheme.profile(mode) : Color.primary.opacity(0.035))
            .overlay(RoundedRectangle(cornerRadius: 10)
                .stroke(manager.powerProfile == mode ? AppTheme.profile(mode) : Color.primary.opacity(0.12), lineWidth: 1))
            .modifier(StateAnimation(value: manager.powerProfile == mode))
    }
}
