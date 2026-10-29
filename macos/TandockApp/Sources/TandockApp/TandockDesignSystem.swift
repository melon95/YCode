import AppKit
import SwiftUI
import TandockCore


enum TandockMetrics {
    static let sidebarWidth: CGFloat = 280
    static let sidebarMinWidth: CGFloat = 280
    static let inspectorWidth: CGFloat = 302
    static let inspectorMinWidth: CGFloat = 260
    static let inspectorMaxWidth: CGFloat = 460
    static let panelColumnWidth: CGFloat = 302
    static let panelColumnMinWidth: CGFloat = 180
    static let topBarHeight: CGFloat = 44
    static let panelCardGap: CGFloat = 8
    static let panelGrip: CGFloat = panelCardGap
    static let trafficLightWidth: CGFloat = 70
    static let canvasMinWidth: CGFloat = 420
    static let windowMinWidth: CGFloat = 720
    static let sidebarAutoCollapseWidth: CGFloat = 920
    static let panelsPerColumn = 2
    static let inspectorTabBarHeight: CGFloat = 38
    static let rowHeight: CGFloat = 28
    static let paneHeaderHeight: CGFloat = 28
    static let panelHeaderHeight: CGFloat = 30
    static let panelMinHeight: CGFloat = 120
    static let statusBarHeight: CGFloat = 26
    static let controlHeight: CGFloat = 24

    static let formLabelColumn: CGFloat = 132
    static let formGap: CGFloat = 14

    static let radiusChip: CGFloat = 4
    static let cornerRadius: CGFloat = 6
    static let radiusCard: CGFloat = 11
    static let radiusSheet: CGFloat = 14
}

enum TandockMotion {
    static let panelArea = Animation.easeInOut(duration: 0.18)
    static let hover = Animation.easeOut(duration: 0.12)
    static let contentSwap = Animation.easeOut(duration: 0.14)
    static let scroll = Animation.easeInOut(duration: 0.18)
}

enum TandockRowSelection {
    case fill
    case tint
    case raised
    case quiet
}

struct TandockRowSurface: ViewModifier {
    var isSelected: Bool
    var selection: TandockRowSelection = .tint
    var cornerRadius: CGFloat = TandockMetrics.cornerRadius
    var horizontalInset: CGFloat = 0

    @State private var hovering = false

    func body(content: Content) -> some View {
        content
            .background(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(fill)
                    .shadow(color: raised ? Color.tandockShadow : .clear, radius: 1, y: 1)
                    .padding(.horizontal, horizontalInset)
                    .animation(TandockMotion.hover, value: hovering)
            )
            .contentShape(Rectangle())
            .onHover { hovering = $0 }
    }

    private var fill: Color {
        switch (isSelected, selection) {
        case (true, .fill): Color.tandockAccent
        case (true, .tint): Color.tandockAccent.opacity(0.16)
        case (true, .raised): Color.tandockSelection
        case (true, .quiet): Color.primary.opacity(hovering ? 0.09 : 0.06)
        case (false, _): hovering ? Color.primary.opacity(0.06) : .clear
        }
    }

    private var raised: Bool { isSelected && selection == .raised }

}

struct TandockPlainButtonStyle: ButtonStyle {
    var cornerRadius: CGFloat = TandockMetrics.radiusChip
    var drawsBackground = true

    func makeBody(configuration: Configuration) -> some View {
        Content(configuration: configuration, cornerRadius: cornerRadius, drawsBackground: drawsBackground)
    }

    private struct Content: View {
        let configuration: ButtonStyleConfiguration
        let cornerRadius: CGFloat
        let drawsBackground: Bool
        @State private var hovering = false

        var body: some View {
            configuration.label
                .opacity(configuration.isPressed ? 0.55 : 1)
                .background {
                    if drawsBackground {
                        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                            .fill(fill)
                            .padding(.horizontal, -5)
                            .padding(.vertical, -3)
                            .animation(configuration.isPressed ? nil : TandockMotion.hover, value: hovering)
                    }
                }
                .contentShape(Rectangle())
                .onHover { hovering = $0 }
        }

        private var fill: Color {
            if configuration.isPressed { return Color.primary.opacity(0.12) }
            return hovering ? Color.primary.opacity(0.06) : .clear
        }
    }
}

