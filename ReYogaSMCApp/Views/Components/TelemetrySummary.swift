import SwiftUI
import AppKit

struct TelemetrySummary: View {
    @ObservedObject var manager: HardwareManager
    var body: some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(minimum: 65), spacing: 8), count: manager.hasDualFan ? 4 : 3), spacing: 8) {
            thermalTile("CPU", value: manager.cpuTemp, source: manager.cpuTemperatureSource)
            thermalTile("GPU", value: manager.gpuTemp, source: manager.gpuTemperatureSource)
            FanReadout(title: manager.fanLabels[0], rpm: manager.fan1RPM, accentColor: AppTheme.cpu)
            if manager.hasDualFan { FanReadout(title: manager.fanLabels[1], rpm: manager.fan2RPM, accentColor: AppTheme.gpu) }
        }
    }
    private func thermalTile(_ title: String, value: Double, source: String) -> some View {
        let isGPU = title == "GPU"
        let unavailableText = isGPU ? "N/A" : "-"
        return VStack(alignment: .leading, spacing: 8) {
            SymbolLabel(title, systemImage: "thermometer").font(.system(size: 11)).foregroundColor(.secondary)
            HStack(alignment: .firstTextBaseline, spacing: 3) {
                Text(value > 0 ? String(format: "%.1f", value) : unavailableText).font(.system(size: value > 0 ? 23 : 18, weight: .semibold, design: .rounded))
                if value > 0 {
                    Text(localizedMessage("°C")).font(.system(size: 10)).foregroundColor(.secondary)
                } else if isGPU {
                    Text("iGPU").font(.system(size: 10)).foregroundColor(.secondary)
                }
            }.foregroundColor(value >= 80 ? .orange : .primary)
        }.frame(maxWidth: .infinity, alignment: .leading).padding(10)
            .background(Color.primary.opacity(0.025)).cornerRadius(8).help(localizedMessage(source))
            .accessibilityElement(children: .ignore).accessibilityLabel(localizedMessage(title))
            .accessibilityValue(localizedMessage(value > 0 ? localizedMessage("%@ degrees Celsius", String(format: "%.1f", value)) : "Unavailable"))
    }
}
private struct FanReadout: View {
    let title: String
    let rpm: Int
    let accentColor: Color
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                AnimatedSymbol( "wind").foregroundColor(accentColor)
                Text(localizedMessage(title)).font(.system(size: 12, weight: .medium))
            }
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(localizedMessage(rpm >= 0 ? String(rpm) : "-"))
                    .font(Font(NSFont.monospacedDigitSystemFont(ofSize: 23, weight: .semibold)))
                Text(localizedMessage("RPM")).font(.caption).foregroundColor(.secondary)
            }
        }.padding(10).frame(maxWidth: .infinity, alignment: .leading)
            .transaction { $0.animation = nil }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(localizedMessage(title))
            .accessibilityValue(localizedMessage(rpm >= 0 ? localizedMessage("%@ revolutions per minute", String(rpm)) : "Unavailable"))
            .background(AppTheme.surface)
            .overlay(RoundedRectangle(cornerRadius: 12).fill(accentColor.opacity(0.045)).allowsHitTesting(false))
            .cornerRadius(12)
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(accentColor.opacity(0.16), lineWidth: 1))
    }
}
