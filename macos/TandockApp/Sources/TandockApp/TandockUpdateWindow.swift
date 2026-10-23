import AppKit
import SwiftUI
import TandockCore

@MainActor
final class TandockUpdateWindowController: NSObject, NSWindowDelegate {
    private let model: TandockUpdateModel
    private let localization = TandockCommandLocalizationModel()
    private var window: NSWindow?
    private var observer: NSObjectProtocol?

    init(model: TandockUpdateModel) {
        self.model = model
        super.init()
        observer = NotificationCenter.default.addObserver(
            forName: .tandockAppearanceSettingsChanged, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.applyAppearance() }
        }
    }

    func show(activate: Bool) {
        let window = window ?? makeWindow()
        self.window = window
        window.title = localization.l10n.text("updTitle")
        applyAppearance()
        if !window.isVisible { window.center() }
        if activate {
            NSApp.activate()
            window.makeKeyAndOrderFront(nil)
        } else {
            window.orderFrontRegardless()
        }
    }

    func close() {
        window?.orderOut(nil)
    }

    private func makeWindow() -> NSWindow {
        let host = NSHostingController(rootView: TandockUpdateView(model: model, localization: localization))
        host.sizingOptions = [.preferredContentSize]
        let window = NSWindow(contentViewController: host)
        window.styleMask = [.titled, .closable]
        window.titlebarAppearsTransparent = true
        window.isReleasedWhenClosed = false
        window.isMovableByWindowBackground = true
        window.backgroundColor = NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
                ? (NSColor(hex: "110F28") ?? .windowBackgroundColor)
                : (NSColor(hex: "EFEEF4") ?? .windowBackgroundColor)
        }
        window.delegate = self
        return window
    }

    private func applyAppearance() {
        let theme = TandockConfigurationStore(
            configurationURL: TandockDataRootResolver.resolve().appendingPathComponent("config.json")
        )
        let id = (try? theme.loadBasicSettings().appearance.theme) ?? TandockThemeCatalog.systemID
        switch id {
        case TandockThemeCatalog.light.id: window?.appearance = NSAppearance(named: .aqua)
        case TandockThemeCatalog.dark.id: window?.appearance = NSAppearance(named: .darkAqua)
        default: window?.appearance = nil
        }
        window?.title = localization.l10n.text("updTitle")
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        if let close = model.handlers.close {
            close()
        } else {
            sender.orderOut(nil)
        }
        return false
    }
}

struct TandockUpdateView: View {
    @ObservedObject var model: TandockUpdateModel
    @ObservedObject var localization: TandockCommandLocalizationModel
    @State private var quitIsStuck = false
    var localeOverride: TandockLocale? = nil
    var flowLayoutObserver: (@Sendable (TandockUpdateFlowMeasurement) -> Void)? = nil

    private var l10n: TandockLocalization {
        localeOverride.map { TandockLocalization(locale: $0) } ?? localization.l10n
    }

    var body: some View {
        content
            .padding(.horizontal, 20)
            .padding(.top, 18)
            .padding(.bottom, 16)
            .frame(width: 440, alignment: .leading)
            .background(Color.tandockCard, in: RoundedRectangle(cornerRadius: 11, style: .continuous))
            .shadow(color: Color.tandockShadow, radius: 4, y: 1)
            .padding(.horizontal, 10)
            .padding(.bottom, 10)
            .padding(.top, 4)
            .fixedSize(horizontal: true, vertical: true)
            .background(Color.tandockChrome)
            .onChange(of: model.phase) { _, phase in announce(phase) }
            .task(id: isWaitingToQuit) {
                quitIsStuck = false
                guard isWaitingToQuit else { return }
                try? await Task.sleep(nanoseconds: 4_000_000_000)
                if !Task.isCancelled { quitIsStuck = true }
            }
    }

    private var isWaitingToQuit: Bool {
        model.phase == .installing(applicationTerminated: false)
    }


