import AppKit
import QuartzCore
import SwiftUI
import SwiftTerm
import Testing
@testable import TandockApp
import TandockCore

@Suite("Native canvas transitions", .serialized)
@MainActor
struct TerminalCanvasTransitionTests {
    private func fixture() -> (NSWindow, TandockCanvasHost<String>) {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1000, height: 700),
                              styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let canvas = TandockCanvasHost<String>(frame: NSRect(x: 0, y: 0, width: 1000, height: 700))
        window.contentView = canvas
        return (window, canvas)
    }

    private func update(_ canvas: TandockCanvasHost<String>, _ mode: TandockTerminalLayout,
                        ids: [String] = ["one", "two"], reduced: Bool = false) {
        canvas.update(panes: ids.enumerated().map { index, id in
            (id, AnyView((index == 0 ? Color.red : Color.blue).overlay(Text(id))))
        }, layout: mode, reduceMotion: reduced, columnLabel: "Column", rowLabel: "Row")
        canvas.layoutSubtreeIfNeeded()
    }

    private var contentWidth: CGFloat {
        1000 - TandockCanvasHost<String>.insets.left - TandockCanvasHost<String>.insets.right
    }

    private func slots(_ canvas: TandockCanvasHost<String>) -> [TandockCanvasPane] {
        canvas.subviews.compactMap { $0 as? TandockCanvasPane }
    }

    private func live(_ canvas: TandockCanvasHost<String>) -> [NSHostingView<AnyView>] {
        slots(canvas).map(\.host)
    }

    private func snapshots(_ canvas: TandockCanvasHost<String>) -> [TandockCanvasSnapshot] {
        slots(canvas).compactMap(\.snapshot)
    }

    private func frameAnimation(_ pane: TandockCanvasPane) throws -> (position: CABasicAnimation, bounds: CABasicAnimation) {
        let group = try #require(pane.layer?.animation(forKey: TandockCanvasPane.frameKey) as? CAAnimationGroup)
        let position = try #require(group.animations?.first as? CABasicAnimation)
        let bounds = try #require(group.animations?.last as? CABasicAnimation)
        return (position, bounds)
    }

    @Test("the fourth-session picker and created terminal occupy identical grid frames")
    func fourthSessionReplacesPickerWithoutReflow() {
        let (window, canvas) = fixture()
        defer { canvas.cancelTransition(); window.close() }
        update(canvas, .mainSide, ids: ["one", "two", "three"], reduced: true)
        let preview = TandockTerminalLayout.reflow(.mainSide, from: 3, to: 4)
        update(canvas, preview, ids: ["one", "two", "three", "picker"], reduced: true)
        let previewFrames = slots(canvas).map(\.frame)
        let existingHosts = live(canvas).prefix(3).map(ObjectIdentifier.init)
        #expect(previewFrames.count == 4)
        #expect(previewFrames[0].height == previewFrames[3].height)
        #expect(previewFrames[2].minY == previewFrames[3].minY)
        #expect(previewFrames[3].width == previewFrames[1].width)

        update(canvas, .grid2x2, ids: ["one", "two", "three", "four"], reduced: true)
        #expect(slots(canvas).map(\.frame) == previewFrames)
        #expect(live(canvas).prefix(3).map(ObjectIdentifier.init) == existingHosts)
        #expect(!canvas.isTransitioning)
    }

    @Test("tab switching retains pane hosts and exposes only the focused content")
    func tabVisibilityAndViewIdentity() {
        let (window, canvas) = fixture()
        defer { canvas.cancelTransition(); window.close() }
        let ids = (1...6).map { "tab-\($0)" }
        func select(_ id: String) {
            canvas.update(panes: ids.map { ($0, AnyView(Text($0))) }, layout: .tabs, focusedID: id,
                          reduceMotion: false, columnLabel: "Column", rowLabel: "Row")
        }
        select(ids[2])
        let originalHosts = live(canvas).map(ObjectIdentifier.init)
        #expect(slots(canvas).count == 6)
        #expect(slots(canvas).enumerated().filter { !$0.element.isHidden }.map(\.offset) == [2])
        select(ids[5])
        #expect(live(canvas).map(ObjectIdentifier.init) == originalHosts)
        #expect(slots(canvas).enumerated().filter { !$0.element.isHidden }.map(\.offset) == [5])
        #expect(!canvas.isTransitioning)
        update(canvas, .grid2x2, ids: Array(ids.prefix(4)))
        #expect(slots(canvas).count == 4)
        #expect(slots(canvas).allSatisfy { !$0.isHidden })
        #expect(!canvas.isTransitioning)
    }

    @Test("live panes jump to their destination while old pixels cover them at the original size")
    func liveDestinationUnderSnapshot() throws {
        let (window, canvas) = fixture()
        defer { canvas.cancelTransition(); window.close() }
        update(canvas, .columns)
        let oldHosts = live(canvas)
        let oldFrames = slots(canvas).map(\.frame)
        update(canvas, .stack)
        #expect(canvas.isTransitioning)
        #expect(live(canvas).map(ObjectIdentifier.init) == oldHosts.map(ObjectIdentifier.init))
        #expect(live(canvas).allSatisfy { $0.frame.width == contentWidth && $0.alphaValue == 1 })
        #expect(snapshots(canvas).count == 2)
        for (index, pane) in slots(canvas).enumerated() {
            let snapshot = try #require(pane.snapshot)
            #expect(snapshot.image.size == oldFrames[index].size)
            #expect(snapshot.frame.origin == .zero)
            #expect(snapshot.frame.width == max(oldFrames[index].width, pane.frame.width))
            #expect(snapshot.frame.height == max(oldFrames[index].height, pane.frame.height))
            #expect(snapshot.alphaValue == 0)
            #expect(snapshot.layer?.animation(forKey: TandockCanvasPane.fadeKey) != nil)
            #expect(pane.layer?.contentsAreFlipped() == true)
            window.displayIfNeeded()
            #expect(pane.clipsToBounds)
            #expect(pane.layer?.masksToBounds == true)
            let animation = try frameAnimation(pane)
            #expect((animation.bounds.fromValue as? NSValue)?.rectValue.size == oldFrames[index].size)
            #expect((animation.position.fromValue as? NSValue)?.pointValue == oldFrames[index].origin)
            #expect((animation.bounds.toValue as? NSValue)?.rectValue.size == pane.frame.size)
        }
    }

    @Test("retargeting before the first render starts at the original visible frame")
    func retargetBeforeCommit() throws {
        let (window, canvas) = fixture()
        defer { canvas.cancelTransition(); window.close() }
        update(canvas, .columns)
        let initial = slots(canvas).map(\.frame)
        update(canvas, .stack)
        let firstSnapshots = snapshots(canvas).map(ObjectIdentifier.init)
        update(canvas, .columns)
        #expect(snapshots(canvas).map(ObjectIdentifier.init) == firstSnapshots)
        for (index, pane) in slots(canvas).enumerated() {
            #expect(pane.frame == initial[index])
            #expect(pane.layer?.animation(forKey: TandockCanvasPane.frameKey) == nil)
        }
        #expect(snapshots(canvas).allSatisfy { $0.layer?.animation(forKey: TandockCanvasPane.fadeKey) != nil })
    }

    @Test("retargeting to a third layout starts from the original visible frame")
    func retargetToThirdLayout() throws {
        let (window, canvas) = fixture()
        defer { canvas.cancelTransition(); window.close() }
        let ids = ["one", "two", "three"]
        update(canvas, .columns, ids: ids)
        let initial = slots(canvas).map(\.frame)
        update(canvas, .stack, ids: ids)
        update(canvas, .mainSide, ids: ids)
        for (index, pane) in slots(canvas).enumerated() where pane.frame != initial[index] {
            let animation = try frameAnimation(pane)
            #expect((animation.position.fromValue as? NSValue)?.pointValue == initial[index].origin)
            #expect((animation.bounds.fromValue as? NSValue)?.rectValue.size == initial[index].size)
        }
    }

    @Test("content refreshes do not restart an in-flight layout transition")
    func refreshKeepsSurfaces() {
        let (window, canvas) = fixture()
        defer { canvas.cancelTransition(); window.close() }
        update(canvas, .columns)
        update(canvas, .stack)
        let before = snapshots(canvas).map(ObjectIdentifier.init)
        let animations = slots(canvas).map { $0.layer?.animation(forKey: TandockCanvasPane.frameKey) }
        update(canvas, .stack)
        #expect(snapshots(canvas).map(ObjectIdentifier.init) == before)
        #expect(slots(canvas).map { $0.layer?.animation(forKey: TandockCanvasPane.frameKey) } .count == animations.count)
        #expect(canvas.isTransitioning)
        canvas.cancelTransition()
        #expect(snapshots(canvas).isEmpty)
        #expect(!canvas.isTransitioning)
        #expect(slots(canvas).allSatisfy { $0.layer?.animationKeys()?.isEmpty ?? true })
    }

    @Test("reduced motion immediately presents the new layout and releases surfaces")
    func reducedMotionCancels() {
        let (window, canvas) = fixture()
        defer { canvas.cancelTransition(); window.close() }
        update(canvas, .columns)
        update(canvas, .stack)
        update(canvas, .columns, reduced: true)
        #expect(snapshots(canvas).isEmpty)
        #expect(!canvas.isTransitioning)
        #expect(live(canvas).allSatisfy { $0.alphaValue == 1 && $0.frame.width < 500 })
    }

    @Test("adding then removing a pane keeps retained hosting views and fades the leaver out")
    func paneIdentity() {
        let (window, canvas) = fixture()
        defer { canvas.cancelTransition(); window.close() }
        update(canvas, .single, ids: ["one"])
        let first = live(canvas).first
        update(canvas, .columns)
        #expect(live(canvas).count == 2)
        #expect(live(canvas).contains { $0 === first })
        #expect(snapshots(canvas).count == 1)
        let added = slots(canvas).first { $0.host !== first }
        #expect(added?.layer?.animation(forKey: TandockCanvasPane.fadeKey) != nil)
        canvas.cancelTransition()
        update(canvas, .single, ids: ["one"])
        #expect(live(canvas).count == 1)
        #expect(live(canvas).first === first)
        let ghosts = canvas.subviews.filter { !($0 is TandockCanvasPane) && $0.alphaValue == 0 }
        #expect(ghosts.count == 1)
        canvas.cancelTransition()
        #expect(snapshots(canvas).isEmpty)
        #expect(canvas.subviews.count == 2)
        #expect(slots(canvas).first.map { canvas.subviews.contains($0.cardShadow) } == true)
        #expect(slots(canvas).first?.alphaValue == 1)
    }

    @Test("native terminal snapshots preserve their backing-layer background")
    func terminalBackground() throws {
        let (window, canvas) = fixture()
        defer { canvas.cancelTransition(); window.close() }
        let panes = [("one", AnyView(CanvasTestTerminal())), ("two", AnyView(Color.blue))]
        canvas.update(panes: panes, layout: .columns, reduceMotion: false, columnLabel: "Column", rowLabel: "Row")
        canvas.layoutSubtreeIfNeeded()
        canvas.update(panes: panes, layout: .stack, reduceMotion: false, columnLabel: "Column", rowLabel: "Row")
        let snapshot = try #require(snapshots(canvas).first?.image)
        let image = try #require(snapshot.cgImage(forProposedRect: nil, context: nil, hints: nil))
        let pixels = NSBitmapImageRep(cgImage: image)
        let pixel = try #require(pixels.colorAt(x: 20, y: image.height / 2)?.usingColorSpace(.deviceRGB))
        #expect(pixel.redComponent > 0.99 && pixel.greenComponent > 0.99 && pixel.blueComponent > 0.99)
        #expect(pixel.alphaComponent > 0.99)
        var dark = 0
        for x in stride(from: 0, to: min(400, image.width), by: 1) {
            if let color = pixels.colorAt(x: x, y: 8)?.usingColorSpace(.deviceRGB), color.redComponent < 0.5 { dark += 1 }
        }
        #expect(dark > 0)
        let insets = TandockCanvasHost<String>.insets
        #expect(snapshot.size == CGSize(width: (contentWidth - TandockCanvasHost<String>.paneGap) / 2,
                                        height: 700 - insets.top - insets.bottom))
    }

    @Test("card edges in the hosted canvas grab the divider and the drag stays with the pointer")
    func hostedDividerTracksPointer() throws {
        let (window, canvas) = try hostedFixture()
        defer { canvas.cancelTransition(); window.close() }
        try expectHostedDrag(canvas, vertical: true, distance: 48)
        canvas.update(panes: [("one", AnyView(Color.red)), ("two", AnyView(Color.blue))],
                      layout: .stack, reduceMotion: true, columnLabel: "Column", rowLabel: "Row")
        canvas.layoutSubtreeIfNeeded()
        try expectHostedDrag(canvas, vertical: false, distance: 40)
    }

    private func hostedFixture() throws -> (NSWindow, TandockCanvasHost<String>) {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: NSRect(x: -4000, y: -4000, width: 1100, height: 800),
                              styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.alphaValue = 0
        window.orderFrontRegardless()
        let root = NSHostingView(rootView: VStack(spacing: 0) {
            Color.clear.frame(height: 44)
            TerminalCanvasView(panes: [ProbePane(id: "one"), ProbePane(id: "two")], layout: .columns, focusedID: "one") { pane in
                pane.id == "one" ? Color.red : Color.blue
            }
        })
        root.frame = NSRect(x: 36, y: 28, width: 1000, height: 700)
        let content = NSView(frame: NSRect(x: 0, y: 0, width: 1100, height: 800))
        content.addSubview(root)
        window.contentView = content
        root.layoutSubtreeIfNeeded()
        window.layoutIfNeeded()
        let canvas = try #require(findCanvas(root))
        canvas.layoutSubtreeIfNeeded()
        return (window, canvas)
    }

    private func findCanvas(_ view: NSView) -> TandockCanvasHost<String>? {
        if let canvas = view as? TandockCanvasHost<String> { return canvas }
        for child in view.subviews {
            if let found = findCanvas(child) { return found }
        }
        return nil
    }

    private func expectHostedDrag(_ canvas: TandockCanvasHost<String>, vertical: Bool, distance: CGFloat) throws {
        let panes = slots(canvas).sorted { vertical ? $0.frame.minX < $1.frame.minX : $0.frame.minY < $1.frame.minY }
        let splitter = try #require(canvas.subviews.first {
            $0.accessibilityRole() == .splitter && (vertical ? $0.frame.width < $0.frame.height : $0.frame.height < $0.frame.width)
        })
        let window = try #require(canvas.window)
        let before = panes[0].frame
        let leading = vertical
            ? CGPoint(x: panes[0].frame.maxX - 3, y: panes[0].frame.midY)
            : CGPoint(x: panes[0].frame.midX, y: panes[0].frame.maxY - 3)
        let trailing = vertical
            ? CGPoint(x: panes[1].frame.minX + 3, y: panes[1].frame.midY)
            : CGPoint(x: panes[1].frame.midX, y: panes[1].frame.minY + 3)
        let interior = vertical
            ? CGPoint(x: panes[0].frame.maxX - TandockCanvasHost<String>.dividerGrabOutset - 10, y: panes[0].frame.midY)
            : CGPoint(x: panes[0].frame.midX, y: panes[0].frame.maxY - TandockCanvasHost<String>.dividerGrabOutset - 10)
        #expect(window.contentView?.hitTest(canvas.convert(leading, to: nil)) === splitter)
        #expect(window.contentView?.hitTest(canvas.convert(trailing, to: nil)) === splitter)
        #expect(window.contentView?.hitTest(canvas.convert(interior, to: nil)) !== splitter)
        let start = canvas.convert(leading, to: nil)
        let end = vertical ? NSPoint(x: start.x + distance, y: start.y) : NSPoint(x: start.x, y: start.y - distance)
        // The hosting view resets unclaimed cursor updates to an arrow, so the splitter must answer them itself.
        let resizeCursor: NSCursor = vertical ? .resizeLeftRight : .resizeUpDown
        #expect(splitter.trackingAreas.contains { $0.options.contains(.cursorUpdate) })
        NSCursor.arrow.set()
        splitter.cursorUpdate(with: try mouse(.mouseMoved, end: start, window: window))
        #expect(NSCursor.current == resizeCursor)
        NSApp.sendEvent(try mouse(.leftMouseDown, end: start, window: window))
        NSApp.sendEvent(try mouse(.leftMouseDragged, end: end, window: window))
        NSApp.sendEvent(try mouse(.leftMouseUp, end: end, window: window))
        canvas.layoutSubtreeIfNeeded()
        let after = panes[0].frame
        if vertical {
            #expect(abs(after.width - before.width - distance) < 0.5, "before=\(before) after=\(after)")
            #expect(abs(after.minX - before.minX) < 0.5)
        } else {
            #expect(abs(after.height - before.height - distance) < 0.5, "before=\(before) after=\(after)")
            #expect(abs(after.minY - before.minY) < 0.5)
        }
        #expect(window.contentView?.hitTest(end) === splitter)
    }

    @Test("a row gap wins over a column divider's grab band where they meet")
    func gridGapWinsAtTheCross() throws {
        let (window, canvas) = fixture()
        defer { canvas.cancelTransition(); window.close() }
        update(canvas, .grid2x2, ids: ["one", "two", "three", "four"], reduced: true)
        let horizontal = try #require(canvas.subviews.first {
            $0.accessibilityRole() == .splitter && $0.frame.height < $0.frame.width
        })
        let vertical = try #require(canvas.subviews.filter {
            $0.accessibilityRole() == .splitter && $0.frame.width < $0.frame.height
        }.min { $0.frame.midY < $1.frame.midY })
        let cross = canvas.convert(CGPoint(x: vertical.frame.midX, y: horizontal.frame.midY), to: nil)
        #expect(window.contentView?.hitTest(cross) === horizontal)
        let column = canvas.convert(CGPoint(x: vertical.frame.midX, y: vertical.frame.midY), to: nil)
        #expect(window.contentView?.hitTest(column) === vertical)
    }

    @Test("divider drag tracks the pointer in both axes and stays in the gap")
    func dividerTracksPointer() throws {
        let (window, canvas) = fixture()
        defer { canvas.cancelTransition(); window.close() }
        update(canvas, .columns, reduced: true)
        try expectDrag(canvas, vertical: true, distance: 36)
        update(canvas, .stack, reduced: true)
        try expectDrag(canvas, vertical: false, distance: 28)
    }

    @Test("a scroller at the card edge keeps its clicks inside the divider grab band")
    func scrollerBeatsGrabBand() throws {
        let (window, canvas) = fixture()
        defer { canvas.cancelTransition(); window.close() }
        update(canvas, .columns, reduced: true)
        let panes = slots(canvas).sorted { $0.frame.minX < $1.frame.minX }
        let splitter = try #require(canvas.subviews.first { $0.accessibilityRole() == .splitter && $0.frame.width < $0.frame.height })
        let scroller = NSScroller(frame: NSRect(x: panes[0].bounds.maxX - 10, y: 0, width: 10, height: panes[0].bounds.height))
        panes[0].addSubview(scroller)
        let edge = panes[0].convert(CGPoint(x: panes[0].bounds.maxX - 3, y: panes[0].bounds.midY), to: nil)
        let hit = window.contentView?.hitTest(edge)
        #expect(hit === scroller, "hit=\(String(describing: hit.map { type(of: $0) }))")
        let gapCenter = splitter.convert(CGPoint(x: splitter.bounds.midX, y: splitter.bounds.midY), to: nil)
        #expect(window.contentView?.hitTest(gapCenter) === splitter)
        let plainEdge = panes[1].convert(CGPoint(x: 3, y: panes[1].bounds.midY), to: nil)
        #expect(window.contentView?.hitTest(plainEdge) === splitter)
    }

    private func expectDrag(_ canvas: TandockCanvasHost<String>, vertical: Bool, distance: CGFloat) throws {
        let panes = slots(canvas).sorted { vertical ? $0.frame.minX < $1.frame.minX : $0.frame.minY < $1.frame.minY }
        let splitter = try #require(canvas.subviews.first {
            $0.accessibilityRole() == .splitter && (vertical ? $0.frame.width < $0.frame.height : $0.frame.height < $0.frame.width)
        })
        let gap = TandockCanvasHost<String>.paneGap
        let outset = TandockCanvasHost<String>.dividerGrabOutset
        if vertical {
            #expect(abs(panes[1].frame.minX - panes[0].frame.maxX - gap) < 0.5)
            #expect(abs(splitter.frame.midX - panes[0].frame.maxX - gap / 2) < 0.5)
            #expect(abs(splitter.frame.width - gap - outset * 2) < 0.5)
        } else {
            #expect(abs(panes[1].frame.minY - panes[0].frame.maxY - gap) < 0.5)
            #expect(abs(splitter.frame.midY - panes[0].frame.maxY - gap / 2) < 0.5)
            #expect(abs(splitter.frame.height - gap - outset * 2) < 0.5)
        }
        let window = try #require(canvas.window)
        let before = panes[0].frame
        let start = splitter.convert(CGPoint(x: splitter.bounds.midX, y: splitter.bounds.midY), to: nil)
        let startHit = window.contentView?.hitTest(start)
        #expect(startHit === splitter, "vertical=\(vertical) startHit=\(String(describing: type(of: startHit)))")
        let end = vertical ? NSPoint(x: start.x + distance, y: start.y) : NSPoint(x: start.x, y: start.y - distance)
        splitter.mouseDown(with: try mouse(.leftMouseDown, end: start, window: window))
        splitter.mouseDragged(with: try mouse(.leftMouseDragged, end: end, window: window))
        let after = panes[0].frame
        if vertical {
            #expect(abs(after.width - before.width - distance) < 0.5)
            #expect(abs(after.minX - before.minX) < 0.5)
        } else {
            #expect(abs(after.height - before.height - distance) < 0.5)
            #expect(abs(after.minY - before.minY) < 0.5)
        }
        let hitView = window.contentView?.hitTest(end)
        #expect(hitView === splitter, "vertical=\(vertical) hit=\(String(describing: type(of: hitView))) point=\(end) splitter=\(splitter.frame)")
    }

    private func mouse(_ type: NSEvent.EventType, end: NSPoint, window: NSWindow) throws -> NSEvent {
        try #require(NSEvent.mouseEvent(with: type, location: end, modifierFlags: [], timestamp: 0,
            windowNumber: window.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: 1))
    }
}

private struct ProbePane: Identifiable {
    let id: String
}

private struct CanvasTestTerminal: NSViewRepresentable {
    func makeNSView(context: Context) -> TerminalView {
        let view = TerminalView(frame: .zero)
        view.nativeBackgroundColor = .white
        view.nativeForegroundColor = .black
        view.feed(text: "Canvas terminal snapshot")
        return view
    }
    func updateNSView(_ view: TerminalView, context: Context) {}
}
