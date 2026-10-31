import SwiftUI
import AppKit

struct StateAnimation<Value: Equatable>: ViewModifier {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let value: Value
    func body(content: Content) -> some View {
        if #available(macOS 12.0, *) {
            content.animation(reduceMotion ? nil : .easeInOut(duration: 0.18), value: value)
        } else {
            content
        }
    }
}

private struct SymbolPressedKey: EnvironmentKey { static let defaultValue = false }
private extension EnvironmentValues {
    var symbolPressed: Bool {
        get { self[SymbolPressedKey.self] }
        set { self[SymbolPressedKey.self] = newValue }
    }
}

struct AnimatedSymbol: View {
    let name: String
    @State private var hovering = false
    @Environment(\.symbolPressed) private var pressed
    @Environment(\.isEnabled) private var enabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    init(_ name: String) { self.name = name }
    var body: some View {
        Image(systemName: name)
            .scaleEffect(reduceMotion || !enabled ? 1 : pressed ? 0.90 : hovering ? 1.10 : 1)
            .opacity(enabled && hovering ? 0.85 : 1)
            .modifier(StateAnimation(value: hovering))
            .modifier(StateAnimation(value: pressed))
            .onHover { hovering = $0 }.accessibilityHidden(true)
    }
}

struct SymbolLabel: View {
    let title: String
    let icon: String
    init(_ title: String, systemImage: String) { self.title = title; icon = systemImage }
    var body: some View {
        HStack(spacing: 6) { AnimatedSymbol(icon); Text(localizedMessage(title)) }
            .accessibilityElement(children: .combine)
    }
}

struct FeedbackButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View { FeedbackButtonBody(configuration: configuration) }
}

private struct FeedbackButtonBody: View {
    let configuration: ButtonStyleConfiguration
    @State private var hovering = false
    @Environment(\.isEnabled) private var enabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var body: some View {
        configuration.label
            .environment(\.symbolPressed, configuration.isPressed)
            .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(enabled && hovering ? 0.045 : 0)))
            .opacity(configuration.isPressed ? 0.82 : 1)
            .scaleEffect(configuration.isPressed && !reduceMotion ? 0.985 : 1)
            .modifier(StateAnimation(value: configuration.isPressed))
            .modifier(StateAnimation(value: hovering))
            .onHover { hovering = $0 }
    }
}

struct ControlSection<Content: View>: View {
    let title: String
    let content: Content
    let fillsRow: Bool
    init(_ title: String, fillsRow: Bool = false, @ViewBuilder content: () -> Content) {
        self.title = title; self.fillsRow = fillsRow; self.content = content()
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(localizedMessage(title)).font(.system(size: 12, weight: .semibold)).foregroundColor(.secondary).accessibilityAddTraits(.isHeader)
            VStack(alignment: .leading, spacing: 0) { content }
                .frame(maxWidth: .infinity, maxHeight: fillsRow ? .infinity : nil, alignment: .topLeading)
                .padding(10).background(AppTheme.surface)
                .cornerRadius(12)
                .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.primary.opacity(0.045), lineWidth: 1))
        }.frame(maxWidth: .infinity, maxHeight: fillsRow ? .infinity : nil, alignment: .topLeading)
    }
}

private struct FeatureRow: View {
    let title: String
    let icon: String
    let isOn: Bool
    let available: Bool
    let reason: String
    let action: () -> Void
    private var color: Color { AppTheme.feature(icon) }
    var body: some View {
        HStack(spacing: 8) {
            Group {
                if icon == "fn" {
                    Text(localizedMessage("fn"))
                        .font(.system(size: 11, weight: .bold, design: .rounded))
                } else {
                    AnimatedSymbol( icon)
                        .font(.system(size: 12, weight: .medium))
                }
            }
            .frame(width: 28, height: 28)
            .foregroundColor(available && isOn ? color : .secondary)
            .background(
                RoundedRectangle(cornerRadius: 7)
                    .fill(available && isOn ? color.opacity(0.12) : Color.primary.opacity(0.04))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 7)
                    .stroke(available && isOn ? color.opacity(0.24) : Color.primary.opacity(0.08), lineWidth: 0.5)
            )
            VStack(alignment: .leading, spacing: 4) {
                Text(localizedMessage(title)).font(.system(size: 12, weight: .medium)).fixedSize(horizontal: false, vertical: true)
                if !available { Text(localizedMessage(reason)).font(.system(size: 11)).foregroundColor(.secondary).fixedSize(horizontal: false, vertical: true) }
            }
            Spacer(minLength: 8)
            Text(localizedMessage(available ? (isOn ? loc(.commonOn) : loc(.commonOff)) : loc(.commonUnavailable)))
                .font(.system(size: 11, weight: isOn && available ? .semibold : .regular))
                .foregroundColor(isOn && available ? color : .secondary)
                .padding(.horizontal, 6).padding(.vertical, 3)
                .background(isOn && available ? color.opacity(0.10) : Color.clear).cornerRadius(5)
            Toggle(title, isOn: Binding(get: { isOn }, set: { _ in action() }))
                .labelsHidden().toggleStyle(SwitchToggleStyle()).accentColor(color).disabled(!available)
                .accessibilityLabel(localizedMessage(title)).accessibilityHint(localizedMessage(available ? "" : reason))
        }.padding(.vertical, 5).frame(minHeight: 40)
    }
}

struct ControlFeatureRow: View {
    @ObservedObject var manager: HardwareManager
    let titleKey: LocalizedKey
    let key: String
    let icon: String
    let state: Bool
    let available: Bool
    let action: () -> Void

    init(_ manager: HardwareManager, _ titleKey: LocalizedKey, _ key: String, _ icon: String,
         _ state: Bool, _ available: Bool, action: @escaping () -> Void) {
        self.manager = manager; self.titleKey = titleKey; self.key = key; self.icon = icon
        self.state = state; self.available = available; self.action = action
    }
    var body: some View {
        FeatureRow(title: loc(titleKey), icon: icon, isOn: state, available: available,
                   reason: manager.featureStatus[key]?.reason ?? "No verified interface on this device", action: action)
            .disabled(manager.applyingControl == key)
    }
}
