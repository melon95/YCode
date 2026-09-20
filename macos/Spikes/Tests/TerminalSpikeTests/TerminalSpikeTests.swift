import AppKit
import SwiftTerm
import Testing
@testable import TerminalSpike

private final class CapturingTerminalDelegate: TerminalViewDelegate {
    var sent: [UInt8] = []

    func send(source: TerminalView, data: ArraySlice<UInt8>) { sent.append(contentsOf: data) }
    func sizeChanged(source: TerminalView, newCols: Int, newRows: Int) {}
    func setTerminalTitle(source: TerminalView, title: String) {}
    func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}
    func scrolled(source: TerminalView, position: Double) {}
    func requestOpenLink(source: TerminalView, link: String, params: [String: String]) {}
    func bell(source: TerminalView) {}
    func clipboardCopy(source: TerminalView, content: Data) {}
    func iTermContent(source: TerminalView, content: ArraySlice<UInt8>) {}
    func rangeChanged(source: TerminalView, startY: Int, endY: Int) {}
}

@Test func backlogRetainsNewestBytesAtCapacity() {
    var backlog = BoundedByteBacklog(capacity: 5)
    backlog.append(ArraySlice([1, 2, 3]))
    backlog.append(ArraySlice([4, 5, 6]))
    #expect(backlog.bytes == [2, 3, 4, 5, 6])

    backlog.append(ArraySlice([7, 8, 9, 10, 11, 12]))
    #expect(backlog.bytes == [8, 9, 10, 11, 12])
}

@Test func waitStatusDecoding() {
    #expect(decodeWaitStatus(42 << 8) == .exited(42))
    #expect(decodeWaitStatus(9) == .signaled(9))
    #expect(decodeWaitStatus((19 << 8) | 0x7f) == .stopped(19))
}

@Test func loginShellArgumentsAreQuoted() {
    #expect(shellQuote("plain") == "'plain'")
    #expect(shellQuote("two words") == "'two words'")
    #expect(shellQuote("it's") == "'it'\\''s'")
}

@Test func terminalEnvironmentOverridesCapabilities() {
    let environment = terminalEnvironment(from: ["TERM": "dumb", "NO_COLOR": "1", "KEEP": "yes"])
    #expect(environment["TERM"] == "xterm-256color")
    #expect(environment["COLORTERM"] == "truecolor")
    #expect(environment["NO_COLOR"] == nil)
    #expect(environment["KEEP"] == "yes")
}

@Test func parsesLastZshTotalDuration() {
    let text = "first 0.200 total\nsecond 0.129 total\n"
    #expect(zshTotalSeconds(in: text) == 0.129)
    #expect(zshTotalSeconds(in: "no timing") == nil)
}

@MainActor
@Test func markedTextCompositionCommitsUTF8() {
    let delegate = CapturingTerminalDelegate()
    let view = TerminalView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
    view.terminalDelegate = delegate

    view.setMarkedText(
        "zhongwen",
        selectedRange: NSRange(location: 8, length: 0),
        replacementRange: NSRange(location: NSNotFound, length: 0)
    )
    #expect(view.hasMarkedText())
    #expect(view.markedRange().length == 8)

    view.insertText("中文", replacementRange: NSRange(location: NSNotFound, length: 0))
    #expect(!view.hasMarkedText())
    #expect(delegate.sent == Array("中文".utf8))
}
