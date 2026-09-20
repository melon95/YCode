import AppKit
import Markdown

public struct YCodeMarkdownRenderer {
    private let bodyFont = NSFont.systemFont(ofSize: 15)

    public init() {}

    public func render(_ source: String) -> NSAttributedString {
        let result = NSMutableAttributedString()
        renderBlocks(Document(parsing: source), into: result, depth: 0)
        if result.string.hasSuffix("\n") {
            result.deleteCharacters(in: NSRange(location: result.length - 1, length: 1))
        }
        return result
    }

    private func renderBlocks(_ node: Markup, into result: NSMutableAttributedString, depth: Int) {
        switch node {
        case let heading as Heading:
            let size = max(17, 30 - CGFloat(heading.level * 3))
            renderInlineChildren(heading, into: result, font: .boldSystemFont(ofSize: size))
            append("\n\n", to: result)
        case let paragraph as Paragraph:
            renderInlineChildren(paragraph, into: result, font: bodyFont)
            append("\n\n", to: result)
        case let list as UnorderedList:
            renderList(list.children, orderedStart: nil, into: result, depth: depth)
        case let list as OrderedList:
            renderList(list.children, orderedStart: Int(list.startIndex), into: result, depth: depth)
        case let quote as BlockQuote:
            append("▎ ", to: result, font: .systemFont(ofSize: 16, weight: .semibold), color: .secondaryLabelColor)
            for child in quote.children { renderBlocks(child, into: result, depth: depth + 1) }
        case let code as CodeBlock:
            append(code.code + "\n\n", to: result, font: .monospacedSystemFont(ofSize: 13, weight: .regular), background: .controlBackgroundColor)
        case let table as Table:
            renderTable(table, into: result)
        case is ThematicBreak:
            append("────────────────────────\n\n", to: result, color: .separatorColor)
        case is HTMLBlock:
            break
        default:
            for child in node.children { renderBlocks(child, into: result, depth: depth) }
        }
    }

    private func renderList(
        _ children: MarkupChildren,
        orderedStart: Int?,
        into result: NSMutableAttributedString,
        depth: Int
    ) {
        for (offset, child) in children.enumerated() {
            guard let item = child as? ListItem else { continue }
            append(String(repeating: "  ", count: depth), to: result)
            if let checkbox = item.checkbox {
                append(checkbox == .checked ? "☑︎ " : "☐ ", to: result)
            } else if let orderedStart {
                append("\(orderedStart + offset). ", to: result)
            } else {
                append("• ", to: result)
            }
            for child in item.children {
                if let paragraph = child as? Paragraph {
                    renderInlineChildren(paragraph, into: result, font: bodyFont)
                } else {
                    renderBlocks(child, into: result, depth: depth + 1)
                }
            }
            if !result.string.hasSuffix("\n") { append("\n", to: result) }
        }
        append("\n", to: result)
    }

    private func renderTable(_ table: Table, into result: NSMutableAttributedString) {
        renderTableRow(table.head, into: result, header: true)
        for row in table.body.children {
            renderTableRow(row, into: result, header: false)
        }
        append("\n", to: result)
    }

    private func renderTableRow(_ row: Markup, into result: NSMutableAttributedString, header: Bool) {
        append("│ ", to: result, color: .secondaryLabelColor)
        for child in row.children {
            if let cell = child as? Table.Cell {
                let font = header ? NSFont.boldSystemFont(ofSize: 14) : bodyFont
                renderInlineChildren(cell, into: result, font: font)
            }
            append(" │ ", to: result, color: .secondaryLabelColor)
        }
        append("\n", to: result)
    }

    private func renderInlineChildren(_ node: Markup, into result: NSMutableAttributedString, font: NSFont) {
        for child in node.children { renderInline(child, into: result, font: font) }
    }

    private func renderInline(_ node: Markup, into result: NSMutableAttributedString, font: NSFont) {
        switch node {
        case let text as Markdown.Text:
            append(text.string, to: result, font: font)
        case let strong as Strong:
            renderInlineChildren(strong, into: result, font: NSFontManager.shared.convert(font, toHaveTrait: .boldFontMask))
        case let emphasis as Emphasis:
            renderInlineChildren(emphasis, into: result, font: NSFontManager.shared.convert(font, toHaveTrait: .italicFontMask))
        case let strike as Strikethrough:
            let start = result.length
            renderInlineChildren(strike, into: result, font: font)
            result.addAttribute(.strikethroughStyle, value: NSUnderlineStyle.single.rawValue, range: NSRange(location: start, length: result.length - start))
        case let code as InlineCode:
            append(code.code, to: result, font: .monospacedSystemFont(ofSize: font.pointSize, weight: .regular), background: .controlBackgroundColor)
        case let link as Markdown.Link:
            let start = result.length
            renderInlineChildren(link, into: result, font: font)
            if let destination = link.destination, let url = URL(string: destination) {
                result.addAttributes([.link: url, .foregroundColor: NSColor.linkColor, .underlineStyle: NSUnderlineStyle.single.rawValue], range: NSRange(location: start, length: result.length - start))
            }
        case let image as Markdown.Image:
            append("🖼 ", to: result, font: font)
            let start = result.length
            renderInlineChildren(image, into: result, font: font)
            if result.length == start { append(image.source ?? "图片", to: result, font: font) }
        case is LineBreak:
            append("\n", to: result, font: font)
        case is SoftBreak:
            append(" ", to: result, font: font)
        case is InlineHTML:
            break
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
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = 3
        paragraph.paragraphSpacing = 2
        var attributes: [NSAttributedString.Key: Any] = [
            .foregroundColor: color,
            .font: font ?? bodyFont,
            .paragraphStyle: paragraph
        ]
        if let background { attributes[.backgroundColor] = background }
        result.append(NSAttributedString(string: string, attributes: attributes))
    }
}

public enum YCodeNativeImageDecoder {
    public static func decode(_ data: Data) -> NSImage? { NSImage(data: data) }
}
