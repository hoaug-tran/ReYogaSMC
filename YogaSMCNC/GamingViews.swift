import SwiftUI

public struct ArcGaugeShape: Shape {
    let startAngle: Angle
    let endAngle: Angle

    public func path(in rect: CGRect) -> Path {
        var path = Path()
        let center = CGPoint(x: rect.midX, y: rect.midY)
        let radius = min(rect.width, rect.height) / 2
        path.addArc(
            center: center,
            radius: radius,
            startAngle: startAngle,
            endAngle: endAngle,
            clockwise: false
        )
        return path
    }
}

public struct FanGaugeCard: View {
    let title: String
    let rpm: Int
    let temp: Int
    let maxRPM: Double = 5200.0
    let accentColor: Color

    public init(title: String, rpm: Int, temp: Int, accentColor: Color) {
        self.title = title
        self.rpm = rpm
        self.temp = temp
        self.accentColor = accentColor
    }

    private var progress: Double {
        min(max(Double(rpm) / maxRPM, 0.0), 1.0)
    }

    private var tempColor: Color {
        if temp <= 0 { return .secondary }
        if temp < 60 { return Color(red: 0.2, green: 0.85, blue: 0.5) }
        if temp < 80 { return Color(red: 0.95, green: 0.70, blue: 0.15) }
        return Color(red: 0.95, green: 0.25, blue: 0.25)
    }

    public var body: some View {
        VStack(spacing: 8) {
            HStack {
                Text(title)
                    .font(.system(size: 11, weight: .semibold, design: .rounded))
                    .foregroundColor(.secondary)
                Spacer()
                if temp > 0 {
                    HStack(spacing: 3) {
                        Circle()
                            .fill(tempColor)
                            .frame(width: 5, height: 5)
                        Text("\(temp)°C")
                            .font(.system(size: 11, weight: .semibold, design: .monospaced))
                            .foregroundColor(tempColor)
                    }
                }
            }

            ZStack {
                ArcGaugeShape(startAngle: .degrees(150), endAngle: .degrees(390))
                    .stroke(
                        Color.primary.opacity(0.07),
                        style: StrokeStyle(lineWidth: 6.5, lineCap: .round)
                    )

                ArcGaugeShape(
                    startAngle: .degrees(150),
                    endAngle: .degrees(150 + progress * 240.0)
                )
                .stroke(
                    LinearGradient(
                        colors: [accentColor.opacity(0.65), accentColor],
                        startPoint: .leading,
                        endPoint: .trailing
                    ),
                    style: StrokeStyle(lineWidth: 6.5, lineCap: .round)
                )
                .animation(.spring(response: 0.45, dampingFraction: 0.72), value: progress)

                VStack(spacing: 1) {
                    Text("\(rpm)")
                        .font(.system(size: 16, weight: .bold, design: .rounded))
                        .monospacedDigit()
                        .foregroundColor(.primary)
                    Text("RPM")
                        .font(.system(size: 9, weight: .semibold, design: .rounded))
                        .foregroundColor(.secondary)
                }
            }
            .frame(width: 86, height: 74)
            .padding(.vertical, 2)
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color(NSColor.controlBackgroundColor).opacity(0.55))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(Color.primary.opacity(0.06), lineWidth: 1)
        )
    }
}

public struct ThermalModePillButton: View {
    let mode: Int
    let title: String
    let icon: String
    let accentColor: Color
    let isSelected: Bool
    let action: () -> Void

