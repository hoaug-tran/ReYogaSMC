import SwiftUI
import AppKit

enum BatteryValueFormat {
    static func powerSource(_ live: LiveBatterySnapshot) -> String {
        live.externalPower == true ? loc(.batteryAcAdapter) : live.externalPower == false ? loc(.sidebarTabBattery) : loc(.commonUnavailable)
    }
    static func capacityText(_ value: Int?) -> String {
        value.map { localizedMessage("%@ mAh", String(describing: NumberFormatter.localizedString(from: NSNumber(value: $0), number: .decimal))) } ?? loc(.commonUnavailable)
    }
    static func minutesText(_ value: Int?) -> String {
        value.map { localizedMessage("%@ h %@ min", String(describing: $0 / 60), String(describing: $0 % 60)) } ?? loc(.commonUnavailable)
    }
    static func batteryStateIcon(_ live: LiveBatterySnapshot) -> String {
        if live.installed == false { return "battery.0" }
        if live.charging == true { return "bolt.fill" }
        if live.fullyCharged == true { return "checkmark.circle.fill" }
        if let current = live.milliamps, current < 0 { return "arrow.down.circle" }
        if live.externalPower == true && live.charging == false { return "pause.circle" }
        return "questionmark.circle"
    }
}

struct BatteryHero: View {
    let live: LiveBatterySnapshot
    var body: some View {
        let barColor = AppTheme.batteryProgressColor(live.percent)
        return HStack(spacing: 20) {
            ZStack {
                Circle().stroke(barColor.opacity(0.12), lineWidth: 5)
                Circle().trim(from: 0, to: CGFloat(live.percent ?? 0) / 100)
                    .stroke(barColor, style: StrokeStyle(lineWidth: 5, lineCap: .round)).rotationEffect(.degrees(-90))
                Text(localizedMessage(live.percent.map { "\($0)%" } ?? "-")).font(.system(size: 18, weight: .semibold, design: .rounded))
            }.frame(width: 56, height: 56).accessibilityElement(children: .ignore)
                .accessibilityLabel(loc(.batteryCharge)).accessibilityValue(localizedMessage(live.percent.map { String(format: loc(.percentFormat), $0) } ?? loc(.commonUnavailable)))
            VStack(alignment: .leading, spacing: 6) {
                SymbolLabel(live.state, systemImage: BatteryValueFormat.batteryStateIcon(live))
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(live.charging == true ? AppTheme.connected : .primary)
                Text(localizedMessage(BatteryValueFormat.powerSource(live))).font(.system(size: 12)).foregroundColor(.secondary)
                Text(localizedMessage(live.deviceName ?? "System battery")).font(.caption).foregroundColor(.secondary)
            }
            Spacer(minLength: 0)
        }.padding(.vertical, 4)
    }
}
