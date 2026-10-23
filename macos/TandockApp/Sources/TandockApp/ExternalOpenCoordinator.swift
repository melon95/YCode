import AppKit
import Foundation
import TandockCore

extension Notification.Name {
    static let tandockExternalOpenReady = Notification.Name("dev.ycode.native.external-open-ready")
    static let tandockExternalOpenFailed = Notification.Name("dev.ycode.native.external-open-failed")
}

@MainActor
final class TandockExternalOpenCoordinator {
    static let shared = TandockExternalOpenCoordinator()

    private let service: TandockProjectOpenService
    private lazy var listener = TandockCLIListener { [weak self, service] request in
        let resolved = try service.resolve(request)
        DispatchQueue.main.async { self?.route(resolved) }
        return resolved
    }
    private var pending: [String: [TandockResolvedOpen]] = [:]
    private var pendingBeforeMainWindow: [TandockResolvedOpen] = []
    private var mainWindowToken: String?

    private init() {
        let dataRoot = TandockDataRootResolver.resolve()
        service = TandockProjectOpenService(databaseURL: dataRoot.appendingPathComponent("ycode.db"))
    }

    func start() {
        do {
            try listener.start()
        } catch {
            report(error)
        }
    }

    func stop() {
        listener.stop()
    }

    func registerMainWindow(token: String) {
        mainWindowToken = token
        if !pendingBeforeMainWindow.isEmpty {
            pending[token, default: []].append(contentsOf: pendingBeforeMainWindow)
            pendingBeforeMainWindow.removeAll()
        }
        if pending[token]?.isEmpty == false {
            NotificationCenter.default.post(
                name: .tandockExternalOpenReady,
                object: nil,
                userInfo: ["windowToken": token]
            )
        }
    }

    func unregisterMainWindow(token: String) {
        if mainWindowToken == token { mainWindowToken = nil }
    }

    func takePending(for token: String) -> [TandockResolvedOpen] {
        let values = pending.removeValue(forKey: token) ?? []
        return values
    }

    func open(urls: [URL]) {
        for url in urls {
            do {
                guard let request = try TandockDeepLinkParser.request(from: url) else {
                    activateCurrentWindow()
                    continue
                }
                route(try service.resolve(request))
            } catch {
                report(error)
            }
        }
    }

    private func route(_ resolved: TandockResolvedOpen) {
        let token: String
        if let projectWindowToken = TandockProjectWindowManager.shared.token(for: resolved.project.id) {
            token = projectWindowToken
            TandockProjectWindowManager.shared.focus(projectID: resolved.project.id)
        } else if let mainWindowToken {
            token = mainWindowToken
            activateWindow(token: token)
        } else {
            pendingBeforeMainWindow.append(resolved)
            activateCurrentWindow()
            return
        }
        pending[token, default: []].append(resolved)
        NotificationCenter.default.post(
            name: .tandockExternalOpenReady,
            object: nil,
            userInfo: ["windowToken": token]
        )
    }

    private func activateCurrentWindow() {
        NSApplication.shared.activate(ignoringOtherApps: true)
        let window = NSApplication.shared.keyWindow ?? NSApplication.shared.windows.first
        window?.makeKeyAndOrderFront(nil)
    }

    private func activateWindow(token: String) {
        NSApplication.shared.activate(ignoringOtherApps: true)
        let identifier = NSUserInterfaceItemIdentifier(token)
        let window = NSApplication.shared.windows.first { $0.identifier == identifier }
        window?.deminiaturize(nil)
        window?.makeKeyAndOrderFront(nil)
    }

    private func report(_ error: Error) {
        NotificationCenter.default.post(
            name: .tandockExternalOpenFailed,
            object: error.localizedDescription,
            userInfo: mainWindowToken.map { ["windowToken": $0] }
        )
    }
}

@MainActor
final class TandockApplicationDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        TandockExternalOpenCoordinator.shared.start()
        Task.detached(priority: .utility) { await TandockBundledHelpers.repairStaleIntegrations() }
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        TandockExternalOpenCoordinator.shared.open(urls: urls)
    }

    func applicationWillTerminate(_ notification: Notification) {
        TandockExternalOpenCoordinator.shared.stop()
        TandockAgentHookListener.shared.stop()
        TandockSessionProcessPool.shared.terminateAllImmediately()
        TandockProjectShellPool.shared.terminateAllImmediately()
    }
}
