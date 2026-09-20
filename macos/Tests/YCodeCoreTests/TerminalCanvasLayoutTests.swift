import Foundation
import Testing
@testable import YCodeCore

@Suite("Terminal canvas layouts")
struct TerminalCanvasLayoutTests {
    @Test("layout availability and automatic reflow match the legacy canvas")
    func validModesAndReflow() {
        #expect(YCodeTerminalLayout.validModes(for: 1) == [.single])
        #expect(YCodeTerminalLayout.validModes(for: 2) == [.stack, .columns])
        #expect(YCodeTerminalLayout.validModes(for: 3) == [.stack, .columns, .mainSide])
        #expect(YCodeTerminalLayout.validModes(for: 4) == [.stack, .columns, .grid2x2, .mainSide])
        #expect(YCodeTerminalLayout.reflow(.single, for: 2) == .stack)
        #expect(YCodeTerminalLayout.reflow(.stack, for: 3) == .stack)
        #expect(YCodeTerminalLayout.reflow(.single, for: 3) == .mainSide)
        #expect(YCodeTerminalLayout.reflow(.single, for: 4) == .grid2x2)
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
        #expect(second.layout == .stack)

        let swapped = YCodeTerminalCanvasRouting.open(
            sessionID: "three", visibleSessionIDs: second.sessionIDs, focusedSlot: 1,
            layout: second.layout, mode: .replaceFocused
        )
        #expect(swapped.sessionIDs == ["one", "three"])
        #expect(swapped.focusedSlot == 1)
        #expect(swapped.layout == .stack)

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
