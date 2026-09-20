import AppKit
import Foundation

@MainActor
func runEditorHeadless() -> Int32 {
    var failures: [String] = []
    func check(_ name: String, _ condition: @autoclosure () -> Bool, detail: String = "") {
        let ok = condition()
        print("[\(ok ? "PASS" : "FAIL")] \(name)\(detail.isEmpty ? "" : " — \(detail)")")
        if !ok { failures.append(name) }
    }

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
    check("TextKit 2 已启用", editor.textLayoutManager != nil)
    check("撤销管理器已连接", editor.undoManager != nil)

    editor.setMarkedText("zhongwen", selectedRange: NSRange(location: 8, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
    check("组合文本状态可建立", editor.hasMarkedText())
    editor.insertText("中文", replacementRange: editor.markedRange())
    check("中文组合输入可提交", editor.string == "中文", detail: editor.string)

    // Treat the committed IME text as the loaded-document baseline. AppKit may
    // coalesce it with the next synthetic insert when no real key event exists.
    editor.undoManager?.removeAllActions()
    editor.insertText(" + edit", replacementRange: NSRange(location: editor.string.utf16.count, length: 0))
    check("编辑可用", editor.string == "中文 + edit")
    editor.undoManager?.undo()
    check("撤销可用", editor.string == "中文")

    let saveURL = FileManager.default.temporaryDirectory.appendingPathComponent("ycode-m04-save-\(UUID().uuidString).txt")
    defer { try? FileManager.default.removeItem(at: saveURL) }
    do {
        try saveUTF8(editor.string + " 🎉", to: saveURL)
        let saved = try String(contentsOf: saveURL, encoding: .utf8)
        check("UTF-8 原子保存内容一致", saved == "中文 🎉")
    } catch {
        check("UTF-8 原子保存内容一致", false, detail: error.localizedDescription)
    }

    let fixture = makeLongFileFixture()
    let start = ContinuousClock.now
    editor.string = fixture
    editor.layoutSubtreeIfNeeded()
    let elapsed = start.duration(to: .now)
    check("20000 行长文件完整装入", editor.string == fixture, detail: "\(fixture.utf8.count) bytes, \(elapsed)")

    do {
        let preview = try makeMarkdownPreview(markdownFixture)
        check("Markdown 原生预览", preview.string.contains("YCode 原生预览") && preview.string.contains("第二项 🎉"))
    } catch {
        check("Markdown 原生预览", false, detail: error.localizedDescription)
    }

    let svg = decodeNativeImage(Data(svgFixture.utf8))
    check("SVG 原生预览", svg != nil, detail: svg.map { "\(Int($0.size.width))×\(Int($0.size.height))" } ?? "decode=nil")

    let bitmap = NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: 8,
        pixelsHigh: 8,
        bitsPerSample: 8,
        samplesPerPixel: 4,
        hasAlpha: true,
        isPlanar: false,
        colorSpaceName: .deviceRGB,
        bytesPerRow: 0,
        bitsPerPixel: 0
    )
    let png = bitmap?.representation(using: .png, properties: [:])
    check("位图原生预览", png.flatMap(decodeNativeImage) != nil)
    check("损坏图片显式失败", decodeNativeImage(Data("broken".utf8)) == nil)
    check("损坏 SVG 显式失败", decodeNativeImage(Data("<svg><broken>".utf8)) == nil)

    print(failures.isEmpty ? "\nM0.4 自动验证全部通过" : "\nM0.4 自动验证失败：\(failures.joined(separator: ", "))")
    return failures.isEmpty ? 0 : 1
}
