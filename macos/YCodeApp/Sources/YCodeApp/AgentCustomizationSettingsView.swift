import AppKit
import SwiftUI
import YCodeCore

enum YCodeCustomizationPage { case skills, mcp }

@MainActor
final class AgentCustomizationSettingsModel: ObservableObject {
    @Published var selectedAgentID = "" { didSet { if selectedAgentID != oldValue { clearContext() } } }
    @Published var selectedProjectID = "" { didSet { if selectedProjectID != oldValue { clearContext() } } }
    @Published private(set) var projects: [ProjectRecord] = []
    @Published private(set) var snapshot: YCodeCustomizationSnapshot?
    @Published private(set) var isLoading = false
    @Published private(set) var isSaving = false
    @Published var errorMessage: String?
    private var generation = 0
    private var loadedContext: String?
    private let service: YCodeAgentCustomizationService
    let displayHome: URL
    private let databaseURL: URL

    init(dataRoot: URL = YCodeDataRootResolver.resolve(), service: YCodeAgentCustomizationService = .init(), displayHome: URL = FileManager.default.homeDirectoryForCurrentUser) {
        self.service = service
        self.displayHome = displayHome
        databaseURL = dataRoot.appendingPathComponent("ycode.db")
        if FileManager.default.fileExists(atPath: databaseURL.path) {
            do { projects = try ProjectWorkspaceRepository(databaseURL: databaseURL).listProjects() }
            catch { errorMessage = error.localizedDescription }
        }
    }

    var projectURL: URL? { projects.first { $0.id == selectedProjectID }?.repositoryURL }

    private func context(_ profile: YCodeAgentProfile) -> String {
        profile.id + ":" + profile.command + ":" + String(profile.environment.hashValue) + ":" + selectedProjectID
    }

    private func clearContext() {
        generation += 1
        loadedContext = nil
        snapshot = nil
    }

    func refresh(profile: YCodeAgentProfile?) async {
        if FileManager.default.fileExists(atPath: databaseURL.path) {
            do {
                projects = try ProjectWorkspaceRepository(databaseURL: databaseURL).listProjects()
                if !selectedProjectID.isEmpty && !projects.contains(where: { $0.id == selectedProjectID }) { selectedProjectID = "" }
            } catch { errorMessage = error.localizedDescription }
        }
        generation += 1
        let request = generation
        guard let profile, let agent = YCodeCustomizationAgent.resolve(profile) else {
            snapshot = nil
            isLoading = false
            return
        }
        isLoading = true
        let result = await service.snapshot(agent: agent, project: projectURL, environment: profile.environment)
        guard request == generation else { return }
        snapshot = result
        loadedContext = context(profile)
        isLoading = false
    }

    func setSkill(_ record: YCodeSkillRecord, enabled: Bool, profile: YCodeAgentProfile) async {
        guard !isSaving, let agent = YCodeCustomizationAgent.resolve(profile) else { return }
        guard loadedContext == context(profile) else { await refresh(profile: profile); return }
        isSaving = true
        defer { isSaving = false }
        do { try await service.setSkillEnabled(enabled, record: record, agent: agent, project: projectURL, environment: profile.environment) }
        catch { errorMessage = error.localizedDescription }
        await refresh(profile: profile)
    }

    func setMCP(_ record: YCodeMCPRecord, enabled: Bool, profile: YCodeAgentProfile) async {
        guard !isSaving, let agent = YCodeCustomizationAgent.resolve(profile) else { return }
        guard loadedContext == context(profile) else { await refresh(profile: profile); return }
        isSaving = true
        defer { isSaving = false }
        do { try await service.setMCPEnabled(enabled, record: record, agent: agent, project: projectURL, environment: profile.environment) }
        catch { errorMessage = error.localizedDescription }
        await refresh(profile: profile)
    }
}

/// A settings list, using the existing system type and accent. Resource names,
/// descriptions and sources carry the hierarchy; no decorative cards or stats.
struct AgentCustomizationSettingsView: View {
    @ObservedObject var model: AgentCustomizationSettingsModel
    let agents: [YCodeAgentProfile]
    let page: YCodeCustomizationPage
    @Environment(\.ycodeL10n) private var l10n
    @State private var query = ""

