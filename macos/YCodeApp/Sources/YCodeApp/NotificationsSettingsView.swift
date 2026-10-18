import SwiftUI
import YCodeCore

struct NotificationsSettingsView: View {
    @Binding var settings: YCodeNotificationSettings
    var permissionReader: @MainActor () async -> String = {
        await YCodeSystemNotificationCoordinator.shared.permissionSummary()
    }
    @Environment(\.ycodeL10n) private var l10n
    @State private var testError: String?
    @State private var testResult: String?
    @State private var sendingTest = false
    @State private var permissionSummary = YCodeLocalization.zh.text("notificationLoading")

    private enum Delivery: String, CaseIterable, Identifiable {
        case always, unfocused
        var id: String { rawValue }
        func title(_ l10n: YCodeLocalization) -> String {
            switch self {
            case .always: l10n.text("always")
            case .unfocused: l10n.text("onlyUnfocused")
            }
        }
    }

    var body: some View {
        Form {
            Section {
                Toggle(l10n.text("systemNotifications"), isOn: $settings.enabled)
                    .toggleStyle(.switch).controlSize(.small)
                YCodeFormRow(label: l10n.text("deliveryTiming"), trailing: true) {
                    Picker("", selection: delivery) {
                        ForEach(Delivery.allCases) { Text($0.title(l10n)).tag($0) }
                    }
                    .labelsHidden()
                    .fixedSize()
                    .disabled(!settings.enabled)
                }
                YCodeFormRow(label: l10n.text("testNotification"), trailing: true) {
                    if sendingTest { ProgressView().controlSize(.mini) }
                    Button {
                        sendingTest = true
                        testResult = nil
                        Task {
                            do {
                                try await YCodeSystemNotificationCoordinator.shared.sendTest()
                                testResult = l10n.text("notificationAccepted")
                            }
                            catch { testError = error.localizedDescription }
                            permissionSummary = await permissionReader()
                            sendingTest = false
                        }
                    } label: { Image(systemName: "paperplane") }
                    .buttonStyle(YCodeIconButtonStyle(width: 22, height: 22, fontSize: 12))
                    .help(l10n.text("send"))
                    .accessibilityLabel(l10n.text("testNotification"))
                    .disabled(!settings.enabled || sendingTest)
                }
                YCodeFormValueRow(label: l10n.text("systemPermission"), value: permissionSummary, trailing: true)
                if let testResult {
                    YCodeFormValueRow(label: l10n.text("recentTest"), value: testResult, trailing: true)
                }
            } header: {
                Text(l10n.text("systemNotifications"))
            } footer: {
                Text(l10n.text("notificationsHelp"))
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            Section {
                eventRow(l10n.text("agentTurnComplete"))
                eventRow(l10n.text("needsApprovalOrAttention"))
            } header: {
                Text(l10n.text("connectedEvents"))
            } footer: {
                Text(l10n.text("notificationApprovalHelp"))
            }
        }
        .formStyle(.grouped)
        .task {
            permissionSummary = await permissionReader()
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
                settings.onlyWhenUnfocused ? .unfocused : .always
            },
            set: { value in
                settings.onlyWhenUnfocused = value == .unfocused
            }
        )
    }

    private func eventRow(_ title: String) -> some View {
        YCodeFormRow(label: title, trailing: true) {
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(.secondary)
                .help(l10n.text("connectedEvents"))
                .accessibilityLabel(l10n.text("connectedEvents"))
        }
    }
}
