import SwiftUI
import AppKit

public struct HardwareControlsActions {
    let showAbout: () -> Void
    let retryDriverConnection: () -> Void
    let resetShortcuts: () -> Void

    public init(showAbout: @escaping () -> Void, retryDriverConnection: @escaping () -> Void,
                resetShortcuts: @escaping () -> Void) {
        self.showAbout = showAbout
        self.retryDriverConnection = retryDriverConnection
        self.resetShortcuts = resetShortcuts
    }
}

public struct HardwareControlsView: View {
    @ObservedObject var manager: HardwareManager
    @AppStorage("ControlsPage") private var savedPage = 0
    @State private var reviewPage = 0
    private var page: ControlsPage {
        get { ControlsPage(rawValue: CommandLine.arguments.contains("--render-ui") ? reviewPage : savedPage) ?? .overview }
        nonmutating set {
            if CommandLine.arguments.contains("--render-ui") { reviewPage = newValue.rawValue }
            else { savedPage = newValue.rawValue }
        }
    }
    private let actions: HardwareControlsActions
    public init(manager: HardwareManager, page: Int = 0, actions: HardwareControlsActions) {
        self.manager = manager; self._reviewPage = State(initialValue: page); self.actions = actions
    }
    public var body: some View {
        dashboard
        .frame(minWidth: AppTheme.width, maxWidth: .infinity, minHeight: AppTheme.height, maxHeight: .infinity)

    }
    private var dashboard: some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    Image(nsImage: ReYogaBrand.menuImage(size: 24)).renderingMode(.template)
                    Text(localizedMessage("ReYogaSMC")).font(.system(size: 15, weight: .semibold))
                }.padding(.bottom, 12).padding(.top, 4)
                ForEach(ControlsPage.sidebar, id: \.self) { destination in
                    Button(action: { page = destination }) {
                        HStack(spacing: 9) {
                            AnimatedSymbol( destination.symbol).frame(width: 18, height: 18)
                            Text(loc(destination.title)).lineLimit(1)
                        }
                            .font(.system(size: 12, weight: page == destination ? .semibold : .regular))
                            .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 9).padding(.vertical, 8)
                            .foregroundColor(page == destination ? AppTheme.accent : .primary)
                            .background(page == destination ? AppTheme.accent.opacity(0.12) : Color.clear)
                            .cornerRadius(8).contentShape(Rectangle())
                    }.buttonStyle(FeedbackButtonStyle()).accessibilityAddTraits(page == destination ? .isSelected : [])
                }
                Spacer()
                HStack(spacing: 9) {
                    Circle().fill(manager.isConnected ? AppTheme.connected : .gray)
                        .frame(width: 6, height: 6).frame(width: 18, height: 18)
                    Text(localizedMessage(manager.isConnected ? loc(.sidebarStatusKextLoaded) : loc(.sidebarStatusKextUnloaded)))
                        .font(.system(size: 11, weight: .medium))
                    Spacer(minLength: 0)
                }.foregroundColor(manager.isConnected ? AppTheme.connected : .secondary)
                    .padding(.horizontal, 9).padding(.vertical, 7)
                    .background((manager.isConnected ? AppTheme.connected : .gray).opacity(0.07))
                    .cornerRadius(8).accessibilityElement(children: .combine)

                Divider()
                HStack(spacing: 8) {
                    Button(action: { page = (page == .settings ? .overview : .settings) }) {
                        AnimatedSymbol("gearshape").frame(width: 18, height: 18)
                            .padding(8)
                            .foregroundColor(page == .settings ? AppTheme.accent : .primary)
                            .background(page == .settings ? AppTheme.accent.opacity(0.12) : Color.clear)
                            .cornerRadius(8).contentShape(Rectangle())
                    }.keyboardShortcut(",", modifiers: .command).help(loc(.sidebarSettingsTooltip))
                    Spacer()
                    Menu {
                        Button(loc(.sidebarAboutApp)) { actions.showAbout() }
                        Divider()
                        Button(loc(.sidebarQuitApp)) { NSApp.terminate(nil) }.keyboardShortcut("q", modifiers: .command)
                    } label: {
                        AnimatedSymbol( "ellipsis").frame(width: 22, height: 28)
                    }.menuStyle(BorderlessButtonMenuStyle()).fixedSize().help(loc(.sidebarAppMenuTooltip))
                }.foregroundColor(.secondary)
            }.buttonStyle(FeedbackButtonStyle()).padding(12).frame(width: 154)
                .background(Color(NSColor.controlBackgroundColor))
            Divider()
            VStack(spacing: 0) {
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(loc(page.title)).font(.system(size: 19, weight: .semibold))
                        Text(localizedMessage(pageSubtitle)).font(.system(size: 11)).foregroundColor(.secondary)
                    }
                    Spacer()
                    if page != .settings {
                        Button(action: { manager.refreshAll() }) { AnimatedSymbol("arrow.clockwise").frame(width: 28, height: 28) }.buttonStyle(FeedbackButtonStyle())
                            .help(loc(.commonRefresh)).accessibilityLabel(loc(.commonRefresh))
                    } else {
                        Button(action: { page = .overview }) {
                            HStack(spacing: 4) {
                                AnimatedSymbol("chevron.left").frame(width: 14, height: 14)
                                Text(loc(.commonBack))
                            }.font(.system(size: 12))
                        }.buttonStyle(FeedbackButtonStyle())
                    }
                }.padding(.horizontal, 16).padding(.vertical, 12)
                Divider()
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        if manager.driverState != .ready {
                            VStack(alignment: .leading, spacing: 8) {
                                SymbolLabel(manager.driverMessage, systemImage: "exclamationmark.triangle")
                                    .font(.system(size: 12)).foregroundColor(.orange)
                                Button(loc(.driverRetryConnection)) { actions.retryDriverConnection() }
                                    .disabled(manager.driverState == .checking)
                            }.padding(10).frame(maxWidth: .infinity, alignment: .leading)
                                .background(Color.orange.opacity(0.06)).cornerRadius(8)
                        }
                        switch page {
                        case .settings: SettingsPage(manager: manager, actions: actions)
                        case .overview: OverviewPage(manager: manager, openBatteryReport: { page = .battery })
                        case .device: DeviceControlsPage(manager: manager)
                        case .cooling: CoolingControlsPage(manager: manager)
                        case .battery: BatteryReportPage(manager: manager)
                        case .lighting: LightingControlsPage(manager: manager)
                        case .diagnostics: DiagnosticsPage(manager: manager)
                        }
                    }.padding(14).frame(maxWidth: .infinity, alignment: .leading)
                }.frame(maxHeight: .infinity).layoutPriority(1)
            }
        }.frame(minWidth: AppTheme.width, maxWidth: .infinity, minHeight: AppTheme.height, maxHeight: .infinity)
            .background(Color(NSColor.windowBackgroundColor))
    }
    private var pageSubtitle: String { loc(page.subtitle) }
}
