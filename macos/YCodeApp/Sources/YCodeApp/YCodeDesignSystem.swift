import AppKit
import SwiftUI
import YCodeCore

/// 设计稿 §02 的 token。整份界面的颜色、尺寸、状态语言都从这里取，不在各视图里另写字面量。

enum YCodeMetrics {
    static let sidebarWidth: CGFloat = 238
    static let sidebarMinWidth: CGFloat = 200
    static let sidebarMaxWidth: CGFloat = 320
    static let inspectorWidth: CGFloat = 302
    static let inspectorMinWidth: CGFloat = 260
    static let inspectorMaxWidth: CGFloat = 460
    /// 面板区：每列默认 302，往宽了拖不设上限 —— 唯一的天花板是画布的最小宽。
    static let panelColumnWidth: CGFloat = 302
    static let panelColumnMinWidth: CGFloat = 180
    /// 画布顶栏 = 面板区第一张卡的卡头：全窗顶上只有这一条横向元素（设计稿 §04）。
    static let topBarHeight: CGFloat = 44
    /// 面板区里卡与卡、列与列之间那条隔条（设计稿 §07 的 `.grip`）。
    static let panelGrip: CGFloat = 5
    /// 红绿灯浮在内容上，侧栏顶栏给它让开的左边一段。
    static let trafficLightWidth: CGFloat = 70
    static let canvasMinWidth: CGFloat = 420
    /// 一列最多两张卡，开第三个就另起一列。
    static let panelsPerColumn = 2
    static let inspectorTabBarHeight: CGFloat = 38
    static let rowHeight: CGFloat = 28
    static let paneHeaderHeight: CGFloat = 28
    /// 面板区里每张卡的卡头与最小高度（设计稿 §07）。
    static let panelHeaderHeight: CGFloat = 30
    static let panelMinHeight: CGFloat = 120
    static let statusBarHeight: CGFloat = 26
    static let controlHeight: CGFloat = 24
    static let cornerRadius: CGFloat = 6
}

/// 布局过渡。开合面板区、加/减一列、收放侧栏这几处的宽度变化都走同一条曲线，
/// 免得一个窗口里几种快慢不一的滑动。
/// 拖分隔条**不**走这里：那一条要跟手，套上动画就变成拖完还在追的滞后感。
enum YCodeMotion {
    static let panelArea = Animation.easeInOut(duration: 0.18)
}

extension Color {
    /// 随系统外观切换的动态色；两个值都取自设计稿的 token 表。
    static func ycodeDynamic(light: String, dark: String) -> Color {
        let lightColor = NSColor(hex: light) ?? .labelColor
        let darkColor = NSColor(hex: dark) ?? .labelColor
        return Color(nsColor: NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? darkColor : lightColor
        })
    }

    /// 会话状态 · 运行中
    static let ycodeOK = Color.ycodeDynamic(light: "1A8A54", dark: "38B87C")
    /// 会话状态 · 等你
    static let ycodeWarn = Color.ycodeDynamic(light: "B67707", dark: "E0A33A")
    /// 破坏性动作 / 删除行
    static let ycodeErr = Color.ycodeDynamic(light: "D2382F", dark: "F0655A")
    /// 三级文字
    static let ycodeLabel3 = Color(nsColor: .tertiaryLabelColor)
    /// 侧栏与检查器共用的 chrome 底色（设计稿 §02 的 --sidebar / --inspector）。
    /// 不用系统材质：sidebar 的 vibrancy 偏亮、inspector 偏暗，两边摆在同一个窗口里能看出色差。
    static let ycodeChrome = Color.ycodeDynamic(light: "F4F4F6", dark: "242426")
}

/// 顶栏与卡头上的图标按钮。系统的 `.bordered` / `.toggleStyle(.button)` 会给每个图标套一个
/// 带描边的胶囊，四个开关并排就是四块厚砖，跟旁边无边框的图标不是一套语言。
/// 这里只留一个 26×24 的圆角命中区：hover 浮一层底、开着时上强调色，平时什么都不画。
struct YCodeIconButtonStyle: ButtonStyle {
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
                .foregroundStyle(isOn ? Color.accentColor : Color.secondary)
                .frame(width: width, height: height)
                .background(fill, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                .contentShape(Rectangle())
                .onHover { hovering = $0 }
        }

