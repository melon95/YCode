import SwiftUI
import TandockCore

@MainActor
final class UsageSettingsModel: ObservableObject {
    @Published private(set) var usage = TandockWorkspaceUsage()
    @Published private(set) var isLoading = false
    @Published private(set) var errorMessage: String?

    private let dataRoot: URL
    private let homeDirectory: URL

    init(dataRoot: URL, homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser) {
        self.dataRoot = dataRoot
        self.homeDirectory = homeDirectory
    }

    func load() async {
        guard !isLoading else { return }
        isLoading = true
        errorMessage = nil
        do {
            let repository = try ProjectWorkspaceRepository(databaseURL: dataRoot.appendingPathComponent("ycode.db"))
            let projects = try repository.listProjects().map { project in
                let worktrees = try repository.listSessions(projectID: project.id, includeArchived: true)
                    .compactMap(\.worktreePath)
                    .map { URL(fileURLWithPath: $0, isDirectory: true) }
                return TandockUsageProject(
                    id: project.id,
                    name: project.name,
                    workspaceURLs: [project.repositoryURL] + worktrees
                )
            }
            let homeDirectory = homeDirectory
            usage = await Task.detached(priority: .userInitiated) {
                TandockUsageAnalyzer().aggregateProjects(homeDirectory: homeDirectory, projects: projects)
            }.value
        } catch {
            errorMessage = error.localizedDescription
        }
        isLoading = false
    }
}

struct UsageSettingsView: View {
    @StateObject private var model: UsageSettingsModel
    @Environment(\.tandockL10n) private var l10n

    init(dataRoot: URL) {
        _model = StateObject(wrappedValue: UsageSettingsModel(dataRoot: dataRoot))
    }

    var body: some View {
        Group {
            if model.isLoading && model.usage.sessions.isEmpty {
                ProgressView(l10n.text("readingUsage"))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let error = model.errorMessage {
                ContentUnavailableView(
                    l10n.text("cannotReadUsage"),
                    systemImage: "exclamationmark.triangle",
                    description: Text(error)
                )
            } else if model.usage.sessions.isEmpty {
                ContentUnavailableView(
                    l10n.text("noUsageRecords"),
                    systemImage: "chart.bar",
                    description: Text(l10n.text("noTokenHistory"))
                )
            } else {
                report
            }
        }
        .task { await model.load() }
    }

    private var report: some View {
        Form {
            Section {
                TandockFormValueRow(label: l10n.text("estimatedCost"), value: currency(model.usage.totalCostUSD), trailing: true)
                TandockFormValueRow(label: l10n.text("totalTokens"), value: compact(model.usage.totals.total), trailing: true)
                TandockFormValueRow(label: l10n.text("sessions"), value: "\(model.usage.sessions.count)", trailing: true)
            } header: {
                HStack {
                    Text(l10n.text("usage"))
                    Spacer()
                    if model.isLoading { ProgressView().controlSize(.mini) }
                    Button { Task { await model.load() } } label: { Image(systemName: "arrow.clockwise") }
                        .buttonStyle(TandockIconButtonStyle(width: 22, height: 22, fontSize: 12))
                        .help(l10n.text("recalculate")).accessibilityLabel(l10n.text("recalculate"))
                        .disabled(model.isLoading)
                }
            } footer: {
                Text(l10n.text("usageEstimateHelp"))
            }
            Section("Token") {
                tokenRow(l10n.text("input"), model.usage.totals.input)
                tokenRow(l10n.text("output"), model.usage.totals.output)
                tokenRow(l10n.text("cacheWrite"), model.usage.totals.cacheCreation)
                tokenRow(l10n.text("cacheRead"), model.usage.totals.cacheRead)
                if model.usage.totals.reasoning > 0 { tokenRow(l10n.text("reasoning"), model.usage.totals.reasoning) }
            }
            if !model.usage.byProject.isEmpty { projectSection }
            if !recentDays.isEmpty { daySection }
            if !model.usage.byModel.isEmpty { modelSection }
            sessionSection
        }
        .formStyle(.grouped)
    }

    private func tokenRow(_ label: String, _ value: UInt64) -> some View {
        TandockFormValueRow(label: label, value: compact(value), trailing: true)
    }

    private var projectSection: some View {
        usageSection(l10n.text("byProject")) {
            ForEach(model.usage.byProject) { project in
                usageRow(
                    title: project.name,
                    subtitle: l10n.text("sessionCountFormat", project.sessionCount, compact(project.tokens.total)),
                    value: currency(project.costUSD)
                )
            }
        }
    }

    private var recentDays: [TandockDayUsage] {
        Array(model.usage.byDay.filter { $0.date != "unknown" }.suffix(7))
    }

    private var daySection: some View {
        usageSection(l10n.text("recentUsageUTC")) {
            ForEach(recentDays) { day in
                usageRow(title: day.date, subtitle: "\(compact(day.tokens.total)) Token", value: currency(day.costUSD))
            }
        }
    }

    private var modelSection: some View {
        usageSection(l10n.text("byModel")) {
            ForEach(model.usage.byModel) { item in
                usageRow(title: item.model, subtitle: "\(compact(item.tokens.total)) Token", value: currency(item.costUSD), monospaced: true)
            }
        }
    }

    private var sessionSection: some View {
        usageSection(l10n.text("sessions")) {
            ForEach(model.usage.sessions.prefix(50)) { session in
                usageRow(
                    title: session.title ?? session.sessionID ?? session.jsonlURL.lastPathComponent,
                    subtitle: "\(session.agent.rawValue) · \(session.model ?? l10n.text("unknownModel")) · \(compact(session.tokens.total)) Token",
                    value: currency(session.costUSD)
                )
            }
        }
    }

    private func usageSection<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        Section(title) { content() }
    }

    private func usageRow(
        title: String,
        subtitle: String,
        value: String,
        monospaced: Bool = false
    ) -> some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .help(title)
                    .font(monospaced ? .system(.body, design: .monospaced) : .body)
                    .lineLimit(1)
                Text(subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer()
            Text(value).monospacedDigit()
        }
    }

    private func compact(_ value: UInt64) -> String {
        if value >= 1_000_000 { return String(format: "%.1fM", Double(value) / 1_000_000) }
        if value >= 1_000 { return String(format: "%.1fK", Double(value) / 1_000) }
        return "\(value)"
    }

    private func currency(_ value: Double) -> String { String(format: "$%.2f", value) }
}