struct TandockFormRow<Content: View>: View {
    let label: String
    var hint: String?
    var error: String?
    var trailing = false
    @ViewBuilder var content: () -> Content

    var body: some View {
        if trailing {
            VStack(alignment: .leading, spacing: 3) {
                HStack(alignment: .firstTextBaseline, spacing: TandockMetrics.formGap) {
                    Text(label).foregroundStyle(.primary)
                    Spacer(minLength: TandockMetrics.formGap)
                    content().multilineTextAlignment(.trailing)
                }
                note
            }
        } else {
            HStack(alignment: .firstTextBaseline, spacing: TandockMetrics.formGap) {
                Text(label)
                    .frame(width: TandockMetrics.formLabelColumn, alignment: .leading)
                    .foregroundStyle(.primary)
                VStack(alignment: .leading, spacing: 3) {
                    content()
                    note
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    @ViewBuilder
    private var note: some View {
        if let error {
            Label(error, systemImage: "exclamationmark.circle.fill")
                .font(.caption)
                .foregroundStyle(Color.tandockErr)
        } else if let hint {
            Text(hint)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

struct TandockFormValueRow: View {
    let label: String
    let value: String
    var mono = false
    var hint: String?
    var trailing = false

    var body: some View {
        TandockFormRow(label: label, hint: hint, trailing: trailing) {
            Text(value)
                .font(mono ? .system(.caption, design: .monospaced) : .body)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
        }
    }
}

extension View {
    func tandockRow(
        isSelected: Bool,
        selection: TandockRowSelection = .tint,
        cornerRadius: CGFloat = TandockMetrics.cornerRadius,
        horizontalInset: CGFloat = 0
    ) -> some View {
        modifier(TandockRowSurface(
            isSelected: isSelected,
            selection: selection,
            cornerRadius: cornerRadius,
            horizontalInset: horizontalInset
        ))
    }
}

struct TandockCardSurface: ViewModifier {
    var cornerRadius: CGFloat = TandockMetrics.radiusSheet
    var elevated = true

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        content
            .background {
                shape.fill(Color.tandockCard)
                    .shadow(color: elevated ? Color.tandockShadow : .clear, radius: 1, y: 1)
                    .shadow(color: elevated ? Color.tandockShadow : .clear, radius: 12, y: 6)
            }
            .overlay { shape.strokeBorder(Color.tandockHairline) }
    }
}

extension View {
    func tandockCard(cornerRadius: CGFloat = TandockMetrics.radiusSheet, elevated: Bool = true) -> some View {
        modifier(TandockCardSurface(cornerRadius: cornerRadius, elevated: elevated))
    }
}

extension Color {
    static func tandockDynamic(light: String, dark: String) -> Color {
        let lightColor = NSColor(hex: light) ?? .labelColor
        let darkColor = NSColor(hex: dark) ?? .labelColor
        return Color(nsColor: NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? darkColor : lightColor
        })
    }

    static let tandockOK = Color.tandockDynamic(light: "1A8A54", dark: "38B87C")
    static let tandockWarn = Color.tandockDynamic(light: "B67707", dark: "E0A33A")
    static let tandockErr = Color.tandockDynamic(light: "D2382F", dark: "F0655A")
    static let tandockLabel3 = Color(nsColor: .tertiaryLabelColor)
    // Dark values follow the Atom One Dark UI palette; the coral accent stays as the brand color.
    static let tandockChrome = Color.tandockDynamic(light: "EFEEF4", dark: "21252B")
    static let tandockAccent = Color.tandockDynamic(light: "FF5A4E", dark: "FF7D72")
    static let tandockAccentText = Color.tandockDynamic(light: "C3301F", dark: "FF8F85")
    static let tandockCard = Color.tandockDynamic(light: "FCFCFE", dark: "282C34")
    static let tandockRowLitBase = Color.tandockDynamic(light: "E1E0E6", dark: "2C313A")
    static let tandockSelection = Color.tandockDynamic(light: "FFFFFF", dark: "3A3F4B")
    static let tandockHairline = Color(nsColor: NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            ? NSColor.white.withAlphaComponent(0.07)
            : NSColor(srgbRed: 22 / 255, green: 19 / 255, blue: 58 / 255, alpha: 0.08)
    })
    static let tandockShadow = Color(nsColor: NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            ? NSColor.black.withAlphaComponent(0.25)
            : NSColor(srgbRed: 22 / 255, green: 19 / 255, blue: 58 / 255, alpha: 0.08)
    })
}

struct TandockIconButtonStyle: ButtonStyle {
    var isOn = false
    var width: CGFloat = 26
    var height: CGFloat = 24
    var fontSize: CGFloat = 13

    func makeBody(configuration: Configuration) -> some View {
        Content(configuration: configuration, isOn: isOn, width: width, height: height, fontSize: fontSize)
    }

    private struct Content: View {
        let configuration: ButtonStyleConfiguration
        let isOn: Bool
        let width: CGFloat
        let height: CGFloat
        let fontSize: CGFloat
        @State private var hovering = false

        var body: some View {
            configuration.label
                .font(.system(size: fontSize, weight: .regular))
                .foregroundStyle(isOn ? Color.tandockAccent : Color.secondary)
                .frame(width: width, height: height)
                .background(fill, in: RoundedRectangle(cornerRadius: TandockMetrics.cornerRadius, style: .continuous))
                .animation(configuration.isPressed ? nil : TandockMotion.hover, value: hovering)
                .contentShape(Rectangle())
                .onHover { hovering = $0 }
        }

        private var fill: Color {
            if configuration.isPressed { return Color.primary.opacity(0.14) }
            if isOn { return Color.tandockAccent.opacity(0.15) }
            return hovering ? Color.primary.opacity(0.07) : .clear
        }
    }
}

struct TandockPanelHeaderSpec {
    let panel: TandockWorkspacePanel
    var badge: Int?
    var height: CGFloat
    var close: () -> Void
    var moveUp: () -> Void
    var moveDown: () -> Void
    var canMoveUp: Bool
    var canMoveDown: Bool
    var iconIsOn = false
    var iconAction: (() -> Void)?
    var iconHelp = ""
    var showsIcon = true
}

struct TandockPanelHeaderTitle: View {
    let spec: TandockPanelHeaderSpec
    @Environment(\.tandockL10n) private var l10n

    var body: some View {
        HStack(spacing: 6) {
            Text(spec.panel.localizedTitle(l10n))
                .font(.caption.weight(.semibold))
                .lineLimit(1)
                .fixedSize()
            if let badge = spec.badge, badge > 0 {
                Text("\(badge)")
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.tertiary)
                    .fixedSize()
            }
        }
    }
}

struct TandockPanelHeader<Leading: View, Actions: View>: View {
    let spec: TandockPanelHeaderSpec
    @ViewBuilder var leading: () -> Leading
    @ViewBuilder var actions: () -> Actions
    @Environment(\.tandockL10n) private var l10n

    var body: some View {
        HStack(spacing: 6) {
            icon
            leading()
            Spacer(minLength: 0).layoutPriority(-1)
            actions()
            Button(action: spec.close) { Image(systemName: "xmark") }
                .buttonStyle(TandockIconButtonStyle(width: 22, height: 22, fontSize: 11))
                .help(l10n.text("closePanel"))
        }
        .padding(.leading, 8)
        .padding(.trailing, 6)
        .frame(height: spec.height)
        .contentShape(Rectangle())
        .contextMenu {
            Button(l10n.text("moveUp"), action: spec.moveUp).disabled(!spec.canMoveUp)
            Button(l10n.text("moveDown"), action: spec.moveDown).disabled(!spec.canMoveDown)
            Divider()
            Button(l10n.text("closePanel"), action: spec.close)
        }
    }
}

extension TandockPanelHeader {
    @ViewBuilder
    private var icon: some View {
        if !spec.showsIcon {
            EmptyView()
        } else if let action = spec.iconAction {
            Button(action: action) { Image(systemName: spec.panel.symbolName) }
                .buttonStyle(TandockIconButtonStyle(isOn: spec.iconIsOn, width: 20, height: 20, fontSize: 11))
                .help(spec.iconHelp)
        } else {
            Image(systemName: spec.panel.symbolName)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(width: 20, height: 20)
                .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: TandockMetrics.radiusChip, style: .continuous))
                .fixedSize()
        }
    }
}

