import Foundation
import Sparkle

@MainActor
final class TandockUpdateController: NSObject, ObservableObject, SPUUpdaterDelegate {
    static let shared = TandockUpdateController()

    @Published private(set) var isConfigured: Bool
    private let driver: TandockUpdateUserDriver?
    private var updater: SPUUpdater?
    private let retry = TandockUpdateRetryCoordinator()

    private init(bundle: Bundle = .main) {
        let feed = bundle.object(forInfoDictionaryKey: "SUFeedURL") as? String
        let publicKey = bundle.object(forInfoDictionaryKey: "SUPublicEDKey") as? String
        let configured = feed?.hasPrefix("https://") == true
            && publicKey?.isEmpty == false
            && publicKey?.contains("REQUIRED") == false
        guard configured else {
            isConfigured = false
            driver = nil
            updater = nil
            super.init()
            return
        }
        let driver = TandockUpdateUserDriver()
        self.driver = driver
        isConfigured = false
        super.init()
        let updater = SPUUpdater(hostBundle: bundle, applicationBundle: bundle, userDriver: driver, delegate: self)
        self.updater = updater
        driver.retryCheck = { [weak self] acknowledgement in
            self?.retry.request(acknowledgement: acknowledgement)
        }
        do {
            try updater.start()
        } catch {
            NSLog("Tandock updater failed to start: \(error.localizedDescription)")
            isConfigured = false
            self.updater = nil
            return
        }
        isConfigured = true
    }

    func updater(_ updater: SPUUpdater, didFinishUpdateCycleFor updateCheck: SPUUpdateCheck, error: (any Error)?) {
        retry.updateCycleDidFinish(
            canCheckForUpdates: updater.canCheckForUpdates,
            sessionInProgress: updater.sessionInProgress
        ) {
            updater.checkForUpdates()
        }
    }

    func checkForUpdates() {
        updater?.checkForUpdates()
    }
}