        private var fill: Color {
            if configuration.isPressed { return Color.primary.opacity(0.14) }
            if isOn { return Color.accentColor.opacity(0.15) }
            return hovering ? Color.primary.opacity(0.07) : .clear
        }
    }
}

/// 面板卡头要画的那几样东西。面板自己拿着它，把自己的动作按钮塞进同一行 ——
/// 卡头底下不再跟第二条工具条（设计稿 §07）。
struct YCodePanelHeaderSpec {
    let panel: YCodeWorkspacePanel
    var badge: Int?
    /// 列首那张 44（与画布顶栏同高），其余 30。
    var height: CGFloat
    var close: () -> Void
    var moveUp: () -> Void
    var moveDown: () -> Void
    var canMoveUp: Bool
    var canMoveDown: Bool
    /// 左边那枚图标可以是个开关（变更面板拿它切树／平铺）。面板自己在传给卡头前填上。
    var iconIsOn = false
    var iconAction: (() -> Void)?
    var iconHelp = ""
}

/// 卡头默认的那段 —— 面板名 + 计数。终端面板用标签条顶掉它。
struct YCodePanelHeaderTitle: View {
    let spec: YCodePanelHeaderSpec
    @Environment(\.ycodeL10n) private var l10n

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
                    // 不钉住的话，右边有东西要位置时这个数会被压成一列竖着的数字。
                    .fixedSize()
            }
        }
    }
}

/// 面板卡头：一行装完 —— 图标 + 名字（或面板自己的一段，比如终端的标签条）
/// + 这个面板自己的动作 + ✕。
struct YCodePanelHeader<Leading: View, Actions: View>: View {
    let spec: YCodePanelHeaderSpec
    @ViewBuilder var leading: () -> Leading
    @ViewBuilder var actions: () -> Actions
    @Environment(\.ycodeL10n) private var l10n

    var body: some View {
        HStack(spacing: 6) {
            icon
            leading()
            // 空位最后才分：不压到这一条，leading 里可伸缩的东西（比如变更的分支面包屑、
            // 文件面板的标签条）会先被 Spacer 抢走宽度，明明放得下却截断了。
            // minLength 必须是 0：leading 把空位吃干净时，一条吃不到的 Spacer
            // 还要硬占 6 就会把整行顶宽，右端的 ✕ 被挤出卡外。
            Spacer(minLength: 0).layoutPriority(-1)
            actions()
            Button(action: spec.close) { Image(systemName: "xmark") }
                .buttonStyle(YCodeIconButtonStyle(width: 22, height: 22, fontSize: 11))
                .help(l10n.text("closePanel"))
        }
        .padding(.leading, 8)
        .padding(.trailing, 6)
        .frame(height: spec.height)
        .background(Color.ycodeChrome)
        .contentShape(Rectangle())
        .contextMenu {
            Button(l10n.text("moveUp"), action: spec.moveUp).disabled(!spec.canMoveUp)
            Button(l10n.text("moveDown"), action: spec.moveDown).disabled(!spec.canMoveDown)
            Divider()
            Button(l10n.text("closePanel"), action: spec.close)
        }
    }
}

extension YCodePanelHeader {
    @ViewBuilder
    private var icon: some View {
        if let action = spec.iconAction {
            Button(action: action) { Image(systemName: spec.panel.symbolName) }
                .buttonStyle(YCodeIconButtonStyle(isOn: spec.iconIsOn, width: 20, height: 20, fontSize: 11))
                .help(spec.iconHelp)
        } else {
            Image(systemName: spec.panel.symbolName)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(width: 20, height: 20)
                .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 5, style: .continuous))
                .fixedSize()
        }
    }
}