    public var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: icon)
                    .font(.system(size: 10, weight: .bold))
                Text(title)
                    .font(.system(size: 11, weight: .semibold, design: .rounded))
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 7)
            .foregroundColor(isSelected ? .white : .primary)
            .background(
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(isSelected ? accentColor : Color.clear)
                    .shadow(color: isSelected ? accentColor.opacity(0.4) : Color.clear, radius: 4, y: 1)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

public struct QuickActionToggleCard: View {
    let title: String
    let subtitle: String
    let icon: String
    let isOn: Bool
    let activeColor: Color
    let action: () -> Void

    public init(
        title: String,
        subtitle: String,
        icon: String,
        isOn: Bool,
        activeColor: Color = Color.accentColor,
        action: @escaping () -> Void
    ) {
        self.title = title
        self.subtitle = subtitle
        self.icon = icon
        self.isOn = isOn
        self.activeColor = activeColor
        self.action = action
    }

    public var body: some View {
        Button(action: action) {
            HStack(spacing: 9) {
                ZStack {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(isOn ? activeColor.opacity(0.18) : Color.primary.opacity(0.05))
                        .frame(width: 30, height: 30)

                    Image(systemName: icon)
                        .font(.system(size: 12, weight: .bold))
                        .foregroundColor(isOn ? activeColor : .secondary)
                }

                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.system(size: 11, weight: .semibold, design: .rounded))
                        .foregroundColor(.primary)
                    Text(subtitle)
                        .font(.system(size: 9))
                        .foregroundColor(.secondary)
                }

                Spacer()

                Circle()
                    .fill(isOn ? activeColor : Color.secondary.opacity(0.25))
                    .frame(width: 6, height: 6)
            }
            .padding(9)
            .background(
                RoundedRectangle(cornerRadius: 11, style: .continuous)
                    .fill(Color(NSColor.controlBackgroundColor).opacity(0.52))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 11, style: .continuous)
                    .stroke(isOn ? activeColor.opacity(0.35) : Color.primary.opacity(0.06), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
    }
}

public struct GamingPopoverView: View {
    @ObservedObject var manager: GamingManager

    public init(manager: GamingManager) {
        self.manager = manager
    }

    public var body: some View {
        VStack(spacing: 12) {
            HStack(alignment: .center) {
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(manager.modelName)
                            .font(.system(size: 13, weight: .bold, design: .rounded))
                        Circle()
                            .fill(manager.isConnected ? Color.green : Color.red)
                            .frame(width: 6, height: 6)
                    }
                    if !manager.cpuBrand.isEmpty {
                        Text(manager.cpuBrand)
                            .font(.system(size: 10, design: .rounded))
                            .foregroundColor(.secondary)
                            .lineLimit(1)
                    }
                }

                Spacer()

                Button(action: {
                    manager.refreshAll()
                }) {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundColor(.secondary)
                        .padding(6)
                        .background(Circle().fill(Color.primary.opacity(0.05)))
                }
                .buttonStyle(.plain)
            }

            if manager.hasDualFan {
                HStack(spacing: 10) {
                    FanGaugeCard(
                        title: "CPU Fan",
                        rpm: manager.cpuFanRPM,
                        temp: manager.cpuTemp,
                        accentColor: Color(red: 0.1, green: 0.75, blue: 1.0)
                    )

                    FanGaugeCard(
                        title: "GPU Fan",
                        rpm: manager.gpuFanRPM,
                        temp: manager.gpuTemp,
                        accentColor: Color(red: 1.0, green: 0.40, blue: 0.15)
                    )
                }
            } else if manager.cpuFanRPM > 0 || manager.cpuTemp > 0 {
                FanGaugeCard(
                    title: "System Fan",
                    rpm: manager.cpuFanRPM,
                    temp: manager.cpuTemp,
                    accentColor: Color(red: 0.1, green: 0.75, blue: 1.0)
                )
            }

            if manager.hasThermalProfiles {
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text("Thermal Profile")
                            .font(.system(size: 10, weight: .bold, design: .rounded))
                            .foregroundColor(.secondary)
                        Spacer()
                        Text("Fn+Q Synced")
                            .font(.system(size: 9, weight: .medium))
                            .foregroundColor(.secondary)
                    }

                    HStack(spacing: 4) {
                        ThermalModePillButton(
                            mode: 1,
                            title: "Quiet",
                            icon: "leaf.fill",
                            accentColor: Color(red: 0.05, green: 0.70, blue: 0.95),
                            isSelected: manager.thermalMode == 1
                        ) {
                            manager.setThermalMode(1)
                        }

                        ThermalModePillButton(
                            mode: 2,
                            title: "Balanced",
                            icon: "speedometer",
                            accentColor: Color(white: 0.95),
                            isSelected: manager.thermalMode == 2
                        ) {
                            manager.setThermalMode(2)
                        }

                        ThermalModePillButton(
                            mode: 3,
                            title: "Performance",
                            icon: "flame.fill",
                            accentColor: Color(red: 0.95, green: 0.15, blue: 0.20),
                            isSelected: manager.thermalMode == 3
                        ) {
                            manager.setThermalMode(3)
                        }
                    }
                    .padding(3)
                    .background(
                        RoundedRectangle(cornerRadius: 11, style: .continuous)
                            .fill(Color(NSColor.controlBackgroundColor).opacity(0.68))
                    )
                }
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("Performance & Battery")
                    .font(.system(size: 10, weight: .bold, design: .rounded))
                    .foregroundColor(.secondary)

                LazyVGrid(
                    columns: [
                        GridItem(.flexible(), spacing: 8),
                        GridItem(.flexible(), spacing: 8)
                    ],
                    spacing: 8
                ) {
                    if manager.hasConservation {
                        QuickActionToggleCard(
                            title: "Conservation",
                            subtitle: "Limit 60% stop charge",
                            icon: "battery.75",
                            isOn: manager.isConservationOn,
                            activeColor: Color(red: 0.1, green: 0.75, blue: 0.95)
                        ) {
                            manager.toggleConservation()
                        }
                    }

                    if manager.hasRapidCharge {
                        QuickActionToggleCard(
                            title: "Rapid Charge",
                            subtitle: "High speed charging",
                            icon: "bolt.fill",
                            isOn: manager.isRapidChargeOn,
                            activeColor: Color(red: 1.0, green: 0.65, blue: 0.0)
                        ) {
                            manager.toggleRapidCharge()
                        }
                    }

                    if manager.hasFullFan {
                        QuickActionToggleCard(
                            title: "Full Fan Boost",
                            subtitle: "Max 100% cooling",
                            icon: "wind",
                            isOn: manager.isFullFanOn,
                            activeColor: Color(red: 0.2, green: 0.85, blue: 0.95)
                        ) {
                            manager.toggleFullFan()
                        }
                    }

                    if manager.hasOverDrive {
                        QuickActionToggleCard(
                            title: "Display OverDrive",
                            subtitle: "3ms high response",
                            icon: "display.and.arrow.down",
                            isOn: manager.isOverDriveOn,
                            activeColor: Color(red: 0.65, green: 0.35, blue: 0.95)
                        ) {
                            manager.toggleOverDrive()
                        }
                    }

                    if manager.hasWinKeyLock {
                        QuickActionToggleCard(
                            title: "Lock WinKey",
                            subtitle: "Disable Command key",
                            icon: "command",
                            isOn: manager.isWinKeyLocked,
                            activeColor: Color.orange
                        ) {
                            manager.toggleWinKey()
                        }
                    }

                    if manager.hasTouchpadLock {
                        QuickActionToggleCard(
                            title: "Lock Touchpad",
                            subtitle: "Disable trackpad",
                            icon: "hand.point.up.braille.fill",
                            isOn: manager.isTouchpadLocked,
                            activeColor: Color.orange
                        ) {
                            manager.toggleTouchpad()
                        }
                    }
                }
            }

            if manager.hasYLogo || manager.hasPortLighting || manager.hasAlwaysOnUSB {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Aesthetics & Ports")
                        .font(.system(size: 10, weight: .bold, design: .rounded))
                        .foregroundColor(.secondary)

                    if manager.hasYLogo || manager.hasPortLighting {
                        HStack(spacing: 8) {
                            if manager.hasYLogo {
                                QuickActionToggleCard(
                                    title: "Logo LED",
                                    subtitle: "Lid lighting",
                                    icon: "sparkles",
                                    isOn: manager.isYLogoOn,
                                    activeColor: Color(red: 0.95, green: 0.80, blue: 0.20)
                                ) {
                                    manager.toggleYLogo()
                                }
                            }

                            if manager.hasPortLighting {
                                QuickActionToggleCard(
                                    title: "Rear Port Icons",
                                    subtitle: "Port backlighting",
                                    icon: "cable.connector.horizontal",
                                    isOn: manager.isPortLightingOn,
                                    activeColor: Color(white: 0.95)
                                ) {
                                    manager.togglePortLighting()
                                }
                            }
                        }
                    }

                    if manager.hasAlwaysOnUSB {
                        VStack(alignment: .leading, spacing: 5) {
                            HStack {
                                Image(systemName: "powerplug.fill")
                                    .font(.system(size: 10))
                                    .foregroundColor(.secondary)
                                Text("Always-On USB Charging")
                                    .font(.system(size: 10, weight: .semibold, design: .rounded))
                                    .foregroundColor(.secondary)
                            }

                            Picker("", selection: Binding(
                                get: { manager.alwaysOnUSBState },
                                set: { manager.setAlwaysOnUSBState($0) }
                            )) {
                                Text("Off").tag(0)
                                Text("When Sleeping").tag(1)
                                Text("Always On").tag(2)
                            }
                            .pickerStyle(.segmented)
                        }
                        .padding(9)
                        .background(
                            RoundedRectangle(cornerRadius: 11, style: .continuous)
                                .fill(Color(NSColor.controlBackgroundColor).opacity(0.52))
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 11, style: .continuous)
                                .stroke(Color.primary.opacity(0.06), lineWidth: 1)
                        )
                    }
                }
            }
        }
        .padding(14)
        .frame(width: 335)
        .background(VisualEffectView().ignoresSafeArea())
    }
}

public struct VisualEffectView: NSViewRepresentable {
    public func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.blendingMode = .behindWindow
        view.state = .active
        view.material = .popover
        return view
    }

    public func updateNSView(_ nsView: NSVisualEffectView, context: Context) {}
}
