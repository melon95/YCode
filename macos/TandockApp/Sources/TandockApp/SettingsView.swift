import AppKit
import SwiftUI
import TandockCore

@MainActor
final class BasicSettingsModel: ObservableObject {
    @Published var agents: [TandockAgentProfile] = TandockAgentCatalog.defaults
    @Published var proxy = TandockProxySettings()
    @Published var notifications = TandockNotificationSettings()
    @Published var appearance = TandockAppearanceSettings()
    @Published var sessions = TandockSessionSettings()
    @Published private(set) var systemProxy = TandockSystemProxy()
    @Published private(set) var commandAvailability: [String: Bool] = [:]
    @Published var errorMessage: String?
    @Published var saved = false
    @Published private(set) var persistedNotifications = TandockNotificationSettings()
    @Published private(set) var persistedAppearance = TandockAppearanceSettings()
    @Published private(set) var persistedAgentSettings = TandockAgentSettings()

    let dataRoot: URL
    private let configurationStore: TandockConfigurationStore
    private let commandProbe: @Sendable (String) -> Bool

    init(dataRoot: URL = TandockDataRootResolver.resolve(), commandProbe: @escaping @Sendable (String) -> Bool = { TandockAgentLauncher.isAvailable(command: $0) }) {
        self.dataRoot = dataRoot
        self.commandProbe = commandProbe
        configurationStore = TandockConfigurationStore(configurationURL: dataRoot.appendingPathComponent("config.json"))
        do {
            let settings = try configurationStore.loadBasicSettings()
            notifications = settings.notifications
            persistedNotifications = settings.notifications
            appearance = settings.appearance
            persistedAppearance = settings.appearance
            sessions = settings.sessions
            let agentSettings = try configurationStore.loadAgentSettings()
            agents = agentSettings.agents
            proxy = agentSettings.proxy
            persistedAgentSettings = agentSettings
            _ = try NativeWorkspaceStateStore(databaseURL: dataRoot.appendingPathComponent("ycode.db"))
            refreshAvailability()
            systemProxy = TandockSystemProxyDetector.detect()
        } catch {
            errorMessage = String(describing: error)
        }
    }

    func save() {
        do {
            let agentSettings = TandockAgentSettings(agents: agents, proxy: proxy)
            try configurationStore.saveSettings(
                basic: TandockBasicSettings(notifications: notifications, appearance: appearance, sessions: sessions),
                agents: agentSettings
            )
            persistedNotifications = notifications
            persistedAppearance = appearance
            persistedAgentSettings = agentSettings
            saved = true
            NotificationCenter.default.post(name: .tandockAppearanceSettingsChanged, object: nil)
        } catch {
            errorMessage = String(describing: error)
        }
    }

    func setAgentEnabled(id: String, enabled: Bool) {
        guard let index = agents.firstIndex(where: { $0.id == id }) else { return }
        agents[index].enabled = enabled
    }

    func removeAgent(id: String) {
        agents.removeAll { $0.id == id }
    }

    func upsertAgent(_ agent: TandockAgentProfile, replacing originalID: String?) {
        if let originalID, let index = agents.firstIndex(where: { $0.id == originalID }) {
            agents[index] = agent
        } else {
            if let index = agents.firstIndex(where: { $0.id == agent.id }) {
                agents[index] = agent
            } else {
                agents.append(agent)
            }
        }
        refreshAvailability()
    }

    func addSuggestion(_ suggestion: TandockAgentProfile) {
        guard !agents.contains(where: { $0.command == suggestion.command }) else { return }
        var agent = suggestion
        agent.enabled = true
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
        let commands = Set((agents + TandockAgentCatalog.defaults + TandockAgentCatalog.suggestions).map(\.command))
        let probe = commandProbe
        Task { [weak self] in
            let statuses = await Task.detached {
                Dictionary(uniqueKeysWithValues: commands.map { ($0, probe($0)) })
            }.value
            self?.commandAvailability = statuses
        }
    }
}

