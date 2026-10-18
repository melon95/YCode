import Foundation
import Sparkle

@MainActor
final class YCodeUpdateController: NSObject, ObservableObject, SPUUpdaterDelegate {
    static let shared = YCodeUpdateController()

    @Published private(set) var isConfigured: Bool
    /// 自绘的更新界面。检查、下载、签名校验和安装仍由 Sparkle 完成，驱动只负责界面。
    private let driver: YCodeUpdateUserDriver?
    private var updater: SPUUpdater?
    private let retry = YCodeUpdateRetryCoordinator()

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
        let driver = YCodeUpdateUserDriver()
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
            NSLog("YCode updater failed to start: \(error.localizedDescription)")
            isConfigured = false
            self.updater = nil
            return
        }
        isConfigured = true
    }

    func updater(_ updater: SPUUpdater, didFinishUpdateCycleFor updateCheck: SPUUpdateCheck, error: (any Error)?) {
        // Sparkle 2.10.0 的 SPUUpdater.m 在通知此回调前，已将 _driver 清空、
        // sessionInProgress 设为 false、canCheckForUpdates 设为 true。
        // 在此同步开始新检查还会阻止旧周期安排下次后台检查。
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
