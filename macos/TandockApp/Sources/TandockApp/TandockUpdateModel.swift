import Foundation
import Sparkle

/// 更新窗口当前处在流程的哪一步（设计稿 docs/update-window-redesign.html §1 的 A–H）。
enum TandockUpdatePhase: Equatable {
    /// A
    case checking
    /// B；`downloaded` 为 true 表示包已经下好了（上次下载完没安装），按钮直接是「安装并重新启动」。
    case available(version: String, currentVersion: String, sizeText: String?, releaseNotesURL: URL?, downloaded: Bool)
    /// 仅提示的更新（例如暂停发布的版本），应打开发布者给出的信息页。
    case information(version: String, infoURL: URL?)
    /// 未找到兼容的更新，不代表当前版本是发布源中的最新版本。
    case unavailable(detail: String)
    /// C；`expected` 为空表示服务器没给总大小，退回不确定进度。
    case downloading(version: String, received: UInt64, expected: UInt64?)
    /// D
    case extracting(progress: Double)
    /// E
    case readyToInstall(version: String)
    /// F
    case installing(applicationTerminated: Bool)
    /// G
    case upToDate(version: String)
    /// H
    case failed(kind: TandockUpdateErrorKind, detail: String)
}

enum TandockUpdateErrorKind: Equatable {
    case network
    case signature
    case permission
    case generic

    /// 把 Sparkle 的错误归成用户能照着做的三类，其余走通用提示。
    static func classify(_ error: NSError) -> TandockUpdateErrorKind {
        if error.domain == NSURLErrorDomain || underlyingDomains(of: error).contains(NSURLErrorDomain) {
            return .network
        }
        if error.domain == SUSparkleErrorDomain {
            // 数值取自 Sparkle 的 SUErrors.h；Swift 里没有导出这些常量。
            switch error.code {
            case 3001, 3002, 2: // SUSignatureError, SUValidationError, SUInsufficientSigningError
                return .signature
            case 4012, 4008: // SUInstallationWriteNoPermissionError, SUInstallationAuthorizeLaterError
                return .permission
            case 2001, 1002, 1004: // SUDownloadError, SUAppcastError, SUResumeAppcastError
                return .network
            default:
                break
            }
        }
        if error.domain == NSCocoaErrorDomain, error.code == NSFileWriteNoPermissionError {
            return .permission
        }
        return .generic
    }

    private static func underlyingDomains(of error: NSError) -> [String] {
        var domains: [String] = []
        var current = error.userInfo[NSUnderlyingErrorKey] as? NSError
        while let next = current {
            domains.append(next.domain)
            current = next.userInfo[NSUnderlyingErrorKey] as? NSError
        }
        return domains
    }
}

/// 各个按钮点下去要做什么。由驱动按阶段设置：窗口只管画，不知道 Sparkle 的回调长什么样。
struct TandockUpdateHandlers {
    var cancel: (() -> Void)?
    var skip: (() -> Void)?
    var later: (() -> Void)?
    var install: (() -> Void)?
    var acknowledge: (() -> Void)?
    var retry: (() -> Void)?
    var retryQuit: (() -> Void)?
    /// 点标题栏的关闭按钮时的语义：取消 / 稍后 / 知道了。为空表示这一步不能中断，只是把窗口收起来。
    var close: (() -> Void)?
}

@MainActor
final class TandockUpdateModel: ObservableObject {
    @Published private(set) var phase: TandockUpdatePhase = .checking
    @Published private(set) var handlers = TandockUpdateHandlers()

    func show(_ phase: TandockUpdatePhase, handlers: TandockUpdateHandlers = TandockUpdateHandlers()) {
        self.phase = phase
        self.handlers = handlers
    }

    /// Sparkle 的回复和取消回调只能消费一次；安装推进本身可能异步完成。
    func consumeHandlers() {
        handlers = TandockUpdateHandlers()
    }

    /// 下载过程里只更新数字，不动按钮。
    func updatePhase(_ phase: TandockUpdatePhase) {
        self.phase = phase
    }
}

/// 错误确认只会启动 Sparkle 的异步清理；必须等整个周期结束后才能重新检查。
@MainActor
final class TandockUpdateRetryCoordinator {
    private(set) var isPending = false

    func request(acknowledgement: () -> Void) {
        isPending = true
        acknowledgement()
    }

    func updateCycleDidFinish(canCheckForUpdates: Bool, sessionInProgress: Bool, check: () -> Void) {
        guard isPending, canCheckForUpdates, !sessionInProgress else { return }
        isPending = false
        check()
    }
}
