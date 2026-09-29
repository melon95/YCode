import Foundation
import Testing
@testable import YCodeCore

@Suite("Terminal canvas layouts")
struct TerminalCanvasLayoutTests {
    @Test("all canvas layouts tile the available area without overlaps or escaped panes")
    func canvasGeometry() {
        for count in 1...4 {
            for layout in YCodeTerminalLayout.validModes(for: count) {
                for size in [CGSize(width: 1200, height: 800), CGSize(width: 420, height: 300), .zero] {
                    let geometry = YCodeTerminalCanvasGeometry(layout: layout, count: count, size: size)
                    #expect(geometry.frames.count == count)
                    let rectangles = geometry.frames + geometry.dividers.map(\.frame)
                    for (index, frame) in rectangles.enumerated() {
                        #expect(frame.width >= 0 && frame.height >= 0)
                        #expect(frame.minX >= 0 && frame.maxX <= size.width + 0.001)
                        #expect(frame.minY >= 0 && frame.maxY <= size.height + 0.001)
                        for other in rectangles.dropFirst(index + 1) {
                            let intersection = frame.intersection(other)
                            #expect(intersection.isNull || intersection.width * intersection.height < 0.001)
                        }
                    }
                    let area = rectangles.reduce(CGFloat.zero) { $0 + $1.width * $1.height }
                    #expect(abs(area - size.width * size.height) < 0.001)
                }
            }
        }
    }

    @Test("divider dragging clamps neighbours, preserves other panes and survives resize")
    func canvasDividerDragging() throws {
        let size = CGSize(width: 1200, height: 800)
        let geometry = YCodeTerminalCanvasGeometry(layout: .columns, count: 4, size: size)
        let divider = try #require(geometry.dividers.first)
        for translation: CGFloat in [-10_000, 70, 10_000] {
            let weights = divider.resizedWeights(translation: translation)
            let resized = YCodeTerminalCanvasGeometry(layout: .columns, count: 4, size: size, weights: [divider.group: weights])
            #expect(resized.frames[0].width >= 220)
            #expect(resized.frames[1].width >= 220)
            #expect(abs(resized.frames[2].minX - geometry.frames[2].minX) < 0.001)
            #expect(abs(resized.frames[3].width - geometry.frames[3].width) < 0.001)
            let smaller = YCodeTerminalCanvasGeometry(layout: .columns, count: 4,
                size: CGSize(width: 600, height: 400), weights: [divider.group: weights])
            #expect(abs(smaller.frames[0].width / 585 - weights[0]) < 0.001)
        }
        let mainSide = YCodeTerminalCanvasGeometry(layout: .mainSide, count: 4, size: size)
        #expect(abs(mainSide.frames[0].width / 1195 - 0.6) < 0.001)
    }

    @Test("layout availability and automatic reflow match the legacy canvas")
    func validModesAndReflow() {
        #expect(YCodeTerminalLayout.validModes(for: 1) == [.single])
        #expect(YCodeTerminalLayout.validModes(for: 2) == [.stack, .columns])
        #expect(YCodeTerminalLayout.validModes(for: 3) == [.stack, .columns, .mainSide])
        #expect(YCodeTerminalLayout.validModes(for: 4) == [.stack, .columns, .grid2x2, .mainSide])
        #expect(YCodeTerminalLayout.reflow(.single, for: 2) == .columns)
        #expect(YCodeTerminalLayout.reflow(.stack, for: 3) == .stack)
        #expect(YCodeTerminalLayout.reflow(.single, for: 3) == .mainSide)
        #expect(YCodeTerminalLayout.reflow(.single, for: 4) == .grid2x2)
    }

    @Test("growing the canvas follows the intro progression unless the user picked a layout")
    func growthProgression() {
        var ids: [String] = []
        var layout = YCodeTerminalLayout.single
        var seen: [YCodeTerminalLayout] = []
        for id in ["one", "two", "three", "four"] {
            let result = YCodeTerminalCanvasRouting.open(
                sessionID: id, visibleSessionIDs: ids, focusedSlot: 0, layout: layout, mode: .newPane
            )
            ids = result.sessionIDs
            layout = result.layout
            seen.append(layout)
        }
        #expect(seen == [.single, .columns, .mainSide, .grid2x2])

        let picked = YCodeTerminalCanvasRouting.open(
            sessionID: "three", visibleSessionIDs: ["one", "two"], focusedSlot: 0, layout: .stack, mode: .newPane
        )
        #expect(picked.layout == .stack)
    }

    @Test("new panes grow the canvas while session selection replaces only the focused slot")
    func openingModesPreserveVisibleProcessIdentity() {
        let first = YCodeTerminalCanvasRouting.open(
            sessionID: "one", visibleSessionIDs: [], focusedSlot: 0, layout: .single, mode: .newPane
        )
        let second = YCodeTerminalCanvasRouting.open(
            sessionID: "two", visibleSessionIDs: first.sessionIDs, focusedSlot: first.focusedSlot,
            layout: first.layout, mode: .newPane
        )
        #expect(second.sessionIDs == ["one", "two"])
        #expect(second.focusedSlot == 1)
        #expect(second.layout == .columns)

        let swapped = YCodeTerminalCanvasRouting.open(
            sessionID: "three", visibleSessionIDs: second.sessionIDs, focusedSlot: 1,
            layout: second.layout, mode: .replaceFocused
        )
        #expect(swapped.sessionIDs == ["one", "three"])
        #expect(swapped.focusedSlot == 1)
        #expect(swapped.layout == .columns)

        let refocused = YCodeTerminalCanvasRouting.open(
            sessionID: "one", visibleSessionIDs: swapped.sessionIDs, focusedSlot: 1,
            layout: swapped.layout, mode: .replaceFocused
        )
        #expect(refocused.sessionIDs == ["one", "three"])
        #expect(refocused.focusedSlot == 0)

        let atCapacity = YCodeTerminalCanvasRouting.open(
            sessionID: "five", visibleSessionIDs: ["one", "two", "three", "four"], focusedSlot: 2,
            layout: .grid2x2, mode: .newPane
        )
        #expect(atCapacity.sessionIDs == ["one", "two", "five", "four"])
        #expect(atCapacity.focusedSlot == 2)
    }

    @Test("terminal links resolve URLs and project-relative source locations")
    func terminalLinks() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ycode-m23-link-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("Sources/App Main.swift")
        try FileManager.default.createDirectory(at: source.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("test".utf8).write(to: source)

        #expect(YCodeTerminalLinkResolver.resolve("https://example.com/a", workingDirectory: root) ==
            .external(URL(string: "https://example.com/a")!))
        #expect(YCodeTerminalLinkResolver.resolve("Sources/App Main.swift:12:4", workingDirectory: root) ==
            .file(source, line: 12, column: 4))
        #expect(YCodeTerminalLinkResolver.resolve("missing.swift:3", workingDirectory: root) == nil)
    }
}
