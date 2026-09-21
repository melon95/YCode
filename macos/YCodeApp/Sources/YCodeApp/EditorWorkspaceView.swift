import AppKit
import SwiftUI
import YCodeCore
import YCodeEditorSupport

struct ProjectFileWorkspaceView: View {
    let project: ProjectRecord
    @ObservedObject var workspace: YCodeEditorWorkspace
    let header: YCodePanelHeaderSpec
    let editorFontSize: CGFloat
    let theme: YCodeThemeOption
    let selectedFileURL: URL?
    let onSelectFile: (URL?) -> Void
    let onOpenFile: (URL) -> Void
    let onMovePath: (URL, URL) -> Void
    let onDeletePath: (URL) -> Void
    @Environment(\.ycodeL10n) private var l10n

    /// 一张卡里是「树 ｜ 编辑器」并排，不是二选一。树在不在只看卡头上那枚开关；
    /// 一篇文档都没开时强制留着树 —— 否则把它收起来这张卡就是一片空白。
    /// 卡头上没有编辑器的动作：保存走 ⌘S 与「文件 › 保存」，不值得在那排图标里再占一格。
    private var treeIsVisible: Bool { workspace.isFileTreeVisible || workspace.tabs.paths.isEmpty }
    private var showsEditor: Bool { !workspace.tabs.paths.isEmpty }

    /// 树的开关就是卡头最前面那枚图标（跟变更面板的树／平铺是同一套做法），
    /// 不在右边另起一个按钮。没开文档时树必须在场，这枚图标就退回成纯标识。
    private var headerSpec: YCodePanelHeaderSpec {
        var spec = header
        guard showsEditor else { return spec }
        spec.iconIsOn = treeIsVisible
        spec.iconHelp = l10n.text("fileTree")
        spec.iconAction = { workspace.isFileTreeVisible.toggle() }
        return spec
    }

    /// 文件名占住卡头最上面那一行；一篇都没开时这格还是面板名。
    @ViewBuilder private var headerLeading: some View {
        if showsEditor {
            YCodeEditorTabStrip(workspace: workspace) { path in
                onSelectFile(workspace.url(for: path))
            }
        } else {
            YCodePanelHeaderTitle(spec: headerSpec)
        }
    }

    var body: some View {
        ProjectFileTreeView(
            project: project,
            header: headerSpec,
            treeIsVisible: treeIsVisible,
            showsDetail: showsEditor,
            selectedFileURL: selectedFileURL,
            onSelectFile: onSelectFile,
            onOpenFile: onOpenFile,
            onMovePath: onMovePath,
            onDeletePath: onDeletePath,
            mayDeletePath: { !workspace.hasDirtyDocument(atOrBelow: $0) },
            headerLeading: { headerLeading }
        ) {
            if showsEditor {
                YCodeEditorWorkspaceView(workspace: workspace, editorFontSize: editorFontSize, theme: theme) { path in
                    onSelectFile(workspace.url(for: path))
                }
            }
        }
    }
}

/// 卡头不在这里 —— 它属于整张文件卡，由 `ProjectFileWorkspaceView` 摆，
/// 好让树和编辑器并排时上面只有一条卡头，而不是一边一条。
private struct YCodeEditorWorkspaceView: View {
    @ObservedObject var workspace: YCodeEditorWorkspace
    let editorFontSize: CGFloat
    let theme: YCodeThemeOption
    let onSelectionChanged: (String?) -> Void
    @Environment(\.ycodeL10n) private var l10n

