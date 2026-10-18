import AppKit
import Foundation
import Sparkle

/// 自绘更新界面的 Sparkle 驱动。检查、下载、签名校验和安装仍由 Sparkle 完成，
/// 这里只接收它的回调、把状态交给 `YCodeUpdateModel`，再把用户的选择回给 Sparkle。
@MainActor
final class YCodeUpdateUserDriver: NSObject, SPUUserDriver {
    let model = YCodeUpdateModel()
    private let windowController: YCodeUpdateWindowController
    /// 出错后「重试」：由控制器接上 `SPUUpdater.checkForUpdates()`。
    var retryCheck: (@escaping () -> Void) -> Void = { $0() }

    private var expectedLength: UInt64?
    private var receivedLength: UInt64 = 0
    private var downloadingVersion = ""
    private var actionGeneration = UUID()

    override init() {
        windowController = YCodeUpdateWindowController(model: model)
        super.init()
    }

    // MARK: 权限

    /// 打包时已写入 `SUEnableAutomaticChecks`，正常不会走到这里。
    /// 万一走到，沿用自动检查、不发送系统信息。
    func show(_ request: SPUUpdatePermissionRequest, reply: @escaping (SUUpdatePermissionResponse) -> Void) {
        reply(SUUpdatePermissionResponse(automaticUpdateChecks: true, sendSystemProfile: false))
    }

    // MARK: 检查

    func showUserInitiatedUpdateCheck(cancellation: @escaping () -> Void) {
        var handlers = newHandlers()
        handlers.cancel = oneShot { [weak self] in
            cancellation()
            self?.windowController.close()
        }
        handlers.close = handlers.cancel
        model.show(.checking, handlers: handlers)
        windowController.show(activate: true)
    }

    func showUpdateFound(with appcastItem: SUAppcastItem, state: SPUUserUpdateState, reply: @escaping (SPUUserUpdateChoice) -> Void) {
        let downloaded = state.stage != .notDownloaded
        let size = appcastItem.contentLength > 0
            ? ByteCountFormatter.string(fromByteCount: Int64(appcastItem.contentLength), countStyle: .file)
            : nil
        let version = appcastItem.displayVersionString
        downloadingVersion = version
        var handlers = newHandlers()
        handlers.install = oneShot { reply(.install) }
        handlers.skip = oneShot { [weak self] in
            reply(.skip)
            self?.windowController.close()
        }
        handlers.later = oneShot { [weak self] in
            reply(.dismiss)
            self?.windowController.close()
        }
        handlers.close = handlers.later
        let phase: YCodeUpdatePhase = appcastItem.isInformationOnlyUpdate
            ? .information(version: version, infoURL: appcastItem.infoURL)
            : .available(
                version: version,
                currentVersion: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "",
                sizeText: size,
                releaseNotesURL: Self.releaseNotesURL(for: appcastItem),
                downloaded: downloaded
            )
        if appcastItem.isInformationOnlyUpdate {
            handlers.install = nil
        }
        model.show(phase, handlers: handlers)
        windowController.show(activate: state.userInitiated)
    }

    /// 窗口里不内嵌更新说明（appcast 里没有，内嵌网页也增加攻击面），这里只给一个能打开的链接。
    static func releaseNotesURL(for item: SUAppcastItem) -> URL? {
        if let url = item.fullReleaseNotesURL ?? item.releaseNotesURL { return url }
        guard let feed = Bundle.main.object(forInfoDictionaryKey: "SUFeedURL") as? String,
              let range = feed.range(of: "/releases/") else { return nil }
        return URL(string: "\(feed[..<range.lowerBound])/releases/tag/v\(item.displayVersionString)")
    }

    func showUpdateReleaseNotes(with downloadData: SPUDownloadData) {}

    func showUpdateReleaseNotesFailedToDownloadWithError(_ error: any Error) {}

    func showUpdateNotFoundWithError(_ error: any Error, acknowledgement: @escaping () -> Void) {
        let current = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""
        var handlers = newHandlers()
        handlers.acknowledge = oneShot { [weak self] in
            acknowledgement()
            self?.windowController.close()
        }
        handlers.close = handlers.acknowledge
        let reason = (error as NSError).userInfo[SPUNoUpdateFoundReasonKey] as? NSNumber
        let isLatest = reason.map {
            $0.intValue == Int(SPUNoUpdateFoundReason.onLatestVersion.rawValue)
                || $0.intValue == Int(SPUNoUpdateFoundReason.onNewerThanLatestVersion.rawValue)
        } ?? false
        model.show(isLatest ? .upToDate(version: current) : .unavailable(detail: error.localizedDescription), handlers: handlers)
        windowController.show(activate: true)
    }

