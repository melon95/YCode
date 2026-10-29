import AppKit
import QuartzCore
import SwiftTerm
import SwiftUI
import TandockCore

struct TerminalCanvasView<Pane: Identifiable, Content: View>: NSViewRepresentable {
    let panes: [Pane]
    let layout: TandockTerminalLayout
    var focusedID: Pane.ID?
    @ViewBuilder let content: (Pane) -> Content
    @Environment(\.self) private var environment

    func makeNSView(context: Context) -> TandockCanvasHost<Pane.ID> {
        TandockCanvasHost(frame: .zero)
    }

    func updateNSView(_ view: TandockCanvasHost<Pane.ID>, context: Context) {
        view.update(
            panes: panes.map { ($0.id, AnyView(content($0).environment(\.self, environment))) },
            layout: layout,
            focusedID: focusedID,
            reduceMotion: environment.accessibilityReduceMotion,
            columnLabel: environment.tandockL10n.text("resizeCanvasColumns"),
            rowLabel: environment.tandockL10n.text("resizeCanvasRows")
        )
    }

    static func dismantleNSView(_ view: TandockCanvasHost<Pane.ID>, coordinator: ()) {
        view.cancelTransition()
    }
}

@MainActor
final class TandockCanvasHost<ID: Hashable>: NSView {
    private struct Origin {
        var frame: CGRect
        var paneOpacity: Float
        var snapshotOpacity: Float?
    }

    private var panes: [ID: TandockCanvasPane] = [:]
    private var order: [ID] = []
    private var layoutMode: TandockTerminalLayout = .single
    private var weights: [String: [String: [CGFloat]]] = [:]
    private var dividers: [String: TandockCanvasDivider] = [:]
    private var ghosts: [TandockCanvasGhost] = []
    private var generation = 0
    private var finishTimer: Timer?
    private(set) var isTransitioning = false
    private var lastSize = CGSize.zero
    private var columnLabel = ""
    private var rowLabel = ""
    private var duration: CFTimeInterval {
#if DEBUG
        if let value = ProcessInfo.processInfo.environment["YCODE_CANVAS_TRANSITION_DURATION"],
           let seconds = Double(value), seconds.isFinite {
            return min(5, max(0.1, seconds))
        }
#endif
        return 0.3
    }
#if DEBUG
    private let traces = ProcessInfo.processInfo.environment["YCODE_TRACE_CANVAS_TRANSITION"] == "1"
#endif

    override var isFlipped: Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        clipsToBounds = true
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    private var configuration: String { "\(layoutMode.rawValue)-\(order.count)" }
    private var focusedID: ID?

    static var paneGap: CGFloat { 8 }
    /// How far past the gap a drag still grabs the divider. Cards are rounded, so the visible seam is wider than the gap and sits on the card edge.
    static var dividerGrabOutset: CGFloat { 8 }
    static var insets: NSEdgeInsets { NSEdgeInsets(top: 4, left: 8, bottom: 8, right: 8) }

    private func geometry() -> TandockTerminalCanvasGeometry {
        geometry(layout: layoutMode, count: order.count, weights: weights[configuration] ?? [:])
    }

    private func geometry(layout: TandockTerminalLayout, count: Int, weights: [String: [CGFloat]]) -> TandockTerminalCanvasGeometry {
        let insets = Self.insets
        let size = CGSize(width: max(0, bounds.width - insets.left - insets.right),
                          height: max(0, bounds.height - insets.top - insets.bottom))
        return TandockTerminalCanvasGeometry(layout: layout, count: count, size: size, weights: weights, gap: Self.paneGap)
    }

    private func placed(_ rect: CGRect) -> CGRect {
        rect.offsetBy(dx: Self.insets.left, dy: Self.insets.top)
    }