private enum SettingsSection: String, CaseIterable, Identifiable {
    case agents, skills, mcp, integrations, notifications, usage
    case terminal, appearance, keyboard, about

    var id: String { rawValue }

    enum Group: String, CaseIterable, Identifiable {
        case general, agent, system

        var id: String { rawValue }

        func localizedTitle(_ l10n: TandockLocalization) -> String {
            switch self {
            case .general: l10n.text("general")
            case .agent: "Agent"
            case .system: l10n.text("system")
            }
        }

        var sections: [SettingsSection] {
            switch self {
            case .general: [.appearance, .keyboard]
            case .agent: [.agents, .skills, .mcp, .terminal, .integrations, .usage]
            case .system: [.notifications, .about]
            }
        }
    }

    func localizedTitle(_ l10n: TandockLocalization) -> String {
        switch self {
        case .agents: l10n.text("agents")
        case .skills: "Skills"
        case .mcp: "MCP"
        case .integrations: l10n.text("integrations")
        case .notifications: l10n.text("notifications")
        case .usage: l10n.text("usage")
        case .terminal: l10n.text("terminal")
        case .appearance: l10n.text("appearance")
        case .keyboard: l10n.text("keyboard")
        case .about: l10n.text("diagnostics")
        }
    }

    var icon: String {
        switch self {
        case .agents: "cpu"
        case .skills: "doc.text"
        case .mcp: "powerplug"
        case .integrations: "puzzlepiece.extension"
        case .notifications: "bell"
        case .usage: "chart.bar"
        case .terminal: "terminal"
        case .appearance: "paintbrush"
        case .keyboard: "keyboard"
        case .about: "info.circle"
        }
    }

}

struct BasicSettingsView: View {
    @StateObject private var model = BasicSettingsModel()
    @StateObject private var mcpIntegrationModel = MCPIntegrationSettingsModel()
    @StateObject private var customizationModel = AgentCustomizationSettingsModel()
    @StateObject private var updateController = TandockUpdateController.shared
    @Environment(\.dismiss) private var dismiss
    @Environment(\.tandockL10n) private var inheritedL10n
    @State private var selectedSection: SettingsSection = .appearance
    @State private var editingAgent: AgentEditorState?
    private var l10n: TandockLocalization { TandockLocalization(locale: model.appearance.locale) }
    @Environment(\.colorScheme) private var colorScheme
    private var theme: TandockThemeOption {
        TandockThemeCatalog.resolve(id: model.appearance.theme, prefersDark: colorScheme == .dark)
    }

