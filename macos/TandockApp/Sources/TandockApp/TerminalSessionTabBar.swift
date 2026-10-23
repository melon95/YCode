import SwiftUI
import TandockCore

struct TerminalSessionTabBar: View {
    nonisolated static let pickerID = "new-session-picker"

    @ObservedObject var model: WorkspaceModel
    let onRename: (SessionMetadata) -> Void
    let onArchive: (SessionMetadata) -> Void
    @Environment(\.tandockL10n) private var l10n

    private var selectedID: String? {
        model.isPresentingNewSession ? Self.pickerID : model.focusedCanvasSessionID
    }

    var body: some View {
        HStack(spacing: 6) {
            ScrollViewReader { proxy in
                ScrollView(.horizontal) {
                    HStack(spacing: 4) {
                        ForEach(Array(model.visibleSessions.enumerated()), id: \.element.id) { slot, session in
                            sessionTab(session, slot: slot)
                                .id(session.id)
                        }
                        if model.isPresentingNewSession {
                            newSessionTab.id(Self.pickerID)
                        }
                    }
                    .padding(.vertical, 4)
                }
                .scrollIndicators(.hidden)
                .onChange(of: selectedID, initial: true) { _, id in
                    if let id { proxy.scrollTo(id, anchor: .center) }
                }
            }
            Button { model.isPresentingNewSession = true } label: {
                Image(systemName: "plus").font(.system(size: 12, weight: .medium))
                    .frame(width: 28, height: 28)
            }
            .buttonStyle(.plain)
            .help(l10n.text("newSessionEllipsis"))
            .accessibilityLabel(l10n.text("newSessionEllipsis"))
        }
        .padding(.horizontal, 8)
        .frame(height: 40)
        .background(Color.tandockChrome)
    }

    private func sessionTab(_ session: SessionMetadata, slot: Int) -> some View {
        let selected = selectedID == session.id
        return HStack(spacing: 6) {
            Button {
                model.isPresentingNewSession = false
                model.focusCanvasSlot(slot)
            } label: {
                HStack(spacing: 6) {
                    TandockStatusDot(presence: model.presence(for: session))
                    TandockAgentIconView(profile: model.agentProfiles.first { $0.id == session.agentProfile }, size: 13)
                    Text(model.displayName(for: session))
                        .font(.caption.weight(selected ? .semibold : .medium))
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help([model.project(id: session.projectID)?.name, model.displayName(for: session)].compactMap { $0 }.joined(separator: " · "))
            .accessibilityAddTraits(selected ? .isSelected : [])

            SessionActionsMenu(model: model, session: session,
                               onRename: { onRename(session) }, onArchive: { onArchive(session) })
            Button {
                if model.runtimeStatus(for: session)?.isLive == true { model.stopSession(session.id) }
                model.closeCanvasSlot(slot)
            } label: {
                Image(systemName: "xmark").font(.system(size: 9, weight: .semibold))
                    .frame(width: 18, height: 22)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help(l10n.text("closeAndStopAgent"))
            .accessibilityLabel(l10n.text("closeAndStopAgent") + " · " + model.displayName(for: session))
        }
        .padding(.horizontal, 9)
        .frame(width: 210, height: 32)
        .foregroundStyle(selected ? Color.primary : Color.secondary)
        .background(selected ? Color.tandockCard : Color.tandockRowLitBase.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
        .contextMenu {
            SessionActionItems(model: model, session: session,
                               onRename: { onRename(session) }, onArchive: { onArchive(session) })
        }
        .overlay(alignment: .bottom) {
            if selected { Capsule().fill(Color.accentColor).frame(height: 2).padding(.horizontal, 8) }
        }
    }

    private var newSessionTab: some View {
        HStack(spacing: 8) {
            Text(l10n.text("newSessionFallback")).font(.caption.weight(.semibold))
            Spacer(minLength: 4)
            Button { model.isPresentingNewSession = false } label: {
                Image(systemName: "xmark").font(.system(size: 9, weight: .semibold))
                    .frame(width: 18, height: 22)
            }
            .buttonStyle(.plain)
            .help(l10n.text("cancel"))
            .accessibilityLabel(l10n.text("cancel"))
        }
        .padding(.horizontal, 10)
        .frame(width: 170, height: 32)
        .background(Color.tandockCard, in: RoundedRectangle(cornerRadius: 8))
        .overlay(alignment: .bottom) {
            Capsule().fill(Color.accentColor).frame(height: 2).padding(.horizontal, 8)
        }
    }
}
