import SwiftUI
import TandockCore

private struct SessionRenameDialog: ViewModifier {
    @ObservedObject var model: WorkspaceModel
    @Binding var target: SessionMetadata?
    @Environment(\.tandockL10n) private var l10n

    @State private var draft = ""

    func body(content: Content) -> some View {
        content.alert(l10n.text("renameSession"), isPresented: isPresented) {
            TextField(l10n.text("name"), text: $draft)
            Button(l10n.text("cancel"), role: .cancel) { target = nil }
            Button(l10n.text("save")) { commit() }
                .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
        .onChange(of: target?.id) { _, _ in
            draft = target.map { l10n.sessionDisplayName($0) } ?? ""
        }
    }

    private var isPresented: Binding<Bool> {
        Binding(get: { target != nil }, set: { if !$0 { target = nil } })
    }

    private func commit() {
        guard let session = target else { return }
        model.renameSession(id: session.id, title: draft)
        target = nil
    }
}

extension View {
    func tandockSessionRenameDialog(
        model: WorkspaceModel,
        target: Binding<SessionMetadata?>
    ) -> some View {
        modifier(SessionRenameDialog(model: model, target: target))
    }
}
