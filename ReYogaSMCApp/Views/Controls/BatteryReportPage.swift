import SwiftUI
import AppKit

struct BatteryReportPage: View {
    @ObservedObject var manager: HardwareManager
    private let columns = [GridItem(.adaptive(minimum: 270), spacing: 12, alignment: .top)]
    @ViewBuilder
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let live = manager.liveBattery {
                ControlSection(loc(.batteryOverviewHeader)) {
                    BatteryHero(live: live)
                }
                BatteryReportColumns(
                    capacity: capacityReport(live), electrical: electricalReport(live),
                    charging: chargingReport(live), identity: identityReport(live))
            } else {
                ControlSection(loc(.batteryMacOS)) {
                    SymbolLabel(loc(.batteryDataUnavailable), systemImage: "battery.0")
                    Text(loc(.batteryDataUnavailableDesc))
                        .font(.caption).foregroundColor(.secondary).padding(.top, 8)
                }
            }

            if manager.batteryDetails.count == 1, let battery = manager.batteryDetails.first {
                ControlSection(String(format: loc(.batteryPackFormat), battery.id + 1)) {
                    ReportValueRow(loc(.diagnosticsStatus), battery.critical ? loc(.batteryStatusCritical) : loc(.batteryStatusPresent))
                    ReportValueRow(loc(.batteryCycleCount), battery.cycleCount.map(String.init) ?? loc(.commonUnavailable))
                    ReportValueRow(loc(.batteryTemperature), battery.temperature ?? loc(.commonUnavailable))
                    ReportValueRow(loc(.batteryManufactureDate), battery.manufactureDate ?? loc(.commonUnavailable))
                    ReportValueRow(loc(.batteryDeviceName), battery.identifier ?? loc(.commonUnavailable))
                    Text(localizedMessage(String(format: loc(.sourceFormat), battery.source))).font(.caption).foregroundColor(.secondary).padding(.top, 8)
                }
            } else if manager.batteryDetails.count > 1 {
                LazyVGrid(columns: columns, alignment: .leading, spacing: 12) {
                    ForEach(manager.batteryDetails) { battery in
                        ControlSection(String(format: loc(.batteryPackFormat), battery.id + 1)) {
                            ReportValueRow(loc(.diagnosticsStatus), battery.critical ? loc(.batteryStatusCritical) : loc(.batteryStatusPresent))
                            ReportValueRow(loc(.batteryCycleCount), battery.cycleCount.map(String.init) ?? loc(.commonUnavailable))
                            ReportValueRow(loc(.batteryTemperature), battery.temperature ?? loc(.commonUnavailable))
                            ReportValueRow(loc(.batteryManufactureDate), battery.manufactureDate ?? loc(.commonUnavailable))
                            ReportValueRow(loc(.batteryDeviceName), battery.identifier ?? loc(.commonUnavailable))
                            Text(localizedMessage(String(format: loc(.sourceFormat), battery.source))).font(.caption).foregroundColor(.secondary).padding(.top, 8)
                        }
                    }
                }
            }

            if let live = manager.liveBattery {
                ControlSection(loc(.batteryDetailsHeader)) {
                    DisclosureGroup(loc(.batteryAboutReadingsTitle)) {
                        VStack(alignment: .leading, spacing: 8) {
                            Text(loc(.batteryAboutReadingsText))
                                .font(.system(size: 11)).foregroundColor(.secondary).lineSpacing(3)
                        }.padding(.vertical, 8)
                    }.font(.system(size: 12)).padding(.bottom, 8)
                    DisclosureGroup("\(loc(.batteryRawFieldsTitle)) (\(live.rawFields.count))") {
                        ForEach(live.rawFields.keys.sorted(), id: \.self) { key in
                            ReportValueRow(key, live.rawFields[key] ?? loc(.commonUnavailable))
                        }
                    }.font(.system(size: 12))
                }
            }

