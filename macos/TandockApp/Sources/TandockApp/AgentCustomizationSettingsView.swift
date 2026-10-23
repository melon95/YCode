import AppKit
import SwiftUI
import TandockCore

enum TandockCustomizationPage { case skills, mcp }

@MainActor
final class AgentCustomizationSettingsModel: ObservableObject {
    @Published var selectedAgentID = "" { didSet { if selectedAgentID != oldValue { clearContext() } } }
    @Published private(set) var snapshot: TandockCustomizationSnapshot?
    @Published private(set) var isLoading = false
    @Published private(set) var isSaving = false
    @Published var errorMessage: String?
    private var generation = 0
    private var loadedContext: String?
    private let service: TandockAgentCustomizationService

    init(service: TandockAgentCustomizationService = .init()) {
        self.service = service
    }

    private func context(_ profile: TandockAgentProfile) -> String {
        profile.id + ":" + profile.command + ":" + String(profile.environment.hashValue)
    }

    private func clearContext() {
        generation += 1
        loadedContext = nil
        snapshot = nil
    }

    func refresh(profile: TandockAgentProfile?) async {
        generation += 1
        let request = generation
        guard let profile, let agent = TandockCustomizationAgent.resolve(profile) else {
            snapshot = nil
            isLoading = false
            return
        }
        isLoading = true
        let result = await service.snapshot(agent: agent, project: nil, environment: profile.environment)
        guard request == generation else { return }
        snapshot = result
        loadedContext = context(profile)
        isLoading = false
    }

    func setSkill(_ record: TandockSkillRecord, enabled: Bool, profile: TandockAgentProfile) async {
        guard !isSaving, let agent = TandockCustomizationAgent.resolve(profile) else { return }
        guard loadedContext == context(profile) else { await refresh(profile: profile); return }
        isSaving = true
        defer { isSaving = false }
        do { try await service.setSkillEnabled(enabled, record: record, agent: agent, project: nil, environment: profile.environment) }
        catch { errorMessage = error.localizedDescription }
        await refresh(profile: profile)
    }

    func setMCP(_ record: TandockMCPRecord, enabled: Bool, profile: TandockAgentProfile) async {
        guard !isSaving, let agent = TandockCustomizationAgent.resolve(profile) else { return }
        guard loadedContext == context(profile) else { await refresh(profile: profile); return }
        isSaving = true
        defer { isSaving = false }
        do { try await service.setMCPEnabled(enabled, record: record, agent: agent, project: nil, environment: profile.environment) }
        catch { errorMessage = error.localizedDescription }
        await refresh(profile: profile)
    }
}

/// Uses the same grouped form and trailing controls as the other settings pages.
struct AgentCustomizationSettingsView: View {
    @ObservedObject var model: AgentCustomizationSettingsModel
    let agents: [TandockAgentProfile]
    let page: TandockCustomizationPage
    @Environment(\.tandockL10n) private var l10n
    @State private var query = ""

    private var profile: TandockAgentProfile? { agents.first { $0.id == model.selectedAgentID } ?? agents.first }
    private var agent: TandockCustomizationAgent? { profile.flatMap(TandockCustomizationAgent.resolve) }
    private var skills: [TandockSkillRecord] {
        (model.snapshot?.skills ?? []).filter { matches($0.name, $0.summary, $0.directory.path) }
    }
    private var servers: [TandockMCPRecord] {
        (model.snapshot?.servers ?? []).filter { matches($0.name, $0.endpoint, $0.source.path) }
    }

    var body: some View {
        Form {
            configurationSection
            Section {
                if model.isLoading && model.snapshot == nil {
                    ProgressView().controlSize(.small)
                        .frame(maxWidth: .infinity, minHeight: 120)
                } else if profile == nil {
                    empty("noAgentsConfigured", "noAgentsHint", symbol: "cpu")
                } else if agent == nil {
                    empty("customizationUnsupported", "customizationSupportedAgents", symbol: "terminal")
                } else if page == .mcp && agent?.supportsMCP == false {
                    empty("customizationNoNativeMCP", "customizationPiMCPHelp", symbol: "powerplug")
                } else {
                    searchRow
                    resourceRows
                }
            } header: {
                HStack {
                    Text(l10n.text(page == .skills ? "customizationSkillList" : "customizationMCPList"))
                    Spacer()
                    if model.snapshot != nil {
                        Text(l10n.text("customizationItemCount", page == .skills ? skills.count : servers.count)
                             + " · " + l10n.text("customizationDisabledCount", disabledCount))
                            .monospacedDigit()
                    }
                }
            } footer: {
                Text(footerMessage)
            }
        }
        .formStyle(.grouped)
        .task(id: requestID) { await model.refresh(profile: profile) }
        .alert(l10n.text("settingsSaveFailed"), isPresented: Binding(
            get: { model.errorMessage != nil }, set: { if !$0 { model.errorMessage = nil } }
        )) { Button(l10n.text("ok")) { model.errorMessage = nil } } message: {
            Text(model.errorMessage ?? "")
        }
    }

