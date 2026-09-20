import AppKit
import SwiftUI
import YCodeCore

@MainActor
final class BasicSettingsModel: ObservableObject {
    @Published var startupMode: YCodeStartupMode = .resume
    @Published var agents: [YCodeAgentProfile] = YCodeAgentCatalog.defaults
    @Published var proxy = YCodeProxySettings()
    @Published var notifications = YCodeNotificationSettings()
    @Published var appearance = YCodeAppearanceSettings()
    @Published private(set) var systemProxy = YCodeSystemProxy()
    @Published private(set) var commandAvailability: [String: Bool] = [:]
    @Published var errorMessage: String?
    @Published var saved = false
    @Published private(set) var persistedStartupMode: YCodeStartupMode = .resume
    @Published private(set) var persistedNotifications = YCodeNotificationSettings()
    @Published private(set) var persistedAppearance = YCodeAppearanceSettings()
    @Published private(set) var persistedAgentSettings = YCodeAgentSettings()
    @Published private(set) var fileTreeWidth = NativeWorkspacePreferences.defaultFileTreeWidth

    let dataRoot: URL
    private let configurationStore: YCodeConfigurationStore

    init() {
        dataRoot = YCodeDataRootResolver.resolve()
        configurationStore = YCodeConfigurationStore(configurationURL: dataRoot.appendingPathComponent("config.json"))
        do {
            let settings = try configurationStore.loadBasicSettings()
            startupMode = settings.startupMode
            persistedStartupMode = settings.startupMode
            notifications = settings.notifications
            persistedNotifications = settings.notifications
            appearance = settings.appearance
            persistedAppearance = settings.appearance
            let agentSettings = try configurationStore.loadAgentSettings()
            agents = agentSettings.agents
            proxy = agentSettings.proxy
            persistedAgentSettings = agentSettings
            let state = try NativeWorkspaceStateStore(databaseURL: dataRoot.appendingPathComponent("ycode.db"))
            fileTreeWidth = try state.preferences().fileTreeWidth
            refreshAvailability()
            systemProxy = YCodeSystemProxyDetector.detect()
        } catch {
            errorMessage = String(describing: error)
        }
    }

    var hasChanges: Bool {
        startupMode != persistedStartupMode
            || notifications != persistedNotifications
            || appearance != persistedAppearance
            || YCodeAgentSettings(agents: agents, proxy: proxy) != persistedAgentSettings
    }

    var isAtDefaults: Bool {
        startupMode == .resume
            && notifications == YCodeNotificationSettings()
            && appearance == YCodeAppearanceSettings()
            && YCodeAgentSettings(agents: agents, proxy: proxy) == YCodeAgentSettings()
    }

    func save() {
        do {
            let agentSettings = YCodeAgentSettings(agents: agents, proxy: proxy)
            try configurationStore.saveSettings(
                basic: YCodeBasicSettings(startupMode: startupMode, notifications: notifications, appearance: appearance),
                agents: agentSettings
            )
            persistedStartupMode = startupMode
            persistedNotifications = notifications
            persistedAppearance = appearance
            persistedAgentSettings = agentSettings
            saved = true
            NotificationCenter.default.post(name: .ycodeAppearanceSettingsChanged, object: nil)
        } catch {
            errorMessage = String(describing: error)
        }
    }

    func cancel() {
        startupMode = persistedStartupMode
        notifications = persistedNotifications
        appearance = persistedAppearance
        agents = persistedAgentSettings.agents
        proxy = persistedAgentSettings.proxy
    }

    func restoreDefaults() {
        startupMode = .resume
        agents = YCodeAgentCatalog.defaults
        proxy = YCodeProxySettings()
        notifications = YCodeNotificationSettings()
        appearance = YCodeAppearanceSettings()
        refreshAvailability()
    }

    func removeAgent(id: String) {
        agents.removeAll { $0.id == id }
    }