    func update(panes incoming: [(ID, AnyView)], layout: TandockTerminalLayout, focusedID: ID? = nil,
                reduceMotion: Bool, columnLabel: String, rowLabel: String) {
        let nextIDs = incoming.map(\.0)
        let previousIDs = order
        let nextGeometry = geometry(layout: layout, count: incoming.count,
                                    weights: weights["\(layout.rawValue)-\(incoming.count)"] ?? [:])
        let nextFrames = nextGeometry.frames.map(placed)
        let geometryChanged = previousIDs.compactMap { panes[$0]?.frame } != nextFrames
        self.focusedID = focusedID
        let animate = !reduceMotion && layout != .tabs && layoutMode != .tabs
            && window != nil && !previousIDs.isEmpty
            && bounds.width > 0 && bounds.height > 0 && geometryChanged
        let continuing = isTransitioning && !reduceMotion && !geometryChanged

        var origins: [ID: Origin] = [:]
        if animate {
            origins = capture(destinations: Dictionary(uniqueKeysWithValues: zip(nextIDs, nextFrames)))
        }
        else if !continuing { cancelTransition() }

        self.columnLabel = columnLabel
        self.rowLabel = rowLabel
        layoutMode = layout
        order = nextIDs
        lastSize = bounds.size

        withoutAnimation {
            for id in Array(panes.keys) where !nextIDs.contains(id) {
                panes.removeValue(forKey: id)?.detach()
            }
            for (index, item) in incoming.enumerated() {
                let (id, root) = item
                let pane: TandockCanvasPane
                if let existing = panes[id] {
                    pane = existing
                    pane.host.rootView = root
                } else {
                    pane = TandockCanvasPane(rootView: root)
                    addSubview(pane.cardShadow)
                    addSubview(pane)
                }
                let hidden = layout == .tabs && id != (focusedID ?? nextIDs.first)
                if hidden, let responder = window?.firstResponder as? NSView, responder.isDescendant(of: pane) {
                    window?.makeFirstResponder(nil)
                }
                pane.isHidden = hidden
                pane.cardShadow.isHidden = hidden
                pane.isFocused = layout != .tabs && id == focusedID
                pane.frame = nextFrames[index]
                pane.layoutSubtreeIfNeeded()
                panes[id] = pane
            }
            refreshDividers(nextGeometry, hidden: animate || continuing)
        }
        if animate { startTransition(from: origins) }
    }

    override func layout() {
        super.layout()
        guard bounds.size != lastSize else { return }
        lastSize = bounds.size
        cancelTransition()
        applyGeometry(geometry())
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        let local = convert(point, from: superview)
        let active = dividers.values.filter { !$0.isHidden && $0.alphaValue > 0.01 }
        if let exact = closest(active.filter { $0.layoutFrame.contains(local) }, to: local) { return exact }
        if let grabbed = closest(active.filter { $0.frame.contains(local) }, to: local) {
            // The grab band overlaps the cards' edges; a scroller or control sitting there keeps its clicks.
            if let underneath = contentHit(at: local), underneath.isInteractiveControl { return underneath }
            return grabbed
        }
        return super.hitTest(point)
    }

    private func contentHit(at local: CGPoint) -> NSView? {
        for subview in subviews.reversed() where !(subview is TandockCanvasDivider) && !subview.isHidden {
            if let hit = subview.hitTest(local) { return hit }
        }
        return nil
    }

    private func grabFrame(for gap: CGRect, vertical: Bool) -> CGRect {
        let expanded = gap.insetBy(dx: vertical ? -Self.dividerGrabOutset : 0,
                                    dy: vertical ? 0 : -Self.dividerGrabOutset)
        return expanded.intersection(bounds)
    }

    private func closest(_ dividers: [TandockCanvasDivider], to point: CGPoint) -> TandockCanvasDivider? {
        dividers.min { centerlineDistance($0, point) < centerlineDistance($1, point) }
    }

    private func centerlineDistance(_ divider: TandockCanvasDivider, _ point: CGPoint) -> CGFloat {
        divider.isVertical ? abs(point.x - divider.layoutFrame.midX) : abs(point.y - divider.layoutFrame.midY)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil { cancelTransition() }
    }

