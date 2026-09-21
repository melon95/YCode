import AppKit
import SwiftUI
import YCodeCore

/// agent 的品牌图标。数据来自 `YCodeAgentIconCatalog`（与非原生版同一份 @lobehub/icons），
/// 按 profile 的 `icon` 字段查表；查不到就回退成首字母，未知 agent 也不会留空。
struct YCodeAgentIconView: View {
    let profile: YCodeAgentProfile?
    var size: CGFloat = 14
    /// 传 nil 表示跟随外层前景色（侧栏选中行要用白色，不能被品牌色顶掉）。
    var tint: Color?

    var body: some View {
        Group {
            if let image = YCodeAgentIconRenderer.brand(for: profile?.icon) {
                // 设计稿那套彩色图标按原色渲染（带渐变），不参与着色。
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
            } else if let image = YCodeAgentIconRenderer.mono(for: profile?.icon) {
                Image(nsImage: image)
                    .resizable()
                    .renderingMode(.template)
                    .aspectRatio(contentMode: .fit)
                    .foregroundStyle(tint ?? brandTint ?? Color.primary)
            } else {
                Text(String((profile?.resolvedDisplayName ?? "?").prefix(1)).uppercased())
                    .font(.system(size: size * 0.72, weight: .semibold))
                    .foregroundStyle(tint ?? brandTint ?? Color.primary)
            }
        }
        .frame(width: size, height: size)
    }

    /// profile 里显式配了颜色就听它的，否则给认识的品牌一个默认色；
    /// 认不出的 agent 跟随前景色，不硬造颜色。
    private var brandTint: Color? {
        if let raw = profile?.color, let color = NSColor(hex: raw) { return Color(nsColor: color) }
        switch profile?.icon {
        case "ClaudeCode", "Claude", "Anthropic": return Color.ycodeDynamic(light: "C15F3C", dark: "D97757")
        case "GeminiCLI", "Gemini", "Google": return Color.ycodeDynamic(light: "1A73E8", dark: "6BA1FF")
        default: return nil
        }
    }
}

@MainActor
enum YCodeAgentIconRenderer {
    private static var cache: [String: NSImage] = [:]

    /// 应用自身的标志（新建会话卡片顶部用它）。
    static var ycodeLogo: NSImage? { brand(for: "ycode") }

    static func brand(for key: String?) -> NSImage? {
        guard let key, let svg = YCodeAgentIconCatalog.brand[key] else { return nil }
        return decode(key: "brand-" + key, svg: svg, template: false)
    }

    /// SVG 交给 NSImage 解码，标记成 template 之后才能跟随 `foregroundStyle` 着色。
    static func mono(for key: String?) -> NSImage? {
        guard let key, let svg = YCodeAgentIconCatalog.mono[key] else { return nil }
        return decode(key: "mono-" + key, svg: svg, template: true)
    }

    private static func decode(key: String, svg: String, template: Bool) -> NSImage? {
        if let cached = cache[key] { return cached }
        guard let data = svg.data(using: .utf8), let image = NSImage(data: data) else { return nil }
        image.isTemplate = template
        cache[key] = image
        return image
    }
}
