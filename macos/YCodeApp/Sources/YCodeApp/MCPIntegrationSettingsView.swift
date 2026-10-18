import AppKit
import SwiftUI
import YCodeCore

@MainActor
final class MCPIntegrationSettingsModel: ObservableObject {
    @Published private(set) var statuses: [YCodeMCPAgent: YCodeMCPRegistrationStatus] = [:]
    @Published private(set) var busyAgents: Set<YCodeMCPAgent> = []
    @Published private(set) var hookStatuses: [YCodeMCPAgent: YCodeHookRegistrationStatus] = [:]
    @Published private(set) var hookBusyAgents: Set<YCodeMCPAgent> = []
    @Published private(set) var cliStatus: YCodeCLIInstallStatus?
    @Published private(set) var cliBusy = false
    @Published private(set) var deepLinkRegistered = false
    @Published private(set) var deepLinkIsDefault = false
    @Published var errorMessage: String?

    private let service: YCodeMCPRegistrationService
    private let hookService: YCodeHookRegistrationService
    private let cliService: YCodeCLIInstallationService

    init(
        service: YCodeMCPRegistrationService? = nil,
        hookService: YCodeHookRegistrationService? = nil,
        cliService: YCodeCLIInstallationService? = nil
    ) {
        let home = FileManager.default.homeDirectoryForCurrentUser
        if let service {
            self.service = service
        } else {
            let helper = Self.helper(named: "ycode-mcp")
            self.service = YCodeMCPRegistrationService(
                homeDirectory: home,
                helperURL: helper
            )
        }
        self.hookService = hookService ?? YCodeHookRegistrationService(
            homeDirectory: home,
            helperURL: Self.helper(named: "ycode-notify")
        )
        self.cliService = cliService ?? YCodeCLIInstallationService(helperURL: Self.helper(named: "ycode"))
        refreshDeepLinkStatus()
    }

    func refresh(_ agents: [YCodeMCPAgent]) async {
        for agent in agents {
            if !busyAgents.contains(agent) {
                do { statuses[agent] = try await service.status(for: agent) }
                catch { errorMessage = error.localizedDescription }
            }
            if !hookBusyAgents.contains(agent) {
                do { hookStatuses[agent] = try await hookService.status(for: agent) }
                catch { errorMessage = error.localizedDescription }
            }
        }
        if !cliBusy { cliStatus = await cliService.status() }
        refreshDeepLinkStatus()
    }

    func setCLIInstalled(_ installed: Bool) async {
        guard !cliBusy else { return }
        cliBusy = true
        defer { cliBusy = false }
        do {
            cliStatus = installed ? try await cliService.install() : try await cliService.uninstall()
        } catch {
            errorMessage = error.localizedDescription
            cliStatus = await cliService.status()
        }
    }

    func refreshCLIStatus() async {
        guard !cliBusy else { return }
        cliBusy = true
        defer { cliBusy = false }
        cliStatus = await cliService.status()
    }

    func setHookInstalled(_ installed: Bool, for agent: YCodeMCPAgent, chainExisting: Bool = false) async {
        guard !hookBusyAgents.contains(agent) else { return }
        hookBusyAgents.insert(agent)
        defer { hookBusyAgents.remove(agent) }
        do {
            if installed {
                hookStatuses[agent] = try await hookService.install(for: agent, chainExistingCodexNotify: chainExisting)
            } else {
                _ = try await hookService.uninstall(for: agent)
                // Removing a chained hook restores the user's notify command.
                hookStatuses[agent] = try await hookService.status(for: agent)
            }
        } catch {
            errorMessage = error.localizedDescription
            hookStatuses[agent] = try? await hookService.status(for: agent)
        }
    }

    private static func helper(named name: String) -> URL {
        let resource = Bundle.main.resourceURL?.appendingPathComponent(name)
        let adjacent = Bundle.main.executableURL?.deletingLastPathComponent().appendingPathComponent(name)
        return [resource, adjacent]
            .compactMap { $0 }
            .first { FileManager.default.isExecutableFile(atPath: $0.path) }
            ?? resource
            ?? adjacent
            ?? URL(fileURLWithPath: name)
    }

    private static func hasYCodeURLScheme() -> Bool {
        guard let types = Bundle.main.object(forInfoDictionaryKey: "CFBundleURLTypes") as? [[String: Any]] else {
            return false
        }
        return types.contains { type in
            (type["CFBundleURLSchemes"] as? [String])?.contains("ycode") == true
        }
    }

