import SwiftUI
import YCodeCore

struct NotificationsSettingsView: View {
    @Binding var settings: YCodeNotificationSettings
    @Environment(\.ycodeL10n) private var l10n
    @State private var testError: String?
    @State private var testResult: String?
    @State private var sendingTest = false
    @State private var permissionSummary = YCodeLocalization.zh.text("notificationLoading")

    private enum Delivery: String, CaseIterable, Identifiable {
        case always, unfocused, off
        var id: String { rawValue }
        func title(_ l10n: YCodeLocalization) -> String {
            switch self {
            case .always: l10n.text("always")
            case .unfocused: l10n.text("onlyUnfocused")
            case .off: l10n.text("off")
            }
        }
    }

    var body: some View {
        Form {
            Section {
                // 「选一个值」而不是模式开关 —— 切换它不改变这一页显示什么，
                // 所以用弹出菜单。分段控件留给真正会换内容的地方（比如代理模式）。
                YCodeFormRow(label: l10n.text("deliveryTiming")) {
                    Picker("", selection: delivery) {
                        ForEach(Delivery.allCases) { Text($0.title(l10n)).tag($0) }
                    }
                    .labelsHidden()
                    .fixedSize()
                }
                YCodeFormRow(label: l10n.text("testNotification")) {
                    Button(l10n.text("send")) {
                        sendingTest = true
                        testResult = nil
                        Task {
                            do {
                                try await YCodeSystemNotificationCoordinator.shared.sendTest()
                                testResult = l10n.text("notificationAccepted")
                            }
                            catch { testError = error.localizedDescription }
                            permissionSummary = await YCodeSystemNotificationCoordinator.shared.permissionSummary()
                            sendingTest = false
                        }
                    }
                    .disabled(!settings.enabled || sendingTest)
                }
                YCodeFormValueRow(label: l10n.text("systemPermission"), value: permissionSummary)
                if let testResult {
                    YCodeFormValueRow(label: l10n.text("recentTest"), value: testResult)
                }
            } header: {
                Text(l10n.text("systemNotifications"))
            } footer: {
                Text(l10n.text("notificationsHelp"))
            }

            Section(l10n.text("connectedEvents")) {
                YCodeFormValueRow(label: l10n.text("agentTurnComplete"), value: l10n.text("enabled"))
                YCodeFormValueRow(label: l10n.text("needsApprovalOrAttention"), value: l10n.text("enabled"))
                Text(l10n.text("notificationApprovalHelp"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .task {
            permissionSummary = await YCodeSystemNotificationCoordinator.shared.permissionSummary()
        }
        .alert(l10n.text("notificationFailed"), isPresented: Binding(
            get: { testError != nil },
            set: { if !$0 { testError = nil } }
        )) {
            Button(l10n.text("ok")) { testError = nil }
        } message: {
            Text(testError ?? l10n.text("unknownError"))
        }
    }

    private var delivery: Binding<Delivery> {
        Binding(
            get: {
                if !settings.enabled { return .off }
                return settings.onlyWhenUnfocused ? .unfocused : .always
            },
            set: { value in
                switch value {
                case .always:
                    settings = YCodeNotificationSettings(enabled: true, onlyWhenUnfocused: false)
                case .unfocused:
                    settings = YCodeNotificationSettings(enabled: true, onlyWhenUnfocused: true)
                case .off:
                    settings = YCodeNotificationSettings(
                        enabled: false,
                        onlyWhenUnfocused: settings.onlyWhenUnfocused
                    )
                }
            }
        )
    }
}
