import AppKit
import SwiftUI
import TandockCore

struct AgentIconPicker: View {
    @Binding var icon: String
    let colorHex: String
    let displayName: String

    @Environment(\.tandockL10n) private var l10n

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 8) {
                Picker("", selection: quickPick) {
                    Text(l10n.text("agentIconLetter")).tag("")
                    Divider()
                    ForEach(Self.featured, id: \.self) { Text($0).tag($0) }
                    if !icon.isEmpty, !Self.featured.contains(icon) {
                        Divider()
                        Text(icon).tag(icon)
                    }
                }
                .labelsHidden()
                .fixedSize()

                TextField("", text: $icon, prompt: Text("DeepSeek"))
                    .labelsHidden()
                    .textFieldStyle(.roundedBorder)
                    .font(.system(.body, design: .monospaced))

                preview(size: 18)
                    .frame(width: 26, height: 22)
            }
            Text(l10n.text("agentIconHelp"))
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var quickPick: Binding<String> {
        Binding(get: { icon }, set: { icon = $0 })
    }

    private func preview(size: CGFloat) -> some View {
        var profile = TandockAgentProfile(id: "preview", command: "")
        profile.icon = icon.isEmpty ? nil : icon
        profile.color = colorHex.isEmpty ? nil : colorHex
        profile.displayName = displayName.isEmpty ? nil : displayName
        return TandockAgentIconView(profile: profile, size: size)
    }

    static let featured: [String] = {
        let common = [
            "ClaudeCode",
            "Codex",
            "Cursor",
            "GithubCopilot",
            "Grok",
            "Pi",
            "OpenCode",
            "Goose",
            "Amp",
            "OpenHands",
            "Qwen",
            "Trae",
            "CodeBuddy",
        ]
        var seenShape = Set<String>()
        return common.filter { key in
            guard let svg = TandockAgentIconCatalog.brand[key] ?? TandockAgentIconCatalog.mono[key] else {
                return false
            }
            return seenShape.insert(svg.replacingOccurrences(of: key, with: "")).inserted
        }
    }()
}