    private var profile: YCodeAgentProfile? { agents.first { $0.id == model.selectedAgentID } ?? agents.first }
    private var agent: YCodeCustomizationAgent? { profile.flatMap(YCodeCustomizationAgent.resolve) }
    private var projectSkillsUnsupported: Bool { agent == .grok && model.projectURL != nil }
    private var skills: [YCodeSkillRecord] {
        (model.snapshot?.skills ?? []).filter { matches($0.name, $0.summary, $0.directory.path) }
    }
    private var servers: [YCodeMCPRecord] {
        (model.snapshot?.servers ?? []).filter { matches($0.name, $0.endpoint, $0.source.path) }
    }

    var body: some View {
        VStack(spacing: 0) {
            controls
            if model.isLoading && model.snapshot == nil {
                Spacer()
                ProgressView().controlSize(.small)
                Spacer()
            } else if profile == nil {
                empty("noAgentsConfigured", "noAgentsHint", symbol: "cpu")
            } else if agent == nil {
                empty("customizationUnsupported", "customizationSupportedAgents", symbol: "terminal")
            } else if page == .mcp && agent?.supportsMCP == false {
                empty("customizationNoNativeMCP", "customizationPiMCPHelp", symbol: "powerplug")
            } else {
                resourceList
            }
            footer
        }
        .background(Color(nsColor: .controlBackgroundColor))
        .task(id: requestID) { await model.refresh(profile: profile) }
        .alert(l10n.text("settingsSaveFailed"), isPresented: Binding(
            get: { model.errorMessage != nil }, set: { if !$0 { model.errorMessage = nil } }
        )) { Button(l10n.text("ok")) { model.errorMessage = nil } } message: {
            Text(model.errorMessage ?? "")
        }
    }

    private var requestID: String {
        (profile?.id ?? "") + ":" + (profile?.command ?? "") + ":" + model.selectedProjectID
            + ":" + String(profile?.environment.hashValue ?? 0)
    }