    var body: some View {
        HStack(spacing: 0) {
            navigationColumn
            Divider()
            VStack(spacing: 0) {
                HStack {
                    Text(selectedSection.localizedTitle(l10n))
                        .font(.title3.weight(.semibold))
                    Spacer()
                }
                .padding(.horizontal, 20)
                .frame(height: 44)
                Divider()
                settingsContent
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(width: 780, height: 540)
        .background {
            Button("") { closeWindow() }
                .keyboardShortcut(.cancelAction)
                .opacity(0)
                .accessibilityHidden(true)
            SettingsWindowChrome()
        }
        .environment(\.tandockL10n, l10n)
        .onChange(of: model.appearance.theme) { _, id in TandockAppearanceProbe.apply(themeID: id) }
        .tint(Color(themeHex: theme.accent))
        .onChange(of: model.notifications) { _, _ in model.save() }
        .onChange(of: model.appearance) { _, _ in model.save() }
        .onChange(of: model.sessions) { _, _ in model.save() }
        .onChange(of: model.proxy) { _, _ in model.save() }
        .onChange(of: model.agents) { _, _ in model.save() }
        .alert(l10n.text("settingsSaveFailed"), isPresented: Binding(
            get: { model.errorMessage != nil },
            set: { if !$0 { model.errorMessage = nil } }
        )) {
            Button(l10n.text("ok")) { model.errorMessage = nil }
        } message: {
            Text(model.errorMessage ?? l10n.text("unknownError"))
        }
        .sheet(item: $editingAgent) { editor in
            AgentEditorView(state: editor, existingIDs: Set(model.agents.map(\.id))) { profile, originalID in
                model.upsertAgent(profile, replacing: originalID)
            }
        }
    }

    private var navigationColumn: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 1) {
                ForEach(SettingsSection.Group.allCases) { group in
                    Text(group.localizedTitle(l10n))
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 18)
                        .padding(.top, 14)
                        .padding(.bottom, 3)
                    ForEach(group.sections) { section in
                        navigationRow(section)
                    }
                }
            }
            .padding(.bottom, 12)
        }
        .frame(width: 196)
        .background(.ultraThinMaterial)
    }

    private func navigationRow(_ section: SettingsSection) -> some View {
        let selected = selectedSection == section
        return HStack(spacing: 9) {
            Image(systemName: section.icon)
                .font(.system(size: 13))
                .frame(width: 18)
                .foregroundStyle(Color.tandockAccent)
            Text(section.localizedTitle(l10n))
                .font(.system(size: 13, weight: selected ? .medium : .regular))
                .lineLimit(1)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10)
        .frame(height: 26)
        .background(
            RoundedRectangle(cornerRadius: TandockMetrics.cornerRadius, style: .continuous)
                .fill(selected ? Color.tandockSelection : .clear)
                .shadow(color: selected ? Color.tandockShadow : .clear, radius: 1, y: 1)
        )
        .foregroundStyle(Color.primary)
        .padding(.horizontal, 8)
        .contentShape(Rectangle())
        .onTapGesture { selectedSection = section }
    }

    private var uiScaleBinding: Binding<Int> {
        Binding(
            get: {
                switch model.appearance.fontSizes.ui {
                case ..<14: 13
                case 14..<16: 14
                default: 16
                }
            },
            set: { model.appearance.fontSizes.ui = TandockFontSizes.clamp($0) }
        )
    }

    private func closeWindow() {
        if let window = NSApp.keyWindow, window.styleMask.contains(.closable) {
            window.performClose(nil)
        } else {
            dismiss()
        }
    }

    @ViewBuilder
    private var settingsContent: some View {
        switch selectedSection {
        case .skills, .mcp:
            AgentCustomizationSettingsView(model: customizationModel, agents: model.agents, page: selectedSection == .skills ? .skills : .mcp)
                .id(selectedSection)
        case .agents:
            AgentSettingsView(model: model, onEdit: { profile in
                editingAgent = AgentEditorState(profile: profile)
            }, onAddCustom: {
                editingAgent = AgentEditorState(profile: nil)
            })
        case .terminal:
            Form {
                Section {
                    TandockFormRow(label: l10n.text("mode"), trailing: true) {
                        Picker("", selection: $model.proxy.mode) {
                            Text(l10n.text("off")).tag(TandockProxyMode.off)
                            Text(l10n.text("followSystem")).tag(TandockProxyMode.system)
                            Text(l10n.text("manual")).tag(TandockProxyMode.manual)
                        }
                        .labelsHidden()
                        .fixedSize()
                    }
                    if model.proxy.mode == .system {
                        TandockFormValueRow(
                            label: l10n.text("currentDetection"),
                            value: proxySummary(model.systemProxy, l10n: l10n),
                            mono: true,
                            trailing: true
                        )
                    }
                    if model.proxy.mode == .manual {
                        TandockFormRow(label: l10n.text("proxyAddress")) {
                            TextField("", text: $model.proxy.url, prompt: Text("127.0.0.1:7897"))
                                .labelsHidden()
                                .textFieldStyle(.roundedBorder)
                                .font(.system(.body, design: .monospaced))
                        }
                        TandockFormRow(label: l10n.text("exceptions")) {
                            TextField("", text: $model.proxy.noProxy, prompt: Text("localhost,127.0.0.1,*.local"))
                                .labelsHidden()
                                .textFieldStyle(.roundedBorder)
                                .font(.system(.body, design: .monospaced))
                        }
                    }
                } header: {
                    Text(l10n.text("proxy"))
                } footer: {
                    Text(l10n.text("proxyHelp"))
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
                agents: TandockMCPAgent.allCases.filter { agent in
                    model.agents.contains { $0.introspect == agent.rawValue }
                }
            )
        case .appearance:
            Form {
                Section {
                    TandockFormRow(label: l10n.text("theme"), trailing: true) {
                        Picker("", selection: $model.appearance.theme) {
                            Text(l10n.text("followSystem")).tag(TandockThemeCatalog.systemID)
                            Text(l10n.text("lightAppearance")).tag(TandockThemeCatalog.light.id)
                            Text(l10n.text("darkAppearance")).tag(TandockThemeCatalog.dark.id)
                        }
                        .labelsHidden()
                        .fixedSize()
                    }
                } header: {
                    Text(l10n.text("theme"))
                } footer: {
                    Text(l10n.text("themeHelp"))
                }
                Section {
                    TandockFormRow(label: l10n.text("interfaceLanguage"), trailing: true) {
                        Picker("", selection: $model.appearance.locale) {
                            Text("中文").tag(TandockLocale.zh)
                            Text("English").tag(TandockLocale.en)
                        }
                        .labelsHidden()
                        .fixedSize()
                    }
                } header: {
                    Text(l10n.text("language"))
                } footer: {
                    Text(l10n.text("languageHelp"))
                }
                Section {
                    TandockFormRow(label: l10n.text("uiScale"), trailing: true) {
                        Picker("", selection: uiScaleBinding) {
                            Text(l10n.text("uiScaleCompact")).tag(13)
                            Text(l10n.text("uiScaleStandard")).tag(14)
                            Text(l10n.text("uiScaleLoose")).tag(16)
                        }
                        .labelsHidden()
                        .fixedSize()
                    }
                } header: {
                    Text(l10n.text("uiScale"))
                } footer: {
                    Text(l10n.text("uiScaleHint"))
                }
                Section {
                    fontRow(l10n.text("editor"), keyPath: \.editor)
                    fontRow(l10n.text("terminal"), keyPath: \.terminal)
                } header: {
                    Text(l10n.text("fontSize"))
                } footer: {
                    Text(l10n.text("fontHelp"))
                }
            }
            .formStyle(.grouped)
        case .keyboard:
            Form {
                Section {
                    keyboardRow(l10n.text("addProject"), "⌘O")
                    keyboardRow(l10n.text("newSession"), "⌘N")
                    keyboardRow(l10n.text("commandPalette"), "⌘K")
                    keyboardRow(l10n.text("save"), "⌘S")
                    keyboardRow(l10n.text("findTerminal"), "⌘F")
                    keyboardRow(l10n.text("showHideProjectSidebar"), "⌘B")
                    keyboardRow(l10n.text("hideInspector"), "⌥⌘→")
                    keyboardRow(l10n.text("inspectorTabFormat", "1–4"), "⌘1–⌘4")
                    keyboardRow(l10n.text("inspectorTabFormat", l10n.text("terminal")), "⌘J")
                    keyboardRow(l10n.text("closeSession"), "⌘W")
                    keyboardRow(l10n.text("focusCanvasFormat", 1) + "–4", "⇧⌘1–⇧⌘4")
                    keyboardRow(l10n.text("refreshHistory"), "⇧⌘R")
                } header: {
                    Text(l10n.text("currentShortcuts"))
                } footer: {
                    Text(l10n.text("shortcutsReadOnly"))
                }

                Section {
                    Toggle(l10n.text("confirmCloseSession"), isOn: $model.sessions.confirmBeforeClose)
                        .toggleStyle(.switch).controlSize(.small)
                } footer: {
                    Text(l10n.text("confirmCloseSessionHelp"))
                }
            }
            .formStyle(.grouped)
        case .about:
            Form {
                Section {
                    VStack(spacing: 12) {
                        appIcon(size: 64)
                        Text(TandockBuildInfo.displayName).font(.title2.weight(.semibold))
                        Text(l10n.text("versionFormat", TandockBuildInfo.versionDescription))
                        Text(TandockBuildInfo.bundleIdentifier)
                            .font(.system(.caption, design: .monospaced))
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity)
                }

                Section {
                    TandockFormRow(label: l10n.text("checkForUpdatesEllipsis"), trailing: true) {
                        Button { updateController.checkForUpdates() } label: { Image(systemName: "arrow.clockwise") }
                            .buttonStyle(TandockIconButtonStyle(width: 22, height: 22, fontSize: 12))
                            .help(l10n.text("checkForUpdatesEllipsis"))
                            .accessibilityLabel(l10n.text("checkForUpdatesEllipsis"))
                            .disabled(!updateController.isConfigured)
                    }
                } header: {
                    Text(l10n.text("updates"))
                } footer: {
                    if !updateController.isConfigured {
                        Text(l10n.text("updatesReleaseOnly"))
                    }
                }

            }
            .formStyle(.grouped)
        case let section:
            ContentUnavailableView(
                l10n.text("sectionUnavailableFormat", section.localizedTitle(l10n)),
                systemImage: section.icon,
                description: Text(l10n.text("sectionPendingBody"))
            )
        }
    }

    private func fontRow(_ label: String, keyPath: WritableKeyPath<TandockFontSizes, Int>) -> some View {
        TandockFormRow(label: label, trailing: true) {
            HStack(spacing: 6) {
                Text("\(model.appearance.fontSizes[keyPath: keyPath])")
                    .font(.system(.body, design: .monospaced))
                    .monospacedDigit()
                    .frame(minWidth: 22, alignment: .trailing)
                Stepper("", value: fontBinding(keyPath), in: 8...32)
                    .labelsHidden()
                    .fixedSize()
            }
        }
    }

    private func fontBinding(_ keyPath: WritableKeyPath<TandockFontSizes, Int>) -> Binding<Int> {
        Binding(
            get: { model.appearance.fontSizes[keyPath: keyPath] },
            set: { model.appearance.fontSizes[keyPath: keyPath] = TandockFontSizes.clamp($0) }
        )
    }

    @ViewBuilder
    private func appIcon(size: CGFloat) -> some View {
        if let icon = NSImage(named: NSImage.applicationIconName) {
            Image(nsImage: icon)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: size, height: size)
        } else {
            Image(systemName: "shippingbox.fill")
                .font(.system(size: size * 0.75))
                .foregroundStyle(.tint)
        }
    }

    private func keyboardRow(_ title: String, _ shortcut: String) -> some View {
        HStack {
            Text(title)
            Spacer(minLength: 16)
            Text(shortcut)
                .font(.system(.body, design: .monospaced))
                .foregroundStyle(.secondary)
        }
    }

    private func proxySummary(_ proxy: TandockSystemProxy, l10n: TandockLocalization) -> String {
        if let pac = proxy.pacURL { return "PAC: \(pac) (\(l10n.text("notFound")))" }
        return proxy.https ?? proxy.http ?? proxy.socks ?? l10n.text("notFound")
    }
}