    private func refreshDeepLinkStatus() {
        deepLinkRegistered = Self.hasYCodeURLScheme()
        guard deepLinkRegistered,
              let url = URL(string: "ycode://activate"),
              let handler = NSWorkspace.shared.urlForApplication(toOpen: url) else {
            deepLinkIsDefault = false
            return
        }
        deepLinkIsDefault = handler.standardizedFileURL.resolvingSymlinksInPath()
            == Bundle.main.bundleURL.standardizedFileURL.resolvingSymlinksInPath()
    }

    func setInstalled(_ installed: Bool, for agent: YCodeMCPAgent) async {
        guard !busyAgents.contains(agent) else { return }
        busyAgents.insert(agent)
        defer { busyAgents.remove(agent) }
        do {
            statuses[agent] = installed
                ? try await service.install(for: agent)
                : try await service.uninstall(for: agent)
        } catch {
            errorMessage = error.localizedDescription
            statuses[agent] = try? await service.status(for: agent)
        }
    }
}

struct MCPIntegrationSettingsView: View {
    @ObservedObject var model: MCPIntegrationSettingsModel
    let agents: [YCodeMCPAgent]
    @Environment(\.ycodeL10n) private var l10n

    var body: some View {
        Form {
            Section {
                if agents.isEmpty {
                    Text(l10n.text("noClaudeOrCodex")).foregroundStyle(.secondary)
                }
                ForEach(agents.map { IntegrationRow(id: "hook-" + $0.id, agent: $0) }) { row in
                    let agent = row.agent
                    HStack(spacing: 10) {
                        agentLabel(agent, subtitle: agent == .claude ? "Stop / permission_prompt" : "turn_complete / PermissionRequest")
                        Spacer(minLength: 8)
                        hookControls(for: agent)
                    }
                }
            } header: {
                Text(l10n.text("agentNotificationHooks"))
            } footer: {
                Text(l10n.text("hookHelp"))
            }

            Section {
                if agents.isEmpty {
                    Text(l10n.text("noClaudeOrCodex")).foregroundStyle(.secondary)
                }
                ForEach(agents.map { IntegrationRow(id: "mcp-" + $0.id, agent: $0) }) { row in
                    let agent = row.agent
                    HStack(spacing: 10) {
                        agentLabel(agent, subtitle: l10n.text("todoMCPPermission"))
                        Spacer(minLength: 8)
                        integrationSwitch(
                            agent.displayName + " · Todo MCP",
                            isOn: model.statuses[agent] == .installed,
                            busy: model.busyAgents.contains(agent) || model.statuses[agent] == nil,
                            available: model.statuses[agent] != nil
                        ) { await model.setInstalled($0, for: agent) }
                    }
                }
                YCodeFormValueRow(label: l10n.text("transport"), value: "ycode-mcp · stdio", mono: true, trailing: true)
                YCodeFormValueRow(label: l10n.text("dataRouting"), value: l10n.text("terminalIDProjectDirectory"), trailing: true)
            } header: {
                Text("Todo MCP")
            } footer: {
                Text(l10n.text("todoMCPHelp"))
            }

            Section {
                HStack(spacing: 10) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(l10n.text("ycodeCommand"))
                        Text(l10n.text("ycodeCommandHelp")).font(.caption).foregroundStyle(.secondary)
                        if let path = cliPath {
                            Text(path).font(.system(.caption, design: .monospaced))
                                .foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                                .textSelection(.enabled).help(path)
                        }
                    }
                    Spacer(minLength: 8)
                    cliControls
                }
                YCodeFormRow(label: l10n.text("deepLink"), hint: l10n.text("deepLinkHelp"), trailing: true) {
                    Image(systemName: model.deepLinkIsDefault ? "checkmark.circle.fill" : "exclamationmark.triangle")
                        .foregroundStyle(model.deepLinkIsDefault ? Color.green : Color.ycodeWarn)
                        .help(deepLinkStatusText).accessibilityLabel(deepLinkStatusText)
                }
            } header: {
                Text(l10n.text("systemIntegration"))
            } footer: {
                Text(l10n.text("systemIntegrationHelp"))
            }
        }
        .formStyle(.grouped)
        .task(id: agents) { await model.refresh(agents) }
        .alert(l10n.text("integrationFailed"), isPresented: Binding(
            get: { model.errorMessage != nil },
            set: { if !$0 { model.errorMessage = nil } }
        )) {
            Button(l10n.text("ok")) { model.errorMessage = nil }
        } message: {
            Text(model.errorMessage ?? l10n.text("unknownError"))
        }
    }

    private func agentLabel(_ agent: YCodeMCPAgent, subtitle: String) -> some View {
        HStack(spacing: 10) {
            if let profile = YCodeAgentCatalog.defaults.first(where: { $0.introspect == agent.rawValue }) {
                AgentBadge(profile: profile)
            }
            VStack(alignment: .leading, spacing: 3) {
                Text(agent.displayName)
                Text(subtitle).font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    // Form flattens row identities across sections; the hook and MCP rows
    // must not share the same agent ID or their group surfaces get misplaced.
    private struct IntegrationRow: Identifiable {
        let id: String
        let agent: YCodeMCPAgent
    }

    private var deepLinkStatusText: String {
        if !model.deepLinkRegistered { return l10n.text("notDeclared") }
        return l10n.text(model.deepLinkIsDefault ? "defaultHandler" : "declaredOtherDefault")
    }

    private var cliPath: String? {
        switch model.cliStatus {
        case let .installed(path, _), let .stale(path, _), let .conflict(path, _): path
        default: nil
        }
    }

    @ViewBuilder
    private var cliControls: some View {
        switch model.cliStatus {
        case .installed:
            integrationSwitch(l10n.text("ycodeCommand"), isOn: true, busy: model.cliBusy) {
                await model.setCLIInstalled($0)
            }
        case .notInstalled:
            integrationSwitch(l10n.text("ycodeCommand"), isOn: false, busy: model.cliBusy) {
                await model.setCLIInstalled($0)
            }
        case .stale:
            warning(l10n.text("needsRepair"))
            iconButton("wrench", help: l10n.text("repair"), disabled: model.cliBusy) {
                await model.setCLIInstalled(true)
            }
            integrationSwitch(l10n.text("ycodeCommand"), isOn: true, busy: model.cliBusy) {
                await model.setCLIInstalled($0)
            }
        case let .conflict(_, detail):
            warning(l10n.text("pathOccupied") + " · " + detail)
            iconButton("arrow.clockwise", help: l10n.text("recheck"), disabled: model.cliBusy) {
                await model.refreshCLIStatus()
            }
            integrationSwitch(l10n.text("ycodeCommand"), isOn: false, available: false) { _ in }
        case nil:
            integrationSwitch(l10n.text("ycodeCommand"), isOn: false, busy: true, available: false) { _ in }
        }
    }

    @ViewBuilder
    private func hookControls(for agent: YCodeMCPAgent) -> some View {
        let status = model.hookStatuses[agent]
        let busy = model.hookBusyAgents.contains(agent)
        let conflict: Bool = if case .conflictUserNotify = status { true } else { false }
        if conflict {
            warning(l10n.text("existingNotify"))
            iconButton("link", help: l10n.text("chainHook"), disabled: busy) {
                await model.setHookInstalled(true, for: agent, chainExisting: true)
            }
        }
        integrationSwitch(
            agent.displayName + " · " + l10n.text("agentNotificationHooks"),
            isOn: status == .installed,
            busy: busy || status == nil,
            available: status != nil && !conflict
        ) { await model.setHookInstalled($0, for: agent) }
    }

    private func integrationSwitch(
        _ title: String, isOn: Bool, busy: Bool = false, available: Bool = true,
        action: @escaping (Bool) async -> Void
    ) -> some View {
        HStack(spacing: 10) {
            if busy { ProgressView().controlSize(.mini) }
            Toggle(title, isOn: Binding(get: { isOn }, set: { value in Task { await action(value) } }))
                .labelsHidden().toggleStyle(.switch).controlSize(.small)
                .disabled(busy || !available)
                .help(title).accessibilityLabel(title)
        }
    }

    private func warning(_ message: String) -> some View {
        Image(systemName: "exclamationmark.triangle")
            .foregroundStyle(Color.ycodeWarn).help(message).accessibilityLabel(message)
    }

    private func iconButton(_ symbol: String, help: String, disabled: Bool, action: @escaping () async -> Void) -> some View {
        Button { Task { await action() } } label: { Image(systemName: symbol) }
            .buttonStyle(YCodeIconButtonStyle(width: 22, height: 22, fontSize: 12))
            .help(help).accessibilityLabel(help).disabled(disabled)
    }
}
