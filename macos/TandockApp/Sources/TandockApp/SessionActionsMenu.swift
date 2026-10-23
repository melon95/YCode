import SwiftUI
import TandockCore

struct SessionActionItems: View {
    @ObservedObject var model: WorkspaceModel
    let session: SessionMetadata
    let onRename: () -> Void
    let onArchive: () -> Void
    @Environment(\.tandockL10n) private var l10n

    var body: some View {
        Button { model.toggleSessionPin(session) } label: {
            Label(l10n.text(model.pinnedSessionIDs.contains(session.id) ? "unpinSession" : "pinSession"),
                  systemImage: model.pinnedSessionIDs.contains(session.id) ? "pin.slash" : "pin")
        }
        Button(action: onRename) { Label(l10n.text("renameEllipsis"), systemImage: "square.and.pencil") }
        Divider()
        Button(role: .destructive, action: onArchive) {
            Label(l10n.text("archiveEllipsis"), systemImage: "archivebox")
        }
    }
}

struct SessionActionsMenu: View {
    @ObservedObject var model: WorkspaceModel
    let session: SessionMetadata
    let onRename: () -> Void
    let onArchive: () -> Void
    @Environment(\.tandockL10n) private var l10n

    var body: some View {
        Menu {
            SessionActionItems(model: model, session: session, onRename: onRename, onArchive: onArchive)
        } label: {
            Image(systemName: "ellipsis").font(.system(size: 11, weight: .medium))
                .frame(width: 20, height: 22)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help(l10n.text("sessionActions"))
        .accessibilityLabel(l10n.text("sessionActions") + " · " + model.displayName(for: session))
    }
}

private struct SessionArchiveDialog: ViewModifier {
    @ObservedObject var model: WorkspaceModel
    @Binding var target: SessionMetadata?
    @Environment(\.tandockL10n) private var l10n

    func body(content: Content) -> some View {
        content.confirmationDialog(
            l10n.text("archiveTitleFormat", target.map { model.displayName(for: $0) } ?? ""),
            isPresented: Binding(get: { target != nil }, set: { if !$0 { target = nil } }),
            titleVisibility: .visible
        ) {
            Button(l10n.text("stopAndArchive"), role: .destructive) {
                guard let session = target else { return }
                target = nil
                Task { await model.archiveSession(id: session.id) }
            }
            Button(l10n.text("cancel"), role: .cancel) { target = nil }
        } message: {
            Text(l10n.text("archiveMessage"))
        }
    }
}

extension View {
    func tandockSessionArchiveDialog(model: WorkspaceModel, target: Binding<SessionMetadata?>) -> some View {
        modifier(SessionArchiveDialog(model: model, target: target))
    }
}