    private func capture(destinations: [ID: CGRect]) -> [ID: Origin] {
        let wasTransitioning = isTransitioning
        generation += 1
#if DEBUG
        let started = CACurrentMediaTime()
#endif
        var origins: [ID: Origin] = [:]
        withoutAnimation {
            for ghost in ghosts { ghost.freeze() }
            for id in order {
                guard let pane = panes[id] else { continue }
                let origin = Origin(frame: pane.visibleFrame, paneOpacity: pane.visibleOpacity,
                                    snapshotOpacity: pane.visibleSnapshotOpacity)
                pane.stopAnimations()
                if let destination = destinations[id] {
                    if !wasTransitioning, let capture = Self.snapshot(pane.host) {
                        pane.showSnapshot(capture.image, background: capture.background, coverage: destination.size)
                    } else {
                        pane.snapshot?.cover(destination.size)
                    }
                    origins[id] = Origin(frame: origin.frame, paneOpacity: origin.paneOpacity,
                                         snapshotOpacity: pane.snapshot == nil ? nil : origin.snapshotOpacity ?? 1)
                } else if origin.paneOpacity > 0.01, let capture = Self.snapshot(pane.host) {
                    let ghost = TandockCanvasGhost(frame: origin.frame, image: capture.image,
                                                 background: capture.background)
                    ghost.alphaValue = CGFloat(origin.paneOpacity)
                    addSubview(ghost, positioned: .below, relativeTo: nil)
                    ghosts.append(ghost)
                }
            }
        }
#if DEBUG
        if traces {
            NSLog("YCODE_CANVAS_TRANSITION capture interrupted=%d ms=%.1f", wasTransitioning ? 1 : 0,
                  (CACurrentMediaTime() - started) * 1000)
        }
#endif
        return origins
    }

