import SwiftUI
import YCodeCore

struct HistoryPanelView: View {
    @ObservedObject var model: WorkspaceModel
    @FocusState private var searchFocused: Bool
    @Environment(\.ycodeL10n) private var l10n

    var body: some View {
        VStack(spacing: 0) {
            searchBar
            Divider()
            if !model.historySearchQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                searchResults
            } else {
                sessionHistory
            }
        }
        .onChange(of: model.historySearchFocusGeneration) { _, _ in searchFocused = true }
    }

    private var searchBar: some View {
        VStack(spacing: 7) {
            HStack(spacing: 6) {
                TextField(l10n.text("searchHistoryBody"), text: Binding(
                    get: { model.historySearchQuery },
                    set: { value in model.setHistorySearchQuery(value) }
                ))
                .textFieldStyle(.roundedBorder)
                .focused($searchFocused)
                .onSubmit { model.searchHistory() }
                Button { model.searchHistory() } label: { Image(systemName: "magnifyingglass") }
                    .buttonStyle(.borderless)
                    .help(l10n.text("search"))
                Button { model.refreshHistory() } label: { Image(systemName: "arrow.clockwise") }
                    .buttonStyle(.borderless)
                    .help(l10n.text("rescan"))
            }
            HStack {
                if model.historyIsLoading { ProgressView().controlSize(.small) }
                Text(statusText).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                Spacer()
            }
        }
        .padding(8)
    }

    private var statusText: String {
        if !model.historySearchQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            if model.historyIsLoading { return l10n.text("searching") }
            return model.historySearchHits.isEmpty
                ? l10n.text("noMatchingResults")
                : l10n.text("foundResultsFormat", model.historySearchHits.count)
        }
        return model.historyStatus
    }

    @ViewBuilder
    private var searchResults: some View {
        if model.historyIsLoading && model.historySearchHits.isEmpty {
            ProgressView(l10n.text("searching")).frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if model.historySearchHits.isEmpty {
            ContentUnavailableView(l10n.text("noMatchingResults"), systemImage: "text.magnifyingglass")
        } else {
            List(model.historySearchHits) { hit in
                Button { model.openHistorySearchHit(hit) } label: {
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text(hit.session.title ?? hit.session.sessionID).font(.caption.weight(.semibold)).lineLimit(1)
                            Spacer()
                            Text(hit.session.agent.rawValue).font(.caption2).foregroundStyle(.secondary)
                        }
                        Text(hit.preview).font(.caption).lineLimit(3).foregroundStyle(.primary)
                    }
                    .padding(.vertical, 3)
                }
                .buttonStyle(.plain)
                .contextMenu {
                    Button(l10n.text("restoreThisSession")) { model.resumeHistorySession(hit.session) }
                }
            }
            .listStyle(.inset)
        }
    }

    private var sessionHistory: some View {
        VStack(spacing: 0) {
            if !model.historySessions.isEmpty {
                HStack(spacing: 8) {
                    Picker(l10n.text("session"), selection: Binding(
                        get: { model.selectedHistorySessionID },
                        set: { value in model.selectHistorySession(value) }
                    )) {
                        ForEach(model.historySessions) { session in
                            Text("\(session.agent.rawValue) · \(session.title ?? session.sessionID)")
                                .tag(Optional(session.id))
                        }
                    }
                    .labelsHidden()
                    Button(l10n.text("restore")) { model.resumeSelectedHistorySession() }
                        .help(l10n.text("restoreOriginalAgentSession"))
                        .disabled(model.selectedHistorySession == nil)
                }
                .padding(8)
                Divider()
            }
            historyEvents
        }
    }

    @ViewBuilder
    private var historyEvents: some View {
        if model.historyIsLoading && model.historyEvents.isEmpty {
            ProgressView(l10n.text("reading")).frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if model.historySessions.isEmpty {
            ContentUnavailableView(l10n.text("noHistorySessions"), systemImage: "clock.arrow.circlepath", description: Text(l10n.text("noProjectJSONL")))
        } else if model.historyEvents.isEmpty {
            ContentUnavailableView(l10n.text("noDisplayableEvents"), systemImage: "text.document")
        } else {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 8) {
                        ForEach(model.historyEvents) { event in
                            eventRow(event).id(event.sequence)
                        }
                    }
                    .padding(8)
                }
                .onChange(of: model.historyTargetSequence) { _, sequence in
                    guard let sequence else { return }
                    withAnimation { proxy.scrollTo(sequence, anchor: .center) }
                }
                .onChange(of: model.historyEvents.count) { _, _ in
                    guard let sequence = model.historyTargetSequence else { return }
                    DispatchQueue.main.async { proxy.scrollTo(sequence, anchor: .center) }
                }
            }
        }
    }

    private func eventRow(_ event: YCodeHistoryEvent) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 5) {
                Image(systemName: eventIcon(event.kind))
                Text(eventLabel(event.kind)).font(.caption2.weight(.semibold))
                Spacer()
                if event.timestampMilliseconds > 0 {
                    Text(Self.timeFormatter.string(from: Date(timeIntervalSince1970: Double(event.timestampMilliseconds) / 1_000)))
                        .font(.caption2).foregroundStyle(.secondary)
                }
            }
            Text(eventText(event.kind))
                .font(.caption)
                .textSelection(.enabled)
                .lineLimit(12)
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(eventBackground(event.kind), in: RoundedRectangle(cornerRadius: 6))
        .overlay {
            if model.historyTargetSequence == event.sequence {
                RoundedRectangle(cornerRadius: 6).stroke(Color.accentColor, lineWidth: 2)
            }
        }
    }

    private func eventLabel(_ kind: YCodeHistoryEventKind) -> String {
        switch kind {
        case let .message(role, _): role == .user ? l10n.text("user") : l10n.text("assistant")
        case .thinking: l10n.text("thinking")
        case let .toolUse(tool, _, _): l10n.text("toolCallFormat", tool)
        case let .toolResult(tool, _, _): l10n.text("toolResultFormat", tool)
        case .unknown: l10n.text("other")
        }
    }

    private func eventText(_ kind: YCodeHistoryEventKind) -> String {
        switch kind {
        case let .message(_, text), let .thinking(text): text
        case let .toolUse(_, input, _): input
        case let .toolResult(_, output, _): output
        case let .unknown(type): type
        }
    }

    private func eventIcon(_ kind: YCodeHistoryEventKind) -> String {
        switch kind {
        case let .message(role, _): role == .user ? "person" : "sparkles"
        case .thinking: "brain"
        case .toolUse: "hammer"
        case .toolResult: "checkmark.square"
        case .unknown: "questionmark.circle"
        }
    }

    private func eventBackground(_ kind: YCodeHistoryEventKind) -> Color {
        if case let .message(role, _) = kind, role == .user { return Color.accentColor.opacity(0.10) }
        return Color.secondary.opacity(0.08)
    }

    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "MM-dd HH:mm:ss"
        return formatter
    }()
}