    func upsertAgent(_ agent: YCodeAgentProfile, replacing originalID: String?) {
        if let originalID, let index = agents.firstIndex(where: { $0.id == originalID }) {
            agents[index] = agent
        } else {
            agents.append(agent)
        }
        refreshAvailability()
    }

    func addSuggestion(_ suggestion: YCodeAgentProfile) {
        guard !agents.contains(where: { $0.command == suggestion.command }) else { return }
        var agent = suggestion
        let base = suggestion.id
        var candidate = base
        var suffix = 2
        while agents.contains(where: { $0.id == candidate }) {
            candidate = "\(base)-\(suffix)"
            suffix += 1
        }
        agent.id = candidate
        agents.append(agent)
        refreshAvailability()
    }

    func refreshAvailability() {
        let commands = Set((agents + YCodeAgentCatalog.suggestions).map(\.command))
        Task.detached {
            let statuses = Dictionary(uniqueKeysWithValues: commands.map { ($0, YCodeAgentLauncher.probe(command: $0)) })
            await MainActor.run { self.commandAvailability = statuses }
        }
    }
}

private enum SettingsSection: String, CaseIterable, Identifiable {
    case general, sessions, panels, agents, integrations, notifications, usage
    case terminal, languages, appearance, keyboard, data, about

    var id: String { rawValue }

    func localizedTitle(_ l10n: YCodeLocalization) -> String {
        switch self {
        case .general: l10n.text("general")
        case .sessions: l10n.text("sessions")
        case .panels: l10n.text("panels")
        case .agents: l10n.text("agents")
        case .integrations: l10n.text("integrations")
        case .notifications: l10n.text("notifications")
        case .usage: l10n.text("usage")
        case .terminal: l10n.text("terminal")
        case .languages: l10n.text("languages")
        case .appearance: l10n.text("appearance")
        case .keyboard: l10n.text("keyboard")
        case .data: l10n.text("data")
        case .about: l10n.text("about")
        }
    }

    var icon: String {
        switch self {
        case .general: "gearshape"
        case .sessions: "bubble.left.and.bubble.right"
        case .panels: "rectangle.split.3x1"
        case .agents: "cpu"
        case .integrations: "puzzlepiece.extension"
        case .notifications: "bell"
        case .usage: "chart.bar"
        case .terminal: "terminal"
        case .languages: "chevron.left.forwardslash.chevron.right"
        case .appearance: "paintbrush"
        case .keyboard: "keyboard"
        case .data: "externaldrive"
        case .about: "info.circle"
        }
    }

    var deliveryStage: String {
        switch self {
        case .sessions, .agents: "M2"
        case .panels, .terminal: "M2–M4"
        case .integrations, .notifications, .usage: "M3"
        case .languages: "M4"
        case .appearance, .keyboard: "M5"
        case .general, .data, .about: "M1–M5"
        }
    }
}

struct BasicSettingsView: View {
    @StateObject private var model = BasicSettingsModel()
    @StateObject private var mcpIntegrationModel = MCPIntegrationSettingsModel()
    @StateObject private var updateController = YCodeUpdateController.shared
    @Environment(\.dismiss) private var dismiss
    @Environment(\.ycodeL10n) private var inheritedL10n
    @State private var selectedSection: SettingsSection = .general
    @State private var editingAgent: AgentEditorState?
    private var l10n: YCodeLocalization { YCodeLocalization(locale: model.appearance.locale) }

