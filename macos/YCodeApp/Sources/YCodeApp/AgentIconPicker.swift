import AppKit
import SwiftUI
import YCodeCore

/// Agent 图标选择器：一个下拉框 + 一个输入框。
///
/// 下拉框列出常用的品牌图标（去重后）；输入框接受**任意**图标名 ——
/// 目录里全部 320 个 @lobehub 图标，或任意 SF Symbol 名。
/// 两者写的是同一个 `icon` 字段，右边那格是实时结果。
///
/// 原先是一张 30 格的网格。网格的问题是它**只能展示被打包进来的那些**，
/// 而目录有 320 个 —— 网格铺满整个表单也列不完，却又让人以为"就这些"。
/// 下拉框承认自己是个快捷入口，输入框才是完整的那条路。
struct AgentIconPicker: View {
    @Binding var icon: String
    /// 预览要用真实的颜色和名字，否则预览的不是用户将要看到的东西。
    let colorHex: String
    let displayName: String

    @Environment(\.ycodeL10n) private var l10n

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 8) {
                Picker("", selection: quickPick) {
                    // 第一项不是「无」—— 它渲染的正是默认图标本身（显示名称的首字母）。
                    // 原先这格标的是「无（字母占位）」，标签和行为对不上。
                    Text(l10n.text("agentIconLetter")).tag("")
                    Divider()
                    ForEach(Self.featured, id: \.self) { Text($0).tag($0) }
                    // 手敲进来的名字不在快捷列表里，补一项，否则下拉框会显示空白。
                    if !icon.isEmpty, !Self.featured.contains(icon) {
                        Divider()
                        Text(icon).tag(icon)
                    }
                }
                .labelsHidden()
                .fixedSize()

                // 占位符要同时做两件事：教格式、给一个认得出且真能用的值。
                // 早先这里是 AgentVoice —— 那是随手从对话里抄来的，没人认识它，
                // 占位符不该是随手拿来的字符串。
                TextField("", text: $icon, prompt: Text("DeepSeek"))
                    .labelsHidden()
                    .textFieldStyle(.roundedBorder)
                    .font(.system(.body, design: .monospaced))

                // 这一格画的就是保存后侧栏里的样子。填错的名字会落回首字母 ——
                // 不需要再写一行「找不到这个图标」，结果本身就是答案。
                preview(size: 18)
                    .frame(width: 26, height: 22)
            }
            Text(l10n.text("agentIconHelp"))
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// 下拉框的选择会直接写 `icon`；手敲的名字也要在下拉框里回显。
    private var quickPick: Binding<String> {
        Binding(get: { icon }, set: { icon = $0 })
    }

    private func preview(size: CGFloat) -> some View {
        var profile = YCodeAgentProfile(id: "preview", command: "")
        profile.icon = icon.isEmpty ? nil : icon
        profile.color = colorHex.isEmpty ? nil : colorHex
        profile.displayName = displayName.isEmpty ? nil : displayName
        return YCodeAgentIconView(profile: profile, size: size)
    }

    /// 下拉框里的**常见 agent 图标**。
    ///
    /// 注意这和「ycode 能启动哪些 agent」是两件事 —— 我一度把两者混为一谈，
    /// 于是下拉里只剩内置目录那五个。这个下拉的用途是"挑一张图"，
    /// 用户给自建的 agent 配图标时，想要的多半正是 Cursor / Cline 这类
    /// **不在**内置目录里的名字。
    ///
    /// "常见"是个判断，没法从代码里推导，所以这里是一份人工名单。
    /// 但它**按目录过滤**：名字写错或上游删了图标，这一项会自动消失，
    /// 而不是在下拉里留一个选了没图的空项 —— 早先那份手写名单栽的就是这个跟头。
    ///
    /// 想要名单外的，直接在旁边敲名字，327 个随便挑。
    static let featured: [String] = {
        // 判据是「有没有命令行」，不是「有没有名气」。这个下拉是给
        // **agent CLI** 配图标的 —— 装进 ycode 的东西必须是一条能启动的命令。
        //
        // 所以像 Cline / RooCode / KiloCode（VS Code 扩展）、Windsurf / Kiro /
        // Antigravity / Qoder（IDE）、Junie / Zencoder / CodeGeeX（插件）、
        // CherryStudio（桌面 GUI）都不在这儿 —— 它们再常见也跑不起来。
        // 图标仍在那 327 个里，想用直接敲名字。
        let common = [
            "ClaudeCode",      // claude
            "Codex",           // codex
            "Cursor",          // cursor-agent
            "GithubCopilot",   // copilot
            "Grok",            // grok
            "Pi",              // pi
            "OpenCode",        // opencode
            "Goose",           // goose
            "Amp",             // amp
            "OpenHands",       // openhands
            "Qwen",            // qwen（qwen-code）
            "Trae",            // trae-agent
            "CodeBuddy",       // codebuddy
        ]
        var seenShape = Set<String>()
        return common.filter { key in
            guard let svg = YCodeAgentIconCatalog.brand[key] ?? YCodeAgentIconCatalog.mono[key] else {
                return false
            }
            // 同图去重：生成器给渐变 id 加了 key 前缀，比图形要先去掉前缀。
            return seenShape.insert(svg.replacingOccurrences(of: key, with: "")).inserted
        }
    }()
}
