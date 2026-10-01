import AppKit
import SwiftUI
import YCodeCore

/// 设计稿 §02 的 token。整份界面的颜色、尺寸、状态语言都从这里取，不在各视图里另写字面量。

enum YCodeMetrics {
    static let sidebarWidth: CGFloat = 280
    static let sidebarMinWidth: CGFloat = 280
    static let inspectorWidth: CGFloat = 302
    static let inspectorMinWidth: CGFloat = 260
    static let inspectorMaxWidth: CGFloat = 460
    /// 面板区：每列默认 302，往宽了拖不设上限 —— 唯一的天花板是画布的最小宽。
    static let panelColumnWidth: CGFloat = 302
    static let panelColumnMinWidth: CGFloat = 180
    /// 画布顶栏 = 面板区第一张卡的卡头：全窗顶上只有这一条横向元素（设计稿 §04）。
    static let topBarHeight: CGFloat = 44
    /// 面板区里卡与卡、列与列之间那条隔条（设计稿 §07 的 `.grip`）。
    /// 浮卡之间的缝与画布四周的留白（视觉方向 B）。画布窗格由 AppKit 画，数值与这里一致。
    static let panelCardGap: CGFloat = 8
    static let panelGrip: CGFloat = panelCardGap
    /// 红绿灯浮在内容上，侧栏顶栏给它让开的左边一段。
    static let trafficLightWidth: CGFloat = 70
    static let canvasMinWidth: CGFloat = 420
    /// 窗口最窄能拉到多少；再窄侧栏已经自动收起，剩下的全归画布。
    static let windowMinWidth: CGFloat = 720
    /// 窗口窄于此值自动收起侧栏（侧栏 280 + 画布 420 + 面板区的余量）。
    static let sidebarAutoCollapseWidth: CGFloat = 920
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

    /// 圆角只有四档。原先散在各视图里的 4/5/6/7/8/9/10/14 是八种写法，
    /// 摆在同一屏上读起来就是「每个人各画各的」——而圆角本身是有语义的：
    /// 贴在网格上的小色块最方（chip），浮起来的卡最圆（sheet）。
    /// 越大的面越圆，因为大面的直角在视觉上比小面的直角更硬。
    /// 设置表单的两列。标签列定宽右对齐，控件列吃掉剩下的宽度并左对齐。
    static let formLabelColumn: CGFloat = 132
    static let formGap: CGFloat = 14

    static let radiusChip: CGFloat = 4
    static let cornerRadius: CGFloat = 6
    static let radiusCard: CGFloat = 11
    static let radiusSheet: CGFloat = 14
}

/// 布局过渡。开合面板区、加/减一列、收放侧栏这几处的宽度变化都走同一条曲线，
/// 免得一个窗口里几种快慢不一的滑动。
/// 拖分隔条**不**走这里：那一条要跟手，套上动画就变成拖完还在追的滞后感。
enum YCodeMotion {
    static let panelArea = Animation.easeInOut(duration: 0.18)
    /// hover 进出。指针经过不是一个「事件」，是一段停留，硬切会让整列行在
    /// 快速划过时闪成一片；120ms 的淡入刚好让它变成一道跟着指针走的光。
    static let hover = Animation.easeOut(duration: 0.12)
    /// 行内内容换位（计数 ⇄ 动作按钮）。比 hover 略长一点，
    /// 因为换的是「内容」不是「底色」，太快会读成闪烁。
    static let contentSwap = Animation.easeOut(duration: 0.14)
    /// 程序触发的滚动定位。原先 ChangesPanelView 自己写了一遍 0.18，
    /// 现在和面板区同源 —— 一个窗口里不该有两条 0.18。
    static let scroll = Animation.easeInOut(duration: 0.18)
}

/// 列表行的选中表现。两种，因为这个应用里「选中」有两种分量：
/// - `.fill`：这一行就是你现在正在做的事（侧栏当前会话、命令面板高亮项）——
///   实心强调色 + 白字，一屏里只该有一个。
/// - `.tint`：这一行是你刚点开、正在右边看的那个（文件树、变更列表）——
///   淡强调色底，保持文字原色，因为它不抢焦点。
enum YCodeRowSelection {
    case fill
    case tint
    /// 选中行是一张浮在底色上的小卡片（视觉方向 B）：卡片底 + 一层极淡的阴影，字色不变。
    /// 侧栏用它 —— 实心强调色底上的白字在珊瑚色上只有 3:1。
    case raised
    /// 常亮的「hover 底」：跟指针扫过时同一种灰，只是不随指针走。
    /// 侧栏里所有已经在画布上的会话行都用它，多个窗格同时亮着。
    case quiet
}

