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
        for agent in agents where !busyAgents.contains(agent) {
            do {
                statuses[agent] = try await service.status(for: agent)
                hookStatuses[agent] = try await hookService.status(for: agent)
            } catch {
                errorMessage = error.localizedDescription
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
        cliStatus = await cliService.status()
    }

    func setHookInstalled(_ installed: Bool, for agent: YCodeMCPAgent, chainExisting: Bool = false) async {
        guard !hookBusyAgents.contains(agent) else { return }
        hookBusyAgents.insert(agent)
        defer { hookBusyAgents.remove(agent) }
        do {
            hookStatuses[agent] = installed
                ? try await hookService.install(for: agent, chainExistingCodexNotify: chainExisting)
                : try await hookService.uninstall(for: agent)
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
                    Text(l10n.text("noClaudeOrCodex"))
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(agents) { agent in
                        LabeledContent {
                            hookControls(for: agent)
                        } label: {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(agent.displayName)
                                Text(agent == .claude ? "Stop / permission_prompt" : "turn_complete / PermissionRequest")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            } header: {
                Text(l10n.text("agentNotificationHooks"))
            } footer: {
                Text(l10n.text("hookHelp"))
            }

            Section {
                if agents.isEmpty {
                    Text(l10n.text("noClaudeOrCodex"))
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(agents) { agent in
                        LabeledContent {
                            statusControls(for: agent)
                        } label: {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(agent.displayName)
                                Text(l10n.text("todoMCPPermission"))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
                LabeledContent(l10n.text("transport"), value: "ycode-mcp · stdio")
                LabeledContent(l10n.text("dataRouting"), value: l10n.text("terminalIDProjectDirectory"))
            } header: {
                Text("Todo MCP")
            } footer: {
                Text(l10n.text("todoMCPHelp"))
            }

            Section {
                LabeledContent {
                    cliControls
                } label: {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(l10n.text("ycodeCommand"))
                        Text(l10n.text("ycodeCommandHelp"))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                LabeledContent {
                    Label(deepLinkStatusText, systemImage: model.deepLinkIsDefault ? "checkmark.circle.fill" : "exclamationmark.circle")
                        .font(.caption)
                        .foregroundStyle(model.deepLinkIsDefault ? .green : .orange)
                } label: {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(l10n.text("deepLink"))
                        Text(l10n.text("deepLinkHelp"))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
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

    private var deepLinkStatusText: String {
        if !model.deepLinkRegistered { return l10n.text("notDeclared") }
        return model.deepLinkIsDefault ? l10n.text("defaultHandler") : l10n.text("declaredOtherDefault")
    }

    @ViewBuilder
    private var cliControls: some View {
        if model.cliBusy {
            ProgressView().controlSize(.small)
        } else if let status = model.cliStatus {
            switch status {
            case let .installed(path, _):
                HStack(spacing: 10) {
                    Label(path, systemImage: "checkmark.circle.fill")
                        .font(.caption)
                        .foregroundStyle(.green)
                    Button(l10n.text("remove")) { Task { await model.setCLIInstalled(false) } }
                }
            case .notInstalled:
                HStack(spacing: 10) {
                    Text(l10n.text("notInstalled")).font(.caption).foregroundStyle(.secondary)
                    Button(l10n.text("install")) { Task { await model.setCLIInstalled(true) } }
                }
            case .stale:
                HStack(spacing: 10) {
                    Text(l10n.text("needsRepair")).font(.caption).foregroundStyle(.orange)
                    Button(l10n.text("repair")) { Task { await model.setCLIInstalled(true) } }
                }
            case .conflict:
                HStack(spacing: 10) {
                    Text(l10n.text("pathOccupied")).font(.caption).foregroundStyle(.orange)
                    Button(l10n.text("recheck")) { Task { await model.refreshCLIStatus() } }
                }
            }
        } else {
            ProgressView().controlSize(.small)
        }
    }

    @ViewBuilder
    private func hookControls(for agent: YCodeMCPAgent) -> some View {
        if model.hookBusyAgents.contains(agent) {
            ProgressView().controlSize(.small)
        } else if let status = model.hookStatuses[agent] {
            switch status {
            case .installed:
                HStack(spacing: 10) {
                    Label(l10n.text("connected"), systemImage: "checkmark.circle.fill")
                        .font(.caption)
                        .foregroundStyle(.green)
                    Button(l10n.text("remove")) { Task { await model.setHookInstalled(false, for: agent) } }
                }
            case .notInstalled:
                HStack(spacing: 10) {
                    Text(l10n.text("notConnected")).font(.caption).foregroundStyle(.secondary)
                    Button(l10n.text("install")) { Task { await model.setHookInstalled(true, for: agent) } }
                }
            case .conflictUserNotify:
                HStack(spacing: 10) {
                    Text(l10n.text("existingNotify")).font(.caption).foregroundStyle(.orange)
                    Button(l10n.text("chainHook")) {
                        Task { await model.setHookInstalled(true, for: agent, chainExisting: true) }
                    }
                }
            }
        } else {
            ProgressView().controlSize(.small)
        }
    }

    @ViewBuilder
    private func statusControls(for agent: YCodeMCPAgent) -> some View {
        if model.busyAgents.contains(agent) {
            ProgressView().controlSize(.small)
        } else if let status = model.statuses[agent] {
            let installed = status == .installed
            HStack(spacing: 10) {
                Label(installed ? l10n.text("registered") : l10n.text("notRegistered"), systemImage: installed ? "checkmark.circle.fill" : "circle")
                    .font(.caption)
                    .foregroundStyle(installed ? .green : .secondary)
                Button(installed ? l10n.text("unregister") : l10n.text("register")) {
                    Task { await model.setInstalled(!installed, for: agent) }
                }
            }
        } else {
            ProgressView().controlSize(.small)
        }
    }
}
