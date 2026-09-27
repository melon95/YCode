import AppKit
import SwiftUI
import YCodeCore

/// agent 的图标。按 profile 的 `icon` 字段依次查四层，任一层命中即止：
///
/// 1. **品牌彩色**（`YCodeAgentIconCatalog.brand`）—— 与非原生版同一份 @lobehub/icons，按原色渲染
/// 2. **品牌单色**（`YCodeAgentIconCatalog.mono`）—— 渲染成 template，跟随前景色
/// 3. **SF Symbol** —— 系统自带的约六千个符号，给目录里没有的 agent 用
/// 4. **首字母** —— 兜底，未知 agent 也不会留空
///
/// 第 3 层是这次补的。在此之前，目录里没有的 agent（自建的、小众的、内部工具）
/// 只能落到首字母，用户没有任何办法给它换个图标 —— 而 `icon` 字段本身是自由文本，
/// 填什么都只会被当成「查不到的品牌键」。
///
/// 选 SF Symbol 而不是「让用户导入图片文件」，是因为它在这个仓库里已经是既有方案：
/// 面板卡头、工具栏、文件树、状态栏一共 50 多处都在用 `Image(systemName:)`，
/// `YCodeWorkspacePanel.symbolName` 就是这么存的。复用它意味着：不新增素材、
/// 不新增存储格式（还是那个 `icon: String`，无需迁移）、自动适配浅深色与字重，
/// 而且它是 template image —— profile 的 `color` 直接就能给它上色。
struct YCodeAgentIconView: View {
    let profile: YCodeAgentProfile?
    var size: CGFloat = 14
    /// 传 nil 表示跟随外层前景色（侧栏选中行要用白色，不能被品牌色顶掉）。
    var tint: Color?

    var body: some View {
        Group {
            switch YCodeAgentIconRenderer.resolve(icon: profile?.icon) {
            case let .brand(image):
                // 彩色图标按原色渲染（带渐变），不参与着色。
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
            case let .mono(image):
                Image(nsImage: image)
                    .resizable()
                    .renderingMode(.template)
                    .aspectRatio(contentMode: .fit)
                    .foregroundStyle(tint ?? brandTint ?? Color.primary)
            case let .symbol(name):
                // 符号不用 .resizable()：那会把它当成位图拉伸，笔画粗细跟着变形。
                // 给字号才是 SF Symbol 的正确缩放方式，光学重量由系统保证。
                Image(systemName: name)
                    .font(.system(size: size * 0.92))
                    .foregroundStyle(tint ?? brandTint ?? Color.primary)
            case .letter:
                Text(String((profile?.resolvedDisplayName ?? "?").prefix(1)).uppercased())
                    .font(.system(size: size * 0.72, weight: .semibold))
                    .foregroundStyle(tint ?? brandTint ?? Color.primary)
            }
        }
        .frame(width: size, height: size)
    }

    /// profile 里显式配了颜色就听它的，否则给认识的品牌一个默认色，
    /// 再否则用强调色。
    ///
    /// 最后这档是补的：以前没配颜色时落到 `Color.primary`（黑/白），
    /// 于是「强调色」这个设置对**默认的首字母图标完全看不出效果** ——
    /// 又一个改了没反应的控件。现在取色器立刻有可见后果。
    private var brandTint: Color? {
        if let raw = profile?.color, let color = NSColor(hex: raw) { return Color(nsColor: color) }
        switch profile?.icon {
        case "ClaudeCode", "Claude", "Anthropic": return Color.ycodeDynamic(light: "C15F3C", dark: "D97757")
        case "GeminiCLI", "Gemini", "Google": return Color.ycodeDynamic(light: "1A73E8", dark: "6BA1FF")
        default: return Color.accentColor
        }
    }
}

@MainActor
enum YCodeAgentIconRenderer {
    /// 一个 `icon` 字段解出来的东西。让调用方 switch 而不是连着问四个
    /// Optional，是因为「解析顺序」本身是规则的一部分，散在 if-else 里就会被改乱。
    enum Resolved {
        case brand(NSImage)
        case mono(NSImage)
        case symbol(String)
        case letter
    }

    private static var cache: [String: NSImage] = [:]
    /// SF Symbol 名字的存在性查询结果。`NSImage(systemSymbolName:)` 每次都要过一遍
    /// 系统符号表，而列表行会随滚动反复重绘，不缓存就是每帧几十次查表。
    private static var symbolExists: [String: Bool] = [:]

    /// 应用自身的标志（新建会话卡片顶部用它）。
    static var ycodeLogo: NSImage? { brand(for: "ycode") }

    /// 四层解析：品牌彩色 → 单色 → SF Symbol → 首字母。
    ///
    /// 不再有 `variant` 参数。选了一张品牌 SVG 就按它自己的配色画 ——
    /// 那是这张图唯一正确的样子。那个「品牌色 / 单色」开关的名字本身也在误导：
    /// 它听起来像在选颜色，实际选的是渲染模式，而颜色来自 SVG 里写死的 fill。
    static func resolve(icon: String?) -> Resolved {
        guard let icon, !icon.isEmpty else { return .letter }
        if let image = brand(for: icon) { return .brand(image) }
        if let image = mono(for: icon) { return .mono(image) }
        if isSymbol(icon) { return .symbol(icon) }
        return .letter
    }

    static func brand(for key: String?) -> NSImage? {
        guard let key, let svg = YCodeAgentIconCatalog.brand[key] else { return nil }
        return decode(key: "brand-" + key, svg: svg, template: false)
    }

    /// SVG 交给 NSImage 解码，标记成 template 之后才能跟随 `foregroundStyle` 着色。
    static func mono(for key: String?) -> NSImage? {
        guard let key, let svg = YCodeAgentIconCatalog.mono[key] else { return nil }
        return decode(key: "mono-" + key, svg: svg, template: true)
    }

    /// 这个字符串是不是一个真实存在的 SF Symbol。
    /// 用于图标选择器的即时校验 —— 打错的符号名要当场说，而不是保存完
    /// 在侧栏里看到一个字母才反应过来。
    static func isSymbol(_ name: String) -> Bool {
        guard !name.isEmpty else { return false }
        if let known = symbolExists[name] { return known }
        let exists = NSImage(systemSymbolName: name, accessibilityDescription: nil) != nil
        symbolExists[name] = exists
        return exists
    }

    private static func decode(key: String, svg: String, template: Bool) -> NSImage? {
        if let cached = cache[key] { return cached }
        guard let data = svg.data(using: .utf8), let image = NSImage(data: data) else { return nil }
        image.isTemplate = template
        cache[key] = image
        return image
    }
}