    private var content: some View {
        HStack(alignment: .top, spacing: 16) {
            icon
            VStack(alignment: .leading, spacing: 0) {
                phaseBody
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    @ViewBuilder
    private var phaseBody: some View {
        switch model.phase {
        case .checking:
            title(l10n.text("updChecking"))
            subtitle(l10n.text("updCurrentVersionFormat", currentVersion))
            indeterminate
            buttons { cancelButton }

        case let .available(version, current, size, notes, downloaded):
            title(l10n.text("updAvailableTitle"))
            TandockUpdateFlowLayout(alignment: .leading, observer: flowLayoutObserver) {
                versionPill(from: current, to: version)
                if let size { Text(size).font(.system(size: 12.5)).foregroundStyle(.secondary) }
                if let notes {
                    Button(l10n.text("updReleaseNotes")) { NSWorkspace.shared.open(notes) }
                        .buttonStyle(UpdateLinkStyle())
                }
            }
            .padding(.bottom, 12)
            TandockUpdateFlowLayout(alignment: .trailing, observer: flowLayoutObserver) {
                Button(l10n.text("updSkip")) { model.handlers.skip?() }
                    .buttonStyle(UpdateButtonStyle())
                Button(l10n.text("updLater")) { model.handlers.later?() }
                    .buttonStyle(UpdateButtonStyle())
                    .keyboardShortcut(.cancelAction)
                Button(l10n.text(downloaded ? "updInstallRelaunch" : "updDownloadInstall")) { model.handlers.install?() }
                    .buttonStyle(UpdateButtonStyle(primary: true))
                    .keyboardShortcut(.defaultAction)
            }
            .padding(.top, 4)

        case let .information(version, infoURL):
            title(l10n.text("updInformationTitle", version))
            buttons {
                Spacer(minLength: 0)
                Button(l10n.text("updLater")) { model.handlers.later?() }
                    .buttonStyle(UpdateButtonStyle())
                    .keyboardShortcut(.cancelAction)
                if let infoURL {
                    Button(l10n.text("updLearnMore")) {
                        NSWorkspace.shared.open(infoURL)
                        model.handlers.later?()
                    }
                    .buttonStyle(UpdateButtonStyle(primary: true))
                    .keyboardShortcut(.defaultAction)
                }
            }

        case let .unavailable(detail):
            title(l10n.text("updUnavailableTitle"))
            subtitle(detail)
            buttons {
                Spacer(minLength: 0)
                Button(l10n.text("updOK")) { model.handlers.acknowledge?() }
                    .buttonStyle(UpdateButtonStyle(primary: true))
                    .keyboardShortcut(.defaultAction)
            }

        case let .downloading(version, received, expected):
            title(l10n.text("updDownloadingFormat", version))
            subtitle(l10n.text("updDownloadHint"))
            if let expected, expected > 0 {
                let fraction = min(1, Double(received) / Double(expected))
                determinate(fraction)
                HStack {
                    Text("\(bytes(received)) / \(bytes(expected))")
                    Spacer()
                    Text("\(Int(fraction * 100))%")
                }
                .font(.system(size: 11.5, design: .monospaced))
                .foregroundStyle(.secondary)
                .padding(.bottom, 12)
            } else {
                indeterminate
                Text(bytes(received))
                    .font(.system(size: 11.5, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .padding(.bottom, 12)
            }
            buttons { cancelButton }

        case let .extracting(progress):
            title(l10n.text("updPreparing"))
            subtitle(l10n.text("updPreparingHint"))
            if progress > 0 { determinate(progress) } else { indeterminate }

        case let .readyToInstall(version):
            title(l10n.text("updReadyFormat", version))
            subtitle(l10n.text("updReadyHint"))
            buttons {
                Button(l10n.text("updLaterShort")) { model.handlers.later?() }
                    .buttonStyle(UpdateLinkStyle())
                    .keyboardShortcut(.cancelAction)
                Spacer(minLength: 0)
                Button(l10n.text("updInstallRelaunch")) { model.handlers.install?() }
                    .buttonStyle(UpdateButtonStyle(primary: true))
                    .keyboardShortcut(.defaultAction)
            }

        case let .installing(terminated):
            title(l10n.text("updInstalling"))
            subtitle(l10n.text(quitIsStuck && !terminated ? "updInstallingStuck" : "updInstallingHint"))
            indeterminate
            if quitIsStuck && !terminated {
                buttons {
                    Spacer(minLength: 0)
                    Button(l10n.text("updRetryQuit")) { model.handlers.retryQuit?() }
                        .buttonStyle(UpdateButtonStyle())
                }
            }

        case let .upToDate(version):
            title(l10n.text("updUpToDateTitle"))
            subtitle(l10n.text("updUpToDateFormat", version))
            buttons {
                Spacer(minLength: 0)
                Button(l10n.text("updOK")) { model.handlers.acknowledge?() }
                    .buttonStyle(UpdateButtonStyle(primary: true))
                    .keyboardShortcut(.defaultAction)
            }

        case let .failed(kind, detail):
            title(l10n.text("updErrorTitle"))
            errorBox(message(for: kind, detail: detail))
            buttons {
                Button(l10n.text("updCopyError")) {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(detail, forType: .string)
                }
                .buttonStyle(UpdateLinkStyle())
                Spacer(minLength: 0)
                Button(l10n.text("updClose")) { model.handlers.acknowledge?() }
                    .buttonStyle(UpdateButtonStyle())
                    .keyboardShortcut(.cancelAction)
                Button(l10n.text("updRetry")) { model.handlers.retry?() }
                    .buttonStyle(UpdateButtonStyle(primary: true))
                    .keyboardShortcut(.defaultAction)
            }
        }
    }


    private var cancelButton: some View {
        HStack {
            Spacer(minLength: 0)
            Button(l10n.text("updCancel")) { model.handlers.cancel?() }
                .buttonStyle(UpdateButtonStyle())
                .keyboardShortcut(.cancelAction)
        }
    }

    private func buttons<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        HStack(spacing: 8) { content() }
            .padding(.top, 4)
    }

    private func title(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 15, weight: .semibold))
            .fixedSize(horizontal: false, vertical: true)
            .padding(.top, 1)
            .padding(.bottom, 3)
            .accessibilityAddTraits(.isHeader)
    }

    private func subtitle(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 12.5))
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.bottom, 12)
    }

    private func versionPill(from: String, to: String) -> some View {
        HStack(spacing: 6) {
            Text(from)
            Text("→").foregroundStyle(Color.tandockAccentText)
            Text(to)
        }
        .font(.system(size: 11.5, weight: .semibold, design: .monospaced))
        .foregroundStyle(.secondary)
        .padding(.horizontal, 7)
        .padding(.vertical, 1)
        .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(from) → \(to)")
    }

    private func determinate(_ fraction: Double) -> some View {
        UpdateProgressBar(fraction: fraction)
            .padding(.top, 2)
            .padding(.bottom, 6)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(l10n.text("updAXProgressFormat", Int(fraction * 100)))
    }

    private var indeterminate: some View {
        UpdateProgressBar(fraction: nil)
            .padding(.top, 2)
            .padding(.bottom, 10)
            .accessibilityHidden(true)
    }

    private func errorBox(_ message: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Image(systemName: "exclamationmark.triangle.fill").font(.system(size: 11))
            Text(message).fixedSize(horizontal: false, vertical: true)
        }
        .font(.system(size: 12))
        .foregroundStyle(Color.tandockErr)
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.tandockErr.opacity(0.1), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .padding(.bottom, 12)
    }

    private func message(for kind: TandockUpdateErrorKind, detail: String) -> String {
        switch kind {
        case .network: l10n.text("updErrorNetwork")
        case .signature: l10n.text("updErrorSignature")
        case .permission: l10n.text("updErrorPermission")
        case .generic: l10n.text("updErrorGenericFormat", detail.split(separator: "\n").dropFirst().first.map(String.init) ?? detail)
        }
    }


    private var icon: some View {
        ZStack(alignment: .bottomTrailing) {
            Group {
                if let logo = TandockAgentIconRenderer.tandockLogo {
                    Image(nsImage: logo).resizable().aspectRatio(contentMode: .fit)
                } else {
                    Image(nsImage: NSApp.applicationIconImage).resizable().aspectRatio(contentMode: .fit)
                }
            }
            .frame(width: 56, height: 56)
            .clipShape(RoundedRectangle(cornerRadius: 13, style: .continuous))
            .shadow(color: Color.tandockAccent.opacity(0.35), radius: 5, y: 3)

            if let badge {
                Image(systemName: badge.symbol)
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 22, height: 22)
                    .background(badge.color, in: Circle())
                    .overlay(Circle().stroke(Color.tandockCard, lineWidth: 2))
                    .offset(x: 6, y: 6)
            }
        }
        .frame(width: 56, height: 56)
        .accessibilityHidden(true)
    }

    private var badge: (symbol: String, color: Color)? {
        switch model.phase {
        case .checking: nil
        case .available, .information: ("arrow.up", Color.tandockAccent)
        case .unavailable: ("exclamationmark", Color.tandockErr)
        case .downloading: ("arrow.down", Color.tandockAccent)
        case .extracting, .installing: ("ellipsis", Color.tandockAccent)
        case .readyToInstall, .upToDate: ("checkmark", Color.tandockOK)
        case .failed: ("exclamationmark", Color.tandockErr)
        }
    }


    private var currentVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""
    }

    private func bytes(_ value: UInt64) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(value), countStyle: .file)
    }

    private func announce(_ phase: TandockUpdatePhase) {
        let text: String
        switch phase {
        case .checking: text = l10n.text("updChecking")
        case .available: text = l10n.text("updAvailableTitle")
        case let .information(version, _): text = l10n.text("updInformationTitle", version)
        case .unavailable: text = l10n.text("updUnavailableTitle")
        case .downloading: return
        case .extracting: text = l10n.text("updPreparing")
        case let .readyToInstall(version): text = l10n.text("updReadyFormat", version)
        case .installing: text = l10n.text("updInstalling")
        case .upToDate: text = l10n.text("updUpToDateTitle")
        case .failed: text = l10n.text("updErrorTitle")
        }
        NSAccessibility.post(element: NSApp as Any, notification: .announcementRequested, userInfo: [.announcement: text])
    }
}