    private func startTransition(from origins: [ID: Origin]) {
        isTransitioning = true
        let token = generation
        let duration = duration
        let start = CACurrentMediaTime()
        let move = CAMediaTimingFunction(controlPoints: 0.2, 0.8, 0.2, 1)
        let fade = CAMediaTimingFunction(name: .easeInEaseOut)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for id in order {
            guard let pane = panes[id], let layer = pane.layer else { continue }
            guard let origin = origins[id] else {
                for view in [pane, pane.cardShadow] as [NSView] {
                    Self.fade(view, from: 0, to: 1, begin: start + duration * 0.35,
                              duration: duration * 0.55, timing: fade)
                }
                continue
            }
            if origin.frame != layer.frame {
                let position = CABasicAnimation(keyPath: "position")
                position.fromValue = NSValue(point: Self.position(of: origin.frame, anchor: layer.anchorPoint))
                position.toValue = NSValue(point: layer.position)
                let bounds = CABasicAnimation(keyPath: "bounds")
                bounds.fromValue = NSValue(rect: CGRect(origin: layer.bounds.origin, size: origin.frame.size))
                bounds.toValue = NSValue(rect: layer.bounds)
                let group = CAAnimationGroup()
                group.animations = [position, bounds]
                group.duration = duration
                group.beginTime = start
                group.timingFunction = move
                group.fillMode = .backwards
                pane.animatedOrigin = origin.frame
                layer.add(group, forKey: TandockCanvasPane.frameKey)
                pane.cardShadow.follow(group, from: origin.frame.size)
            }
            if origin.paneOpacity < 1 {
                for view in [pane, pane.cardShadow] as [NSView] {
                    Self.fade(view, from: origin.paneOpacity, to: 1, begin: start,
                              duration: duration * 0.6 * Double(1 - origin.paneOpacity), timing: fade)
                }
            }
            if let snapshot = pane.snapshot, let opacity = origin.snapshotOpacity, opacity > 0 {
                let fresh = opacity >= 1
                Self.fade(snapshot, from: opacity, to: 0, begin: start + (fresh ? duration * 0.55 : 0),
                          duration: duration * 0.35 * Double(opacity), timing: fade)
            }
        }
        for ghost in ghosts where ghost.alphaValue > 0 {
            Self.fade(ghost, from: Float(ghost.alphaValue), to: 0, begin: start,
                      duration: duration * 0.5 * Double(ghost.alphaValue), timing: fade)
        }
        CATransaction.commit()
        finishTimer?.invalidate()
        let timer = Timer(timeInterval: max(0, start + duration - CACurrentMediaTime()), repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.generation == token, self.isTransitioning else { return }
                self.finishTransition()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        finishTimer = timer
#if DEBUG
        if traces { NSLog("YCODE_CANVAS_TRANSITION begin generation=%d panes=%d", token, order.count) }
#endif
    }

    private func finishTransition() {
        finishTimer?.invalidate()
        finishTimer = nil
        withoutAnimation {
            for pane in panes.values { pane.endTransition() }
            ghosts.forEach { $0.removeFromSuperview() }
            ghosts.removeAll()
            for divider in dividers.values where divider.isHidden {
                divider.isHidden = false
                Self.fade(divider, from: 0, to: 1, begin: CACurrentMediaTime(), duration: 0.12,
                          timing: CAMediaTimingFunction(name: .easeOut))
            }
        }
        isTransitioning = false
#if DEBUG
        if traces { NSLog("YCODE_CANVAS_TRANSITION finish live=%d", panes.count) }
#endif
    }

    func cancelTransition() {
        guard isTransitioning || !ghosts.isEmpty || panes.values.contains(where: { $0.snapshot != nil }) else { return }
        generation += 1
        for pane in panes.values { pane.stopAnimations() }
        finishTransition()
    }

    private static func position(of frame: CGRect, anchor: CGPoint) -> CGPoint {
        CGPoint(x: frame.minX + frame.width * anchor.x, y: frame.minY + frame.height * anchor.y)
    }

    private static func fade(_ view: NSView, from: Float, to: Float, begin: CFTimeInterval,
                             duration: CFTimeInterval, timing: CAMediaTimingFunction) {
        view.alphaValue = CGFloat(to)
        guard let layer = view.layer, duration > 0 else { return }
        let animation = CABasicAnimation(keyPath: "opacity")
        animation.fromValue = from
        animation.toValue = to
        animation.beginTime = begin
        animation.duration = duration
        animation.timingFunction = timing
        animation.fillMode = .backwards
        layer.add(animation, forKey: TandockCanvasPane.fadeKey)
    }

    static func snapshot(_ host: NSView) -> (image: NSImage, background: NSColor)? {
        guard host.bounds.width > 0, host.bounds.height > 0,
              let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return nil }
        host.cacheDisplay(in: host.bounds, to: bitmap)
        guard let image = bitmap.cgImage else { return nil }
        var terminals: [TerminalView] = []
        func collect(_ parent: NSView) {
            for child in parent.subviews where !child.isHidden {
                if let terminal = child as? TerminalView { terminals.append(terminal) } else { collect(child) }
            }
        }
        collect(host)
        guard let first = terminals.first else {
            return (NSImage(cgImage: image, size: host.bounds.size), .windowBackgroundColor)
        }
        guard let context = CGContext(data: nil, width: image.width, height: image.height,
                                      bitsPerComponent: 8, bytesPerRow: 0,
                                      space: image.colorSpace ?? CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        let scale = CGFloat(image.width) / host.bounds.width
        context.saveGState()
        context.scaleBy(x: scale, y: scale)
        for terminal in terminals {
            var rect = host.convert(terminal.bounds, from: terminal)
            if host.isFlipped { rect.origin.y = host.bounds.height - rect.maxY }
            context.setFillColor(terminal.nativeBackgroundColor.cgColor)
            context.fill(rect)
        }
        context.restoreGState()
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        guard let composited = context.makeImage() else { return nil }
        return (NSImage(cgImage: composited, size: host.bounds.size), first.nativeBackgroundColor)
    }

    private func applyGeometry(_ geometry: TandockTerminalCanvasGeometry) {
        withoutAnimation {
            for (index, id) in order.enumerated() {
                guard index < geometry.frames.count else { continue }
                panes[id]?.frame = placed(geometry.frames[index])
            }
            refreshDividers(geometry, hidden: false)
        }
    }

    private func refreshDividers(_ geometry: TandockTerminalCanvasGeometry, hidden: Bool) {
        let ids = Set(geometry.dividers.map(\.id))
        for id in Array(dividers.keys) where !ids.contains(id) {
            dividers.removeValue(forKey: id)?.removeFromSuperview()
        }
        for divider in geometry.dividers {
            let view = dividers[divider.id] ?? TandockCanvasDivider(frame: .zero)
            // Dividers must stay above the cards, but re-adding one mid-drag resets its cursor rects.
            let topCard = subviews.lastIndex { !($0 is TandockCanvasDivider) } ?? -1
            if view.superview !== self || (subviews.firstIndex(of: view) ?? -1) < topCard { addSubview(view) }
            view.isVertical = divider.isVertical
            view.layoutFrame = placed(divider.frame)
            view.frame = grabFrame(for: view.layoutFrame, vertical: view.isVertical)
            view.isHidden = hidden
            view.setAccessibilityLabel(divider.isVertical ? columnLabel : rowLabel)
            view.onResize = { [weak self] delta in
                guard let self else { return }
                self.cancelTransition()
                self.weights[self.configuration, default: [:]][divider.group] = divider.resizedWeights(translation: delta)
                self.applyGeometry(self.geometry())
            }
            dividers[divider.id] = view
        }
        window?.invalidateCursorRects(for: self)
    }

    private func withoutAnimation(_ action: () -> Void) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0
            context.allowsImplicitAnimation = false
            action()
        }
        CATransaction.commit()
    }
}

