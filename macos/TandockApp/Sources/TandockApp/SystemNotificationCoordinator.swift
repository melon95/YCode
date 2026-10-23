import AppKit
import Combine
import Foundation
import UserNotifications
import TandockCore

enum TandockSystemNotificationError: LocalizedError {
    case permissionDenied
    case deliveryNotObserved

    var errorDescription: String? {
        switch self {
        case .permissionDenied: TandockLocalization(locale: TandockSystemNotificationCoordinator.currentLocale()).text("notificationPermissionDenied")
        case .deliveryNotObserved: TandockLocalization(locale: TandockSystemNotificationCoordinator.currentLocale()).text("notificationDeliveryNotObserved")
        }
    }
}

@MainActor
final class TandockSystemNotificationCoordinator: NSObject, UNUserNotificationCenterDelegate {
    static let shared = TandockSystemNotificationCoordinator()

    private let center = UNUserNotificationCenter.current()
    private var eventObserver: AnyCancellable?
    private var started = false

    func start() {
        guard !started else { return }
        started = true
        center.delegate = self
        _ = try? TandockAgentHookListener.shared.start()
        eventObserver = NotificationCenter.default.publisher(for: .tandockAcceptedAttention)
            .compactMap { $0.object as? TandockAcceptedAttention }
            .sink { [weak self] event in self?.handle(event) }
    }

    func sendTest() async throws {
        try await authorizeIfNeeded()
        let identifier = "tandock-test-\(UUID().uuidString)"
        try await deliver(
            title: "Tandock",
            body: TandockLocalization(locale: Self.currentLocale()).text("testNotificationDelivered"),
            identifier: identifier
        )
        for _ in 0..<20 {
            if await hasDeliveredNotification(identifier: identifier) {
                return
            }
            try await Task.sleep(for: .milliseconds(50))
        }
        throw TandockSystemNotificationError.deliveryNotObserved
    }

    func permissionSummary() async -> String {
        let settings = await notificationSettingsSnapshot()
        let l10n = TandockLocalization(locale: Self.currentLocale())
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

    nonisolated static func currentLocale() -> TandockLocale {
        let store = TandockConfigurationStore(
            configurationURL: TandockDataRootResolver.resolve().appendingPathComponent("config.json")
        )
        return (try? store.loadBasicSettings().appearance.locale) ?? .zh
    }

    private func handle(_ accepted: TandockAcceptedAttention) {
        let store = TandockConfigurationStore(
            configurationURL: accepted.dataRoot.appendingPathComponent("config.json")
        )
        let settings = (try? store.loadBasicSettings().notifications) ?? TandockNotificationSettings()
        guard TandockNotificationPolicy.shouldDeliver(settings: settings, appIsActive: NSApp.isActive) else { return }
        let l10n = TandockLocalization(locale: (try? store.loadBasicSettings().appearance.locale) ?? .zh)
        let item = accepted.item
        Task {
            do {
                try await authorizeIfNeeded()
                let attention = TandockAttentionStore.shared(dataRoot: accepted.dataRoot)
                attention.reconcile()
                guard attention.items.contains(where: { $0.id == item.id && $0.version == item.version }) else { return }
                try await deliver(
                    content: Self.notificationContent(for: item, dataRoot: accepted.dataRoot, locale: l10n.locale),
                    identifier: "tandock-\(item.id)-\(item.version)"
                )
            } catch {
            }
        }
    }

    static func notificationContent(for item: TandockAttentionItem, dataRoot: URL, locale: TandockLocale) throws -> UNMutableNotificationContent {
        let repository = try ProjectWorkspaceRepository(databaseURL: dataRoot.appendingPathComponent("ycode.db"))
        let session = try repository.session(id: item.sessionID)
        let l10n = TandockLocalization(locale: locale)
        let titleKey = switch item.kind {
        case .approval: "attentionApproval"
        case .completion: "attentionCompletion"
        case .failure: "attentionFailure"
        case .ended: "attentionEnded"
        }
        let runtime = TandockSessionProcessPool.shared.runtime(id: session.id)
        let liveTitle = runtime?.runID == item.runID ? runtime?.title : nil
        let name = l10n.sessionDisplayName(session, liveTitle: liveTitle)
        let content = UNMutableNotificationContent()
        content.title = name
        content.body = item.summary.isEmpty ? l10n.text(titleKey) : item.summary
        return content
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
                throw TandockSystemNotificationError.permissionDenied
            }
        case .denied:
            throw TandockSystemNotificationError.permissionDenied
        @unknown default:
            throw TandockSystemNotificationError.permissionDenied
        }
    }

    private struct NotificationSettingsSnapshot: Sendable {
        let authorizationStatus: UNAuthorizationStatus
        let alertsEnabled: Bool
    }

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
        try await deliver(content: content, identifier: identifier)
    }

    private func deliver(content: UNMutableNotificationContent, identifier: String) async throws {
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