    var body: some View {
        NavigationSplitView {
            List(selection: $selectedSection) {
                ForEach(SettingsSection.allCases) { section in
                    Label(section.localizedTitle(l10n), systemImage: section.icon).tag(section)
                }
            }
            .navigationTitle(l10n.text("settings"))
            .navigationSplitViewColumnWidth(min: 170, ideal: 190)
        } detail: {
            settingsContent
                .navigationTitle(selectedSection.localizedTitle(l10n))
        }
        .frame(width: 780, height: 540)
        .environment(\.ycodeL10n, l10n)
        .safeAreaInset(edge: .bottom) {
            HStack {
                Button(l10n.text("restoreDefaults")) {
                    model.restoreDefaults()
                }
                .disabled(model.isAtDefaults)
                Spacer()
                Button(l10n.text("cancel")) {
                    model.cancel()
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)
                Button(l10n.text("save")) {
                    model.save()
                    if model.errorMessage == nil { dismiss() }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!model.hasChanges)
            }
            .padding()
            .background(.bar)
        }
        .alert(l10n.text("settingsSaveFailed"), isPresented: Binding(
            get: { model.errorMessage != nil },
            set: { if !$0 { model.errorMessage = nil } }
        )) {
            Button(l10n.text("ok")) { model.errorMessage = nil }
        } message: {
            Text(model.errorMessage ?? l10n.text("unknownError"))
        }
        .sheet(item: $editingAgent) { editor in
            AgentEditorView(state: editor) { profile, originalID in
                model.upsertAgent(profile, replacing: originalID)
            }
        }
    }