extension TandockPanelHeader where Leading == TandockPanelHeaderTitle {
    init(spec: TandockPanelHeaderSpec, @ViewBuilder actions: @escaping () -> Actions) {
        self.init(spec: spec, leading: { TandockPanelHeaderTitle(spec: spec) }, actions: actions)
    }
}

extension TandockPanelHeader where Leading == TandockPanelHeaderTitle, Actions == EmptyView {
    init(spec: TandockPanelHeaderSpec) {
        self.init(spec: spec, leading: { TandockPanelHeaderTitle(spec: spec) }, actions: { EmptyView() })
    }
}

extension View {
    func tandockPanelAction() -> some View {
        buttonStyle(TandockIconButtonStyle(width: 22, height: 22, fontSize: 11))
    }

    func tandockPanelMenu() -> some View {
        menuStyle(.button)
            .buttonStyle(TandockIconButtonStyle(width: 22, height: 22, fontSize: 11))
            .menuIndicator(.hidden)
            .fixedSize()
    }
}

enum TandockSessionPresence: Equatable {
    case running
    case needsYou
    case unread
    case idle

    var color: Color {
        switch self {
        case .running: .tandockOK
        case .needsYou: .tandockWarn
        case .unread: .blue
        case .idle: .tandockLabel3
        }
    }

