import AppKit
import XCTest
@testable import EditorSpike

final class EditorSpikeTests: XCTestCase {
    func testSyntaxRegistryMatchesCurrentEditor() {
        XCTAssertEqual(syntaxLanguageGroups.count, 39)
        XCTAssertEqual(Set(syntaxLanguageGroups.map(\.id)).count, 39)
        XCTAssertEqual(syntaxLanguageGroups.filter { $0.engine == .treeSitter }.count, 37)
        XCTAssertEqual(Set(syntaxLanguageGroups.filter { $0.indentWidth == 4 }.map(\.id)), ["rust", "python", "java", "csharp"])
        XCTAssertTrue(syntaxLanguageGroups.allSatisfy { !$0.extensions.isEmpty || !$0.filenames.isEmpty })
    }

    func testPreviewRouting() {
        XCTAssertEqual(previewKind(for: URL(fileURLWithPath: "README.md")), .markdown)
        XCTAssertEqual(previewKind(for: URL(fileURLWithPath: "logo.SVG")), .svg)
        XCTAssertEqual(previewKind(for: URL(fileURLWithPath: "photo.png")), .image)
        XCTAssertEqual(previewKind(for: URL(fileURLWithPath: "main.swift")), .source)
    }

    func testMarkdownAndSVGDecodeNatively() throws {
        let markdown = try makeMarkdownPreview(markdownFixture)
        XCTAssertTrue(markdown.string.contains("YCode 原生预览\n\n"))
        XCTAssertTrue(markdown.string.contains("• 第一项\n• 第二项 🎉"))
        XCTAssertFalse(markdown.string.contains("**粗体**"))
        XCTAssertNotNil(decodeNativeImage(Data(svgFixture.utf8)))
    }

    func testBrokenPreviewDataFailsClosed() {
        XCTAssertNil(decodeNativeImage(Data("broken".utf8)))
        XCTAssertNil(decodeNativeImage(Data("<svg><broken>".utf8)))
    }

    @MainActor
    func testTextKit2CompositionUndoAndSave() throws {
        let hostWindow = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 800, height: 600),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        let editor = NSTextView(usingTextLayoutManager: true)
        hostWindow.contentView = editor
        hostWindow.makeFirstResponder(editor)
        editor.isRichText = false
        editor.allowsUndo = true
        XCTAssertNotNil(editor.textLayoutManager)
        XCTAssertNotNil(editor.undoManager)

        editor.setMarkedText("zhongwen", selectedRange: NSRange(location: 8, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
        XCTAssertTrue(editor.hasMarkedText())
        editor.insertText("中文", replacementRange: editor.markedRange())
        XCTAssertEqual(editor.string, "中文")
        editor.undoManager?.removeAllActions()
        editor.insertText(" 🎉", replacementRange: NSRange(location: editor.string.utf16.count, length: 0))
        editor.undoManager?.undo()
        XCTAssertEqual(editor.string, "中文")

        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: url) }
        try saveUTF8(editor.string, to: url)
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "中文")
    }
}
