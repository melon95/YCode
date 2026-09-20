import Foundation
import Sparkle

@MainActor
final class YCodeUpdateController: ObservableObject {
    static let shared = YCodeUpdateController()

    @Published private(set) var isConfigured: Bool
    private let controller: SPUStandardUpdaterController?

    private init(bundle: Bundle = .main) {
        let feed = bundle.object(forInfoDictionaryKey: "SUFeedURL") as? String
        let publicKey = bundle.object(forInfoDictionaryKey: "SUPublicEDKey") as? String
        let configured = feed?.hasPrefix("https://") == true
            && publicKey?.isEmpty == false
            && publicKey?.contains("REQUIRED") == false
        isConfigured = configured
        controller = configured
            ? SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: nil, userDriverDelegate: nil)
            : nil
    }

    func checkForUpdates() {
        controller?.checkForUpdates(nil)
    }
}