@MainActor
final class TandockCanvasPane: NSView {
    static let frameKey = "canvas-frame"
    static let fadeKey = "canvas-fade"

    let host: NSHostingView<AnyView>
    let cardShadow = TandockCanvasShadow()
    private(set) var snapshot: TandockCanvasSnapshot?
    var animatedOrigin: CGRect?

    var isFocused = false {
        didSet {
            guard isFocused != oldValue else { return }
            cardShadow.isFocused = isFocused
            applyBorder()
        }
    }

    override var isFlipped: Bool { true }

    init(rootView: AnyView) {
        host = NSHostingView(rootView: rootView)
        host.sizingOptions = []
        super.init(frame: .zero)
        wantsLayer = true
        clipsToBounds = true
        layer?.cornerRadius = TandockCanvasShadow.cornerRadius
        layer?.cornerCurve = .continuous
        layer?.borderWidth = 1
        addSubview(host)
        applyBorder()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyBorder()
    }

    private func applyBorder() {
        let dark = effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        let color: NSColor = isFocused
            ? (NSColor(hex: dark ? "FF7D72" : "FF5A4E") ?? .systemRed)
            : (dark ? NSColor.white.withAlphaComponent(0.07)
                    : NSColor(srgbRed: 22 / 255, green: 19 / 255, blue: 58 / 255, alpha: 0.08))
        layer?.borderColor = color.cgColor
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func setFrameOrigin(_ newOrigin: NSPoint) {
        super.setFrameOrigin(newOrigin)
        cardShadow.setFrameOrigin(newOrigin)
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        host.frame = bounds
        cardShadow.setFrameSize(newSize)
    }

    func detach() {
        cardShadow.removeFromSuperview()
        removeFromSuperview()
    }

    private func presented(_ layer: CALayer, key: String) -> CALayer? {
        layer.animation(forKey: key) == nil ? layer : layer.presentation()
    }

    var visibleFrame: CGRect {
        guard let layer else { return frame }
        return presented(layer, key: Self.frameKey)?.frame ?? animatedOrigin ?? layer.frame
    }

    var visibleOpacity: Float {
        guard let layer else { return 1 }
        return presented(layer, key: Self.fadeKey)?.opacity ?? 0
    }

    var visibleSnapshotOpacity: Float? {
        guard let layer = snapshot?.layer else { return nil }
        return presented(layer, key: Self.fadeKey)?.opacity ?? 1
    }

    func showSnapshot(_ image: NSImage, background: NSColor, coverage: CGSize) {
        let view = TandockCanvasSnapshot(image: image, background: background, coverage: coverage)
        addSubview(view, positioned: .above, relativeTo: host)
        snapshot = view
        layer?.backgroundColor = background.cgColor
    }

    func stopAnimations() {
        layer?.removeAnimation(forKey: Self.frameKey)
        layer?.removeAnimation(forKey: Self.fadeKey)
        snapshot?.layer?.removeAnimation(forKey: Self.fadeKey)
        cardShadow.stopAnimations()
        animatedOrigin = nil
    }

    func endTransition() {
        stopAnimations()
        alphaValue = 1
        cardShadow.alphaValue = 1
        snapshot?.removeFromSuperview()
        snapshot = nil
        layer?.backgroundColor = nil
    }
}

@MainActor
final class TandockCanvasShadow: NSView {
    static let cornerRadius: CGFloat = TandockMetrics.radiusCard
    private static let pathKey = "canvas-shadow-path"

