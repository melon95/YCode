import AppKit
import os
import SwiftUI
import Testing
@testable import TandockApp
import TandockCore

@Suite("Update window", .serialized)
@MainActor
struct UpdateWindowTests {
    init() { _ = NSApplication.shared }

    @Test("errors are sorted into the three actionable kinds")
    func classifiesErrors() {
        let offline = NSError(domain: NSURLErrorDomain, code: NSURLErrorNotConnectedToInternet)
        #expect(TandockUpdateErrorKind.classify(offline) == .network)

        let wrapped = NSError(domain: "SUSparkleErrorDomain", code: 2001,
                              userInfo: [NSUnderlyingErrorKey: offline])
        #expect(TandockUpdateErrorKind.classify(wrapped) == .network)

        let signature = NSError(domain: "SUSparkleErrorDomain", code: 3001)
        #expect(TandockUpdateErrorKind.classify(signature) == .signature)

        let permission = NSError(domain: "SUSparkleErrorDomain", code: 4012)
        #expect(TandockUpdateErrorKind.classify(permission) == .permission)

        let unknown = NSError(domain: "Other", code: 1)
        #expect(TandockUpdateErrorKind.classify(unknown) == .generic)
    }

    @Test("error detail keeps domain, code and the underlying error for bug reports")
    func errorDetail() {
        let inner = NSError(domain: NSURLErrorDomain, code: -1009, userInfo: [NSLocalizedDescriptionKey: "offline"])
        let outer = NSError(domain: "Outer", code: 7, userInfo: [NSUnderlyingErrorKey: inner])
        let detail = TandockUpdateUserDriver.detail(of: outer)
        #expect(detail.contains("Outer (7)"))
        #expect(detail.contains("NSURLErrorDomain (-1009)"))
    }

    @Test("download progress accumulates and falls back to indeterminate without a length")
    func downloadProgress() {
        let driver = TandockUpdateUserDriver()
        driver.showDownloadInitiated(cancellation: {})
        driver.showDownloadDidReceiveData(ofLength: 100)
        guard case let .downloading(_, received, expected) = driver.model.phase else {
            Issue.record("expected downloading phase"); return
        }
        #expect(received == 100)
        #expect(expected == nil)

        driver.showDownloadDidReceiveExpectedContentLength(400)
        driver.showDownloadDidReceiveData(ofLength: 100)
        guard case let .downloading(_, received2, expected2) = driver.model.phase else {
            Issue.record("expected downloading phase"); return
        }
        #expect(received2 == 200)
        #expect(expected2 == 400)
        driver.dismissUpdateInstallation()
    }

    @Test("ready-to-install consumes one reply and invalidates stale actions")
    func readyToInstallReplies() {
        let driver = TandockUpdateUserDriver()
        var choices: [SPUUserUpdateChoice] = []
        driver.showReady(toInstallAndRelaunch: { choices.append($0) })
        let install = driver.model.handlers.install
        let later = driver.model.handlers.later
        install?()
        install?()
        later?()
        #expect(choices.count == 1)
        #expect(choices.first == .install)
        #expect(driver.model.handlers.install == nil)
        driver.showReady(toInstallAndRelaunch: { choices.append($0) })
        install?()
        #expect(choices.count == 1)
        driver.model.handlers.close?()
        #expect(choices.count == 2)
        #expect(choices.last == .dismiss)
    }

    @Test("retry waits for Sparkle teardown and starts only one new check")
    func retryWaitsForFinishedCycle() {
        let retry = TandockUpdateRetryCoordinator()
        let driver = TandockUpdateUserDriver()
        driver.retryCheck = { retry.request(acknowledgement: $0) }
        var acknowledgements = 0
        var checks = 0
        driver.showUpdaterError(NSError(domain: NSURLErrorDomain, code: -1009), acknowledgement: {
            acknowledgements += 1
            #expect(retry.isPending)
        })
        let action = driver.model.handlers.retry
        action?()
        action?()
        #expect(acknowledgements == 1)
        #expect(checks == 0)
        #expect(retry.isPending)
        retry.updateCycleDidFinish(canCheckForUpdates: true, sessionInProgress: true) { checks += 1 }
        retry.updateCycleDidFinish(canCheckForUpdates: false, sessionInProgress: false) { checks += 1 }
        #expect(checks == 0)
        retry.updateCycleDidFinish(canCheckForUpdates: true, sessionInProgress: false) { checks += 1 }
        retry.updateCycleDidFinish(canCheckForUpdates: true, sessionInProgress: false) { checks += 1 }
        #expect(checks == 1)
        #expect(!retry.isPending)
    }