    private var requestID: String {
        (profile?.id ?? "") + ":" + (profile?.command ?? "")
            + ":" + String(profile?.environment.hashValue ?? 0)
    }

    private var configurationSection: some View {
        Section {
            TandockFormRow(label: "Agent", trailing: true) {
                Picker("Agent", selection: Binding(
                    get: { profile?.id ?? "" }, set: { model.selectedAgentID = $0 }
                )) {
                    ForEach(agents) { Text($0.resolvedDisplayName).tag($0.id) }
                }
                .labelsHidden()
                .frame(maxWidth: 220, alignment: .trailing)
            }
        } footer: {
            VStack(alignment: .leading, spacing: 6) {
                Text(l10n.text(page == .skills ? "customizationSkillsHelp" : "customizationMCPHelp"))
                ForEach(configurationSources, id: \.path) { source in
                    Label(source.path, systemImage: page == .skills ? "folder" : "doc.text")
                        .font(.system(.caption, design: .monospaced))
                        .lineLimit(2)
                        .truncationMode(.middle)
                        .textSelection(.enabled)
                        .help(source.path)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .disabled(model.isSaving)
    }

    private var searchRow: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
            TextField(l10n.text(page == .skills ? "customizationSearchSkills" : "customizationSearchMCP"), text: $query)
                .textFieldStyle(.plain)
                .accessibilityLabel(l10n.text("search"))
            if !query.isEmpty {
                Button { query = "" } label: { Image(systemName: "xmark.circle.fill") }
                    .buttonStyle(TandockIconButtonStyle(width: 22, height: 22, fontSize: 12))
                    .help(l10n.text("customizationClearSearch"))
                    .accessibilityLabel(l10n.text("customizationClearSearch"))
            }
            if model.isSaving || model.isLoading {
                ProgressView().controlSize(.mini)
            } else {
                Button { Task { await model.refresh(profile: profile) } } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(TandockIconButtonStyle(width: 22, height: 22, fontSize: 12))
                .help(l10n.text("customizationRefresh"))
                .accessibilityLabel(l10n.text("customizationRefresh"))
            }
        }
        .padding(.vertical, 2)
    }

    @ViewBuilder
    private var resourceRows: some View {
        if let issues = model.snapshot?.issues, !issues.isEmpty {
            Label(issues.joined(separator: "\n"), systemImage: "exclamationmark.triangle")
                .font(.caption)
                .foregroundStyle(Color.tandockWarn)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
        if page == .skills {
            ForEach(skills) { skill in skillRow(skill) }
        } else {
            ForEach(servers) { server in serverRow(server) }
        }
        if page == .skills ? skills.isEmpty : servers.isEmpty {
            empty(query.isEmpty ? "customizationEmpty" : "customizationNoResults",
                  query.isEmpty ? "customizationEmptyHelp" : "customizationSearchHelp",
                  symbol: query.isEmpty ? (page == .skills ? "doc.text" : "powerplug") : "magnifyingglass")
        }
    }

    private func skillRow(_ skill: TandockSkillRecord) -> some View {
        HStack(spacing: 16) {
            VStack(alignment: .leading, spacing: 3) {
                Text(skill.name)
                    .font(.body.weight(.medium))
                    .lineLimit(1)
                    .help(skill.name)
                    .textSelection(.enabled)
                if !skill.summary.isEmpty {
                    Text(skill.summary)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .help(skill.summary)
                }
                sourceLabel(scope: skill.scope, url: skill.directory.appendingPathComponent("SKILL.md"))
                if !skill.stateDetail.isEmpty {
                    Text(l10n.text(skill.stateDetail == "user-invocable-only" ? "customizationManualOnly" : "customizationNameOnly"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Toggle(l10n.text("customizationEnabled"), isOn: Binding(
                get: { skill.enabled ?? false },
                set: { enabled in
                    if let profile { Task { await model.setSkill(skill, enabled: enabled, profile: profile) } }
                }
            ))
            .labelsHidden().toggleStyle(.switch).controlSize(.small)
            .accessibilityLabel(skill.name)
            .disabled(model.isSaving || model.isLoading || skill.enabled == nil)
            .help(l10n.text("customizationNewSession"))
        }
        .padding(.vertical, 4)
    }

    private func serverRow(_ server: TandockMCPRecord) -> some View {
        HStack(spacing: 16) {
            VStack(alignment: .leading, spacing: 3) {
                Text(server.name)
                    .font(.body.weight(.medium))
                    .lineLimit(1)
                    .help(server.name)
                    .textSelection(.enabled)
                Text(server.endpoint)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(server.endpoint)
                    .textSelection(.enabled)
                sourceLabel(scope: server.scope, url: server.source)
                if server.isShadowed || server.requiresApproval || server.isDisabledByGlobalConfiguration {
                    Label(l10n.text(server.isShadowed ? "customizationOverridden" : server.requiresApproval ? "customizationApprovalRequired" : "customizationGloballyDisabled"),
                          systemImage: server.requiresApproval ? "lock" : "info.circle")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Toggle(l10n.text("customizationEnabled"), isOn: Binding(
                get: { server.enabled },
                set: { enabled in
                    if let profile { Task { await model.setMCP(server, enabled: enabled, profile: profile) } }
                }
            ))
            .labelsHidden().toggleStyle(.switch).controlSize(.small)
            .accessibilityLabel(server.name)
            .disabled(model.isSaving || model.isLoading || server.requiresApproval || server.isShadowed || server.isDisabledByGlobalConfiguration || agent == .claude)
            .help(l10n.text(server.isDisabledByGlobalConfiguration ? "customizationGrokGlobalMCP" : agent == .claude ? "customizationClaudeGlobalMCPReadOnly" : "customizationNewSession"))
        }
        .padding(.vertical, 4)
    }

    private func sourceLabel(scope: TandockCustomizationScope, url: URL) -> some View {
        let key: String = switch scope {
        case .project: "customizationProjectSource"
        case .local: "customizationLocalSource"
        case .shared: "customizationSharedSource"
        case .user: "customizationGlobal"
        }
        return HStack(spacing: 5) {
            Text(l10n.text(key))
                .fixedSize()
            Text("·")
            Text(url.path)
                .lineLimit(1)
                .truncationMode(.middle)
                .help(url.path)
                .textSelection(.enabled)
        }
        .font(.system(size: 11))
        .foregroundStyle(.secondary)
    }

    private var configurationSources: [URL] {
        guard let snapshot = model.snapshot, agent != nil,
              !(page == .mcp && agent?.supportsMCP == false) else { return [] }
        // On a failed read, individual rows still expose their known sources;
        // avoid presenting a fallback directory as the active config location.
        guard snapshot.issues.isEmpty else { return [] }
        let sources = page == .skills
            ? [snapshot.skillDestination] + snapshot.skills.map(\.root)
            : [snapshot.mcpDestination] + snapshot.servers.map(\.source)
        var seen: Set<String> = []
        return sources.filter { seen.insert($0.path).inserted }
    }

    private var disabledCount: Int {
        page == .skills ? skills.filter { $0.enabled == false }.count : servers.filter { !$0.enabled }.count
    }

    private var footerMessage: String {
        l10n.text(page == .mcp && agent == .claude ? "customizationClaudeGlobalMCPReadOnly" : "customizationNewSession")
    }

    private func empty(_ title: String, _ message: String, symbol: String) -> some View {
        TandockInspectorEmptyState(title: l10n.text(title), message: l10n.text(message), symbol: symbol)
            .frame(maxWidth: .infinity, minHeight: 120)
    }

    private func matches(_ values: String...) -> Bool {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return query.isEmpty || values.contains { $0.localizedCaseInsensitiveContains(query) }
    }
}
