import SwiftUI
import TandockCore

struct AttentionPanelView: View {
    @ObservedObject var model: WorkspaceModel
    let header: TandockPanelHeaderSpec
    @State private var expandedItems: Set<String> = []
    @Environment(\.tandockL10n) private var l10n

    var body: some View {
        VStack(spacing: 0) {
            TandockPanelHeader(spec: header)
            Divider()
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {
                    section("attentionRequired", items: model.requiredAttentionItems)
                    section("attentionWaiting", items: model.waitingAttentionItems)
                    if model.scopedAttentionItems.isEmpty {
                        Text(l10n.text("attentionEmpty")).foregroundStyle(.secondary).padding(.vertical, 20)
                    }
                    if model.projects.contains(where: { project in
                        (model.attentionProjectID == nil || model.attentionProjectID == project.id) && model.sessions(in: project.id).contains {
                            model.runtimeStatus(for: $0)?.isLive == true && !model.attentionStore.hasHookIdentity(sessionID: $0.id)
                        }
                    }) {
                        Text(l10n.text("attentionLegacy")).font(.caption).foregroundStyle(.secondary)
                    }
                }
                .padding(12)
            }
        }
    }

    private func section(_ key: String, items: [TandockAttentionItem]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(l10n.text(key)).font(.subheadline.weight(.semibold))
                Spacer()
                Text("\(items.count)").foregroundStyle(.secondary)
            }
            ForEach(items) { item in row(item) }
        }
    }

    private func row(_ item: TandockAttentionItem) -> some View {
        let session = model.session(id: item.sessionID)
        let sessionTitle = session.map { model.displayName(for: $0) } ?? item.sessionID
        let projectName = model.project(id: item.projectID)?.name ?? ""
        let live = session.map { model.runtimeStatus(for: $0)?.isLive == true } ?? false
        let information = VStack(alignment: .leading, spacing: 7) {
            Label(item.kind == .completion ? sessionTitle : l10n.text(titleKey(item.kind)), systemImage: symbol(item.kind))
                .font(.caption.weight(.semibold)).foregroundStyle(tint(item.kind))
                .lineLimit(2)
                .help(item.kind == .completion ? sessionTitle : l10n.text(titleKey(item.kind)))
            if item.kind == .completion {
                summary(item)
            } else {
                summary(item).textSelection(.enabled)
            }
            Text(item.kind == .completion ? projectName : "\(projectName) / \(sessionTitle)")
                .font(.caption).foregroundStyle(.secondary).lineLimit(1)
            HStack {
                Text(item.firstReceivedAt, style: .time)
                if item.runID != model.attentionStore.currentRunID(sessionID: item.sessionID) {
                    Text(l10n.text("attentionPreviousRun"))
                }
            }
            .font(.caption2).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .contentShape(Rectangle())

        let card = VStack(alignment: .leading, spacing: 0) {
            information
            if item.kind != .completion {
                HStack(spacing: 8) {
                    if live {
                        Button(l10n.text("attentionGo")) { model.locateAttention(item) }
                    } else if session != nil {
                        Button(l10n.text("attentionDetails")) {
                            toggleSummary(item)
                        }
                    }
                    Spacer(minLength: 0)
                    Button(l10n.text("attentionDismiss")) {
                        model.acknowledgeAttention(item)
                    }
                }
                .controlSize(.small)
                .padding([.horizontal, .bottom], 10)
            }
            if !live, session != nil, item.kind != .completion {
                Button(l10n.text("attentionRestore")) { model.restartSession(item.sessionID) }
                    .controlSize(.small).disabled(model.isResuming(item.sessionID))
                    .padding([.horizontal, .bottom], 10)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(tint(item.kind).opacity(0.06), in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(tint(item.kind).opacity(0.18)))
        .contentShape(RoundedRectangle(cornerRadius: 8))

        return Group {
            if item.kind == .completion {
                Button {
                    if live { model.locateAttention(item) }
                    model.acknowledgeAttention(item)
                } label: { card }
                    .buttonStyle(.plain)
                    .help(l10n.text(live ? "attentionGo" : "attentionRead"))
            } else {
                card
            }
        }
    }

    private func toggleSummary(_ item: TandockAttentionItem) {
        if !expandedItems.insert(item.id).inserted { expandedItems.remove(item.id) }
    }

    private func summary(_ item: TandockAttentionItem) -> some View {
        Text(item.summary.isEmpty ? l10n.text("attentionNoSummary") : item.summary)
            .font(.callout)
            .lineLimit(expandedItems.contains(item.id) ? nil : 2)
            .help(item.summary)
    }

    private func titleKey(_ kind: TandockAttentionKind) -> String {
        switch kind {
        case .approval: "attentionApproval"
        case .completion: "attentionCompletion"
        case .failure: "attentionFailure"
        case .ended: "attentionEnded"
        }
    }
    private func symbol(_ kind: TandockAttentionKind) -> String {
        switch kind {
        case .approval: "hand.raised"
        case .completion: "envelope.badge"
        case .failure: "exclamationmark.triangle"
        case .ended: "stop.circle"
        }
    }
    private func tint(_ kind: TandockAttentionKind) -> Color {
        switch kind {
        case .approval: .tandockWarn
        case .completion: .blue
        case .failure: .red
        case .ended: .secondary
        }
    }
}