            if manager.batteryDetails.isEmpty && manager.liveBattery == nil {
                Text(loc(.batteryNoAcpiPresence)).font(.caption).foregroundColor(.secondary)
            }
        }
    }
    private func capacityReport(_ live: LiveBatterySnapshot) -> some View {
        ControlSection(loc(.batteryCapacityWearHeader), fillsRow: true) {
            ReportValueRow(loc(.batteryCurrentCapacity), BatteryValueFormat.capacityText(live.currentCapacity))
            ReportValueRow(loc(.batteryFullCapacity), BatteryValueFormat.capacityText(live.maximumCapacity))
            ReportValueRow(loc(.batteryDesignCapacity), BatteryValueFormat.capacityText(live.designCapacity))
            ReportValueRow(loc(.batteryCapacityRetained), live.healthPercent.map { String(format: loc(.retainedFormat), $0) } ?? loc(.commonUnavailable))
            ReportValueRow(loc(.batteryCycleCount), live.cycleCount.map(String.init) ?? loc(.commonUnavailable))
            ReportValueRow(loc(.batteryCondition), live.health ?? loc(.batteryNotReported))
        }
    }
    private func electricalReport(_ live: LiveBatterySnapshot) -> some View {
        ControlSection(loc(.batteryElectricalHeader), fillsRow: true) {
            ReportValueRow(loc(.batteryVoltage), live.voltage.map { String(format: "%.3f V", $0) } ?? loc(.commonUnavailable))
            ReportValueRow(loc(.batteryCurrent), live.milliamps.map { localizedMessage("%@ mA", String(describing: $0)) } ?? loc(.commonUnavailable))
            ReportValueRow(loc(.batteryPower), live.watts.map { String(format: "%.2f W", $0) } ?? loc(.commonUnavailable))
            ReportValueRow(loc(.batteryTemperature), live.temperatureCelsius.map { String(format: "%.1f °C", $0) } ?? loc(.commonUnavailable))
            ReportValueRow(loc(.batteryPowerSource), BatteryValueFormat.powerSource(live))
            ReportValueRow(loc(.batteryChargingState), live.charging.map { $0 ? loc(.commonYes) : loc(.commonNo) } ?? loc(.commonUnavailable))
        }
    }
    private func chargingReport(_ live: LiveBatterySnapshot) -> some View {
        ControlSection(loc(.batteryChargingAdapterHeader), fillsRow: true) {
            ReportValueRow(loc(.batteryFullyCharged), live.fullyCharged.map { $0 ? loc(.commonYes) : loc(.commonNo) } ?? loc(.commonUnavailable))
            ReportValueRow(loc(.batteryAdapterRating), live.adapterWatts.map { String(format: "%.0f W", $0) } ?? loc(.commonUnavailable))
            ReportValueRow(loc(.batteryTimeToEmpty), live.externalPower == false ? BatteryValueFormat.minutesText(live.timeToEmpty) : loc(.batteryNotDischarging))
            ReportValueRow(loc(.batteryTimeToFull), live.charging == true ? BatteryValueFormat.minutesText(live.timeToFull) : loc(.batteryNotCharging))
        }
    }
    private func identityReport(_ live: LiveBatterySnapshot) -> some View {
        ControlSection(loc(.batteryPackIdentityHeader), fillsRow: true) {
            ReportValueRow(loc(.batteryInstalled), live.installed.map { $0 ? loc(.commonYes) : loc(.commonNo) } ?? loc(.commonUnavailable))
            ReportValueRow(loc(.batteryManufacturer), live.manufacturer ?? loc(.commonUnavailable))
            ReportValueRow(loc(.batteryDeviceName), live.deviceName ?? loc(.commonUnavailable))
            ReportValueRow(loc(.batterySerialNumber), live.serial ?? loc(.commonUnavailable))
        }
    }
}
private struct BatteryReportWidth: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = nextValue() }
}

private struct BatteryReportColumns<A: View, B: View, C: View, D: View>: View {
    let capacity: A
    let electrical: B
    let charging: C
    let identity: D
    @State private var width: CGFloat = 0
    var body: some View {
        Group {
            if width >= 552 {
                VStack(spacing: 12) {
                    HStack(alignment: .top, spacing: 12) { capacity; electrical }
                        .fixedSize(horizontal: false, vertical: true)
                    HStack(alignment: .top, spacing: 12) { charging; identity }
                        .fixedSize(horizontal: false, vertical: true)
                }
            } else {
                VStack(alignment: .leading, spacing: 12) { capacity; electrical; charging; identity }
            }
        }.frame(maxWidth: .infinity)
            .background(GeometryReader { proxy in Color.clear.preference(key: BatteryReportWidth.self, value: proxy.size.width) })
            .onPreferenceChange(BatteryReportWidth.self) { width = $0 }
    }
}
