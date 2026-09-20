import AppKit
import Foundation

@MainActor
final class EditorSpikeWindowController: NSWindowController {
    private let content = NSView()
    private let status = NSTextField(labelWithString: "")
    private let editor = NSTextView(usingTextLayoutManager: true)
    private lazy var editorScroll = NSScrollView()
    private var evidenceSequence = 0

    convenience init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1120, height: 760),
            styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = "YCode M0.4 — 原生编辑器 / 预览"
        window.center()
        self.init(window: window)
        configureUI()
        showEditor()
    }

    private func configureUI() {
        guard let window else { return }
        let root = NSView(frame: window.contentLayoutRect)
        root.autoresizingMask = [.width, .height]

        let picker = NSSegmentedControl(
            labels: ["编辑器", "Markdown", "SVG", "损坏图片"],
            trackingMode: .selectOne,
            target: self,
            action: #selector(changeMode(_:))
        )
        picker.selectedSegment = 0
        picker.frame = NSRect(x: 18, y: root.bounds.height - 48, width: 430, height: 28)
        picker.autoresizingMask = [.maxXMargin, .minYMargin]

        status.frame = NSRect(x: 470, y: root.bounds.height - 45, width: root.bounds.width - 490, height: 22)
        status.autoresizingMask = [.width, .minYMargin]
        status.alignment = .right
        status.textColor = .secondaryLabelColor

        content.frame = NSRect(x: 18, y: 18, width: root.bounds.width - 36, height: root.bounds.height - 78)
        content.autoresizingMask = [.width, .height]
        content.wantsLayer = true
        content.layer?.cornerRadius = 10
        content.layer?.borderWidth = 1
        content.layer?.borderColor = NSColor.separatorColor.cgColor

        root.addSubview(picker)
        root.addSubview(status)
        root.addSubview(content)
        window.contentView = root

        editor.isRichText = false
        editor.isAutomaticQuoteSubstitutionEnabled = false
        editor.isAutomaticDashSubstitutionEnabled = false
        editor.isAutomaticTextReplacementEnabled = false
        editor.allowsUndo = true
        editor.font = .monospacedSystemFont(ofSize: 14, weight: .regular)
        editor.textContainerInset = NSSize(width: 14, height: 14)
        editor.autoresizingMask = [.width]
        editor.string = "// TextKit 2\nlet message = \"中文组合输入与 Emoji 🎉\"\n"

        editorScroll.hasVerticalScroller = true
        editorScroll.hasHorizontalScroller = true
        editorScroll.autohidesScrollers = true
        editorScroll.borderType = .noBorder
        editorScroll.documentView = editor
    }

    @objc private func changeMode(_ sender: NSSegmentedControl) {
        switch sender.selectedSegment {
        case 0: showEditor()
        case 1: showMarkdown()
        case 2: showSVG()
        default: showBrokenImage()
        }
    }

    private func replaceContent(with view: NSView) {
        content.subviews.forEach { $0.removeFromSuperview() }
        view.frame = content.bounds
        view.autoresizingMask = [.width, .height]
        content.addSubview(view)
    }

    private func showEditor() {
        replaceContent(with: editorScroll)
        status.stringValue = editor.textLayoutManager == nil ? "TextKit 2 未启用" : "TextKit 2 · 可撤销 · UTF-8 保存"
        window?.makeFirstResponder(editor)
    }

    private func showMarkdown() {
        let preview = NSTextView(usingTextLayoutManager: true)
        preview.isEditable = false
        preview.drawsBackground = false
        preview.textContainerInset = NSSize(width: 24, height: 24)
        preview.textStorage?.setAttributedString((try? makeMarkdownPreview(markdownFixture)) ?? NSAttributedString(string: markdownFixture))
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.documentView = preview
        replaceContent(with: scroll)
        status.stringValue = "Swift Markdown → AppKit 原生富文本"
    }

    private func showSVG() {
        let imageView = NSImageView()
        imageView.imageScaling = .scaleProportionallyUpOrDown
        imageView.image = decodeNativeImage(Data(svgFixture.utf8))
        replaceContent(with: imageView)
        status.stringValue = imageView.image == nil ? "SVG 解码失败" : "NSImage 原生 SVG 解码"
    }

    private func showBrokenImage() {
        let label = NSTextField(wrappingLabelWithString: "无法预览图片：文件内容损坏")
        label.alignment = .center
        label.textColor = .secondaryLabelColor
        replaceContent(with: label)
        status.stringValue = decodeNativeImage(Data("not-an-image".utf8)) == nil ? "错误已显式处理" : "异常：损坏数据被接受"
    }

    @objc func saveFixture() {
        let url = URL(fileURLWithPath: "/tmp/ycode-m04-editor-save.swift")
        do {
            try saveUTF8(editor.string, to: url)
            status.stringValue = "已原子保存：\(url.path)"
        } catch {
            status.stringValue = "保存失败：\(error.localizedDescription)"
        }
    }

    @objc func captureEvidence() {
        guard let view = window?.contentView,
              let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: bitmap)
        guard let png = bitmap.representation(using: .png, properties: [:]) else { return }
        evidenceSequence += 1
        let path = String(format: "/tmp/ycode-m04-editor-%02d.png", evidenceSequence)
        do {
            try png.write(to: URL(fileURLWithPath: path), options: .atomic)
            status.stringValue = "已保存界面证据：\(path)"
        } catch {
            status.stringValue = "保存界面证据失败：\(error.localizedDescription)"
        }
    }
}

@MainActor
final class EditorSpikeAppDelegate: NSObject, NSApplicationDelegate {
    private var controller: EditorSpikeWindowController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        controller = EditorSpikeWindowController()
        controller?.showWindow(nil)
        buildMenu()
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    private func buildMenu() {
        let main = NSMenu()
        let appItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu
        main.addItem(appItem)

        let editItem = NSMenuItem()
        let edit = NSMenu(title: "Edit")
        edit.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        edit.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "Z")
        edit.addItem(NSMenuItem.separator())
        edit.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = edit
        main.addItem(editItem)

        let fileItem = NSMenuItem()
        let file = NSMenu(title: "File")
        let save = NSMenuItem(title: "Save Fixture", action: #selector(EditorSpikeWindowController.saveFixture), keyEquivalent: "s")
        save.target = controller
        file.addItem(save)
        let capture = NSMenuItem(title: "Capture Evidence", action: #selector(EditorSpikeWindowController.captureEvidence), keyEquivalent: "5")
        capture.target = controller
        file.addItem(capture)
        fileItem.submenu = file
        main.addItem(fileItem)
        NSApp.mainMenu = main
    }
}

@MainActor
func runEditorGUI() {
    let app = NSApplication.shared
    let delegate = EditorSpikeAppDelegate()
    app.setActivationPolicy(.regular)
    app.delegate = delegate
    app.run()
    withExtendedLifetime(delegate) {}
}
