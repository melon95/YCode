import SwiftUI
import TandockCore

/// Session tabs that live in the canvas top bar for every layout. In split layouts a tab may be
/// off the canvas; selecting it swaps it into the focused pane.
struct TerminalSessionTabBar: View {
    nonisolated static let pickerID = "new-session-picker"
    private static let regularTabWidth: CGFloat = 190
    private static let compactTabWidth: CGFloat = 132
    private static let tabHeight: CGFloat = 30

    @ObservedObject var model: WorkspaceModel
    let onRename: (SessionMetadata) -> Void
    let onArchive: (SessionMetadata) -> Void
    @Environment(\.tandockL10n) private var l10n
    @State private var hoveredID: String?

    private var showsPickerTab: Bool {
        model.isPresentingNewSession && model.presentedTerminalLayout == .tabs
    }

    private var selectedID: String? {
        showsPickerTab ? Self.pickerID : model.focusedCanvasSessionID
    }

    var body: some View {
        HStack(spacing: 4) {
            ViewThatFits(in: .horizontal) {
                tabRow(width: Self.regularTabWidth)
                tabRow(width: Self.compactTabWidth)
                ScrollViewReader { proxy in
                    ScrollView(.horizontal) {
                        tabRow(width: Self.compactTabWidth)
                    }
                    .scrollIndicators(.hidden)
                    .onChange(of: selectedID, initial: true) { _, id in
                        if let id { proxy.scrollTo(id, anchor: .center) }
                    }
                }
            }
            Button { model.isPresentingNewSession = true } label: {
                Image(systemName: "plus")
            }
            .buttonStyle(TandockIconButtonStyle())
            .help(l10n.text("newSessionEllipsis"))
            .accessibilityLabel(l10n.text("newSessionEllipsis"))
        }
    }

    private func tabRow(width: CGFloat) -> some View {
        let sessions = model.canvasTabSessions
        return HStack(spacing: 2) {
            ForEach(Array(sessions.enumerated()), id: \.element.id) { index, session in
                if index > 0 { separator(between: sessions[index - 1].id, and: session.id) }
                sessionTab(session, width: width).id(session.id)
            }
            if showsPickerTab {
                if let last = sessions.last { separator(between: last.id, and: Self.pickerID) }
                newSessionTab(width: width).id(Self.pickerID)
            }
        }
        .fixedSize()
    }

    /// Hairline between two flat tabs; hidden next to a filled tab, which already has its own edge.
    private func separator(between left: String, and right: String) -> some View {
        let visible = model.visibleSessionIDs
        let filled = { (id: String) in id == selectedID || visible.contains(id) || id == hoveredID }
        return Rectangle()
            .fill(Color.primary.opacity(filled(left) || filled(right) ? 0 : 0.14))
            .frame(width: 1, height: 14)
    }

    private func sessionTab(_ session: SessionMetadata, width: CGFloat) -> some View {
        let selected = selectedID == session.id
        let onCanvas = model.visibleSessionIDs.contains(session.id)
        let hovered = hoveredID == session.id
        return HStack(spacing: 4) {
            Button { model.selectCanvasTab(session.id) } label: {
                HStack(spacing: 6) {
                    TandockAgentIconView(profile: model.agentProfiles.first { $0.id == session.agentProfile }, size: 13)
                    TandockStatusDot(presence: model.presence(for: session))
                    Text(model.displayName(for: session))
                        .font(.system(size: 12, weight: selected ? .semibold : .medium))
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help([model.project(id: session.projectID)?.name, model.displayName(for: session)].compactMap { $0 }.joined(separator: " · "))
            .accessibilityAddTraits(selected ? .isSelected : [])

            Button { model.closeSessionPane(session.id) } label: {
                Image(systemName: "xmark").font(.system(size: 9, weight: .semibold))
                    .frame(width: 16, height: 16)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .opacity(selected || hovered ? 1 : 0)
            .help(l10n.text("closeAndStopAgent"))
            .accessibilityLabel(l10n.text("closeAndStopAgent") + " · " + model.displayName(for: session))
        }
        .padding(.leading, 9)
        .padding(.trailing, 5)
        .frame(width: width, height: Self.tabHeight)
        .foregroundStyle(selected ? Color.primary : Color.secondary)
        .background { tabBackground(selected: selected, onCanvas: onCanvas, hovered: hovered) }
        .onHover { inside in
            if inside { hoveredID = session.id } else if hoveredID == session.id { hoveredID = nil }
        }
        .contextMenu {
            SessionActionItems(model: model, session: session,
                               onRename: { onRename(session) }, onArchive: { onArchive(session) })
        }
    }

    @ViewBuilder
    private func tabBackground(selected: Bool, onCanvas: Bool, hovered: Bool) -> some View {
        let shape = RoundedRectangle(cornerRadius: 8, style: .continuous)
        if selected {
            shape.fill(Color.tandockCard)
                .shadow(color: .black.opacity(0.10), radius: 1.5, y: 1)
                .overlay(shape.strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.5))
        } else if onCanvas || hovered {
            shape.fill(Color.tandockRowLitBase.opacity(onCanvas ? 0.45 : 0.3))
        }
    }

    private func newSessionTab(width: CGFloat) -> some View {
        let shape = RoundedRectangle(cornerRadius: 8, style: .continuous)
        return HStack(spacing: 6) {
            Text(l10n.text("newSessionFallback")).font(.system(size: 12, weight: .semibold))
            Spacer(minLength: 4)
            Button { model.isPresentingNewSession = false } label: {
                Image(systemName: "xmark").font(.system(size: 9, weight: .semibold))
                    .frame(width: 16, height: 16)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help(l10n.text("cancel"))
            .accessibilityLabel(l10n.text("cancel"))
        }
        .padding(.leading, 9)
        .padding(.trailing, 5)
        .frame(width: width, height: Self.tabHeight)
        .background {
            shape.fill(Color.tandockCard)
                .shadow(color: .black.opacity(0.10), radius: 1.5, y: 1)
                .overlay(shape.strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.5))
        }
    }
}
