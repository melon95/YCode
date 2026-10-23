import AppKit
import SwiftUI
import TandockCore

@MainActor
final class MCPIntegrationSettingsModel: ObservableObject {
    @Published private(set) var statuses: [TandockMCPAgent: TandockMCPRegistrationStatus] = [:]
    @Published private(set) var busyAgents: Set<TandockMCPAgent> = []
    @Published private(set) var hookStatuses: [TandockMCPAgent: TandockHookRegistrationStatus] = [:]
    @Published private(set) var hookBusyAgents: Set<TandockMCPAgent> = []
    @Published private(set) var cliStatus: TandockCLIInstallStatus?
    @Published private(set) var cliBusy = false
    @Published private(set) var deepLinkRegistered = false
    @Published private(set) var deepLinkIsDefault = false
    @Published var errorMessage: String?

    private let service: TandockMCPRegistrationService
    private let hookService: TandockHookRegistrationService
    private let cliService: TandockCLIInstallationService

    init(
        service: TandockMCPRegistrationService? = nil,
        hookService: TandockHookRegistrationService? = nil,
        cliService: TandockCLIInstallationService? = nil
    ) {
        let home = FileManager.default.homeDirectoryForCurrentUser
        if let service {
            self.service = service
        } else {
            let helper = TandockBundledHelpers.url(named: "tandock-mcp")
            self.service = TandockMCPRegistrationService(
                homeDirectory: home,
                helperURL: helper
            )
        }
        self.hookService = hookService ?? TandockHookRegistrationService(
            homeDirectory: home,
            helperURL: TandockBundledHelpers.url(named: "tandock-notify")
        )
        self.cliService = cliService ?? TandockCLIInstallationService(helperURL: TandockBundledHelpers.url(named: "tandock"))
        refreshDeepLinkStatus()
    }

    func refresh(_ agents: [TandockMCPAgent]) async {
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

    func setHookInstalled(_ installed: Bool, for agent: TandockMCPAgent, chainExisting: Bool = false) async {
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

    private static func hasTandockURLScheme() -> Bool {
        guard let types = Bundle.main.object(forInfoDictionaryKey: "CFBundleURLTypes") as? [[String: Any]] else {
            return false
        }
        return types.contains { type in
            (type["CFBundleURLSchemes"] as? [String])?.contains("tandock") == true
        }
    }

    private func refreshDeepLinkStatus() {
        deepLinkRegistered = Self.hasTandockURLScheme()
        guard deepLinkRegistered,
              let url = URL(string: "tandock://activate"),
              let handler = NSWorkspace.shared.urlForApplication(toOpen: url) else {
            deepLinkIsDefault = false
            return
        }
        deepLinkIsDefault = handler.standardizedFileURL.resolvingSymlinksInPath()
            == Bundle.main.bundleURL.standardizedFileURL.resolvingSymlinksInPath()
    }

    func repairMCP(for agent: TandockMCPAgent) async {
        guard !busyAgents.contains(agent) else { return }
        busyAgents.insert(agent)
        defer { busyAgents.remove(agent) }
        do { try await service.repairStaleHelperPath(for: agent) } catch {
            errorMessage = error.localizedDescription
        }
        statuses[agent] = try? await service.status(for: agent)
    }

    func repairHook(for agent: TandockMCPAgent) async {
        guard !hookBusyAgents.contains(agent) else { return }
        hookBusyAgents.insert(agent)
        defer { hookBusyAgents.remove(agent) }
        do { try await hookService.repairStaleHelperPath(for: agent) } catch {
            errorMessage = error.localizedDescription
        }
        hookStatuses[agent] = try? await hookService.status(for: agent)
    }

    func setInstalled(_ installed: Bool, for agent: TandockMCPAgent) async {
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
    let agents: [TandockMCPAgent]
    @Environment(\.tandockL10n) private var l10n

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
                        if case let .stale(registered) = model.statuses[agent] {
                            staleControls(registered: registered, busy: model.busyAgents.contains(agent)) {
                                await model.repairMCP(for: agent)
                            }
                        }
                        integrationSwitch(
                            agent.displayName + " · Todo MCP",
                            isOn: model.statuses[agent].map { $0 != .notInstalled } ?? false,
                            busy: model.busyAgents.contains(agent) || model.statuses[agent] == nil,
                            available: model.statuses[agent] != nil
                        ) { await model.setInstalled($0, for: agent) }
                    }
                }
                TandockFormValueRow(label: l10n.text("transport"), value: "tandock-mcp · stdio", mono: true, trailing: true)
                TandockFormValueRow(label: l10n.text("dataRouting"), value: l10n.text("terminalIDProjectDirectory"), trailing: true)
            } header: {
                Text("Todo MCP")
            } footer: {
                Text(l10n.text("todoMCPHelp"))
            }

