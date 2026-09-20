import AppKit
import Foundation
import YCodeCore

extension Notification.Name {
    static let ycodeExternalOpenReady = Notification.Name("dev.ycode.native.external-open-ready")
    static let ycodeExternalOpenFailed = Notification.Name("dev.ycode.native.external-open-failed")
}

@MainActor
final class YCodeExternalOpenCoordinator {
    static let shared = YCodeExternalOpenCoordinator()

    private let service: YCodeProjectOpenService
    private lazy var listener = YCodeCLIListener { [weak self, service] request in
        let resolved = try service.resolve(request)
        DispatchQueue.main.async { self?.route(resolved) }
        return resolved
    }
    private var pending: [String: [YCodeResolvedOpen]] = [:]
    private var pendingBeforeMainWindow: [YCodeResolvedOpen] = []
    private var mainWindowToken: String?

    private init() {
        let dataRoot = YCodeDataRootResolver.resolve()
        service = YCodeProjectOpenService(databaseURL: dataRoot.appendingPathComponent("ycode.db"))
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
                name: .ycodeExternalOpenReady,
                object: nil,
                userInfo: ["windowToken": token]
            )
        }
    }

    func unregisterMainWindow(token: String) {
        if mainWindowToken == token { mainWindowToken = nil }
    }

    func takePending(for token: String) -> [YCodeResolvedOpen] {
        let values = pending.removeValue(forKey: token) ?? []
        return values
    }

    func open(urls: [URL]) {
        for url in urls {
            do {
                guard let request = try YCodeDeepLinkParser.request(from: url) else {
                    activateCurrentWindow()
                    continue
                }
                route(try service.resolve(request))
            } catch {
                report(error)
            }
        }
    }

    private func route(_ resolved: YCodeResolvedOpen) {
        let token: String
        if let projectWindowToken = YCodeProjectWindowManager.shared.token(for: resolved.project.id) {
            token = projectWindowToken
            YCodeProjectWindowManager.shared.focus(projectID: resolved.project.id)
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
            name: .ycodeExternalOpenReady,
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
            name: .ycodeExternalOpenFailed,
            object: error.localizedDescription,
            userInfo: mainWindowToken.map { ["windowToken": $0] }
        )
    }
}

@MainActor
final class YCodeApplicationDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        YCodeExternalOpenCoordinator.shared.start()
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        YCodeExternalOpenCoordinator.shared.open(urls: urls)
    }

    func applicationWillTerminate(_ notification: Notification) {
        YCodeExternalOpenCoordinator.shared.stop()
        YCodeAgentHookListener.shared.stop()
        YCodeSessionProcessPool.shared.terminateAllImmediately()
        YCodeProjectShellPool.shared.terminateAllImmediately()
    }
}
