import SwiftUI
import YCodeCore

struct AttentionInboxView: View {
    @ObservedObject var model: WorkspaceModel
    let dismiss: () -> Void
    @Environment(\.ycodeL10n) private var l10n

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(l10n.text("attentionInbox")).font(.headline)
                if model.unreadAttentionCount > 0 {
                    Text("\(model.unreadAttentionCount)")
                        .font(.caption2.bold())
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.red, in: Capsule())
                        .foregroundStyle(.white)
                }
                Spacer()
                Text("⇧⌘A").font(.system(.caption2, design: .monospaced)).foregroundStyle(.secondary)
            }
            .padding(12)
            Divider()

            if model.attentionItems.isEmpty {
                ContentUnavailableView(
                    l10n.text("nothingNeedsAttention"),
                    systemImage: "tray",
                    description: Text(l10n.text("attentionHint"))
                )
                .frame(height: 170)
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(model.attentionItems) { item in
                            Button {
                                model.focusAttentionItem(item)
                                dismiss()
                            } label: {
                                HStack(spacing: 10) {
                                    Image(systemName: item.event.needsApproval ? "exclamationmark.circle.fill" : "checkmark.circle.fill")
                                        .foregroundStyle(item.event.needsApproval ? Color.red : Color.orange)
                                    VStack(alignment: .leading, spacing: 3) {
                                        HStack {
                                            Text(item.session.title.isEmpty ? l10n.text("newSessionFallback") : item.session.title)
                                                .lineLimit(1)
                                            if model.unreadAttentionSessionIDs.contains(item.session.id) {
                                                Circle().fill(Color.red).frame(width: 6, height: 6)
                                            }
                                        }
                                        Text("\(item.project.name) · \(eventLabel(item.event)) · \(relativeTime(item.event.occurredAt))")
                                            .font(.caption2)
                                            .foregroundStyle(.secondary)
                                            .lineLimit(1)
                                        if let preview = item.event.bodyPreview {
                                            Text(preview)
                                                .font(.caption)
                                                .foregroundStyle(.secondary)
                                                .lineLimit(2)
                                        }
                                    }
                                    Spacer(minLength: 4)
                                    Image(systemName: "arrow.right").foregroundStyle(.tertiary)
                                }
                                .contentShape(Rectangle())
                                .padding(.horizontal, 12)
                                .padding(.vertical, 10)
                            }
                            .buttonStyle(.plain)
                            Divider().padding(.leading, 38)
                        }
                    }
                }
                .frame(maxHeight: 340)
            }
            Divider()
            Text(l10n.text("attentionFooter"))
                .font(.caption2)
                .foregroundStyle(.secondary)
                .padding(12)
        }
        .frame(width: 390)
    }

    private func eventLabel(_ event: YCodeAgentHookEvent) -> String {
        event.needsApproval ? l10n.text("needsHandling") : l10n.text("turnComplete")
    }

    private func relativeTime(_ date: Date) -> String {
        let seconds = max(0, Int(Date().timeIntervalSince(date)))
        if seconds < 5 { return l10n.text("justNow") }
        if seconds < 60 { return l10n.text("secondsAgoFormat", seconds) }
        if seconds < 3_600 { return l10n.text("minutesAgoFormat", seconds / 60) }
        return l10n.text("hoursAgoFormat", seconds / 3_600)
    }
}