    @Test("a real Sparkle error cycle clears its session before starting a pending retry")
    func realUpdaterRetryCycle() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("Tandock-update-retry-\(UUID().uuidString).bundle")
        let contents = directory.appendingPathComponent("Contents")
        try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
        let bundleID = "dev.ycode.update-retry-test.\(UUID().uuidString)"
        defer {
            try? FileManager.default.removeItem(at: directory)
            UserDefaults.standard.removePersistentDomain(forName: bundleID)
        }
        let info: [String: Any] = [
            "CFBundleIdentifier": bundleID, "CFBundleName": "Tandock Update Test",
            "CFBundleVersion": "1", "CFBundlePackageType": "BNDL",
            "SUPublicEDKey": Data(repeating: 1, count: 32).base64EncodedString(),
            "SUEnableAutomaticChecks": false
        ]
        try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
            .write(to: contents.appendingPathComponent("Info.plist"))
        let bundle = try #require(Bundle(url: directory))
        let retry = TandockUpdateRetryCoordinator()
        let driver = TandockUpdateUserDriver()
        defer {
            driver.model.handlers.acknowledge?()
            driver.dismissUpdateInstallation()
        }
        let delegate = RetryCycleDelegate(retry: retry)
        let updater = SPUUpdater(hostBundle: bundle, applicationBundle: bundle, userDriver: driver, delegate: delegate)
        driver.retryCheck = { retry.request(acknowledgement: $0) }
        try updater.start()
        updater.checkForUpdates()
        guard await waitForUpdateCondition({ driver.model.handlers.retry != nil }) else { return }
        #expect(updater.sessionInProgress)
        driver.model.handlers.retry?()
        #expect(retry.isPending)
        #expect(delegate.finishedCycles == 0)
        guard await waitForUpdateCondition({ delegate.retriesStarted == 1 && driver.model.handlers.retry != nil }) else { return }
        #expect(delegate.finishedCycles == 1)
        #expect(delegate.readyStates == [true])
        #expect(!retry.isPending)
        driver.model.handlers.acknowledge?()
        guard await waitForUpdateCondition({ delegate.finishedCycles == 2 }) else { return }
        #expect(delegate.readyStates == [true, true])
        #expect(delegate.retriesStarted == 1)
        #expect(!updater.sessionInProgress)
        driver.dismissUpdateInstallation()
    }

    @Test("an incompatible or unknown feed result is never described as the latest version")
    func unavailableUpdate() {
        let driver = TandockUpdateUserDriver()
        for reason in [SPUNoUpdateFoundReason.systemIsTooOld, .systemIsTooNew, .hardwareDoesNotSupportARM64, .unknown] {
            var acknowledgements = 0
            let error = NSError(domain: SUSparkleErrorDomain, code: 1001, userInfo: [
                SPUNoUpdateFoundReasonKey: NSNumber(value: reason.rawValue),
                NSLocalizedDescriptionKey: "Requires a newer macOS version"
            ])
            driver.showUpdateNotFoundWithError(error, acknowledgement: { acknowledgements += 1 })
            #expect(driver.model.phase == .unavailable(detail: error.localizedDescription))
            let close = driver.model.handlers.close
            close?()
            close?()
            #expect(acknowledgements == 1)
        }
        let latest = NSError(domain: SUSparkleErrorDomain, code: 1001, userInfo: [
            SPUNoUpdateFoundReasonKey: NSNumber(value: SPUNoUpdateFoundReason.onLatestVersion.rawValue)
        ])
        driver.showUpdateNotFoundWithError(latest, acknowledgement: {})
        guard case .upToDate = driver.model.phase else { Issue.record("expected latest version result"); return }
        driver.dismissUpdateInstallation()
    }

    @Test("informational updates offer the info page and never an install reply")
    func informationOnlyUpdate() throws {
        let item = try #require(SUAppcastItem(dictionary: [
            "sparkle:version": "0.8.0", "link": "https://example.invalid/update-info"
        ]))
        let state = try #require(SPUUserUpdateState(coder: UpdateStateCoder()))
        let driver = TandockUpdateUserDriver()
        var choices: [SPUUserUpdateChoice] = []
        driver.showUpdateFound(with: item, state: state, reply: { choices.append($0) })
        #expect(driver.model.phase == .information(version: "0.8.0", infoURL: item.infoURL))
        #expect(driver.model.handlers.install == nil)
        driver.model.handlers.close?()
        #expect(choices.count == 1)
        #expect(choices.first == .dismiss)
    }

    @Test("available updates forward skip, later and install once for every download stage")
    func availableUpdateChoices() throws {
        let item = try #require(SUAppcastItem(dictionary: ["enclosure": [
            "url": "https://example.invalid/Tandock.zip", "sparkle:version": "0.8.0"
        ]]))
        for stage in [SPUUserUpdateStage.notDownloaded, .downloaded, .installing] {
            for choice in [SPUUserUpdateChoice.skip, .dismiss, .install] {
                let state = try #require(SPUUserUpdateState(coder: UpdateStateCoder(stage: stage)))
                let driver = TandockUpdateUserDriver()
                var replies: [SPUUserUpdateChoice] = []
                driver.showUpdateFound(with: item, state: state, reply: { replies.append($0) })
                guard case let .available(_, _, _, _, downloaded) = driver.model.phase else {
                    Issue.record("expected available update"); continue
                }
                #expect(downloaded == (stage != .notDownloaded))
                let action = choice == .skip ? driver.model.handlers.skip
                    : choice == .install ? driver.model.handlers.install : driver.model.handlers.later
                let close = driver.model.handlers.close
                action?()
                action?()
                close?()
                #expect(replies.count == 1)
                #expect(replies.first == choice)
                driver.dismissUpdateInstallation()
            }
        }
    }

    @Test("downloading cancels once while extraction cannot cancel and quit can be retried")
    func progressActionSemantics() {
        let driver = TandockUpdateUserDriver()
        var cancellations = 0
        driver.showDownloadInitiated(cancellation: { cancellations += 1 })
        let cancel = driver.model.handlers.close
        cancel?()
        cancel?()
        #expect(cancellations == 1)
        driver.showDownloadInitiated(cancellation: { cancellations += 1 })
        let obsoleteCancel = driver.model.handlers.cancel
        driver.showDownloadDidStartExtractingUpdate()
        #expect(driver.model.handlers.close == nil)
        #expect(driver.model.handlers.cancel == nil)
        obsoleteCancel?()
        #expect(cancellations == 1)
        var retries = 0
        driver.showInstallingUpdate(withApplicationTerminated: false, retryTerminatingApplication: { retries += 1 })
        driver.model.handlers.retryQuit?()
        driver.model.handlers.retryQuit?()
        #expect(retries == 2)
        #expect(driver.model.handlers.close == nil)
        let oldRetry = driver.model.handlers.retryQuit
        driver.showInstallingUpdate(withApplicationTerminated: true, retryTerminatingApplication: { retries += 1 })
        oldRetry?()
        #expect(driver.model.handlers.retryQuit == nil)
        #expect(retries == 2)
        driver.dismissUpdateInstallation()
    }

    @Test("dismissal invalidates retained cancellation callbacks")
    func dismissalClearsCallbacks() {
        let driver = TandockUpdateUserDriver()
        var cancellations = 0
        driver.showUserInitiatedUpdateCheck(cancellation: { cancellations += 1 })
        let cancel = driver.model.handlers.cancel
        driver.dismissUpdateInstallation()
        cancel?()
        #expect(cancellations == 0)
        #expect(driver.model.handlers.cancel == nil)
    }

    @Test("closing the title bar during an update check cancels it")
    func closeCancelsCheck() {
        let driver = TandockUpdateUserDriver()
        var cancelled = false
        driver.showUserInitiatedUpdateCheck(cancellation: { cancelled = true })
        driver.model.handlers.close?()
        #expect(cancelled)
    }

    @Test("translated update actions retain their full natural widths inside the card")
    func availableUpdateGeometry() throws {
        for locale in [TandockLocale.zh, .en] {
            for downloaded in [false, true] {
                let model = TandockUpdateModel()
                model.show(.available(
                    version: "2026.10.18", currentVersion: "2026.10.17", sizeText: "128.4 MB",
                    releaseNotesURL: URL(string: "https://example.invalid/notes"), downloaded: downloaded
                ))
                let capturedMeasurements = OSAllocatedUnfairLock(initialState: [TandockUpdateFlowMeasurement]())
                let host = NSHostingView(rootView: TandockUpdateView(
                    model: model, localization: TandockCommandLocalizationModel(), localeOverride: locale,
                    flowLayoutObserver: { measurement in
                        capturedMeasurements.withLock { $0.append(measurement) }
                    }
                ))
                let fittingSize = host.fittingSize
                capturedMeasurements.withLock { $0.removeAll() }
                host.frame = NSRect(origin: .zero, size: fittingSize)
                host.needsLayout = true
                host.layoutSubtreeIfNeeded()
                let placements = capturedMeasurements.withLock { $0 }
                let measurements = [false, true].compactMap { trailing in
                    placements.last { $0.isTrailing == trailing }
                }
                #expect(abs(host.bounds.width - 460) < 1)
                #expect(measurements.count >= 2, "Both metadata and actions must be measured during actual layout")
                for measurement in measurements {
                    #expect(measurement.width <= 328.5, "The icon and card padding leave 328 points for text and controls")
                    for (index, frame) in measurement.frames.enumerated() {
                        #expect(frame.minX >= -0.5 && frame.maxX <= measurement.width + 0.5,
                                "A translated control extends outside the update card")
                        #expect(frame.minY >= -0.5 && frame.maxY <= measurement.height + 0.5)
                        #expect(frame.width >= measurement.idealSizes[index].width - 0.5,
                                "A button, version or release-notes label was compressed")
                        for previous in measurement.frames.prefix(index) {
                            #expect(!frame.insetBy(dx: 0.25, dy: 0.25).intersects(previous), "Controls overlap")
                        }
                    }
                }
                let footerCandidate = measurements.last { $0.isTrailing }
                let footer = try #require(footerCandidate)
                #expect(footer.frames.count == 3)
                if locale == .en {
                    #expect(footer.frames.last!.minY > footer.frames.first!.minY,
                            "English action labels require a second row at this width")
                }
            }
        }
    }

    @Test("every phase lays out to a non-empty view, in both languages")
    func rendersEveryPhase() throws {
        _ = NSApplication.shared
        let phases: [(String, TandockUpdatePhase)] = [
            ("a-checking", .checking),
            ("b-available", .available(version: "0.8.0", currentVersion: "0.7.0", sizeText: "34 MB",
                                       releaseNotesURL: URL(string: "https://example.invalid/notes"), downloaded: false)),
            ("c-downloading", .downloading(version: "0.8.0", received: 21_000_000, expected: 34_000_000)),
            ("d-extracting", .extracting(progress: 0.78)),
            ("e-ready", .readyToInstall(version: "0.8.0")),
            ("f-installing", .installing(applicationTerminated: false)),
            ("g-uptodate", .upToDate(version: "0.8.0")),
            ("i-unavailable", .unavailable(detail: "This update requires macOS 15 or later.")),
            ("j-information", .information(version: "0.8.0", infoURL: URL(string: "https://example.invalid/info"))),
            ("h-error", .failed(kind: .network, detail: "x\ny")),
        ]
        let dir = ProcessInfo.processInfo.environment["YCODE_UPDATE_SNAPSHOT_DIR"]
        if let dir { try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true) }
        for locale in [TandockLocale.zh, .en] {
            for (theme, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
                for (name, phase) in phases {
                    let model = TandockUpdateModel()
                    model.show(phase)
                    let host = NSHostingView(rootView: TandockUpdateView(
                        model: model, localization: TandockCommandLocalizationModel(), localeOverride: locale
                    ))
                    host.appearance = NSAppearance(named: appearance)
                    host.frame = NSRect(origin: .zero, size: host.fittingSize)
                    host.layoutSubtreeIfNeeded()
                    #expect(abs(host.fittingSize.width - 460) < 1, "\(name) must keep the card width")
                    #expect(host.fittingSize.height > 60, "\(name) height")
                    if let dir, let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) {
                        host.cacheDisplay(in: host.bounds, to: rep)
                        try rep.representation(using: .png, properties: [:])?
                            .write(to: URL(fileURLWithPath: dir).appendingPathComponent("\(locale.rawValue)-\(theme)-\(name).png"))
                    }
                }
            }
        }
    }
}