    func title(_ l10n: TandockLocalization) -> String {
        switch self {
        case .running: l10n.text("presenceRunning")
        case .needsYou: l10n.text("presenceNeedsYou")
        case .unread: l10n.text("presenceUnread")
        case .idle: l10n.text("presenceIdle")
        }
    }
}

struct TandockStatusDot: View {
    let presence: TandockSessionPresence
    var size: CGFloat = 7

    var body: some View {
        Circle()
            .fill(presence.color)
            .frame(width: size, height: size)
    }
}

struct TandockStatusBadge: View {
    let presence: TandockSessionPresence
    let ringColor: Color
    var size: CGFloat = 9

    var body: some View {
        if presence != .idle {
            Circle()
                .fill(presence.color)
                .frame(width: size, height: size)
                .overlay(Circle().strokeBorder(ringColor, lineWidth: 1.5))
                .padding(-1.5)
        }
    }
}

extension WorkspaceModel {
    func presence(for session: SessionMetadata) -> TandockSessionPresence {
        if needsYouSessionIDs.contains(session.id) { return .needsYou }
        if unreadSessionIDs.contains(session.id) { return .unread }
        switch runtimeStatus(for: session) {
        case .running, .starting: return .running
        default: return .idle
        }
    }

    var needsYouSessionIDs: Set<String> {
        Set(attentionItems.filter { $0.kind.needsAttention }.map(\.sessionID))
    }
}

@MainActor
enum TandockAppearanceProbe {
    static var prefersDark: Bool {
        NSApp?.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
    }

    /// Sets the app-wide appearance synchronously so `activeTheme` resolves against the new value in the same pass.
    /// `.preferredColorScheme` flips it only after the render, leaving terminal colors on the previous scheme when returning to system.
    static func apply(themeID: String) {
        let name: NSAppearance.Name? = switch themeID {
        case TandockThemeCatalog.light.id: .aqua
        case TandockThemeCatalog.dark.id: .darkAqua
        default: nil
        }
        let appearance = name.flatMap(NSAppearance.init(named:))
        if NSApp?.appearance?.name != appearance?.name { NSApp?.appearance = appearance }
    }
}

extension ProjectRecord {
    var displayTitle: String {
        guard let first = name.first, first.isLowercase else { return name }
        return first.uppercased() + name.dropFirst()
    }
}

struct TandockInspectorEmptyState: View {
    let title: String
    let message: String
    var symbol: String?

    var body: some View {
        VStack(spacing: 5) {
            if let symbol {
                Image(systemName: symbol)
                    .font(.system(size: 22, weight: .light))
                    .foregroundStyle(.tertiary)
                    .padding(.bottom, 3)
            }
            Text(title)
                .font(.subheadline.weight(.semibold))
            Text(message)
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