private struct UpdateProgressBar: View {
    let fraction: Double?
    @State private var sweep = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        GeometryReader { proxy in
            let width = proxy.size.width
            ZStack(alignment: .leading) {
                Capsule().fill(Color.primary.opacity(0.1))
                if let fraction {
                    Capsule().fill(Color.tandockAccent)
                        .frame(width: max(6, width * fraction))
                        .animation(.easeOut(duration: 0.2), value: fraction)
                } else {
                    Capsule()
                        .fill(LinearGradient(colors: [.clear, Color.tandockAccent, .clear], startPoint: .leading, endPoint: .trailing))
                        .frame(width: width * 0.36)
                        .offset(x: reduceMotion ? width * 0.32 : (sweep ? width * 0.64 : 0))
                        .animation(reduceMotion ? nil : .easeInOut(duration: 1.1).repeatForever(autoreverses: true), value: sweep)
                }
            }
            .clipShape(Capsule())
            .onAppear { sweep = true }
        }
        .frame(height: 6)
    }
}

private struct UpdateButtonStyle: ButtonStyle {
    var primary = false
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12.5, weight: .semibold))
            .lineLimit(1)
            .fixedSize()
            .foregroundStyle(primary ? Color.white : Color.primary)
            .padding(.horizontal, 14)
            .frame(height: 28)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(primary ? Color.tandockAccent : Color.primary.opacity(0.07))
                    .brightness(configuration.isPressed ? -0.08 : 0)
            )
            .opacity(isEnabled ? 1 : 0.5)
            .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}