    @ViewBuilder
    private var settingsContent: some View {
        switch selectedSection {
        case .general:
            Form {
                Section(l10n.text("startup")) {
                    Picker(l10n.text("showAtStartup"), selection: $model.startupMode) {
                        Text(l10n.text("resumeRecentWorkspace")).tag(YCodeStartupMode.resume)
                        Text(l10n.text("projectOverview")).tag(YCodeStartupMode.overview)
                        Text(l10n.text("blankRecentProjectWorkspace")).tag(YCodeStartupMode.blank)
                    }
                    .pickerStyle(.radioGroup)
                    Text(l10n.text("startupTakesEffectNextLaunch"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .formStyle(.grouped)
        case .panels:
            Form {
                Section(l10n.text("migratedInterfaceState")) {
                    LabeledContent(l10n.text("fileTreeWidth"), value: "\(Int(model.fileTreeWidth)) px")
                    Text(l10n.text("importedWidthUsed"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .formStyle(.grouped)
        case .sessions:
            Form {
                Section(l10n.text("sessionLifetime")) {
                    Toggle(l10n.text("keepPTY"), isOn: .constant(false))
                        .disabled(true)
                    Text(l10n.text("keepPTYPending"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Picker(l10n.text("idleReaping"), selection: .constant("off")) {
                        Text(l10n.text("off")).tag("off")
                        Text(l10n.text("after30Minutes")).tag("30m")
                        Text(l10n.text("after2Hours")).tag("2h")
                    }
                    .disabled(true)
                    Text(l10n.text("idleReapingPending"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Section(l10n.text("archive")) {
                    Toggle(l10n.text("automaticArchive"), isOn: .constant(false))
                        .disabled(true)
                    Text(l10n.text("automaticArchivePending"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .formStyle(.grouped)
        case .agents:
            Form {
                Section(l10n.text("configured")) {
                    if model.agents.isEmpty {
                        Text(l10n.text("noAgentsConfigured")).foregroundStyle(.secondary)
                    }
                    ForEach(model.agents) { agent in
                        HStack(spacing: 10) {
                            AgentBadge(profile: agent)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(agent.resolvedDisplayName)
                                Text(agent.command)
                                    .font(.system(.caption, design: .monospaced))
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            availabilityLabel(for: agent.command)
                            Button {
                                editingAgent = AgentEditorState(profile: agent)
                            } label: {
                                Image(systemName: "pencil")
                            }
                            .buttonStyle(.borderless)
                            .help("\(l10n.text("editor")) \(agent.resolvedDisplayName)")
                            Button(role: .destructive) { model.removeAgent(id: agent.id) } label: {
                                Image(systemName: "trash")
                            }
                            .buttonStyle(.borderless)
                            .help("\(l10n.text("delete")) \(agent.resolvedDisplayName)")
                        }
                    }
                }
                let suggestions = YCodeAgentCatalog.suggestions.filter { suggestion in
                    !model.agents.contains(where: { $0.command == suggestion.command })
                        && model.commandAvailability[suggestion.command] == true
                }
                if !suggestions.isEmpty {
                    Section(l10n.text("detected")) {
                        ForEach(suggestions) { suggestion in
                            HStack {
                                AgentBadge(profile: suggestion)
                                Text(suggestion.resolvedDisplayName)
                                Spacer()
                                Text(suggestion.command).foregroundStyle(.secondary)
                                Button(l10n.text("add")) { model.addSuggestion(suggestion) }
                            }
                        }
                    }
                }
                Section {
                    Button(l10n.text("addCustomAgent")) {
                        editingAgent = AgentEditorState(profile: nil)
                    }
                } footer: {
                    Text(l10n.text("agentHelp"))
                }
            }
            .formStyle(.grouped)
        case .terminal:
            Form {
                Section(l10n.text("launchEnvironment")) {
                    LabeledContent("Shell", value: "\(ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/sh") -l -i")
                    LabeledContent(l10n.text("terminalCapabilities"), value: "256 色 / True Color")
                }
                Section(l10n.text("proxy")) {
                    Picker(l10n.text("mode"), selection: $model.proxy.mode) {
                        Text(l10n.text("off")).tag(YCodeProxyMode.off)
                        Text(l10n.text("followSystem")).tag(YCodeProxyMode.system)
                        Text(l10n.text("manual")).tag(YCodeProxyMode.manual)
                    }
                    .pickerStyle(.segmented)
                    if model.proxy.mode == .system {
                        LabeledContent(l10n.text("currentDetection")) {
                            Text(proxySummary(model.systemProxy, l10n: l10n))
                                .font(.system(.caption, design: .monospaced))
                                .textSelection(.enabled)
                        }
                    }
                    if model.proxy.mode == .manual {
                        TextField(l10n.text("proxyAddress"), text: $model.proxy.url, prompt: Text("127.0.0.1:7897"))
                        TextField(l10n.text("exceptions"), text: $model.proxy.noProxy, prompt: Text("localhost,127.0.0.1,*.local"))
                    }
                    Text(l10n.text("proxyHelp"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .formStyle(.grouped)
        case .usage:
            UsageSettingsView(dataRoot: model.dataRoot)
        case .notifications:
            NotificationsSettingsView(settings: $model.notifications)
        case .integrations:
            MCPIntegrationSettingsView(
                model: mcpIntegrationModel,
                agents: YCodeMCPAgent.allCases.filter { agent in
                    model.agents.contains { $0.introspect == agent.rawValue }
                }
            )
        case .languages:
            LanguageSettingsView(dataRoot: model.dataRoot)
        case .appearance:
            Form {
                Section(l10n.text("theme")) {
                    Picker(l10n.text("theme"), selection: $model.appearance.theme) {
                        ForEach(YCodeThemeCatalog.options) { option in
                            Text(option.label).tag(option.id)
                        }
                    }
                    .pickerStyle(.menu)
                    if YCodeThemeCatalog.option(id: model.appearance.theme) == nil {
                        LabeledContent(l10n.text("unknownTheme"), value: model.appearance.theme)
                    }
                    Text(l10n.text("themeHelp"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Section(l10n.text("language")) {
                    Picker(l10n.text("interfaceLanguage"), selection: $model.appearance.locale) {
                        Text("中文").tag(YCodeLocale.zh)
                        Text("English").tag(YCodeLocale.en)
                    }
                    .pickerStyle(.segmented)
                    Text(l10n.text("languageHelp"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Section(l10n.text("fontSize")) {
                    Stepper(value: fontBinding(\.ui), in: 8...32) {
                        LabeledContent(l10n.text("interface"), value: "\(model.appearance.fontSizes.ui) pt")
                    }
                    Stepper(value: fontBinding(\.editor), in: 8...32) {
                        LabeledContent(l10n.text("editor"), value: "\(model.appearance.fontSizes.editor) pt")
                    }
                    Stepper(value: fontBinding(\.terminal), in: 8...32) {
                        LabeledContent(l10n.text("terminal"), value: "\(model.appearance.fontSizes.terminal) pt")
                    }
                    Text(l10n.text("fontHelp"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .formStyle(.grouped)
        case .keyboard:
            Form {
                Section(l10n.text("currentShortcuts")) {
                    keyboardRow(l10n.text("addProject"), "⌘O")
                    keyboardRow(l10n.text("newAgentSession"), "⌘N")
                    keyboardRow(l10n.text("save"), "⌘S")
                    keyboardRow(l10n.text("searchProjectHistory"), "⌘K")
                    keyboardRow(l10n.text("refreshHistory"), "⇧⌘R")
                    keyboardRow(l10n.text("panels") + " 1–4", "⌘1–⌘4")
                    keyboardRow("Canvas 1–4", "⇧⌘1–⇧⌘4")
                }
                Section {
                    Text(l10n.text("shortcutsReadOnly"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .formStyle(.grouped)
        case .data:
            Form {
                Section(l10n.text("nativeData")) {
                    LabeledContent(l10n.text("dataDirectory")) {
                        Text(model.dataRoot.path)
                            .font(.system(.caption, design: .monospaced))
                            .textSelection(.enabled)
                    }
                    Text(l10n.text("legacyDataUnchanged"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .formStyle(.grouped)
        case .about:
            Form {
                Section {
                    VStack(spacing: 12) {
                        Image(systemName: "shippingbox.fill").font(.system(size: 48)).foregroundStyle(.tint)
                        Text(YCodeBuildInfo.displayName).font(.title2.weight(.semibold))
                        Text(l10n.text("versionFormat", YCodeBuildInfo.installedVersion))
                        Text(YCodeBuildInfo.bundleIdentifier)
                            .font(.system(.caption, design: .monospaced))
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity)
                }

                Section(l10n.text("updates")) {
                    Button(l10n.text("checkForUpdatesEllipsis")) {
                        updateController.checkForUpdates()
                    }
                    .disabled(!updateController.isConfigured)
                    Picker(l10n.text("updateChannel"), selection: .constant("stable")) {
                        Text(l10n.text("stableChannel")).tag("stable")
                    }
                    .disabled(true)
                    Toggle(l10n.text("automaticUpdateDownloads"), isOn: .constant(false))
                        .disabled(true)
                    Text(l10n.text("updateOptionsPending"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Button(l10n.text("viewLicenses")) {}
                        .disabled(true)
                    Text(l10n.text("licensesPending"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    if !updateController.isConfigured {
                        Text(l10n.text("updatesReleaseOnly"))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .formStyle(.grouped)
        case let section:
            ContentUnavailableView(
                l10n.text("sectionUnavailableFormat", section.localizedTitle(l10n)),
                systemImage: section.icon,
                description: Text(l10n.text("sectionStageFormat", section.deliveryStage))
            )
        }
    }

    private func fontBinding(_ keyPath: WritableKeyPath<YCodeFontSizes, Int>) -> Binding<Int> {
        Binding(
            get: { model.appearance.fontSizes[keyPath: keyPath] },
            set: { model.appearance.fontSizes[keyPath: keyPath] = YCodeFontSizes.clamp($0) }
        )
    }

    private func keyboardRow(_ title: String, _ shortcut: String) -> some View {
        LabeledContent(title) {
            Text(shortcut)
                .font(.system(.body, design: .monospaced))
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private func availabilityLabel(for command: String) -> some View {
        if let available = model.commandAvailability[command] {
            Label(available ? l10n.text("available") : l10n.text("notFound"), systemImage: available ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                .font(.caption)
                .foregroundStyle(available ? .green : .orange)
        } else {
            ProgressView().controlSize(.small)
        }
    }

    private func proxySummary(_ proxy: YCodeSystemProxy, l10n: YCodeLocalization) -> String {
        if let pac = proxy.pacURL { return "PAC: \(pac) (\(l10n.text("notFound")))" }
        return proxy.https ?? proxy.http ?? proxy.socks ?? l10n.text("notFound")
    }
}

private enum AgentIconRegistry {
    static let options = [
        "ClaudeCode", "Claude", "Anthropic", "Codex", "OpenAI", "GeminiCLI", "Gemini", "Google",
        "Cline", "Copilot", "GithubCopilot", "KiloCode", "Trae", "Amp", "Phind", "Ollama",
        "Mistral", "DeepSeek", "Qwen", "Doubao", "Kimi", "Moonshot", "Grok", "XAI", "Meta",
        "MetaAI", "Cohere", "Perplexity", "Replit",
    ]

    static func systemName(for key: String?) -> String? {
        switch key {
        case "ClaudeCode": "sparkles"
        case "Claude", "Anthropic": "brain.head.profile"
        case "Codex", "OpenAI": "shippingbox.fill"
        case "GeminiCLI", "Gemini", "Google": "diamond.fill"
        case "Cline": "command"
        case "Copilot", "GithubCopilot": "airplane"
        case "KiloCode": "k.square.fill"
        case "Trae": "t.square.fill"
        case "Amp": "bolt.fill"
        case "Phind", "Perplexity": "magnifyingglass"
        case "Ollama": "brain"
        case "Mistral": "wind"
        case "DeepSeek": "wave.3.right"
        case "Qwen": "q.square.fill"
        case "Doubao": "d.circle.fill"
        case "Kimi": "moon.fill"
        case "Moonshot": "moon.stars.fill"
        case "Grok", "XAI": "xmark.circle.fill"
        case "Meta", "MetaAI": "infinity"
        case "Cohere": "circle.grid.2x2.fill"
        case "Replit": "terminal"
        default: nil
        }
    }
}

private struct AgentBadge: View {
    let profile: YCodeAgentProfile

    private var tint: Color {
        guard let raw = profile.color, let color = NSColor(hex: raw) else { return .accentColor }
        return Color(nsColor: color)
    }

    var body: some View {
        Group {
            if let systemName = AgentIconRegistry.systemName(for: profile.icon) {
                Image(systemName: systemName)
                    .symbolRenderingMode(profile.iconVariant == "mono" ? .monochrome : .hierarchical)
            } else {
                Text(String(profile.resolvedDisplayName.prefix(1)).uppercased()).font(.caption.bold())
            }
        }
        .frame(width: 26, height: 26)
        .background(tint.opacity(0.12), in: RoundedRectangle(cornerRadius: 6))
        .foregroundStyle(tint)
    }
}

private struct AgentEditorState: Identifiable {
    let id = UUID()
    let originalID: String?
    var agentID: String
    var displayName: String
    var command: String
    var arguments: String
    var environment: String
    var icon: String
    var iconVariant: String
    var color: String
    var original: YCodeAgentProfile?

    init(profile: YCodeAgentProfile?) {
        originalID = profile?.id
        agentID = profile?.id ?? ""
        displayName = profile?.displayName ?? ""
        command = profile?.command ?? ""
        arguments = profile?.arguments.joined(separator: "\n") ?? ""
        environment = profile?.environment.sorted(by: { $0.key < $1.key }).map { "\($0.key)=\($0.value)" }.joined(separator: "\n") ?? ""
        icon = profile?.icon ?? ""
        iconVariant = profile?.iconVariant ?? ""
        color = profile?.color ?? ""
        original = profile
    }
}

private struct AgentEditorView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.ycodeL10n) private var l10n
    @State var state: AgentEditorState
    let onSave: (YCodeAgentProfile, String?) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(state.originalID == nil ? l10n.text("addCustomAgent") : l10n.text("editAgent")).font(.title2.bold())
            Form {
                TextField(l10n.text("identifier"), text: $state.agentID, prompt: Text("my-agent"))
                TextField(l10n.text("displayName"), text: $state.displayName)
                TextField(l10n.text("command"), text: $state.command, prompt: Text(l10n.text("commandPrompt")))
                VStack(alignment: .leading) {
                    Text(l10n.text("argumentsOnePerLine"))
                    TextEditor(text: $state.arguments).font(.system(.body, design: .monospaced)).frame(height: 72)
                }
                VStack(alignment: .leading) {
                    Text(l10n.text("environmentKeyValue"))
                    TextEditor(text: $state.environment).font(.system(.body, design: .monospaced)).frame(height: 92)
                }
                Picker(l10n.text("agentIcon"), selection: $state.icon) {
                    Text(l10n.text("agentIconNone")).tag("")
                    ForEach(AgentIconRegistry.options, id: \.self) { name in Text(name).tag(name) }
                    if !state.icon.isEmpty, !AgentIconRegistry.options.contains(state.icon) {
                        Text("\(state.icon) · ?").tag(state.icon)
                    }
                }
                VStack(alignment: .leading, spacing: 4) {
                    TextField(l10n.text("agentIconKey"), text: $state.icon, prompt: Text("ClaudeCode"))
                    Text(l10n.text("agentIconKeyHelp")).font(.caption).foregroundStyle(.secondary)
                }
                Picker(l10n.text("agentIconVariant"), selection: $state.iconVariant) {
                    Text(l10n.text("agentIconBrand")).tag("")
                    Text(l10n.text("agentIconMono")).tag("mono")
                }
                HStack {
                    TextField(l10n.text("agentColor"), text: $state.color, prompt: Text("#7C3AED"))
                    ColorPicker("", selection: agentColor, supportsOpacity: false).labelsHidden()
                    Button(l10n.text("clearAgentColor")) { state.color = "" }
                        .disabled(state.color.isEmpty)
                }
            }
            HStack {
                Spacer()
                Button(l10n.text("cancel")) { dismiss() }.keyboardShortcut(.cancelAction)
                Button(l10n.text("doneButton")) {
                    var profile = state.original ?? YCodeAgentProfile(id: "", command: "")
                    profile.id = state.agentID.trimmingCharacters(in: .whitespacesAndNewlines)
                    profile.displayName = state.displayName.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
                    profile.command = state.command.trimmingCharacters(in: .whitespacesAndNewlines)
                    profile.arguments = state.arguments.lines
                    profile.environment = state.environment.lines.reduce(into: [:]) { result, line in
                        guard let split = line.firstIndex(of: "=") else { return }
                        let key = String(line[..<split]).trimmingCharacters(in: .whitespaces)
                        guard !key.isEmpty else { return }
                        result[key] = String(line[line.index(after: split)...])
                    }
                    profile.icon = state.icon.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
                    profile.iconVariant = state.iconVariant.nilIfEmpty
                    profile.color = state.color.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
                    onSave(profile, state.originalID)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(state.agentID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || state.command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 520, height: 470)
    }

    private var agentColor: Binding<Color> {
        Binding(
            get: { Color(nsColor: NSColor(hex: state.color) ?? .controlAccentColor) },
            set: { color in
                if let hex = NSColor(color).ycodeHexRGB { state.color = hex }
            }
        )
    }
}

private extension NSColor {
    var ycodeHexRGB: String? {
        guard let rgb = usingColorSpace(.deviceRGB) else { return nil }
        let red = Int((rgb.redComponent * 255).rounded())
        let green = Int((rgb.greenComponent * 255).rounded())
        let blue = Int((rgb.blueComponent * 255).rounded())
        return String(format: "#%02X%02X%02X", red, green, blue)
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
    var lines: [String] {
        split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
    }
}