/// 所有列表行共用的一层底。
///
/// 改之前：侧栏会话行、命令面板行、文件树行、变更树行各写各的 background —— 有的只认
/// selected、有的只认 hover、没有一个认 pressed。结果是同一个窗口里，指针划过侧栏没反应、
/// 划过变更面板有反应；按下去则全都没反应，点击有没有落上全靠列表自己改没改。
///
/// 这里把两种状态一次说清，所有行接同一个：hover 走 `YCodeMotion.hover` 淡入，
/// 选中按 `YCodeRowSelection` 的两档走。
///
/// **不做「按下态」**，这是踩了坑之后的决定，不是省事：
///
/// 早先这里挂了一条 `simultaneousGesture(DragGesture(minimumDistance: 0))` 来观测按压。
/// 它把所有行的点击都吃掉了 —— 项目头点不开、会话点不动。原因是手势装在 modifier
/// **内部**（子视图），而调用方的 `.onTapGesture` 装在 `.ycodeRow(...)` **之后**（父视图）；
/// SwiftUI 里子手势优先于父手势，而 `simultaneousGesture` 只对同层与后代生效，
/// 对后挂的父手势无效。于是子 DragGesture 赢了，父 TapGesture 永远不触发。
///
/// 而且这个「按下态」本来就是从触摸端搬来的习惯。macOS 的列表行（访达、邮件、Xcode）
/// **没有**独立于选中的按下态 —— 点下去的确认是「立刻选中」，不是「先变个色」。
/// 真正需要按压反馈的是按钮，那边走 `ButtonStyle` 的 `configuration.isPressed`，
/// 不与任何 TapGesture 争抢，一直是好的。
struct YCodeRowSurface: ViewModifier {
    var isSelected: Bool
    var selection: YCodeRowSelection = .tint
    var cornerRadius: CGFloat = YCodeMetrics.cornerRadius
    /// 行底相对行内容往里收的量。侧栏/命令面板的行是「浮在列里的一块」，
    /// 文件树/变更树的行是「铺满整列的一条」，两者只差这一个数。
    var horizontalInset: CGFloat = 0

    @State private var hovering = false

    func body(content: Content) -> some View {
        content
            .background(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(fill)
                    .shadow(color: raised ? Color.ycodeShadow : .clear, radius: 1, y: 1)
                    .padding(.horizontal, horizontalInset)
                    .animation(YCodeMotion.hover, value: hovering)
            )
            .contentShape(Rectangle())
            .onHover { hovering = $0 }
    }

    /// 只管底，不管字。`.fill` 行上的白字由调用方自己写 —— 侧栏的归档行、
    /// 命令面板的副标题各有一套「选中时的次级白」，收到这里来只会变成一堆开关。
    private var fill: Color {
        switch (isSelected, selection) {
        case (true, .fill): Color.ycodeAccent
        case (true, .tint): Color.ycodeAccent.opacity(0.16)
        case (true, .raised): Color.ycodeSelection
        case (true, .quiet): Color.primary.opacity(hovering ? 0.09 : 0.06)
        case (false, _): hovering ? Color.primary.opacity(0.06) : .clear
        }
    }

    private var raised: Bool { isSelected && selection == .raised }

}