import Sparkle

private final class UpdateStateCoder: NSCoder {
    private let stage: SPUUserUpdateStage
    init(stage: SPUUserUpdateStage = .notDownloaded) { self.stage = stage; super.init() }
    override func decodeInteger(forKey key: String) -> Int { stage.rawValue }
    override func decodeBool(forKey key: String) -> Bool { true }
}

@MainActor
private final class RetryCycleDelegate: NSObject, SPUUpdaterDelegate {
    let retry: TandockUpdateRetryCoordinator
    var finishedCycles = 0
    var retriesStarted = 0
    var readyStates: [Bool] = []

    init(retry: TandockUpdateRetryCoordinator) { self.retry = retry; super.init() }

    func updater(_ updater: SPUUpdater, didFinishUpdateCycleFor updateCheck: SPUUpdateCheck, error: (any Error)?) {
        finishedCycles += 1
        readyStates.append(updater.canCheckForUpdates && !updater.sessionInProgress)
        retry.updateCycleDidFinish(
            canCheckForUpdates: updater.canCheckForUpdates, sessionInProgress: updater.sessionInProgress
        ) {
            updater.checkForUpdates()
            if updater.sessionInProgress { retriesStarted += 1 }
        }
    }
}

@MainActor
private func waitForUpdateCondition(_ condition: () -> Bool) async -> Bool {
    let deadline = Date().addingTimeInterval(25)
    while !condition() {
        guard Date() < deadline else {
            Issue.record("Sparkle did not complete the expected local update cycle")
            return false
        }
        do { try await Task.sleep(for: .milliseconds(10)) }
        catch { Issue.record("Sparkle cycle wait was cancelled"); return false }
    }
    return true
}
