import Foundation
import Sparkle

enum TandockUpdatePhase: Equatable {
    case checking
    case available(version: String, currentVersion: String, sizeText: String?, releaseNotesURL: URL?, downloaded: Bool)
    case information(version: String, infoURL: URL?)
    case unavailable(detail: String)
    case downloading(version: String, received: UInt64, expected: UInt64?)
    case extracting(progress: Double)
    case readyToInstall(version: String)
    case installing(applicationTerminated: Bool)
    case upToDate(version: String)
    case failed(kind: TandockUpdateErrorKind, detail: String)
}

enum TandockUpdateErrorKind: Equatable {
    case network
    case signature
    case permission
    case generic

    static func classify(_ error: NSError) -> TandockUpdateErrorKind {
        if error.domain == NSURLErrorDomain || underlyingDomains(of: error).contains(NSURLErrorDomain) {
            return .network
        }
        if error.domain == SUSparkleErrorDomain {
            switch error.code {
            case 3001, 3002, 2:
                return .signature
            case 4012, 4008:
                return .permission
            case 2001, 1002, 1004:
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

struct TandockUpdateHandlers {
    var cancel: (() -> Void)?
    var skip: (() -> Void)?
    var later: (() -> Void)?
    var install: (() -> Void)?
    var acknowledge: (() -> Void)?
    var retry: (() -> Void)?
    var retryQuit: (() -> Void)?
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

    func consumeHandlers() {
        handlers = TandockUpdateHandlers()
    }

    func updatePhase(_ phase: TandockUpdatePhase) {
        self.phase = phase
    }
}

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