/// 无边框按钮。`.buttonStyle(.plain)` 在 macOS 上是字面意义的「什么都不画」——
/// 不 hover、不按下，点了没有任何确认。侧栏底部的「新建会话」、加项目、
/// 清空搜索这些都挂在它上面，于是这个应用里最常点的几个按钮恰好是反馈最少的。
/// 这里补上与 `YCodeIconButtonStyle` 同源的两级反馈，形状留给调用方。
struct YCodePlainButtonStyle: ButtonStyle {
    var cornerRadius: CGFloat = YCodeMetrics.radiusChip
    /// 纯文字/图标按钮（比如搜索框里的 ✕）不铺底，只压一下不透明度。
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
                            .animation(configuration.isPressed ? nil : YCodeMotion.hover, value: hovering)
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

/// 设置表单里的一行：右对齐的标签列 + 左对齐的控件列，说明文字贴着控件左边缘。
///
/// 这是为了替掉 `LabeledContent`。`LabeledContent` 把控件丢进**尾列**，于是
/// `TextField` 的文本变成右对齐 —— 标签贴左、值贴右、中间一片空，一行里两头跑，
/// 整张表没有一条能贴住的竖线。截图里「标识」那行就是这么来的，
/// 连带「保存后不可更改…」那句说明也跟着右边走。
///
/// 这里标签列定宽右对齐、控件列左对齐，是 macOS 系统设置的标准做法：
/// 标签的右边缘和控件的左边缘各自成一条线，眼睛有地方落。
struct YCodeFormRow<Content: View>: View {
    let label: String
    /// 控件下方的说明或格式约定。标签负责说「这是什么」，格式说明属于控件旁边。
    var hint: String?
    /// 报错占说明的位置，所以出错时行高不变，表单不会整体抖一下。
    var error: String?
    @ViewBuilder var content: () -> Content

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: YCodeMetrics.formGap) {
            // 标签左对齐：分组标题和脚注都贴着分组左边缘，标签再右对齐的话，
            // 每一行的起点都随字数浮动，整块看起来像是往中间缩了一截。
            // 固定列宽保留 —— 控件仍然对齐成一列。
            Text(label)
                .frame(width: YCodeMetrics.formLabelColumn, alignment: .leading)
                .foregroundStyle(.primary)
            VStack(alignment: .leading, spacing: 3) {
                content()
                if let error {
                    // 红色不是唯一信号 —— 旁边永远有一句话说明为什么，
                    // 只靠颜色传达状态对色觉障碍用户等于没说。
                    Label(error, systemImage: "exclamationmark.circle.fill")
                        .font(.caption)
                        .foregroundStyle(Color.ycodeErr)
                } else if let hint {
                    Text(hint)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

/// 只读的一行（路径、版本、探测结果这类）。单独成型而不是给 `YCodeFormRow`
/// 加便利构造：`Text` 上链了修饰符之后类型不再是 `Text`，泛型约束写不住。
struct YCodeFormValueRow: View {
    let label: String
    let value: String
    var mono = false
    var hint: String?

    var body: some View {
        YCodeFormRow(label: label, hint: hint) {
            Text(value)
                .font(mono ? .system(.caption, design: .monospaced) : .body)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
        }
    }
}

extension View {
    /// 列表行统一底。见 `YCodeRowSurface`。
    func ycodeRow(
        isSelected: Bool,
        selection: YCodeRowSelection = .tint,
        cornerRadius: CGFloat = YCodeMetrics.cornerRadius,
        horizontalInset: CGFloat = 0
    ) -> some View {
        modifier(YCodeRowSurface(
            isSelected: isSelected,
            selection: selection,
            cornerRadius: cornerRadius,
            horizontalInset: horizontalInset
        ))
    }
}

/// 视觉方向 B 的「浮卡」：卡片底 + 极细描边 + 两层柔和阴影（贴近的一层给轮廓，
/// 散开的一层给悬浮感）。欢迎卡片、新会话卡片、面板卡片都走这一个修饰器，
/// 于是窗口里所有「浮起来的东西」是同一种高度。终端窗格是 AppKit 画的，参数与这里对齐。
struct YCodeCardSurface: ViewModifier {
    var cornerRadius: CGFloat = YCodeMetrics.radiusSheet
    var elevated = true

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        content
            .background {
                shape.fill(Color.ycodeCard)
                    .shadow(color: elevated ? Color.ycodeShadow : .clear, radius: 1, y: 1)
                    .shadow(color: elevated ? Color.ycodeShadow : .clear, radius: 12, y: 6)
            }
            .overlay { shape.strokeBorder(Color.ycodeHairline) }
    }
}

extension View {
    func ycodeCard(cornerRadius: CGFloat = YCodeMetrics.radiusSheet, elevated: Bool = true) -> some View {
        modifier(YCodeCardSurface(cornerRadius: cornerRadius, elevated: elevated))
    }
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
    /// 窗口底色：侧栏、画布顶栏、画布缝隙与面板区共用这一层（视觉方向 B 的「底」）。
    /// 取官网的 --bg，带一点紫调；侧栏与顶栏融进它，不再靠分隔线切开。
    /// 不用系统材质：sidebar 的 vibrancy 偏亮、inspector 偏暗，两边摆在同一个窗口里能看出色差。
    static let ycodeChrome = Color.ycodeDynamic(light: "EFEEF4", dark: "110F28")
    /// 品牌强调色（珊瑚）。不用 `Color.ycodeAccent`：macOS 上它读的是系统强调色，
    /// 不跟随 `.tint`，结果焦点描边、开关高亮在一个珊瑚色的应用里还是系统蓝。
    /// 珊瑚在白底上只有 3:1，只用于描边、图形与填充；小字号文字用 `ycodeAccentText`。
    static let ycodeAccent = Color.ycodeDynamic(light: "FF5A4E", dark: "FF7D72")
    /// 强调色的文字版，白底 5.4:1。
    static let ycodeAccentText = Color.ycodeDynamic(light: "C3301F", dark: "FF8F85")
    /// 浮在底色上的卡片：终端窗格、面板卡片、新会话卡片（视觉方向 B 的「卡」）。
    static let ycodeCard = Color.ycodeDynamic(light: "FCFCFE", dark: "1B1840")
    /// 侧栏选中行的小卡片底。
    /// chrome 底上叠 6% 前景色（`.quiet` 行底）之后的实色，给压在行上的角标描边用。
    static let ycodeRowLitBase = Color.ycodeDynamic(light: "E1E0E6", dark: "1F1D35")
    static let ycodeSelection = Color.ycodeDynamic(light: "FFFFFF", dark: "2A2658")
    /// 卡片内部的分隔线与卡片描边。
    static let ycodeHairline = Color(nsColor: NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            ? NSColor.white.withAlphaComponent(0.07)
            : NSColor(srgbRed: 22 / 255, green: 19 / 255, blue: 58 / 255, alpha: 0.08)
    })
    /// 浮起元素的阴影色（深色下阴影在深墨底上看不见，交给描边表达层次）。
    static let ycodeShadow = Color(nsColor: NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            ? NSColor.black.withAlphaComponent(0.25)
            : NSColor(srgbRed: 22 / 255, green: 19 / 255, blue: 58 / 255, alpha: 0.08)
    })
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
                .foregroundStyle(isOn ? Color.ycodeAccent : Color.secondary)
                .frame(width: width, height: height)
                .background(fill, in: RoundedRectangle(cornerRadius: YCodeMetrics.cornerRadius, style: .continuous))
                // hover 淡入、按下即时 —— press 是确认，不能有过渡。
                .animation(configuration.isPressed ? nil : YCodeMotion.hover, value: hovering)
                .contentShape(Rectangle())
                .onHover { hovering = $0 }
        }

