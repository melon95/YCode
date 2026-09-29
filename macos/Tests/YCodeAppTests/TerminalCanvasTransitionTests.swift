import AppKit
import QuartzCore
import SwiftUI
import SwiftTerm
import Testing
@testable import YCodeApp
import YCodeCore

@Suite("Native canvas transitions", .serialized)
@MainActor
struct TerminalCanvasTransitionTests {
    private func fixture() -> (NSWindow, YCodeCanvasHost<String>) {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1000, height: 700),
                              styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let canvas = YCodeCanvasHost<String>(frame: NSRect(x: 0, y: 0, width: 1000, height: 700))
        window.contentView = canvas
        return (window, canvas)
    }

    private func update(_ canvas: YCodeCanvasHost<String>, _ mode: YCodeTerminalLayout,
                        ids: [String] = ["one", "two"], reduced: Bool = false) {
        canvas.update(panes: ids.enumerated().map { index, id in
            (id, AnyView((index == 0 ? Color.red : Color.blue).overlay(Text(id))))
        }, layout: mode, reduceMotion: reduced, columnLabel: "Column", rowLabel: "Row")
        canvas.layoutSubtreeIfNeeded()
    }

    private func slots(_ canvas: YCodeCanvasHost<String>) -> [YCodeCanvasPane] {
        canvas.subviews.compactMap { $0 as? YCodeCanvasPane }
    }

    private func live(_ canvas: YCodeCanvasHost<String>) -> [NSHostingView<AnyView>] {
        slots(canvas).map(\.host)
    }

    private func snapshots(_ canvas: YCodeCanvasHost<String>) -> [YCodeCanvasSnapshot] {
        slots(canvas).compactMap(\.snapshot)
    }

    private func frameAnimation(_ pane: YCodeCanvasPane) throws -> (position: CABasicAnimation, bounds: CABasicAnimation) {
        let group = try #require(pane.layer?.animation(forKey: YCodeCanvasPane.frameKey) as? CAAnimationGroup)
        let position = try #require(group.animations?.first as? CABasicAnimation)
        let bounds = try #require(group.animations?.last as? CABasicAnimation)
        return (position, bounds)
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
        // Terminals are resized once, to the destination, and stay visible.
        #expect(live(canvas).allSatisfy { $0.frame.width == 1000 && $0.alphaValue == 1 })
        #expect(snapshots(canvas).count == 2)
        for (index, pane) in slots(canvas).enumerated() {
            let snapshot = try #require(pane.snapshot)
            #expect(snapshot.image.size == oldFrames[index].size)
            // The old pixels plus their background cover every intermediate slot size.
            #expect(snapshot.frame.origin == .zero)
            #expect(snapshot.frame.width == max(oldFrames[index].width, pane.frame.width))
            #expect(snapshot.frame.height == max(oldFrames[index].height, pane.frame.height))
            #expect(snapshot.alphaValue == 0)
            #expect(snapshot.layer?.animation(forKey: YCodeCanvasPane.fadeKey) != nil)
            // Flipped geometry keeps cropped content pinned to the visual top-left.
            #expect(pane.layer?.contentsAreFlipped() == true)
            // The live destination-sized content must not spill over neighbours.
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
        // The visible pixels are reused rather than re-captured from the hidden future.
        #expect(snapshots(canvas).map(ObjectIdentifier.init) == firstSnapshots)
        for (index, pane) in slots(canvas).enumerated() {
            // Back at the original layout: nothing visibly moved yet, so nothing moves.
            #expect(pane.frame == initial[index])
            #expect(pane.layer?.animation(forKey: YCodeCanvasPane.frameKey) == nil)
        }
        #expect(snapshots(canvas).allSatisfy { $0.layer?.animation(forKey: YCodeCanvasPane.fadeKey) != nil })
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
        let animations = slots(canvas).map { $0.layer?.animation(forKey: YCodeCanvasPane.frameKey) }
        update(canvas, .stack)
        #expect(snapshots(canvas).map(ObjectIdentifier.init) == before)
        #expect(slots(canvas).map { $0.layer?.animation(forKey: YCodeCanvasPane.frameKey) } .count == animations.count)
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
        // Only the existing pane needs old pixels; the new one fades in live.
        #expect(snapshots(canvas).count == 1)
        let added = slots(canvas).first { $0.host !== first }
        #expect(added?.layer?.animation(forKey: YCodeCanvasPane.fadeKey) != nil)
        canvas.cancelTransition()
        update(canvas, .single, ids: ["one"])
        #expect(live(canvas).count == 1)
        #expect(live(canvas).first === first)
        let ghosts = canvas.subviews.filter { !($0 is YCodeCanvasPane) && $0.alphaValue == 0 }
        #expect(ghosts.count == 1)
        canvas.cancelTransition()
        #expect(snapshots(canvas).isEmpty)
        #expect(canvas.subviews.count == 1)
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
        // The glyphs are part of the same pass, drawn over the background.
        var dark = 0
        for x in stride(from: 0, to: min(400, image.width), by: 1) {
            if let color = pixels.colorAt(x: x, y: 8)?.usingColorSpace(.deviceRGB), color.redComponent < 0.5 { dark += 1 }
        }
        #expect(dark > 0)
        #expect(snapshot.size == CGSize(width: 497.5, height: 700))
    }
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