            Section {
                HStack(spacing: 10) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(l10n.text("tandockCommand"))
                        Text(l10n.text("tandockCommandHelp")).font(.caption).foregroundStyle(.secondary)
                        if let path = cliPath {
                            Text(path).font(.system(.caption, design: .monospaced))
                                .foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                                .textSelection(.enabled).help(path)
                        }
                    }
                    Spacer(minLength: 8)
                    cliControls
                }
                TandockFormRow(label: l10n.text("deepLink"), hint: l10n.text("deepLinkHelp"), trailing: true) {
                    Image(systemName: model.deepLinkIsDefault ? "checkmark.circle.fill" : "exclamationmark.triangle")
                        .foregroundStyle(model.deepLinkIsDefault ? Color.green : Color.tandockWarn)
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

    private func agentLabel(_ agent: TandockMCPAgent, subtitle: String) -> some View {
        HStack(spacing: 10) {
            if let profile = TandockAgentCatalog.defaults.first(where: { $0.introspect == agent.rawValue }) {
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
        let agent: TandockMCPAgent
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
            integrationSwitch(l10n.text("tandockCommand"), isOn: true, busy: model.cliBusy) {
                await model.setCLIInstalled($0)
            }
        case .notInstalled:
            integrationSwitch(l10n.text("tandockCommand"), isOn: false, busy: model.cliBusy) {
                await model.setCLIInstalled($0)
            }
        case .stale:
            warning(l10n.text("needsRepair"))
            iconButton("wrench", help: l10n.text("repair"), disabled: model.cliBusy) {
                await model.setCLIInstalled(true)
            }
            integrationSwitch(l10n.text("tandockCommand"), isOn: true, busy: model.cliBusy) {
                await model.setCLIInstalled($0)
            }
        case let .conflict(_, detail):
            warning(l10n.text("pathOccupied") + " · " + detail)
            iconButton("arrow.clockwise", help: l10n.text("recheck"), disabled: model.cliBusy) {
                await model.refreshCLIStatus()
            }
            integrationSwitch(l10n.text("tandockCommand"), isOn: false, available: false) { _ in }
        case nil:
            integrationSwitch(l10n.text("tandockCommand"), isOn: false, busy: true, available: false) { _ in }
        }
    }

    @ViewBuilder
    private func hookControls(for agent: TandockMCPAgent) -> some View {
        let status = model.hookStatuses[agent]
        let busy = model.hookBusyAgents.contains(agent)
        let conflict: Bool = if case .conflictUserNotify = status { true } else { false }
        if case let .stale(registered) = status {
            staleControls(registered: registered, busy: busy) { await model.repairHook(for: agent) }
        }
        if conflict {
            warning(l10n.text("existingNotify"))
            iconButton("link", help: l10n.text("chainHook"), disabled: busy) {
                await model.setHookInstalled(true, for: agent, chainExisting: true)
            }
        }
        integrationSwitch(
            agent.displayName + " · " + l10n.text("agentNotificationHooks"),
            isOn: status == .installed || status?.isStale == true,
            busy: busy || status == nil,
            available: status != nil && !conflict
        ) { await model.setHookInstalled($0, for: agent) }
    }

    /// Registered, but the agent still runs a helper from another location; the
    /// tooltip names that path so the user can see what repair will replace.
    @ViewBuilder
    private func staleControls(registered: String, busy: Bool, repair: @escaping () async -> Void) -> some View {
        warning(l10n.text("needsRepair") + (registered.isEmpty ? "" : " · " + registered))
        iconButton("wrench", help: l10n.text("repair"), disabled: busy, action: repair)
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
            .foregroundStyle(Color.tandockWarn).help(message).accessibilityLabel(message)
    }

    private func iconButton(_ symbol: String, help: String, disabled: Bool, action: @escaping () async -> Void) -> some View {
        Button { Task { await action() } } label: { Image(systemName: symbol) }
            .buttonStyle(TandockIconButtonStyle(width: 22, height: 22, fontSize: 12))
            .help(help).accessibilityLabel(help).disabled(disabled)
    }
}
