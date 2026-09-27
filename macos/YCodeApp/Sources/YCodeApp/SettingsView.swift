import AppKit
import SwiftUI
import YCodeCore

@MainActor
final class BasicSettingsModel: ObservableObject {
    @Published var agents: [YCodeAgentProfile] = YCodeAgentCatalog.defaults
    @Published var proxy = YCodeProxySettings()
    @Published var notifications = YCodeNotificationSettings()
    @Published var appearance = YCodeAppearanceSettings()
    @Published private(set) var systemProxy = YCodeSystemProxy()
    @Published private(set) var commandAvailability: [String: Bool] = [:]
    @Published var errorMessage: String?
    @Published var saved = false
    @Published private(set) var persistedNotifications = YCodeNotificationSettings()
    @Published private(set) var persistedAppearance = YCodeAppearanceSettings()
    @Published private(set) var persistedAgentSettings = YCodeAgentSettings()

    let dataRoot: URL
    private let configurationStore: YCodeConfigurationStore

    init() {
        dataRoot = YCodeDataRootResolver.resolve()
        configurationStore = YCodeConfigurationStore(configurationURL: dataRoot.appendingPathComponent("config.json"))
        do {
            let settings = try configurationStore.loadBasicSettings()
            notifications = settings.notifications
            persistedNotifications = settings.notifications
            appearance = settings.appearance
            persistedAppearance = settings.appearance
            let agentSettings = try configurationStore.loadAgentSettings()
            agents = agentSettings.agents
            proxy = agentSettings.proxy
            persistedAgentSettings = agentSettings
            let state = try NativeWorkspaceStateStore(databaseURL: dataRoot.appendingPathComponent("ycode.db"))
            refreshAvailability()
            systemProxy = YCodeSystemProxyDetector.detect()
        } catch {
            errorMessage = String(describing: error)
        }
    }

    func save() {
        do {
            let agentSettings = YCodeAgentSettings(agents: agents, proxy: proxy)
            try configurationStore.saveSettings(
                basic: YCodeBasicSettings(notifications: notifications, appearance: appearance),
                agents: agentSettings
            )
            persistedNotifications = notifications
            persistedAppearance = appearance
            persistedAgentSettings = agentSettings
            saved = true
            NotificationCenter.default.post(name: .ycodeAppearanceSettingsChanged, object: nil)
        } catch {
            errorMessage = String(describing: error)
        }
    }

    func removeAgent(id: String) {
        agents.removeAll { $0.id == id }
    }