private struct UpdateLinkStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12.5, weight: .medium))
            .lineLimit(1)
            .fixedSize()
            .foregroundStyle(Color.tandockAccentText)
            .opacity(configuration.isPressed ? 0.6 : 1)
            .padding(.horizontal, 4)
            .frame(height: 28)
            .contentShape(Rectangle())
    }
}

struct TandockUpdateFlowLayout: Layout {
    var alignment: HorizontalAlignment
    var spacing: CGFloat = 8
    var observer: (@Sendable (TandockUpdateFlowMeasurement) -> Void)? = nil

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let idealWidth = subviews.reduce(CGFloat.zero) { $0 + $1.sizeThatFits(.unspecified).width + spacing }
        let width = proposal.width.flatMap { $0.isFinite ? $0 : nil } ?? idealWidth
        let frames = frames(width: width, subviews: subviews)
        return CGSize(width: width, height: frames.map(\.maxY).max() ?? 0)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let frames = frames(width: bounds.width, subviews: subviews)
        for (index, frame) in frames.enumerated() {
            subviews[index].place(
                at: CGPoint(x: bounds.minX + frame.minX, y: bounds.minY + frame.minY),
                anchor: .topLeading, proposal: ProposedViewSize(frame.size)
            )
        }
        observer?(TandockUpdateFlowMeasurement(
            width: bounds.width, height: bounds.height, isTrailing: alignment == .trailing, frames: frames,
            idealSizes: subviews.map { $0.sizeThatFits(.unspecified) }
        ))
    }

    private func frames(width: CGFloat, subviews: Subviews) -> [CGRect] {
        var frames: [CGRect] = []
        var rowStart = 0
        var rowWidth: CGFloat = 0
        var rowHeight: CGFloat = 0
        var y: CGFloat = 0

        func finishRow() {
            let offset = alignment == .trailing ? max(0, width - rowWidth) : 0
            for index in rowStart..<frames.count {
                frames[index].origin.x += offset
                frames[index].origin.y += (rowHeight - frames[index].height) / 2
            }
        }

        for subview in subviews {
            let ideal = subview.sizeThatFits(.unspecified)
            let size = subview.sizeThatFits(ProposedViewSize(width: min(width, ideal.width), height: nil))
            let gap = frames.count == rowStart ? 0 : spacing
            if rowWidth + gap + size.width > width, frames.count > rowStart {
                finishRow()
                y += rowHeight + spacing
                rowStart = frames.count
                rowWidth = 0
                rowHeight = 0
            }
            let x = rowWidth + (frames.count == rowStart ? 0 : spacing)
            frames.append(CGRect(origin: CGPoint(x: x, y: y), size: size))
            rowWidth = x + size.width
            rowHeight = max(rowHeight, size.height)
        }
        finishRow()
        return frames
    }
}

struct TandockUpdateFlowMeasurement: Sendable {
    let width: CGFloat
    let height: CGFloat
    let isTrailing: Bool
    let frames: [CGRect]
    let idealSizes: [CGSize]
}