    var isFocused = false {
        didSet { if isFocused != oldValue { applyStyle() } }
    }

    override var isFlipped: Bool { true }

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        clipsToBounds = false
        setAccessibilityElement(false)
        applyStyle()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        layer?.shadowPath = Self.path(for: newSize)
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyStyle()
    }

    private static func path(for size: CGSize) -> CGPath {
        CGPath(roundedRect: CGRect(origin: .zero, size: size), cornerWidth: cornerRadius,
               cornerHeight: cornerRadius, transform: nil)
    }

    private func applyStyle() {
        guard let layer else { return }
        let dark = effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        if isFocused {
            layer.shadowColor = (NSColor(hex: dark ? "FF7D72" : "FF5A4E") ?? .systemRed).cgColor
            layer.shadowOpacity = dark ? 0.55 : 0.4
            layer.shadowRadius = 5
            layer.shadowOffset = .zero
        } else {
            layer.shadowColor = (dark ? NSColor.black : NSColor(srgbRed: 22 / 255, green: 19 / 255, blue: 58 / 255, alpha: 1)).cgColor
            layer.shadowOpacity = dark ? 0.35 : 0.12
            layer.shadowRadius = 5
            layer.shadowOffset = CGSize(width: 0, height: 2)
        }
    }

    func follow(_ frame: CAAnimationGroup, from size: CGSize) {
        guard let layer else { return }
        layer.add(frame, forKey: TandockCanvasPane.frameKey)
        let path = CABasicAnimation(keyPath: "shadowPath")
        path.fromValue = Self.path(for: size)
        path.toValue = layer.shadowPath
        path.duration = frame.duration
        path.beginTime = frame.beginTime
        path.timingFunction = frame.timingFunction
        path.fillMode = .backwards
        layer.add(path, forKey: Self.pathKey)
    }

    func stopAnimations() {
        layer?.removeAnimation(forKey: TandockCanvasPane.frameKey)
        layer?.removeAnimation(forKey: TandockCanvasPane.fadeKey)
        layer?.removeAnimation(forKey: Self.pathKey)
    }
}

@MainActor
final class TandockCanvasSnapshot: NSView {
    let image: NSImage

