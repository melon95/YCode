import AppKit
import SwiftUI
import Testing
@testable import TandockApp

@Suite("Sidebar overlay layout", .serialized)
@MainActor
struct SidebarOverlayTests {
    private final class Probe {
        var view: NSView?
        var creations = 0
    }

    private struct MeasuredView: NSViewRepresentable {
        let probe: Probe
        func makeNSView(context: Context) -> NSView {
            let view = NSView()
            probe.view = view
            probe.creations += 1
            return view
        }
        func updateNSView(_ view: NSView, context: Context) {}
    }

    @MainActor
    private final class Fixture {
        let presentation = TandockSidebarPresentation()
        let sidebar = Probe()
        let detail = Probe()
        let window: NSWindow
        let host: NSHostingView<AnyView>

        init(width: CGFloat) {
            _ = NSApplication.shared
            presentation.isExpanded = false
            window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: width, height: 700),
                              styleMask: .borderless, backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            let sidebarProbe = sidebar, detailProbe = detail
            host = NSHostingView(rootView: AnyView(TandockSidebarLayout(presentation: presentation) {
                MeasuredView(probe: sidebarProbe)
            } detail: {
                MeasuredView(probe: detailProbe)
            }))
            host.sizingOptions = []
            window.contentView = host
            host.frame = NSRect(x: 0, y: 0, width: width, height: 700)
        }

        func settle() async throws {
            try await Task.sleep(for: .milliseconds(300))
            host.layoutSubtreeIfNeeded()
        }

        /// Polls until `done` holds, for at most two seconds. A fixed sleep raced the
        /// 220 ms dismissal timer and the slide animation when suites ran in parallel.
        func settle(until done: () throws -> Bool) async throws {
            let deadline = ContinuousClock.now + .seconds(2)
            repeat {
                try await Task.sleep(for: .milliseconds(20))
                host.layoutSubtreeIfNeeded()
            } while (try? done()) != true && ContinuousClock.now < deadline
        }

        func frame(of probe: Probe) throws -> NSRect {
            let view = try #require(probe.view)
            return view.convert(view.bounds, to: host)
        }

        func close() {
            presentation.dismissPreview()
            window.close()
        }
    }

    @Test("edge hover overlays the sidebar without moving, resizing or recreating the detail host",
          arguments: [CGFloat(720), CGFloat(1240)])
    func hoverKeepsDetailFrame(width: CGFloat) async throws {
        let f = Fixture(width: width)
        defer { f.close() }
        try await f.settle()
        let before = try f.frame(of: f.detail)
        #expect(before.minX == 0)
        #expect(before.width == width)

        f.presentation.hover(at: CGPoint(x: 2, y: 250), sidebarWidth: 280)
        try await f.settle { try f.presentation.isPreviewing && f.frame(of: f.sidebar).minX == 0 }
        #expect(f.presentation.isPreviewing)
        #expect(try f.frame(of: f.sidebar).minX == 0)
        #expect(try f.frame(of: f.detail) == before)
        #expect(f.detail.creations == 1)

        f.presentation.hover(at: CGPoint(x: 400, y: 250), sidebarWidth: 280)
        try await f.settle { !f.presentation.isPreviewing }
        #expect(!f.presentation.isPreviewing)
        #expect(try f.frame(of: f.detail) == before)
        #expect(f.detail.creations == 1)
    }

    @Test("explicit expansion reserves sidebar width and collapsing restores the same detail host")
    func pinnedLayout() async throws {
        let f = Fixture(width: 1240)
        defer { f.close() }
        try await f.settle()
        f.presentation.hover(at: CGPoint(x: 2, y: 250), sidebarWidth: 280)
        f.presentation.isExpanded = true
        try await f.settle()
        #expect(!f.presentation.isPreviewing)
        #expect(try f.frame(of: f.detail).minX == 281)
        #expect(try f.frame(of: f.detail).width == 959)
        f.presentation.isExpanded = false
        try await f.settle()
        #expect(try f.frame(of: f.detail).minX == 0)
        #expect(try f.frame(of: f.detail).width == 1240)
        #expect(f.detail.creations == 1)
        #expect(f.sidebar.creations == 1)
    }

    @Test("returning to the preview cancels dismissal and sidebar menus retain their anchor")
    func delayedDismissalAndMenus() async throws {
        let f = Fixture(width: 1240)
        defer { f.close() }
        f.presentation.hover(at: CGPoint(x: 2, y: 250), sidebarWidth: 280)
        f.presentation.hover(at: nil, sidebarWidth: 280)
        f.presentation.hover(at: CGPoint(x: 150, y: 250), sidebarWidth: 280)
        try await f.settle()
        #expect(f.presentation.isPreviewing)
        f.presentation.beginMenuTracking()
        f.presentation.hover(at: nil, sidebarWidth: 280)
        try await f.settle()
        #expect(f.presentation.isPreviewing)
        f.presentation.endMenuTracking()
        #expect(!f.presentation.isPreviewing)
    }
}