struct AgentSettingsView: View {
    @ObservedObject var model: BasicSettingsModel
    let onEdit: (TandockAgentProfile) -> Void
    let onAddCustom: () -> Void
    @Environment(\.tandockL10n) private var l10n

    private var suggestions: [TandockAgentProfile] {
        (TandockAgentCatalog.defaults + TandockAgentCatalog.suggestions).filter { suggestion in
            !model.agents.contains(where: { $0.command == suggestion.command })
                && model.commandAvailability[suggestion.command] == true
        }
    }

    var body: some View {
        Form {
            Section {
                if model.agents.isEmpty {
                    TandockInspectorEmptyState(title: l10n.text("noAgentsConfigured"), message: l10n.text("noAgentsHint"), symbol: "cpu")
                        .frame(minHeight: 130)
                }
                ForEach(model.agents) { agent in
                    HStack(spacing: 10) {
                        agentIdentity(agent)
                        Spacer(minLength: 8)
                        if model.commandAvailability[agent.command] == false {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .foregroundStyle(Color.tandockWarn)
                                .help(l10n.text("notFound"))
                                .accessibilityLabel(l10n.text("notFound"))
                        } else if model.commandAvailability[agent.command] == nil {
                            ProgressView().controlSize(.mini)
                        }
                        Button { onEdit(agent) } label: { Image(systemName: "pencil") }
                            .buttonStyle(TandockIconButtonStyle(width: 22, height: 22, fontSize: 12))
                            .help(l10n.text("editAgent") + " · " + agent.resolvedDisplayName)
                            .accessibilityLabel(l10n.text("editAgent") + " · " + agent.resolvedDisplayName)
                        Button(role: .destructive) { model.removeAgent(id: agent.id) } label: { Image(systemName: "trash") }
                            .buttonStyle(TandockIconButtonStyle(width: 22, height: 22, fontSize: 12))
                            .help(l10n.text("delete") + " " + agent.resolvedDisplayName)
                            .accessibilityLabel(l10n.text("delete") + " " + agent.resolvedDisplayName)
                        Toggle(l10n.text("enabled"), isOn: Binding(
                            get: { agent.enabled },
                            set: { model.setAgentEnabled(id: agent.id, enabled: $0) }
                        ))
                        .labelsHidden().toggleStyle(.switch).controlSize(.small)
                        .help(l10n.text("agentEnablementHelp"))
                        .accessibilityLabel(agent.resolvedDisplayName)
                    }
                }
            } header: {
                HStack {
                    Text(l10n.text("configured"))
                    Spacer()
                    Button(action: onAddCustom) { Image(systemName: "plus") }
                        .buttonStyle(TandockIconButtonStyle(width: 22, height: 22, fontSize: 12))
                        .help(l10n.text("addCustomAgent"))
                        .accessibilityLabel(l10n.text("addCustomAgent"))
                }
            } footer: {
                Text(l10n.text("agentEnablementHelp"))
            }
            if !suggestions.isEmpty {
                Section(l10n.text("detected")) {
                    ForEach(suggestions) { suggestion in
                        HStack(spacing: 10) {
                            agentIdentity(suggestion)
                            Spacer(minLength: 8)
                            Toggle(l10n.text("enabled"), isOn: Binding(
                                get: { false },
                                set: { enabled in if enabled { model.addSuggestion(suggestion) } }
                            ))
                            .labelsHidden().toggleStyle(.switch).controlSize(.small)
                            .help(l10n.text("agentEnableDetectedHelp", suggestion.resolvedDisplayName))
                            .accessibilityLabel(suggestion.resolvedDisplayName)
                        }
                    }
                }
            }
        }
        .formStyle(.grouped)
    }

