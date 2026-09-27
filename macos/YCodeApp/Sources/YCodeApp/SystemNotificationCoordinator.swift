import AppKit
import Combine
import Foundation
import UserNotifications
import YCodeCore

enum YCodeSystemNotificationError: LocalizedError {
    case permissionDenied
    case deliveryNotObserved

    var errorDescription: String? {
        switch self {
        case .permissionDenied: YCodeLocalization(locale: YCodeSystemNotificationCoordinator.currentLocale()).text("notificationPermissionDenied")
        case .deliveryNotObserved: YCodeLocalization(locale: YCodeSystemNotificationCoordinator.currentLocale()).text("notificationDeliveryNotObserved")
        }
    }
}

@MainActor
final class YCodeSystemNotificationCoordinator: NSObject, UNUserNotificationCenterDelegate {
    static let shared = YCodeSystemNotificationCoordinator()

    private let center = UNUserNotificationCenter.current()
    private var eventObserver: AnyCancellable?
    private var started = false

    func start() {
        guard !started else { return }
        started = true
        center.delegate = self
        _ = try? YCodeAgentHookListener.shared.start()
        eventObserver = NotificationCenter.default.publisher(for: .ycodeAgentHookEvent)
            .compactMap { $0.object as? YCodeAgentHookEvent }
            .sink { [weak self] event in self?.handle(event) }
    }

    func sendTest() async throws {
        try await authorizeIfNeeded()
        let identifier = "ycode-test-\(UUID().uuidString)"
        try await deliver(
            title: "YCode",
            body: YCodeLocalization(locale: Self.currentLocale()).text("testNotificationDelivered"),
            identifier: identifier
        )
        for _ in 0..<20 {
            if await hasDeliveredNotification(identifier: identifier) {
                return
            }
            try await Task.sleep(for: .milliseconds(50))
        }
        throw YCodeSystemNotificationError.deliveryNotObserved
    }

    func permissionSummary() async -> String {
        let settings = await notificationSettingsSnapshot()
        let l10n = YCodeLocalization(locale: Self.currentLocale())
        return switch settings.authorizationStatus {
        case .authorized:
            settings.alertsEnabled ? l10n.text("permissionAllowed") : l10n.text("permissionAllowedBannersOff")
        case .provisional: l10n.text("permissionProvisional")
        case .ephemeral: l10n.text("permissionEphemeral")
        case .denied: l10n.text("permissionDenied")
        case .notDetermined: l10n.text("permissionNotDetermined")
        @unknown default: l10n.text("unknownError")
        }
    }

    nonisolated static func currentLocale() -> YCodeLocale {
        let store = YCodeConfigurationStore(
            configurationURL: YCodeDataRootResolver.resolve().appendingPathComponent("config.json")
        )
        return (try? store.loadBasicSettings().appearance.locale) ?? .zh
    }

    private func handle(_ event: YCodeAgentHookEvent) {
        let store = YCodeConfigurationStore(
            configurationURL: YCodeDataRootResolver.resolve().appendingPathComponent("config.json")
        )
        let settings = (try? store.loadBasicSettings().notifications) ?? YCodeNotificationSettings()
        guard YCodeNotificationPolicy.shouldDeliver(settings: settings, appIsActive: NSApp.isActive) else { return }
        Task {
            do {
                try await authorizeIfNeeded()
                try await deliver(
                    title: event.notificationTitle,
                    body: event.notificationBody,
                    identifier: "ycode-\(event.terminalID)-\(event.occurredAt.timeIntervalSince1970)"
                )
            } catch {
                // Hook delivery remains best-effort and must never interfere
                // with the Agent process that invoked the helper.
            }
        }
    }

    private func authorizeIfNeeded() async throws {
        let settings = await notificationSettingsSnapshot()
        switch settings.authorizationStatus {
        case .authorized, .provisional, .ephemeral:
            return
        case .notDetermined:
            let granted = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Bool, Error>) in
                center.requestAuthorization(options: [.alert]) { granted, error in
                    if let error { continuation.resume(throwing: error) }
                    else { continuation.resume(returning: granted) }
                }
            }
            guard granted else {
                throw YCodeSystemNotificationError.permissionDenied
            }
        case .denied:
            throw YCodeSystemNotificationError.permissionDenied
        @unknown default:
            throw YCodeSystemNotificationError.permissionDenied
        }
    }

    private struct NotificationSettingsSnapshot: Sendable {
        let authorizationStatus: UNAuthorizationStatus
        let alertsEnabled: Bool
    }

    // Older SDKs do not mark notification objects Sendable. Read them in the
    // completion handler and pass only value snapshots back to the main actor.
    private func notificationSettingsSnapshot() async -> NotificationSettingsSnapshot {
        await withCheckedContinuation { continuation in
            center.getNotificationSettings { settings in
                continuation.resume(returning: NotificationSettingsSnapshot(
                    authorizationStatus: settings.authorizationStatus,
                    alertsEnabled: settings.alertSetting == .enabled
                ))
            }
        }
    }

    private func hasDeliveredNotification(identifier: String) async -> Bool {
        await withCheckedContinuation { continuation in
            center.getDeliveredNotifications { notifications in
                continuation.resume(returning: notifications.contains { $0.request.identifier == identifier })
            }
        }
    }

    private func deliver(title: String, body: String, identifier: String) async throws {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            center.add(UNNotificationRequest(identifier: identifier, content: content, trigger: nil)) { error in
                if let error { continuation.resume(throwing: error) }
                else { continuation.resume() }
            }
        }
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner])
    }
}