extension YCodePanelHeader where Leading == YCodePanelHeaderTitle {
    init(spec: YCodePanelHeaderSpec, @ViewBuilder actions: @escaping () -> Actions) {
        self.init(spec: spec, leading: { YCodePanelHeaderTitle(spec: spec) }, actions: actions)
    }
}

extension YCodePanelHeader where Leading == YCodePanelHeaderTitle, Actions == EmptyView {
    init(spec: YCodePanelHeaderSpec) {
        self.init(spec: spec, leading: { YCodePanelHeaderTitle(spec: spec) }, actions: { EmptyView() })
    }
}

extension View {
    /// 卡头上那一排动作按钮共用的样式 —— 跟画布顶栏的图标是同一套，只是小一号。
    func ycodePanelAction() -> some View {
        buttonStyle(YCodeIconButtonStyle(width: 22, height: 22, fontSize: 11))
    }

    /// 卡头上的 ⋯ 菜单，跟旁边的按钮同一个尺寸与颜色。
    /// 走 `.menuStyle(.button)` 而不是 `.borderlessButton`：后者不认 label 上的
    /// `foregroundStyle`，会把 ⋯ 染成强调色蓝，一排灰图标里就它是蓝的。
    func ycodePanelMenu() -> some View {
        menuStyle(.button)
            .buttonStyle(YCodeIconButtonStyle(width: 22, height: 22, fontSize: 11))
            .menuIndicator(.hidden)
            .fixedSize()
    }
}

/// 设计稿 §02「状态语言 —— 只有两个」：会话永远可以 resume，
/// 所以 exited / signaled / recoverable 不进入界面，只留「运行中 / 等你 / 静默」。
enum YCodeSessionPresence {
    /// agent 在干活，不需要你
    case running
    /// 在等输入、等审批，或刚建好还没跑起来 —— 唯一会进收件箱、会亮侧栏计数的状态
    case needsYou
    /// 没有进程在跑。列表里不强调，点进去就接着跑
    case idle

    var color: Color {
        switch self {
        case .running: .ycodeOK
        case .needsYou: .ycodeWarn
        case .idle: .ycodeLabel3
        }
    }

    func title(_ l10n: YCodeLocalization) -> String {
        switch self {
        case .running: l10n.text("presenceRunning")
        case .needsYou: l10n.text("presenceNeedsYou")
        case .idle: l10n.text("presenceIdle")
        }
    }
}

/// 侧栏会话行、画布窗格头、收件箱条目共用的同一个点。
struct YCodeStatusDot: View {
    let presence: YCodeSessionPresence
    var size: CGFloat = 7

    var body: some View {
        Circle()
            .fill(presence.color)
            .frame(width: size, height: size)
    }
}

extension WorkspaceModel {
    func presence(for session: SessionMetadata) -> YCodeSessionPresence {
        if attentionEvent(for: session.id) != nil { return .needsYou }
        switch runtimeStatus(for: session) {
        case .running, .starting: return .running
        default: return .idle
        }
    }

    /// 「等你」的会话数 —— 侧栏过滤 chip、工具栏铃铛、收件箱三处同源。
    var needsYouSessionIDs: Set<String> {
        Set(attentionEvents.keys)
    }
}

enum YCodeAppearanceProbe {
    /// 当前系统外观是不是深色。
    static var prefersDark: Bool {
        NSApp?.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
    }
}

extension ProjectRecord {
    /// 窗口标题里的项目名首字母大写 —— 标题栏是句首位置，`ycode` 在那里读起来像路径片段。
    /// 只动第一个字母，其余原样保留（`melon-autoui` → `Melon-autoui`）。
    var displayTitle: String {
        guard let first = name.first, first.isLowercase else { return name }
        return first.uppercased() + name.dropFirst()
    }
}

/// 检查器里的空状态。`ContentUnavailableView` 的默认排版是为整页准备的 ——
/// 在 302 px 宽的一栏里，它的大图标和 title 字号会把一句话撑成一屏。
struct YCodeInspectorEmptyState: View {
    let title: String
    let message: String

    var body: some View {
        VStack(spacing: 5) {
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