    private var controls: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(l10n.text(page == .skills ? "customizationSkillsHelp" : "customizationMCPHelp"))
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 14) {
                Picker("Agent", selection: Binding(
                    get: { profile?.id ?? "" }, set: { model.selectedAgentID = $0 }
                )) {
                    ForEach(agents) { Text($0.resolvedDisplayName).tag($0.id) }
                }
                Picker(l10n.text("customizationScope"), selection: $model.selectedProjectID) {
                    Text(l10n.text("customizationGlobal")).tag("")
                    ForEach(model.projects) { Text($0.name).tag($0.id) }
                }
            }
            .disabled(model.isSaving)
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField(l10n.text(page == .skills ? "customizationSearchSkills" : "customizationSearchMCP"), text: $query)
                    .textFieldStyle(.plain)
                    .accessibilityLabel(l10n.text("search"))
                if !query.isEmpty {
                    Button { query = "" } label: { Image(systemName: "xmark.circle.fill") }
                        .buttonStyle(.plain).foregroundStyle(.secondary)
                        .accessibilityLabel(l10n.text("customizationClearSearch"))
                }
                Button { Task { await model.refresh(profile: profile) } } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.borderless)
                .help(l10n.text("customizationRefresh"))
                .disabled(model.isLoading || model.isSaving)
            }
            .padding(10)
            .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 6))
        }
        .padding(20)
    }

    private var resourceList: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                if let issues = model.snapshot?.issues, !issues.isEmpty {
                    Label(issues.joined(separator: "\n"), systemImage: "exclamationmark.triangle")
                        .font(.callout)
                        .foregroundStyle(.orange)
                        .textSelection(.enabled)
                        .padding(14)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                if page == .skills {
                    ForEach(skills) { skill in skillRow(skill) }
                } else {
                    ForEach(servers) { server in serverRow(server) }
                }
                if (page == .skills ? skills.isEmpty : servers.isEmpty) {
                    empty(query.isEmpty ? "customizationEmpty" : "customizationNoResults",
                          query.isEmpty ? "customizationEmptyHelp" : "customizationSearchHelp",
                          symbol: query.isEmpty ? (page == .skills ? "doc.text" : "powerplug") : "magnifyingglass")
                        .frame(minHeight: 160)
                }
            }
            .padding(.horizontal, 20)
        }
    }

    private func skillRow(_ skill: YCodeSkillRecord) -> some View {
        HStack(alignment: .top, spacing: 14) {
            VStack(alignment: .leading, spacing: 5) {
                Text(skill.name).font(.body.weight(.semibold)).textSelection(.enabled)
                Text(skill.summary).font(.callout).foregroundStyle(.secondary)
                    .lineLimit(2).help(skill.summary)
                sourceLabel(scope: skill.scope, url: skill.directory)
                if !skill.stateDetail.isEmpty {
                    Text(l10n.text(skill.stateDetail == "user-invocable-only" ? "customizationManualOnly" : "customizationNameOnly"))
                        .font(.caption).foregroundStyle(.secondary)
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
            .disabled(model.isSaving || model.isLoading || skill.enabled == nil || projectSkillsUnsupported)
            .help(l10n.text(projectSkillsUnsupported ? "customizationGrokProjectSkills" : "customizationNewSession"))
            .padding(.top, 1)
        }
        .padding(.vertical, 14)
    }

    private func serverRow(_ server: YCodeMCPRecord) -> some View {
        HStack(alignment: .top, spacing: 14) {
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 8) {
                    Text(server.name).font(.body.weight(.semibold)).textSelection(.enabled)
                    Text(l10n.text(server.isShadowed ? "customizationOverridden" : server.requiresApproval ? "customizationApprovalRequired" : server.isDisabledByGlobalConfiguration ? "customizationGloballyDisabled" : server.enabled ? "customizationEnabled" : "customizationDisabled"))
                        .font(.caption).foregroundStyle(.secondary)
                }
                Text(server.endpoint).font(.callout).foregroundStyle(.secondary).textSelection(.enabled)
                sourceLabel(scope: server.scope, url: server.source)
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
            .disabled(model.isSaving || model.isLoading || server.requiresApproval || server.isShadowed || server.isDisabledByGlobalConfiguration || (agent == .claude && model.projectURL == nil))
            .help(l10n.text(server.isDisabledByGlobalConfiguration ? "customizationGrokGlobalMCP" : agent == .claude && model.projectURL == nil ? "customizationClaudeProjectToggle" : "customizationNewSession"))
            .padding(.top, 1)
        }
        .padding(.vertical, 14)
    }

    private func sourceLabel(scope: YCodeCustomizationScope, url: URL) -> some View {
        HStack(spacing: 6) {
            Text(l10n.text(scope == .project ? "customizationProjectSource" : scope == .local ? "customizationLocalSource" : "customizationUserSource"))
            Text("·")
            Text(displayPath(url))
                .lineLimit(1).truncationMode(.middle).help(url.path)
        }
        .font(.caption).foregroundStyle(.secondary)
    }

    private func displayPath(_ url: URL) -> String {
        for (path, home) in [(url.path, model.displayHome.path),
                             (url.resolvingSymlinksInPath().path, model.displayHome.resolvingSymlinksInPath().path)] {
            if path.hasPrefix(home + "/") { return "~" + path.dropFirst(home.count) }
        }
        return url.path
    }

    private var footer: some View {
        HStack(alignment: .top, spacing: 8) {
            if model.isSaving { ProgressView().controlSize(.mini) }
            Text(l10n.text(page == .skills && projectSkillsUnsupported ? "customizationGrokProjectSkills" : page == .mcp && agent == .claude && model.projectURL == nil ? "customizationClaudeProjectToggle" : "customizationNewSession"))
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            if model.snapshot != nil {
                Text(l10n.text("customizationItemCount", page == .skills ? skills.count : servers.count))
                    .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 20).padding(.vertical, 12)
    }

    private func empty(_ title: String, _ message: String, symbol: String) -> some View {
        YCodeInspectorEmptyState(title: l10n.text(title), message: l10n.text(message), symbol: symbol)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func matches(_ values: String...) -> Bool {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return query.isEmpty || values.contains { $0.localizedCaseInsensitiveContains(query) }
    }
}