    func upsertAgent(_ agent: YCodeAgentProfile, replacing originalID: String?) {
        if let originalID, let index = agents.firstIndex(where: { $0.id == originalID }) {
            agents[index] = agent
        } else {
            // 兜底去重。编辑器已经在输入时就挡住了重复标识（见 AgentEditorView.idError），
            // 但 upsert 是模型层的公开入口 —— 原先这里直接 append，两个同 id 的 agent
            // 就能并排躺在列表里，之后按 id 查找永远只命中第一个，另一个是个查不到、
            // 删不掉、却一直显示着的幽灵。addSuggestion 早就防了这件事，这里漏了。
            if let index = agents.firstIndex(where: { $0.id == agent.id }) {
                agents[index] = agent
            } else {
                agents.append(agent)
            }
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
    case agents, integrations, notifications, usage
    case terminal, appearance, keyboard, about

    var id: String { rawValue }

    /// 设计稿 §08：分组按用户心智，而不是按模块。
    enum Group: String, CaseIterable, Identifiable {
        case general, agent, system

        var id: String { rawValue }

        func localizedTitle(_ l10n: YCodeLocalization) -> String {
            switch self {
            case .general: l10n.text("general")
            case .agent: "Agent"
            case .system: l10n.text("system")
            }
        }

        var sections: [SettingsSection] {
            switch self {
            case .general: [.appearance, .keyboard]
            case .agent: [.agents, .terminal, .integrations, .usage]
            case .system: [.notifications, .about]
            }
        }
    }

    func localizedTitle(_ l10n: YCodeLocalization) -> String {
        switch self {
        case .agents: l10n.text("agents")
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
    @StateObject private var updateController = YCodeUpdateController.shared
    @Environment(\.dismiss) private var dismiss
    @Environment(\.ycodeL10n) private var inheritedL10n
    @State private var selectedSection: SettingsSection = .appearance
    @State private var editingAgent: AgentEditorState?
    private var l10n: YCodeLocalization { YCodeLocalization(locale: model.appearance.locale) }
    private var theme: YCodeThemeOption {
        YCodeThemeCatalog.resolve(id: model.appearance.theme, prefersDark: YCodeAppearanceProbe.prefersDark)
    }
    /// 设置窗跟着 app 的外观走，不然主窗口是深色、设置窗是浅色。
    private var preferredScheme: ColorScheme? {
        switch model.appearance.theme {
        case YCodeThemeCatalog.light.id: .light
        case YCodeThemeCatalog.dark.id: .dark
        default: nil
        }
    }

    var body: some View {
        // 自绘两栏：NavigationSplitView 是给主窗口用的，放进设置窗会带上一条空的
        // 工具栏区和一个侧栏折叠按钮 —— 系统设置里没有这两样东西。
        HStack(spacing: 0) {
            navigationColumn
            Divider()
            VStack(spacing: 0) {
                // 页名放在内容区顶部：设置窗的标题栏由系统给（「设置」），
                // navigationTitle 没有 navigation 容器托管，不能指望它显示页名。
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
        // Esc 关窗原本挂在「取消」按钮上，按钮去掉后要单独接回来（⌘W 由系统管）
        .background {
            Button("") { closeWindow() }
                .keyboardShortcut(.cancelAction)
                .opacity(0)
                .accessibilityHidden(true)
        }
        .environment(\.ycodeL10n, l10n)
        .preferredColorScheme(preferredScheme)
        .tint(Color(themeHex: theme.accent))
        // macOS 的设置是即时生效的，所以不放「保存 / 取消」，改完就写盘
        .onChange(of: model.notifications) { _, _ in model.save() }
        .onChange(of: model.appearance) { _, _ in model.save() }
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
                .foregroundStyle(selected ? Color.white : Color.accentColor)
            Text(section.localizedTitle(l10n))
                .font(.system(size: 13))
                .lineLimit(1)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10)
        .frame(height: 26)
        .background(
            RoundedRectangle(cornerRadius: YCodeMetrics.cornerRadius)
                .fill(selected ? Color.accentColor : .clear)
        )
        .foregroundStyle(selected ? Color.white : Color.primary)
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
            set: { model.appearance.fontSizes.ui = YCodeFontSizes.clamp($0) }
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
        case .agents:
            Form {
                Section(l10n.text("configured")) {
                    if model.agents.isEmpty {
                        // 空状态是新用户看到的第一屏。原先是一行灰字「未配置 Agent」——
                        // 它只陈述现状，不说下一步。
                        YCodeInspectorEmptyState(
                            title: l10n.text("noAgentsConfigured"),
                            message: l10n.text("noAgentsHint"),
                            symbol: "cpu"
                        )
                        .frame(minHeight: 130)
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
            // 曾经这里还有一组「启动环境」：一行 Shell、一行写死的「256 色 / True Color」。
            // 后者是硬编码常量，任何机器上都显示同一句，不回答任何问题；
            // 前者虽然是准的，但 agent 起不来时你真正要看的是 login shell 解出来的
            // **PATH**（`probe()` 跑的就是 `$SHELL -l -i -c "command -v ..."`），
            // 知道 shell 叫 /bin/zsh 帮不上忙。两行都删掉，这一页只留真正的设置：代理。
            Form {
                Section(l10n.text("proxy")) {
                    // 这里本可以用分段控件（切换它确实会改变下面出现哪些字段，
                    // 是个真正的模式开关）。但设置窗里其余的三选一都已经是弹出菜单，
                    // 只剩它一个是分段的话，同一个窗口里就有了两套「选一个」的说法。
                    // **一致性优先于这条细分规则**：看起来一样的东西应该行为一样，
                    // 反过来也成立 —— 做同一件事的东西不该长得不一样。
                    YCodeFormRow(label: l10n.text("mode")) {
                        Picker("", selection: $model.proxy.mode) {
                            Text(l10n.text("off")).tag(YCodeProxyMode.off)
                            Text(l10n.text("followSystem")).tag(YCodeProxyMode.system)
                            Text(l10n.text("manual")).tag(YCodeProxyMode.manual)
                        }
                        .labelsHidden()
                        .fixedSize()
                    }
                    if model.proxy.mode == .system {
                        YCodeFormValueRow(
                            label: l10n.text("currentDetection"),
                            value: proxySummary(model.systemProxy, l10n: l10n),
                            mono: true
                        )
                    }
                    if model.proxy.mode == .manual {
                        YCodeFormRow(label: l10n.text("proxyAddress")) {
                            TextField("", text: $model.proxy.url, prompt: Text("127.0.0.1:7897"))
                                .labelsHidden()
                                .textFieldStyle(.roundedBorder)
                                .font(.system(.body, design: .monospaced))
                        }
                        YCodeFormRow(label: l10n.text("exceptions")) {
                            TextField("", text: $model.proxy.noProxy, prompt: Text("localhost,127.0.0.1,*.local"))
                                .labelsHidden()
                                .textFieldStyle(.roundedBorder)
                                .font(.system(.body, design: .monospaced))
                        }
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
        case .appearance:
            Form {
                // 下面三项都只是「选一个值」，切换后页面其余部分不变，
                // 所以用弹出菜单而不是分段控件 —— 这也是 macOS 系统设置的做法。
                // 三个分段控件叠在一起时，三块实心强调色会把整页的重心全抢走。
                Section(l10n.text("theme")) {
                    YCodeFormRow(label: l10n.text("theme")) {
                        Picker("", selection: $model.appearance.theme) {
                            Text(l10n.text("followSystem")).tag(YCodeThemeCatalog.systemID)
                            Text(l10n.text("lightAppearance")).tag(YCodeThemeCatalog.light.id)
                            Text(l10n.text("darkAppearance")).tag(YCodeThemeCatalog.dark.id)
                        }
                        .labelsHidden()
                        .fixedSize()
                    }
                    Text(l10n.text("themeHelp"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Section(l10n.text("language")) {
                    YCodeFormRow(label: l10n.text("interfaceLanguage")) {
                        Picker("", selection: $model.appearance.locale) {
                            Text("中文").tag(YCodeLocale.zh)
                            Text("English").tag(YCodeLocale.en)
                        }
                        .labelsHidden()
                        .fixedSize()
                    }
                    Text(l10n.text("languageHelp"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Section(l10n.text("uiScale")) {
                    // 三档按系统字阶整体缩放，不再整棵视图树覆盖一个绝对字号（设计稿问题 07）。
                    YCodeFormRow(label: l10n.text("uiScale")) {
                        Picker("", selection: uiScaleBinding) {
                            Text(l10n.text("uiScaleCompact")).tag(13)
                            Text(l10n.text("uiScaleStandard")).tag(14)
                            Text(l10n.text("uiScaleLoose")).tag(16)
                        }
                        .labelsHidden()
                        .fixedSize()
                    }
                    Text(l10n.text("uiScaleHint"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Section(l10n.text("fontSize")) {
                    // 之前是 Stepper 包着整行：标签和数字被撑到行两端，中间空一大段，
                    // 数字还顶在加减箭头左边几十个点的地方，看不出它俩是一回事。
                    // 现在和这一页其余的行一样走 YCodeFormRow —— 标签一列，控件一列，
                    // Stepper 自己收到内容宽度（.fixedSize），数字就贴在箭头旁边。
                    // 只显示数字：单位在分组脚注里说一次就够，不必每行重复。
                    fontRow(l10n.text("editor"), keyPath: \.editor)
                    fontRow(l10n.text("terminal"), keyPath: \.terminal)
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
                    keyboardRow(l10n.text("newSession"), "⌘N")
                    keyboardRow(l10n.text("commandPalette"), "⌘K")
                    keyboardRow(l10n.text("save"), "⌘S")
                    keyboardRow(l10n.text("findTerminal"), "⌘F")
                    keyboardRow(l10n.text("showHideProjectSidebar"), "⌘B")
                    keyboardRow(l10n.text("hideInspector"), "⌥⌘→")
                    keyboardRow(l10n.text("inspectorTabFormat", "1–4"), "⌘1–⌘4")
                    keyboardRow(l10n.text("focusCanvasFormat", 1) + "–4", "⇧⌘1–⇧⌘4")
                    keyboardRow(l10n.text("refreshHistory"), "⇧⌘R")
                }
                Section {
                    Text(l10n.text("shortcutsReadOnly"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .formStyle(.grouped)
        case .about:
            Form {
                Section {
                    VStack(spacing: 12) {
                        // 画 app 自己的图标，不是一个 SF Symbol 的纸箱：
                        // 「关于」页要回答「我装的是哪个 app」，拿系统通用符号糊在这里，
                        // 等于这一页唯一的图形不指向任何具体的东西。
                        appIcon(size: 64)
                        Text(YCodeBuildInfo.displayName).font(.title2.weight(.semibold))
                        Text(l10n.text("versionFormat", YCodeBuildInfo.versionDescription))
                        Text(YCodeBuildInfo.bundleIdentifier)
                            .font(.system(.caption, design: .monospaced))
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity)
                }

                // 这一节曾经有「更新渠道」「自动下载更新」「查看许可证」三个控件，
                // 三个都是 .constant + .disabled(true) 的空壳，底下还各配一段解释自己
                // 为什么不能用的说明文字 —— 五个元素加起来不产生任何一个可执行的动作，
                // 却把唯一真能用的「检查更新…」压在了最底下。占位符不是功能：
                // 想不起来自己没实现什么的时候，界面不该替用户记着。做出来时再加回来。
                Section(l10n.text("updates")) {
                    Button(l10n.text("checkForUpdatesEllipsis")) {
                        updateController.checkForUpdates()
                    }
                    .disabled(!updateController.isConfigured)
                    // 唯一留下的说明：它解释的是那个按钮**此刻为什么灰着**，
                    // 而且只在真的灰着时出现 —— 这是状态反馈，不是道歉。
                    if !updateController.isConfigured {
                        Text(l10n.text("updatesReleaseOnly"))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                // 这一页现在是纯粹的「这是什么、什么版本」，不放任何会改状态的东西。
                // 原先挂在这儿的诊断四行里，「文件树宽度」是界面状态不是诊断，
                // 「最近一次错误」是弹窗之后的过期回声。
                // 「恢复默认」是个能清空全部配置的破坏性动作，和这页的用途没关系。
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

    /// 字号一行：标签 + 数字 + 光秃秃的加减箭头。等宽数字，9→10 时箭头不会横移。
    ///
    /// 数字**不能**放进 Stepper 的 label：带 label 的 Stepper 在 Form 里会把 label
    /// 撑满整行，再加 .fixedSize() 就等于把「整行宽度」变成它的理想宽度，
    /// 一路顶穿设置窗固定的 780pt —— 表现为窗口左右两边各被裁掉一截。
    /// labelsHidden 之后 Stepper 只剩箭头，fixedSize 才是真的紧凑。
    private func fontRow(_ label: String, keyPath: WritableKeyPath<YCodeFontSizes, Int>) -> some View {
        YCodeFormRow(label: label) {
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

    private func fontBinding(_ keyPath: WritableKeyPath<YCodeFontSizes, Int>) -> Binding<Int> {
        Binding(
            get: { model.appearance.fontSizes[keyPath: keyPath] },
            set: { model.appearance.fontSizes[keyPath: keyPath] = YCodeFontSizes.clamp($0) }
        )
    }

    /// 运行中这个 app 的真实图标（bundle 里的 AppIcon.icns）。
    /// 取不到时才退回 SF Symbol —— 那是兜底，不是默认。
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

    /// 快捷键行：键位靠右成一列，等宽字，眼睛可以顺着扫。
    /// 这是整个设置窗里唯一**不**走 `YCodeFormRow` 的行——它是「名称 ↔ 键位」
    /// 的对照表，两端对齐才读得快，而不是「标签 + 控件」。
    private func keyboardRow(_ title: String, _ shortcut: String) -> some View {
        HStack {
            Text(title)
            Spacer(minLength: 16)
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

private struct AgentBadge: View {
    let profile: YCodeAgentProfile

    private var tint: Color {
        guard let raw = profile.color, let color = NSColor(hex: raw) else { return .accentColor }
        return Color(nsColor: color)
    }

    var body: some View {
        YCodeAgentIconView(profile: profile, size: 16, tint: tint)
            .frame(width: 26, height: 26)
        .background(tint.opacity(0.12), in: RoundedRectangle(cornerRadius: YCodeMetrics.cornerRadius))
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
    /// 「用户动过这个字段了吗」。新建表单一打开就把必填项标红是在先骂人一顿，
    /// 所以报错等到字段被编辑过之后才出现；按钮的禁用判据不看这个。
    var touchedID = false
    var touchedCommand = false

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
        // 编辑已有 agent 时两个必填字段本来就有值，直接算「碰过」——
        // 用户要是把它们清空，立刻就该看到原因。
        touchedID = profile != nil
        touchedCommand = profile != nil
    }
}

private struct AgentEditorView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.ycodeL10n) private var l10n
    @State var state: AgentEditorState
    /// 用于就地查重。编辑已有 agent 时要把自己排除掉，否则一打开就说「标识已被占用」。
    var existingIDs: Set<String> = []
    let onSave: (YCodeAgentProfile, String?) -> Void

    var body: some View {
        // 三段式：标题钉在顶上、表单自己滚、按钮钉在底下。
        //
        // 改之前这三样装在一个 VStack 里，外面套死 `.frame(height: 470)` ——
        // 内容超过 470 之后既不滚也不挤，直接从两头溢出：标题被切掉一半，
        // 而「取消 / 完成」整排被推到窗外。也就是说这个表单**填完了没法提交**，
        // 只能靠回车碰运气。这不是排版问题，是功能问题。
        VStack(spacing: 0) {
            // 省略号属于**打开它的那个菜单项**（表示「还要再问你」）。
            // 对话框自己就是那个「再问」，标题不该再带一次。
            Text(state.originalID == nil ? l10n.text("addCustomAgentTitle") : l10n.text("editAgent"))
                .font(.title2.bold())
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 20)
                .padding(.top, 20)
                .padding(.bottom, 12)
            // .formStyle(.grouped)：设置窗口其余每一页都是这个样式，唯独这张表单
            // 用的是默认样式，于是它看起来不像同一个应用的东西。顺带，grouped 的
            // Form 在 macOS 上自带滚动，溢出就滚而不是溢到窗外。
            Form {
                // 「完成」原先只是静默变灰：缺什么、为什么不能存，界面一个字都不说。
                // 校验信息就近长在对应字段下面 —— 提交时才报错等于让用户先失败一次。
                Section {
                    // 标识在保存后**锁死**。它不是一个显示名，而是持久化的外键：
                    // 会话表的 `agentProfile` 列存的就是这个字符串，
                    // `AgentSessionService.restartSession` 靠
                    // `agents.first { $0.id == row.agentProfile }` 找回 profile，
                    // 找不到就抛 `unknownAgent`。也就是说改掉它，所有用过这个 agent 的
                    // 历史会话当场变成无法 resume —— 而界面上不会有任何征兆，
                    // 用户下次点开那些会话才会撞上错误。
                    //
                    // 这种代价不该由一句「不建议」来兜；不可逆的破坏应该直接挡住。
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
                        YCodeFormRow(label: l10n.text("identifier"), hint: l10n.text("agentIDLocked")) {
                            // 只读但**可选中复制** —— 它要被填进命令行和配置文件，
                            // 锁住编辑不等于锁住取用。
                            Text(state.agentID)
                                .font(.system(.body, design: .monospaced))
                                .textSelection(.enabled)
                        }
                    }
                    YCodeFormRow(label: l10n.text("displayName")) {
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
                    YCodeFormRow(label: l10n.text("argumentsOnePerLine"), hint: l10n.text("argumentsHelp")) {
                        codeEditor($state.arguments, height: 72, placeholder: "--model opus\n--verbose")
                    }
                    YCodeFormRow(label: l10n.text("environmentKeyValue"), hint: l10n.text("environmentHelp")) {
                        codeEditor($state.environment, height: 92, placeholder: "ANTHROPIC_API_KEY=$MY_KEY\nHTTP_PROXY=127.0.0.1:7897")
                    }
                }
                // 图标的两个控件写的是同一个 `state.icon`。原先它们被别的字段隔开，
                // 看上去像两个独立设置 —— 上面选「无」下面却提示 ClaudeCode，
                // 谁覆盖谁完全没有线索。放进同一个 Section 并加一句脚注，
                // 靠邻近关系说明它们是一件事。
                Section(l10n.text("agentEditorAppearance")) {
                    // 「图标样式（品牌色/单色）」整行去掉了。选了一张品牌 SVG，
                    // 就按它自己的配色画 —— 那是这张图唯一正确的样子，不该再问一次。
                    // 而且这个开关的名字一直在误导：它听起来像在选颜色，
                    // 实际选的是渲染模式；颜色来自 SVG 里写死的 fill。
                    YCodeFormRow(label: l10n.text("agentIcon")) {
                        AgentIconPicker(
                            icon: $state.icon,
                            colorHex: state.color,
                            displayName: state.displayName.isEmpty ? state.agentID : state.displayName
                        )
                    }
                    YCodeFormRow(label: l10n.text("agentColor"), hint: colorHint) {
                        HStack(spacing: 8) {
                            // 占位符不再是一个和任何东西都无关的紫色 #7C3AED ——
                            // 它明明没设值，却显示得像个具体颜色。现在直接说「跟随强调色」。
                            TextField("", text: $state.color, prompt: Text(l10n.text("agentColorFollowsAccent")))
                                .labelsHidden()
                                .textFieldStyle(.roundedBorder)
                                .font(.system(.body, design: .monospaced))
                            ColorPicker("", selection: agentColor, supportsOpacity: false)
                                .labelsHidden()
                                // 未设值时打一道斜杠：ColorPicker 的色块由系统绘制，
                                // 没设颜色时它回退显示系统强调色 —— 于是「未设置」和
                                // 「显式设成同一个蓝」在界面上长得一模一样，控件在撒谎。
                                // 斜杠把这两种状态分开；点它照样能选色，选完斜杠消失。
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
                    // 「图标样式」的界面去掉了（选了 SVG 就用原色），但字段原样回写：
                    // 非原生版的 AgentIcon.tsx 也读这个字段，我们只是不再使用它，
                    // 不该在保存时静默把别人的数据抹掉。
                    profile.iconVariant = state.iconVariant.nilIfEmpty
                    profile.color = state.color.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
                    onSave(profile, state.originalID)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                // 和字段下的红字同一个判据，不会出现「没有报错但按钮还是灰的」。
                .disabled(!canSave)
            }
            .padding(20)
        }
        // 高度给一个区间而不是钉死：内容多时到 640 为止再交给表单滚动，
        // 无论如何底下那排按钮都在窗内。
        .frame(minWidth: 560, idealWidth: 560, maxWidth: 560, minHeight: 420, idealHeight: 580, maxHeight: 640)
    }

    // MARK: 就地校验

    private var trimmedID: String { state.agentID.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var trimmedCommand: String { state.command.trimmingCharacters(in: .whitespacesAndNewlines) }

    /// 标识为空，或与另一个 agent 撞号。
    ///
    /// 只在用户**动过**这个字段之后才报错：一打开新建表单就通红一片，
    /// 那不是帮忙，是先骂人一顿。空表单的沉默由「完成」灰着来表达。
    private var idError: String? {
        guard state.touchedID else { return nil }
        if trimmedID.isEmpty { return l10n.text("fieldRequired") }
        // 编辑自己那条时要把自己排除，否则打开就报「已被占用」。
        if trimmedID != state.originalID, existingIDs.contains(trimmedID) {
            return l10n.text("agentIDTaken")
        }
        return nil
    }

    private var commandError: String? {
        guard state.touchedCommand, trimmedCommand.isEmpty else { return nil }
        return l10n.text("fieldRequired")
    }

    /// 按钮的判据要**独立于 touched**：没碰过的空字段一样不能存，
    /// 只是不红而已。两者用同一组条件，界面才不会自相矛盾。
    private var canSave: Bool {
        guard !trimmedID.isEmpty, !trimmedCommand.isEmpty else { return false }
        if trimmedID != state.originalID, existingIDs.contains(trimmedID) { return false }
        return true
    }

    /// 一个必填文本框 + 它下面那行说明/报错。说明与报错占同一行位置，
    /// 所以出错时行高不变 —— 表单不会因为报错而整体往下抖一下。
    @ViewBuilder
    private func validatedField(
        _ label: String,
        text: Binding<String>,
        prompt: String,
        error: String?,
        help: String?
    ) -> some View {
        YCodeFormRow(label: label, hint: help, error: error) {
            TextField("", text: text, prompt: Text(prompt))
                .labelsHidden()
                // grouped Form 里 TextField 默认无边框 —— 空的时候就等于不存在，
                // 「显示名称」那一行看上去完全是空白，看不出哪儿能输入。
                // 而多行框是有描边的，于是同一张表里两种输入框一种看得见一种看不见。
                .textFieldStyle(.roundedBorder)
                .font(.system(.body, design: .monospaced))
                .overlay {
                    if error != nil {
                        RoundedRectangle(cornerRadius: YCodeMetrics.radiusChip)
                            .stroke(Color.ycodeErr, lineWidth: 1)
                    }
                }
        }
    }

    /// 多行输入（参数 / 环境变量）。TextEditor 默认既无边框又无底色，
    /// 在 grouped 表单里就是一片什么都没有的空地 —— 截图里那个光标是悬在虚空中的，
    /// 根本看不出哪儿是输入区、到哪儿为止。这里补上与 TextField 同款的描边和底。
    ///
    /// 占位符也是自己画的：`TextEditor` 没有 `prompt`。两个空框如果不给例子，
    /// 用户不知道该填 `--model opus` 还是 `--model=opus`。
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
                in: RoundedRectangle(cornerRadius: YCodeMetrics.radiusChip)
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
                RoundedRectangle(cornerRadius: YCodeMetrics.radiusChip)
                    .stroke(Color.secondary.opacity(0.28))
            }
    }

    /// 说明这一行当前到底在用什么颜色 —— 未设值时它跟随强调色，
    /// 而那正是「色块看起来是蓝的但其实没设」的根源，得说出来。
    private var colorHint: String {
        state.color.isEmpty ? l10n.text("agentColorUnsetHint") : l10n.text("agentColorSetHint")
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