    private func agentIdentity(_ agent: TandockAgentProfile) -> some View {
        HStack(spacing: 10) {
            AgentBadge(profile: agent)
            VStack(alignment: .leading, spacing: 2) {
                Text(agent.resolvedDisplayName).lineLimit(1).help(agent.resolvedDisplayName)
                Text(agent.command)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(1).truncationMode(.middle).help(agent.command)
            }
        }
    }
}

struct AgentBadge: View {
    let profile: TandockAgentProfile

    private var tint: Color {
        guard let raw = profile.color, let color = NSColor(hex: raw) else { return .tandockAccent }
        return Color(nsColor: color)
    }

    var body: some View {
        TandockAgentIconView(profile: profile, size: 16, tint: tint)
            .frame(width: 26, height: 26)
        .background(tint.opacity(0.12), in: RoundedRectangle(cornerRadius: TandockMetrics.cornerRadius))
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
    var original: TandockAgentProfile?
    var touchedID = false
    var touchedCommand = false

    init(profile: TandockAgentProfile?) {
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
        touchedID = profile != nil
        touchedCommand = profile != nil
    }
}

private struct AgentEditorView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.tandockL10n) private var l10n
    @State var state: AgentEditorState
    var existingIDs: Set<String> = []
    let onSave: (TandockAgentProfile, String?) -> Void

    var body: some View {
        VStack(spacing: 0) {
            Text(state.originalID == nil ? l10n.text("addCustomAgentTitle") : l10n.text("editAgent"))
                .font(.title2.bold())
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 20)
                .padding(.top, 20)
                .padding(.bottom, 12)
            Form {
                Section {
                    if state.originalID == nil {
                        validatedField(
                            l10n.text("identifier"),
                            text: $state.agentID,
                            prompt: "my-agent",
                            error: idError,
                            help: l10n.text("agentIDHelp")
                        )
                        .onChange(of: state.agentID) { _, _ in state.touchedID = true }
                    } else {
                        TandockFormRow(label: l10n.text("identifier"), hint: l10n.text("agentIDLocked")) {
                            Text(state.agentID)
                                .font(.system(.body, design: .monospaced))
                                .textSelection(.enabled)
                        }
                    }
                    TandockFormRow(label: l10n.text("displayName")) {
                        TextField("", text: $state.displayName, prompt: Text("My Agent"))
                            .labelsHidden()
                            .textFieldStyle(.roundedBorder)
                    }
                    validatedField(
                        l10n.text("command"),
                        text: $state.command,
                        prompt: l10n.text("commandPrompt"),
                        error: commandError,
                        help: nil
                    )
                    .onChange(of: state.command) { _, _ in state.touchedCommand = true }
                }
                Section(l10n.text("agentEditorLaunch")) {
                    TandockFormRow(label: l10n.text("argumentsOnePerLine"), hint: l10n.text("argumentsHelp")) {
                        codeEditor($state.arguments, height: 72, placeholder: "--model opus\n--verbose")
                    }
                    TandockFormRow(label: l10n.text("environmentKeyValue"), hint: l10n.text("environmentHelp")) {
                        codeEditor($state.environment, height: 92, placeholder: "ANTHROPIC_API_KEY=$MY_KEY\nHTTP_PROXY=127.0.0.1:7897")
                    }
                }
                Section(l10n.text("agentEditorAppearance")) {
                    TandockFormRow(label: l10n.text("agentIcon")) {
                        AgentIconPicker(
                            icon: $state.icon,
                            colorHex: state.color,
                            displayName: state.displayName.isEmpty ? state.agentID : state.displayName
                        )
                    }
                    TandockFormRow(label: l10n.text("agentColor"), hint: colorHint) {
                        HStack(spacing: 8) {
                            TextField("", text: $state.color, prompt: Text(l10n.text("agentColorFollowsAccent")))
                                .labelsHidden()
                                .textFieldStyle(.roundedBorder)
                                .font(.system(.body, design: .monospaced))
                            ColorPicker("", selection: agentColor, supportsOpacity: false)
                                .labelsHidden()
                                .overlay {
                                    if state.color.isEmpty {
                                        GeometryReader { geo in
                                            Path { path in
                                                path.move(to: CGPoint(x: 2, y: geo.size.height - 2))
                                                path.addLine(to: CGPoint(x: geo.size.width - 2, y: 2))
                                            }
                                            .stroke(Color.secondary, style: StrokeStyle(lineWidth: 1.5, lineCap: .round))
                                        }
                                        .allowsHitTesting(false)
                                    }
                                }
                            Button(l10n.text("clearAgentColor")) { state.color = "" }
                                .disabled(state.color.isEmpty)
                        }
                    }
                }
            }
            .formStyle(.grouped)
            Divider()
            HStack {
                Spacer()
                Button(l10n.text("cancel")) { dismiss() }.keyboardShortcut(.cancelAction)
                Button(l10n.text("doneButton")) {
                    var profile = state.original ?? TandockAgentProfile(id: "", command: "")
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
                .disabled(!canSave)
            }
            .padding(20)
        }
        .frame(minWidth: 560, idealWidth: 560, maxWidth: 560, minHeight: 420, idealHeight: 580, maxHeight: 640)
    }


    private var trimmedID: String { state.agentID.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var trimmedCommand: String { state.command.trimmingCharacters(in: .whitespacesAndNewlines) }

    private var idError: String? {
        guard state.touchedID else { return nil }
        if trimmedID.isEmpty { return l10n.text("fieldRequired") }
        if trimmedID != state.originalID, existingIDs.contains(trimmedID) {
            return l10n.text("agentIDTaken")
        }
        return nil
    }

    private var commandError: String? {
        guard state.touchedCommand, trimmedCommand.isEmpty else { return nil }
        return l10n.text("fieldRequired")
    }

    private var canSave: Bool {
        guard !trimmedID.isEmpty, !trimmedCommand.isEmpty else { return false }
        if trimmedID != state.originalID, existingIDs.contains(trimmedID) { return false }
        return true
    }

    @ViewBuilder
    private func validatedField(
        _ label: String,
        text: Binding<String>,
        prompt: String,
        error: String?,
        help: String?
    ) -> some View {
        TandockFormRow(label: label, hint: help, error: error) {
            TextField("", text: text, prompt: Text(prompt))
                .labelsHidden()
                .textFieldStyle(.roundedBorder)
                .font(.system(.body, design: .monospaced))
                .overlay {
                    if error != nil {
                        RoundedRectangle(cornerRadius: TandockMetrics.radiusChip)
                            .stroke(Color.tandockErr, lineWidth: 1)
                    }
                }
        }
    }

    @ViewBuilder
    private func codeEditor(_ text: Binding<String>, height: CGFloat, placeholder: String) -> some View {
        TextEditor(text: text)
            .font(.system(.body, design: .monospaced))
            .scrollContentBackground(.hidden)
            .padding(.horizontal, 5)
            .padding(.vertical, 4)
            .frame(height: height)
            .background(
                Color(nsColor: .textBackgroundColor),
                in: RoundedRectangle(cornerRadius: TandockMetrics.radiusChip)
            )
            .overlay(alignment: .topLeading) {
                if text.wrappedValue.isEmpty {
                    Text(placeholder)
                        .font(.system(.body, design: .monospaced))
                        .foregroundStyle(.tertiary)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 8)
                        .allowsHitTesting(false)
                }
            }
            .overlay {
                RoundedRectangle(cornerRadius: TandockMetrics.radiusChip)
                    .stroke(Color.secondary.opacity(0.28))
            }
    }

    private var colorHint: String {
        state.color.isEmpty ? l10n.text("agentColorUnsetHint") : l10n.text("agentColorSetHint")
    }

    private var agentColor: Binding<Color> {
        Binding(
            get: { Color(nsColor: NSColor(hex: state.color) ?? .controlAccentColor) },
            set: { color in
                if let hex = NSColor(color).tandockHexRGB { state.color = hex }
            }
        )
    }
}

private extension NSColor {
    var tandockHexRGB: String? {
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

/// The content runs under the titlebar, so the system title would sit on the sidebar edge; the section header names the page instead.
private struct SettingsWindowChrome: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        DispatchQueue.main.async { view.window?.titleVisibility = .hidden }
        return view
    }

    func updateNSView(_ view: NSView, context: Context) {}
}