    func showUpdaterError(_ error: any Error, acknowledgement: @escaping () -> Void) {
        let nsError = error as NSError
        var handlers = newHandlers()
        handlers.acknowledge = oneShot { [weak self] in
            acknowledgement()
            self?.windowController.close()
        }
        handlers.retry = oneShot { [weak self] in
            self?.windowController.close()
            self?.retryCheck(acknowledgement)
        }
        handlers.close = handlers.acknowledge
        model.show(
            .failed(kind: YCodeUpdateErrorKind.classify(nsError), detail: Self.detail(of: nsError)),
            handlers: handlers
        )
        windowController.show(activate: true)
    }

    /// 贴到 issue 里用的错误详情：域、码、描述，以及底层错误。
    static func detail(of error: NSError) -> String {
        var lines = ["\(error.domain) (\(error.code))", error.localizedDescription]
        if let reason = error.localizedFailureReason { lines.append(reason) }
        if let underlying = error.userInfo[NSUnderlyingErrorKey] as? NSError {
            lines.append("↳ \(underlying.domain) (\(underlying.code)): \(underlying.localizedDescription)")
        }
        return lines.joined(separator: "\n")
    }

    // MARK: 下载

    func showDownloadInitiated(cancellation: @escaping () -> Void) {
        expectedLength = nil
        receivedLength = 0
        var handlers = newHandlers()
        handlers.cancel = oneShot { [weak self] in
            cancellation()
            self?.windowController.close()
        }
        handlers.close = handlers.cancel
        model.show(.downloading(version: downloadingVersion, received: 0, expected: nil), handlers: handlers)
        windowController.show(activate: false)
    }

    func showDownloadDidReceiveExpectedContentLength(_ expectedContentLength: UInt64) {
        expectedLength = expectedContentLength > 0 ? expectedContentLength : nil
        publishDownloadProgress()
    }

    func showDownloadDidReceiveData(ofLength length: UInt64) {
        receivedLength += length
        publishDownloadProgress()
    }

    private func publishDownloadProgress() {
        model.updatePhase(.downloading(version: downloadingVersion, received: receivedLength, expected: expectedLength))
    }

    // MARK: 解压与安装

    func showDownloadDidStartExtractingUpdate() {
        // 解压和校验不能取消：不给按钮，关窗只是把窗口收起来，更新在后台继续。
        model.show(.extracting(progress: 0), handlers: newHandlers())
        windowController.show(activate: false)
    }

    func showExtractionReceivedProgress(_ progress: Double) {
        model.updatePhase(.extracting(progress: progress))
    }

    func showReady(toInstallAndRelaunch reply: @escaping (SPUUserUpdateChoice) -> Void) {
        var handlers = newHandlers()
        handlers.install = oneShot { reply(.install) }
        handlers.later = oneShot { [weak self] in
            reply(.dismiss)
            self?.windowController.close()
        }
        handlers.close = handlers.later
        model.show(.readyToInstall(version: downloadingVersion), handlers: handlers)
        windowController.show(activate: true)
    }

    func showInstallingUpdate(withApplicationTerminated applicationTerminated: Bool, retryTerminatingApplication: @escaping () -> Void) {
        var handlers = newHandlers()
        if !applicationTerminated {
            let generation = actionGeneration
            handlers.retryQuit = { [weak self] in
                guard self?.actionGeneration == generation else { return }
                retryTerminatingApplication()
            }
        }
        model.show(.installing(applicationTerminated: applicationTerminated), handlers: handlers)
        windowController.show(activate: false)
    }

    func showUpdateInstalledAndRelaunched(_ relaunched: Bool, acknowledgement: @escaping () -> Void) {
        // 重启之后不再弹「已更新」：新版本能正常打开就是最好的确认。
        acknowledgement()
        windowController.close()
    }

    func showUpdateInFocus() {
        windowController.show(activate: true)
    }

    func dismissUpdateInstallation() {
        actionGeneration = UUID()
        model.consumeHandlers()
        windowController.close()
    }

    private func newHandlers() -> YCodeUpdateHandlers {
        actionGeneration = UUID()
        return YCodeUpdateHandlers()
    }

    /// 清空本阶段所有动作，使「安装」后紧接着的关闭或重复按键不会再回复 Sparkle。
    private func oneShot(_ action: @escaping () -> Void) -> () -> Void {
        let generation = actionGeneration
        return { [weak self] in
            guard let self, self.actionGeneration == generation else { return }
            self.actionGeneration = UUID()
            self.model.consumeHandlers()
            action()
        }
    }
}
