import AppKit
import Foundation
import Markdown

enum PreviewKind: String, CaseIterable {
    case source
    case markdown
    case image
    case svg
}

func previewKind(for url: URL) -> PreviewKind {
    switch url.pathExtension.lowercased() {
    case "md", "markdown": .markdown
    case "svg": .svg
    case "png", "jpg", "jpeg", "gif", "webp", "heic", "tiff", "bmp": .image
    default: .source
    }
}

func makeMarkdownPreview(_ source: String) throws -> NSAttributedString {
    NativeMarkdownRenderer().render(source)
}

private struct NativeMarkdownRenderer {
    private let bodyFont = NSFont.systemFont(ofSize: 15)

    func render(_ source: String) -> NSAttributedString {
        let result = NSMutableAttributedString()
        renderBlocks(Document(parsing: source), into: result)
        return result
    }

    private func renderBlocks(_ node: Markup, into result: NSMutableAttributedString) {
        switch node {
        case let heading as Heading:
            let size = max(18, 30 - CGFloat(heading.level * 3))
            renderInlineChildren(heading, into: result, font: .boldSystemFont(ofSize: size))
            append("\n\n", to: result)
        case let paragraph as Paragraph:
            renderInlineChildren(paragraph, into: result, font: bodyFont)
            append("\n\n", to: result)
        case let list as UnorderedList:
            for child in list.children {
                append("• ", to: result, font: bodyFont)
                renderListItem(child, into: result)
                append("\n", to: result)
            }
            append("\n", to: result)
        case let list as OrderedList:
            for (offset, child) in list.children.enumerated() {
                append("\(list.startIndex + UInt(offset)). ", to: result, font: bodyFont)
                renderListItem(child, into: result)
                append("\n", to: result)
            }
            append("\n", to: result)
        case let code as CodeBlock:
            append(code.code + "\n\n", to: result, font: .monospacedSystemFont(ofSize: 14, weight: .regular), background: .textBackgroundColor)
        case is ThematicBreak:
            append("────────────────────\n\n", to: result, font: bodyFont, color: .separatorColor)
        default:
            for child in node.children { renderBlocks(child, into: result) }
        }
    }

    private func renderListItem(_ node: Markup, into result: NSMutableAttributedString) {
        if let item = node as? ListItem {
            for child in item.children {
                if let paragraph = child as? Paragraph {
                    renderInlineChildren(paragraph, into: result, font: bodyFont)
                } else {
                    renderBlocks(child, into: result)
                }
            }
        } else {
            renderBlocks(node, into: result)
        }
    }

    private func renderInlineChildren(_ node: Markup, into result: NSMutableAttributedString, font: NSFont) {
        for child in node.children { renderInline(child, into: result, font: font) }
    }

    private func renderInline(_ node: Markup, into result: NSMutableAttributedString, font: NSFont) {
        switch node {
        case let text as Markdown.Text:
            append(text.string, to: result, font: font)
        case let strong as Strong:
            let bold = NSFontManager.shared.convert(font, toHaveTrait: .boldFontMask)
            renderInlineChildren(strong, into: result, font: bold)
        case let emphasis as Emphasis:
            let italic = NSFontManager.shared.convert(font, toHaveTrait: .italicFontMask)
            renderInlineChildren(emphasis, into: result, font: italic)
        case let code as InlineCode:
            append(code.code, to: result, font: .monospacedSystemFont(ofSize: font.pointSize, weight: .regular), background: .controlBackgroundColor)
        case let link as Markdown.Link:
            let start = result.length
            renderInlineChildren(link, into: result, font: font)
            if let destination = link.destination, let url = URL(string: destination) {
                result.addAttributes([.link: url, .foregroundColor: NSColor.linkColor], range: NSRange(location: start, length: result.length - start))
            }
        case is LineBreak:
            append("\n", to: result, font: font)
        case is SoftBreak:
            append(" ", to: result, font: font)
        default:
            renderInlineChildren(node, into: result, font: font)
        }
    }

    private func append(
        _ string: String,
        to result: NSMutableAttributedString,
        font: NSFont? = nil,
        background: NSColor? = nil,
        color: NSColor = .labelColor
    ) {
        var attributes: [NSAttributedString.Key: Any] = [.foregroundColor: color]
        attributes[.font] = font ?? bodyFont
        if let background { attributes[.backgroundColor] = background }
        result.append(NSAttributedString(string: string, attributes: attributes))
    }
}

func decodeNativeImage(_ data: Data) -> NSImage? {
    NSImage(data: data)
}

func saveUTF8(_ text: String, to url: URL) throws {
    try Data(text.utf8).write(to: url, options: .atomic)
}

func makeLongFileFixture(lineCount: Int = 20_000) -> String {
    (1...lineCount).map {
        "let value\($0) = \($0) // 中文长文件验证 abcdefghijklmnopqrstuvwxyz"
    }.joined(separator: "\n")
}

let markdownFixture = """
    # YCode 原生预览

    中文段落与 **粗体**、`inline code`。

    - 第一项
    - 第二项 🎉
    """

let svgFixture = """
    <svg xmlns="http://www.w3.org/2000/svg" width="640" height="240" viewBox="0 0 640 240">
      <rect width="640" height="240" rx="28" fill="#111827"/>
      <circle cx="96" cy="120" r="48" fill="#22c55e"/>
      <text x="170" y="135" font-family="-apple-system" font-size="44" fill="white">YCode 原生 SVG</text>
    </svg>
    """
