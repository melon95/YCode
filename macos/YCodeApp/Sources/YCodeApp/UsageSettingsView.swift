import SwiftUI
import YCodeCore

@MainActor
final class UsageSettingsModel: ObservableObject {
    @Published private(set) var usage = YCodeWorkspaceUsage()
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
                return YCodeUsageProject(
                    id: project.id,
                    name: project.name,
                    workspaceURLs: [project.repositoryURL] + worktrees
                )
            }
            let homeDirectory = homeDirectory
            usage = await Task.detached(priority: .userInitiated) {
                YCodeUsageAnalyzer().aggregateProjects(homeDirectory: homeDirectory, projects: projects)
            }.value
        } catch {
            errorMessage = error.localizedDescription
        }
        isLoading = false
    }
}

struct UsageSettingsView: View {
    @StateObject private var model: UsageSettingsModel
    @Environment(\.ycodeL10n) private var l10n

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
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(l10n.text("usageEstimateHelp"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer(minLength: 8)
                    Button { Task { await model.load() } } label: { Image(systemName: "arrow.clockwise") }
                        .buttonStyle(.borderless)
                        .help(l10n.text("recalculate"))
                        .disabled(model.isLoading)
                }

                HStack(spacing: 10) {
                    summaryCard(l10n.text("estimatedCost"), value: currency(model.usage.totalCostUSD), emphasized: true)
                    summaryCard(l10n.text("totalTokens"), value: compact(model.usage.totals.total))
                    summaryCard(l10n.text("sessions"), value: "\(model.usage.sessions.count)")
                }

                tokenBreakdown
                if !model.usage.byProject.isEmpty { projectSection }
                if !recentDays.isEmpty { daySection }
                if !model.usage.byModel.isEmpty { modelSection }
                sessionSection
            }
            .padding(22)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func summaryCard(_ label: String, value: String, emphasized: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(label).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.title2.weight(.semibold)).foregroundStyle(emphasized ? Color.accentColor : .primary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(.quaternary.opacity(0.55), in: RoundedRectangle(cornerRadius: 9))
    }

    private var tokenBreakdown: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 105), spacing: 7)], alignment: .leading, spacing: 7) {
            tokenChip(l10n.text("input"), model.usage.totals.input)
            tokenChip(l10n.text("output"), model.usage.totals.output)
            tokenChip(l10n.text("cacheWrite"), model.usage.totals.cacheCreation)
            tokenChip(l10n.text("cacheRead"), model.usage.totals.cacheRead)
            if model.usage.totals.reasoning > 0 { tokenChip(l10n.text("reasoning"), model.usage.totals.reasoning) }
        }
    }

    private func tokenChip(_ label: String, _ value: UInt64) -> some View {
        Text("\(label)  \(compact(value))")
            .font(.caption)
            .padding(.horizontal, 9)
            .padding(.vertical, 5)
            .background(.quaternary.opacity(0.65), in: Capsule())
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

    private var recentDays: [YCodeDayUsage] {
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
        VStack(alignment: .leading, spacing: 7) {
            Text(title).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            VStack(spacing: 0) { content() }
                .padding(.horizontal, 10)
                .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 8))
        }
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
                    .font(monospaced ? .system(.body, design: .monospaced) : .body)
                    .lineLimit(1)
                Text(subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer()
            Text(value).monospacedDigit()
        }
        .padding(.vertical, 8)
        .overlay(alignment: .bottom) { Divider() }
    }

    private func compact(_ value: UInt64) -> String {
        if value >= 1_000_000 { return String(format: "%.1fM", Double(value) / 1_000_000) }
        if value >= 1_000 { return String(format: "%.1fK", Double(value) / 1_000) }
        return "\(value)"
    }

    private func currency(_ value: Double) -> String { String(format: "$%.2f", value) }
}