    init(image: NSImage, background: NSColor, coverage: CGSize) {
        self.image = image
        super.init(frame: CGRect(origin: .zero, size: CGSize(width: max(image.size.width, coverage.width),
                                                              height: max(image.size.height, coverage.height))))
        wantsLayer = true
        layerContentsRedrawPolicy = .never
        layer?.backgroundColor = background.cgColor
        let pixels = TandockCanvasBitmap(frame: CGRect(origin: .zero, size: image.size))
        pixels.layer?.contents = image.cgImage(forProposedRect: nil, context: nil, hints: nil)
        pixels.layer?.contentsScale = image.representations.first
            .map { CGFloat($0.pixelsWide) / max(1, image.size.width) } ?? 2
        addSubview(pixels)
        setAccessibilityElement(false)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func cover(_ size: CGSize) {
        setFrameSize(CGSize(width: max(frame.width, size.width), height: max(frame.height, size.height)))
    }

    override var isFlipped: Bool { true }
    override var wantsUpdateLayer: Bool { true }
    override func updateLayer() {}
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

@MainActor
private final class TandockCanvasBitmap: NSView {
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layerContentsRedrawPolicy = .never
        layer?.contentsGravity = .resize
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var isFlipped: Bool { true }
    override var wantsUpdateLayer: Bool { true }
    override func updateLayer() {}
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

@MainActor
private final class TandockCanvasGhost: NSView {
    override var isFlipped: Bool { true }

    init(frame: CGRect, image: NSImage, background: NSColor) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.cornerRadius = TandockCanvasShadow.cornerRadius
        layer?.cornerCurve = .continuous
        clipsToBounds = true
        layer?.backgroundColor = background.cgColor
        addSubview(TandockCanvasSnapshot(image: image, background: background, coverage: frame.size))
        setAccessibilityElement(false)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    func freeze() {
        guard let layer else { return }
        let opacity = (layer.animation(forKey: TandockCanvasPane.fadeKey) == nil ? layer : layer.presentation())?.opacity
        layer.removeAnimation(forKey: TandockCanvasPane.fadeKey)
        alphaValue = CGFloat(opacity ?? Float(alphaValue))
    }
}

@MainActor
private final class TandockCanvasDivider: NSView {
    var isVertical = true {
        didSet { if isVertical != oldValue { window?.invalidateCursorRects(for: self) } }
    }
    var layoutFrame = CGRect.zero
    var onResize: ((CGFloat) -> Void)?
    private var dragOrigin = CGPoint.zero
    private var dragResize: ((CGFloat) -> Void)?
    override var isFlipped: Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setAccessibilityElement(true)
        setAccessibilityRole(.splitter)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.cursorUpdate, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self))
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    var resizeCursor: NSCursor { isVertical ? .resizeLeftRight : .resizeUpDown }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: resizeCursor)
    }

    // Unhandled cursor updates travel up to the SwiftUI hosting view, which resets the pointer to an arrow.
    override func cursorUpdate(with event: NSEvent) { resizeCursor.set() }
    override func mouseEntered(with event: NSEvent) { resizeCursor.set() }

    override func mouseDown(with event: NSEvent) {
        dragOrigin = event.locationInWindow
        dragResize = onResize
        resizeCursor.set()
    }

    override func mouseDragged(with event: NSEvent) {
        resizeCursor.set()
        let delta = isVertical ? event.locationInWindow.x - dragOrigin.x : dragOrigin.y - event.locationInWindow.y
        dragResize?(delta)
    }

    override func mouseUp(with event: NSEvent) {
        dragResize = nil
        window?.invalidateCursorRects(for: self)
    }
    override func accessibilityPerformIncrement() -> Bool { onResize?(20); return true }
    override func accessibilityPerformDecrement() -> Bool { onResize?(-20); return true }
}

private extension NSView {
    var isInteractiveControl: Bool {
        var view: NSView? = self
        while let current = view {
            if current is NSScroller || current is NSControl { return true }
            view = current.superview
        }
        return false
    }
}