        private var fill: Color {
            if configuration.isPressed { return Color.primary.opacity(0.14) }
            if isOn { return Color.ycodeAccent.opacity(0.15) }
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
    /// 终端面板关掉它：卡头上没有「终端」两个字，标签自己写着「终端 1」，
    /// 图标既不点也不说明什么，只是占着 26 pt。
    var showsIcon = true
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
        // 卡头是卡片的一部分，底色跟卡片走，不再是一条 chrome 色带。
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
        if !spec.showsIcon {
            EmptyView()
        } else if let action = spec.iconAction {
            Button(action: action) { Image(systemName: spec.panel.symbolName) }
                .buttonStyle(YCodeIconButtonStyle(isOn: spec.iconIsOn, width: 20, height: 20, fontSize: 11))
                .help(spec.iconHelp)
        } else {
            Image(systemName: spec.panel.symbolName)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(width: 20, height: 20)
                .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: YCodeMetrics.radiusChip, style: .continuous))
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
enum YCodeSessionPresence: Equatable {
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

/// 状态角标：贴在 agent 图标右上角的一枚小圆点。
///
/// 改之前它是行首**独立的一列**，而且 idle 也画一个实心灰点。结果是一整列
/// 一模一样的灰点：占了宽度、占了视线，却没有任何区别可言。指示器只有在
/// **有变化**时才有价值 —— 全都一样时它就是噪声，而且会稀释真正该被看到的
/// 那两种颜色（某天真有一条在跑，那个绿点要在十几个灰点里被认出来）。
///
/// 现在：idle **不画**，只有「运行中 / 等你」才亮；而且贴在图标上而不是
/// 另起一列 —— 状态描述的就是这个 agent，两者本来就该长在一起。
/// 那一列平时是空的，一旦有东西亮起来，眼睛会直接落上去。
struct YCodeStatusBadge: View {
    let presence: YCodeSessionPresence
    /// 角标要压在图标上，得有一圈和行底同色的描边才分得开。
    /// 选中行是实心强调色，非选中行是 chrome 底，所以这个颜色由调用方给。
    let ringColor: Color
    var size: CGFloat = 9

    var body: some View {
        if presence != .idle {
            Circle()
                .fill(presence.color)
                .frame(width: size, height: size)
                .overlay(Circle().strokeBorder(ringColor, lineWidth: 1.5))
                // 描边往外扩，不吃掉圆点本身的面积。
                .padding(-1.5)
        }
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

@MainActor
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
    /// 空卡里除了两行字什么都没有时，一枚淡图标能把视线定在中间。传 nil 就还是纯文字。
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