    var body: some View {
        VStack(spacing: 0) {
            // 标签条不在这里 —— 文件名在卡头最上面那一行，横跨树与编辑器（设计稿）。
            // 这一条上的东西（LSP、跳定义、预览／源码）只属于当前选中的那篇文档，
            // 所以它得站在标签条**下面** —— 浮在标签之上会读成「这排标签的工具条」。
            if hasDocumentBar {
                documentBar
                Divider()
            }
            if let document = workspace.selectedDocument, document.hasExternalConflict {
                conflictBanner(document)
                Divider()
            }
            ZStack {
                ForEach(workspace.openDocuments) { document in
                    YCodeEditorDocumentView(
                        document: document,
                        isActive: workspace.tabs.selectedPath == document.path,
                        editorFontSize: editorFontSize,
                        theme: theme
                    ) { text in
                        workspace.edit(path: document.path, text: text)
                    }
                    .opacity(workspace.tabs.selectedPath == document.path ? 1 : 0)
                    .allowsHitTesting(workspace.tabs.selectedPath == document.path)
                    .accessibilityHidden(workspace.tabs.selectedPath != document.path)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            if let errorMessage = workspace.errorMessage {
                Divider()
                HStack(alignment: .top, spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                    Text(errorMessage).textSelection(.enabled)
                    Spacer(minLength: 0)
                    Button { workspace.errorMessage = nil } label: { Image(systemName: "xmark") }
                        .buttonStyle(.borderless)
                }
                .font(.caption)
                .padding(8)
                .background(Color.orange.opacity(0.08))
            }
        }
        .task {
            await workspace.checkForExternalChanges()
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                guard !Task.isCancelled else { break }
                await workspace.checkForExternalChanges()
            }
        }
        .confirmationDialog(
            workspace.pendingClosePath.map { "\(l10n.text("close")) \"\(displayName($0))\"?" } ?? l10n.text("close"),
            isPresented: closeConfirmation,
            titleVisibility: .visible
        ) {
            Button(l10n.text("discardAndClose"), role: .destructive) {
                workspace.discardAndClosePending()
                onSelectionChanged(workspace.tabs.selectedPath)
            }
            Button(l10n.text("cancel"), role: .cancel) { workspace.cancelClose() }
        } message: {
            Text(l10n.text("discardMessage"))
        }
        .confirmationDialog(
            workspace.pendingSaveConflictPath.map { "\"\(displayName($0))\" \(l10n.text("fileChangedOnDisk"))" } ?? l10n.text("saveConflict"),
            isPresented: conflictConfirmation,
            titleVisibility: .visible
        ) {
            Button(l10n.text("reloadDiskVersion"), role: .destructive) { workspace.reloadConflict() }
            Button(l10n.text("overwriteDiskVersion"), role: .destructive) { workspace.overwriteConflict() }
            Button(l10n.text("cancel"), role: .cancel) { workspace.cancelConflictSave() }
        } message: {
            Text(l10n.text("saveConflictMessage"))
        }
    }

    /// 属于「当前这篇文档」的那几样（LSP、跳定义、预览／源码）留在这一条，
    /// 没有内容时整条不出现。面板级的动作在卡头上，不在这儿。
    private var hasDocumentBar: Bool {
        guard let document = workspace.selectedDocument else { return false }
        return document.lspActive || document.canTogglePreview || document.previewKind == .image
    }

    private var documentBar: some View {
        HStack(spacing: 10) {
            Spacer()
            if let document = workspace.selectedDocument {
                if document.lspActive {
                    Label("LSP", systemImage: document.diagnostics.isEmpty ? "checkmark.seal" : "exclamationmark.triangle")
                        .font(.caption)
                        .foregroundStyle(document.diagnostics.isEmpty ? Color.green : Color.orange)
                        .help(document.diagnostics.first?.message ?? "LSP")
                    Button {
                        workspace.requestDefinition(
                            path: document.path,
                            line: document.cursorLine,
                            utf16Character: document.cursorUTF16Character
                        )
                    } label: {
                        Label(l10n.text("jumpToDefinition"), systemImage: "arrowshape.turn.up.right")
                    }
                    .buttonStyle(.borderless)
                    .help(l10n.text("jumpToDefinitionHelp"))
                }
                if document.canTogglePreview {
                    HStack(spacing: 2) {
                        presentationButton(l10n.text("preview"), systemImage: "eye", value: .preview, document: document)
                        presentationButton(l10n.text("source"), systemImage: "chevron.left.forwardslash.chevron.right", value: .source, document: document)
                    }
                } else if document.previewKind == .image {
                    Label(l10n.text("imagePreview"), systemImage: "photo")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(.horizontal, 10)
        .frame(height: 28)
    }

    private func presentationButton(
        _ title: String,
        systemImage: String,
        value: YCodeEditorPresentation,
        document: YCodeEditorDocument
    ) -> some View {
        Button {
            document.setPresentation(value)
        } label: {
            Label(title, systemImage: systemImage)
                .labelStyle(.iconOnly)
                .frame(width: 24, height: 22)
                .background(document.presentation == value ? Color.accentColor.opacity(0.16) : Color.clear)
                .clipShape(RoundedRectangle(cornerRadius: 4))
        }
        .buttonStyle(.plain)
        .help(title)
        .accessibilityLabel(title)
    }

    private func conflictBanner(_ document: YCodeEditorDocument) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            Text(document.externalWasDeleted
                ? l10n.text("fileDeletedDraftKept")
                : l10n.text("fileChangedOnDisk"))
            Spacer()
            if !document.externalWasDeleted {
                Button(l10n.text("reload")) {
                    workspace.pendingSaveConflictPath = document.path
                    workspace.reloadConflict()
                }
            }
            Button(l10n.text("saveEllipsis")) { workspace.save(document.path) }
        }
        .font(.caption)
        .padding(.horizontal, 10)
        .frame(minHeight: 34)
        .background(Color.orange.opacity(0.08))
    }

    private var closeConfirmation: Binding<Bool> {
        Binding(
            get: { workspace.pendingClosePath != nil },
            set: { if !$0 { workspace.cancelClose() } }
        )
    }

    private var conflictConfirmation: Binding<Bool> {
        Binding(
            get: { workspace.pendingSaveConflictPath != nil },
            set: { if !$0 { workspace.cancelConflictSave() } }
        )
    }

    private func displayName(_ path: String) -> String {
        path.split(separator: "/").last.map(String.init) ?? path
    }
}

private struct YCodeEditorDocumentView: View {
    @ObservedObject var document: YCodeEditorDocument
    let isActive: Bool
    let editorFontSize: CGFloat
    let theme: YCodeThemeOption
    let onChange: (String) -> Void
    @Environment(\.ycodeL10n) private var l10n

    var body: some View {
        Group {
            if document.isLoading {
                ProgressView(l10n.text("opening")).frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let errorMessage = document.errorMessage {
                ContentUnavailableView(l10n.text("cannotOpenFile"), systemImage: "exclamationmark.triangle", description: Text(errorMessage))
            } else {
                content
            }
        }
    }

    @ViewBuilder
    private var content: some View {
        switch document.previewKind {
        case .image:
            if let data = document.previewData, let image = YCodeNativeImageDecoder.decode(data) {
                YCodeNativeImagePreview(image: image)
            } else {
                ContentUnavailableView(l10n.text("cannotPreviewImage"), systemImage: "photo.badge.exclamationmark", description: Text(l10n.text("imageCorrupt")))
            }
        case .markdown where document.presentation == .preview:
            YCodeNativeMarkdownPreview(source: document.value)
        case .svg where document.presentation == .preview:
            if let image = YCodeNativeImageDecoder.decode(Data(document.value.utf8)) {
                YCodeNativeImagePreview(image: image)
            } else {
                ContentUnavailableView(l10n.text("cannotPreviewSVG"), systemImage: "photo.badge.exclamationmark", description: Text(l10n.text("invalidSVG")))
            }
        default:
            if document.isBinary {
                ContentUnavailableView(l10n.text("binaryFile"), systemImage: "doc.badge.ellipsis", description: Text(l10n.text("binaryNotEditable")))
            } else {
                YCodeNativeTextEditor(
                    text: document.value,
                    path: document.path,
                    fontSize: editorFontSize,
                    theme: theme,
                    revision: document.revision,
                    semanticTokens: document.semanticTokens,
                    semanticRevision: document.semanticRevision,
                    diagnostics: document.diagnostics,
                    navigationLine: document.navigationLine,
                    navigationUTF16Character: document.navigationUTF16Character,
                    navigationRevision: document.navigationRevision,
                    isActive: isActive,
                    onChange: onChange,
                    onCursor: { line, character in document.moveCursor(line: line, utf16Character: character) }
                )
            }
        }
    }
}

private struct YCodeNativeTextEditor: NSViewRepresentable {
    let text: String
    let path: String
    let fontSize: CGFloat
    let theme: YCodeThemeOption
    let revision: Int
    let semanticTokens: [YCodeLSPSemanticToken]
    let semanticRevision: Int
    let diagnostics: [YCodeLSPDiagnostic]
    let navigationLine: Int?
    let navigationUTF16Character: Int?
    let navigationRevision: Int
    let isActive: Bool
    let onChange: (String) -> Void
    let onCursor: (Int, Int) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(onChange: onChange, onCursor: onCursor, fontSize: fontSize, theme: theme) }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder

        let textView = NSTextView(usingTextLayoutManager: true)
        textView.delegate = context.coordinator
        textView.isRichText = false
        textView.importsGraphics = false
        textView.allowsUndo = true
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        context.coordinator.fontSize = fontSize
        context.coordinator.theme = theme
        configure(textView, in: scrollView)
        textView.textContainerInset = NSSize(width: 12, height: 12)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = true
        textView.minSize = NSSize(width: 0, height: 0)
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.textContainer?.containerSize = NSSize(
            width: CGFloat.greatestFiniteMagnitude,
            height: CGFloat.greatestFiniteMagnitude
        )
        textView.textContainer?.widthTracksTextView = false
        textView.string = text
        context.coordinator.lastRevision = revision
        context.coordinator.lastSemanticRevision = semanticRevision
        context.coordinator.lastNavigationRevision = navigationRevision
        context.coordinator.lastPath = path
        context.coordinator.requestHighlighting(
            for: textView,
            path: path,
            semanticTokens: semanticTokens,
            diagnostics: diagnostics
        )
        scrollView.documentView = textView
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = scrollView.documentView as? NSTextView else { return }
        context.coordinator.onChange = onChange
        context.coordinator.onCursor = onCursor
        let appearanceChanged = context.coordinator.fontSize != fontSize || context.coordinator.theme != theme
        context.coordinator.fontSize = fontSize
        context.coordinator.theme = theme
        if appearanceChanged {
            configure(textView, in: scrollView)
        }
        var needsHighlighting = appearanceChanged
        if context.coordinator.lastRevision != revision, !textView.hasMarkedText() {
            context.coordinator.isApplyingModel = true
            textView.string = text
            textView.undoManager?.removeAllActions()
            context.coordinator.isApplyingModel = false
            context.coordinator.lastRevision = revision
            needsHighlighting = true
        } else if context.coordinator.lastSemanticRevision != semanticRevision {
            needsHighlighting = true
        } else if context.coordinator.lastPath != path {
            needsHighlighting = true
        }
        if needsHighlighting {
            context.coordinator.requestHighlighting(
                for: textView,
                path: path,
                semanticTokens: semanticTokens,
                diagnostics: diagnostics
            )
        }
        context.coordinator.lastPath = path
        context.coordinator.lastSemanticRevision = semanticRevision
        if context.coordinator.lastNavigationRevision != navigationRevision,
           let navigationLine,
           let navigationUTF16Character,
           let range = context.coordinator.range(
                line: navigationLine,
                utf16Character: navigationUTF16Character,
                length: 0,
                in: textView.string
           ) {
            context.coordinator.lastNavigationRevision = navigationRevision
            textView.setSelectedRange(range)
            textView.scrollRangeToVisible(range)
            textView.window?.makeFirstResponder(textView)
        }
        if isActive, !context.coordinator.wasActive {
            DispatchQueue.main.async { textView.window?.makeFirstResponder(textView) }
        }
        context.coordinator.wasActive = isActive
    }

    private func configure(_ textView: NSTextView, in scrollView: NSScrollView) {
        textView.font = .monospacedSystemFont(ofSize: fontSize, weight: .regular)
        textView.backgroundColor = theme.nsTerminalBackground
        textView.textColor = theme.nsTerminalForeground
        textView.insertionPointColor = theme.nsTerminalCursor
        textView.typingAttributes = [
            .font: NSFont.monospacedSystemFont(ofSize: fontSize, weight: .regular),
            .foregroundColor: theme.nsTerminalForeground
        ]
        scrollView.drawsBackground = true
        scrollView.backgroundColor = theme.nsTerminalBackground
    }

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate {
        var onChange: (String) -> Void
        var onCursor: (Int, Int) -> Void
        var fontSize: CGFloat
        var theme: YCodeThemeOption
        var isApplyingModel = false
        var lastRevision = -1
        var lastSemanticRevision = -1
        var lastNavigationRevision = -1
        var lastPath = ""
        var wasActive = false
        weak var pendingTextView: NSTextView?
        var pendingPath = ""
        var pendingSemanticTokens: [YCodeLSPSemanticToken] = []
        var pendingDiagnostics: [YCodeLSPDiagnostic] = []
        private var highlightGeneration = 0

        init(onChange: @escaping (String) -> Void, onCursor: @escaping (Int, Int) -> Void, fontSize: CGFloat, theme: YCodeThemeOption) {
            self.onChange = onChange
            self.onCursor = onCursor
            self.fontSize = fontSize
            self.theme = theme
        }

        func textDidChange(_ notification: Notification) {
            guard !isApplyingModel, let textView = notification.object as? NSTextView else { return }
            onChange(textView.string)
            publishCursor(textView)
            scheduleHighlighting(
                textView,
                path: lastPath,
                semanticTokens: pendingSemanticTokens,
                diagnostics: pendingDiagnostics
            )
        }

        func textViewDidChangeSelection(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            publishCursor(textView)
        }

        func scheduleHighlighting(
            _ textView: NSTextView,
            path: String,
            semanticTokens: [YCodeLSPSemanticToken],
            diagnostics: [YCodeLSPDiagnostic]
        ) {
            NSObject.cancelPreviousPerformRequests(withTarget: self, selector: #selector(applyScheduledHighlighting), object: nil)
            pendingTextView = textView
            pendingPath = path
            pendingSemanticTokens = semanticTokens
            pendingDiagnostics = diagnostics
            perform(#selector(applyScheduledHighlighting), with: nil, afterDelay: 0.08)
        }

        @objc private func applyScheduledHighlighting() {
            guard let textView = pendingTextView, !textView.hasMarkedText() else { return }
            requestHighlighting(
                for: textView,
                path: pendingPath,
                semanticTokens: pendingSemanticTokens,
                diagnostics: pendingDiagnostics
            )
        }

        func requestHighlighting(
            for textView: NSTextView,
            path: String,
            semanticTokens: [YCodeLSPSemanticToken],
            diagnostics: [YCodeLSPDiagnostic]
        ) {
            guard !textView.hasMarkedText() else { return }
            let source = textView.string
            highlightGeneration += 1
            let generation = highlightGeneration
            Task { [weak self, weak textView] in
                let tokens = await Task.detached(priority: .userInitiated) {
                    YCodeSyntaxHighlighter().tokens(in: source, path: path)
                }.value
                guard let self,
                      let textView,
                      self.highlightGeneration == generation,
                      textView.string == source,
                      !textView.hasMarkedText()
                else { return }
                self.apply(tokens: tokens, semanticTokens: semanticTokens, diagnostics: diagnostics, to: textView)
            }
        }

        private func apply(
            tokens: [YCodeSyntaxToken],
            semanticTokens: [YCodeLSPSemanticToken],
            diagnostics: [YCodeLSPDiagnostic],
            to textView: NSTextView
        ) {
            guard let storage = textView.textStorage else { return }
            let fullRange = NSRange(location: 0, length: storage.length)
            let selection = textView.selectedRange()
            let baseFont = NSFont.monospacedSystemFont(ofSize: fontSize, weight: .regular)
            isApplyingModel = true
            textView.undoManager?.disableUndoRegistration()
            storage.beginEditing()
            storage.setAttributes([.font: baseFont, .foregroundColor: theme.nsTerminalForeground], range: fullRange)
            for token in tokens where NSMaxRange(token.range) <= storage.length {
                var attributes: [NSAttributedString.Key: Any] = [.foregroundColor: color(for: token.kind)]
                if token.kind == .heading {
                    attributes[.font] = NSFont.monospacedSystemFont(ofSize: fontSize, weight: .bold)
                }
                storage.addAttributes(attributes, range: token.range)
            }
            for token in semanticTokens {
                guard let range = range(
                    line: token.line,
                    utf16Character: token.utf16Character,
                    length: token.length,
                    in: textView.string
                ), NSMaxRange(range) <= storage.length else { continue }
                storage.addAttribute(.foregroundColor, value: color(forSemanticType: token.type), range: range)
            }
            for diagnostic in diagnostics {
                guard let line = diagnostic.line,
                      let character = diagnostic.utf16Character,
                      let range = range(line: line, utf16Character: character, length: 1, in: textView.string),
                      NSMaxRange(range) <= storage.length else { continue }
                storage.addAttributes([
                    .underlineStyle: NSUnderlineStyle.single.rawValue | NSUnderlineStyle.patternDot.rawValue,
                    .underlineColor: NSColor.systemOrange
                ], range: range)
            }
            storage.endEditing()
            textView.undoManager?.enableUndoRegistration()
            textView.typingAttributes = [.font: baseFont, .foregroundColor: theme.nsTerminalForeground]
            if NSMaxRange(selection) <= storage.length { textView.setSelectedRange(selection) }
            isApplyingModel = false
        }

        func range(line: Int, utf16Character: Int, length: Int, in text: String) -> NSRange? {
            guard line >= 0, utf16Character >= 0, length >= 0 else { return nil }
            let nsText = text as NSString
            var currentLine = 0
            var lineStart = 0
            while currentLine < line {
                let searchRange = NSRange(location: lineStart, length: nsText.length - lineStart)
                let newline = nsText.range(of: "\n", options: [], range: searchRange)
                guard newline.location != NSNotFound else { return nil }
                lineStart = newline.location + newline.length
                currentLine += 1
            }
            let location = lineStart + utf16Character
            guard location <= nsText.length else { return nil }
            return NSRange(location: location, length: min(length, nsText.length - location))
        }

        private func publishCursor(_ textView: NSTextView) {
            let location = textView.selectedRange().location
            let prefix = (textView.string as NSString).substring(to: min(location, (textView.string as NSString).length))
            let lines = prefix.components(separatedBy: "\n")
            onCursor(max(0, lines.count - 1), lines.last.map { ($0 as NSString).length } ?? 0)
        }

        private func color(for kind: YCodeSyntaxTokenKind) -> NSColor {
            switch kind {
            case .keyword: .systemPurple
            case .string: .systemRed
            case .comment: .secondaryLabelColor
            case .number: .systemBlue
            case .property: .systemOrange
            case .heading: .systemBlue
            case .addition: .systemGreen
            case .deletion: .systemRed
            case .metadata: .systemPurple
            }
        }

        private func color(forSemanticType type: String) -> NSColor {
            switch type {
            case "function", "method": .systemIndigo
            case "class", "struct", "interface", "type", "enum": .systemTeal
            case "property", "variable", "parameter": .systemOrange
            case "keyword", "macro": .systemPurple
            case "string": .systemRed
            case "number": .systemBlue
            default: theme.nsTerminalForeground
            }
        }
    }
}

private struct YCodeNativeMarkdownPreview: NSViewRepresentable {
    let source: String

    func makeNSView(context: Context) -> NSScrollView {
        let textView = NSTextView(usingTextLayoutManager: true)
        textView.isEditable = false
        textView.isSelectable = true
        textView.drawsBackground = false
        textView.textContainerInset = NSSize(width: 24, height: 24)
        textView.linkTextAttributes = [.foregroundColor: NSColor.linkColor, .underlineStyle: NSUnderlineStyle.single.rawValue]
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.minSize = .zero
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.textContainer?.containerSize = NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude)
        textView.textContainer?.widthTracksTextView = true
        textView.autoresizingMask = [.width]
        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = false
        scrollView.documentView = textView
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = scrollView.documentView as? NSTextView else { return }
        textView.textStorage?.setAttributedString(YCodeMarkdownRenderer().render(source))
    }
}

private struct YCodeNativeImagePreview: NSViewRepresentable {
    let image: NSImage

    func makeNSView(context: Context) -> NSImageView {
        let view = NSImageView()
        view.imageScaling = .scaleProportionallyDown
        view.imageAlignment = .alignCenter
        view.animates = true
        return view
    }

    func updateNSView(_ view: NSImageView, context: Context) {
        view.image = image
    }
}

/// 卡头上那一行文件名。放不下的标签收进末尾的 ⌄ 菜单里 ——
/// 横向滚动条在一条 22 高的卡头上既看不见也不好拨。
/// 当前选中的那张永远留在外面：它要是被挤进菜单，这一行就再也说不出「你在看哪篇」。
private struct YCodeEditorTabStrip: View {
    @ObservedObject var workspace: YCodeEditorWorkspace
    let onSelectionChanged: (String?) -> Void
    @Environment(\.ycodeL10n) private var l10n

    /// 标签自己定宽，不让 HStack 去分 —— 宽度算得出来，才知道第几张开始放不下。
    private static let font = NSFont.systemFont(ofSize: 11)
    private static let spacing: CGFloat = 2
    private static let overflowWidth: CGFloat = 24

    var body: some View {
        GeometryReader { proxy in
            let split = split(in: proxy.size.width)
            HStack(spacing: Self.spacing) {
                ForEach(split.visible, id: \.self) { path in
                    tab(path).frame(width: width(of: path))
                }
                if !split.overflow.isEmpty { overflowMenu(split.overflow) }
                Spacer(minLength: 0)
            }
            .frame(width: proxy.size.width, height: proxy.size.height, alignment: .leading)
        }
        .frame(height: 24)
    }

    /// 从左往右能塞几张就塞几张；塞不下的进菜单。选中的那张一定在 `visible` 里。
    private func split(in total: CGFloat) -> (visible: [String], overflow: [String]) {
        let paths = workspace.tabs.paths
        let full = paths.reduce(CGFloat.zero) { $0 + width(of: $1) } + Self.spacing * CGFloat(max(0, paths.count - 1))
        guard full > total else { return (paths, []) }

        let budget = total - Self.overflowWidth - Self.spacing
        var visible: [String] = []
        var used: CGFloat = 0
        for path in paths {
            let step = width(of: path) + (visible.isEmpty ? 0 : Self.spacing)
            guard used + step <= budget else { break }
            visible.append(path)
            used += step
        }
        if let selected = workspace.tabs.selectedPath, !visible.contains(selected) {
            let step = width(of: selected)
            while used + Self.spacing + step > budget, let dropped = visible.popLast() {
                used -= width(of: dropped) + (visible.isEmpty ? 0 : Self.spacing)
            }
            visible.append(selected)
        }
        let kept = Set(visible)
        return (visible, paths.filter { !kept.contains($0) })
    }

    private func width(of path: String) -> CGFloat {
        let text = (displayName(path) as NSString).size(withAttributes: [.font: Self.font]).width
        let dirtyDot: CGFloat = workspace.tabs.dirtyPaths.contains(path) ? 11 : 0
        // 8 左内边距 + 5 间距 + 9 的 ✕ + 8 右内边距，取整到 32。
        return min(max(ceil(text) + dirtyDot + 32, 58), 150)
    }

    private func tab(_ path: String) -> some View {
        HStack(spacing: 5) {
            Button {
                workspace.select(path)
                onSelectionChanged(path)
            } label: {
                HStack(spacing: 5) {
                    Text(displayName(path))
                        .italic(workspace.tabs.previewPath == path)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    if workspace.tabs.dirtyPaths.contains(path) {
                        Circle().fill(Color.orange).frame(width: 6, height: 6)
                            .accessibilityLabel(l10n.text("unsaved"))
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .simultaneousGesture(TapGesture(count: 2).onEnded {
                workspace.select(path)
                workspace.pin(path)
                onSelectionChanged(path)
            })
            Button {
                workspace.requestClose(path)
                if workspace.pendingClosePath == nil {
                    onSelectionChanged(workspace.tabs.selectedPath)
                }
            } label: {
                Image(systemName: "xmark").font(.system(size: 9, weight: .semibold))
            }
            .buttonStyle(.borderless)
            .help(l10n.text("close"))
        }
        .font(.system(size: 11))
        .padding(.horizontal, 8)
        .frame(height: 24)
        .background(workspace.tabs.selectedPath == path ? Color.accentColor.opacity(0.15) : Color.clear)
        .clipShape(RoundedRectangle(cornerRadius: 5))
        .help(workspace.tabs.previewPath == path ? l10n.text("previewTabHelpFormat", path) : path)
    }

    private func overflowMenu(_ paths: [String]) -> some View {
        Menu {
            ForEach(paths, id: \.self) { path in
                Button(displayName(path)) {
                    workspace.select(path)
                    onSelectionChanged(path)
                }
            }
        } label: {
            Image(systemName: "chevron.down")
        }
        .ycodePanelMenu()
        .help(l10n.text("moreTabsFormat", "\(paths.count)"))
    }

    private func displayName(_ path: String) -> String {
        path.split(separator: "/").last.map(String.init) ?? path
    }
}
