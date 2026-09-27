import SwiftUI
import YCodeCore

/// 会话重命名对话框。
///
/// 这段原本在 `TerminalWorkspaceView` 和 `YCodeNativeApp` 里各写了一遍，
/// 两份还长得不一样 —— 而不一样的那处正好是个 bug：
///
/// ```swift
/// // TerminalWorkspaceView：改名在 guard 里
/// if let target = renameTarget {
///     model.selectSession(target.id)
///     model.renameSelectedSession(renameDraft)
/// }
///
/// // YCodeNativeApp：改名在 guard 外
/// if let target = renameTarget { model.selectSession(target.id) }
/// model.renameSelectedSession(renameDraft)   // ← target 为 nil 时，
///                                            //   改的是「当前恰好选中的那个会话」
/// ```
///
/// 重复的代码不会一起腐烂，只会各自腐烂。上一轮给「保存」加空值门槛时，
/// 同一个补丁打了两遍、模型层还兜了第三遍 —— 那是重复本身在收利息。
/// 现在只有这一份。
///
/// 草稿（`draft`）也收进来了：调用方过去要自己记得在弹出前把 `renameDraft`
/// 填成当前标题，漏填就会弹出一个空输入框，用户以为这是「输入新名字」，
/// 实际上一按保存就是清空。现在草稿由对话框自己在出现时从 target 里取。
private struct SessionRenameDialog: ViewModifier {
    @ObservedObject var model: WorkspaceModel
    @Binding var target: SessionMetadata?
    @Environment(\.ycodeL10n) private var l10n

    @State private var draft = ""

    func body(content: Content) -> some View {
        content.alert(l10n.text("renameSession"), isPresented: isPresented) {
            TextField(l10n.text("name"), text: $draft)
            Button(l10n.text("cancel"), role: .cancel) { target = nil }
            Button(l10n.text("save")) { commit() }
                // 空名字不是一个有效的重命名：会话标题会被写成空串，侧栏那一行
                // 从此回落成斜体的「新会话」，而用户以为自己只是取消了 —— 且无法撤销。
                .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
        // 每次换一个目标就重新播种草稿，而不是靠调用方在别处记得赋值。
        .onChange(of: target?.id) { _, _ in
            draft = target.map { l10n.sessionDisplayName($0) } ?? ""
        }
    }

    private var isPresented: Binding<Bool> {
        Binding(get: { target != nil }, set: { if !$0 { target = nil } })
    }

    private func commit() {
        // target 必须存在才动手。原先 YCodeNativeApp 那份把改名放在 guard 外面，
        // 于是 target 为 nil 时会去改「当前选中的会话」—— 改错对象，且没有撤销。
        guard let session = target else { return }
        model.selectSession(session.id)
        model.renameSelectedSession(draft)
        target = nil
    }
}

extension View {
    /// 挂上会话重命名对话框。把 `target` 置为某个会话即弹出；对话框自己负责
    /// 播种草稿、挡空值、改完复位。
    func ycodeSessionRenameDialog(
        model: WorkspaceModel,
        target: Binding<SessionMetadata?>
    ) -> some View {
        modifier(SessionRenameDialog(model: model, target: target))
    }
}
