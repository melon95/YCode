import AppKit
import Foundation
import Testing
import TandockCore
import TandockEditorSupport

@Suite("Syntax highlighting and native preview", .serialized)
struct SyntaxPreviewTests {
    @Test("all 39 legacy language groups resolve and produce native highlight tokens")
    func allLanguageGroupsHighlight() {
        #expect(TandockSyntaxRegistry.groups.count == 39)
        #expect(Set(TandockSyntaxRegistry.groups.map(\.id)).count == 39)

        let highlighter = TandockSyntaxHighlighter()
        for group in TandockSyntaxRegistry.groups {
            let path: String
            if let ext = group.extensions.first {
                path = "sample.\(ext)"
            } else {
                path = "Dockerfile.dev"
            }
            #expect(TandockSyntaxRegistry.language(forPath: path)?.id == group.id, "did not resolve \(group.id)")
            #expect(!highlighter.tokens(in: group.verificationSample, path: path).isEmpty, "did not highlight \(group.id)")
        }
    }

    @Test("every extension and special filename stays mapped with legacy indentation")
    func registryMapping() {
        for group in TandockSyntaxRegistry.groups {
            for ext in group.extensions {
                #expect(TandockSyntaxRegistry.language(forPath: "folder/file.\(ext)")?.id == group.id)
            }
            for filename in group.filenames where !filename.contains("*") {
                #expect(TandockSyntaxRegistry.language(forPath: filename)?.id == group.id)
            }
        }
        #expect(TandockSyntaxRegistry.language(forPath: "Dockerfile.release")?.id == "dockerfile")
        #expect(Set(TandockSyntaxRegistry.groups.filter { $0.indentWidth == 4 }.map(\.id)) == ["rust", "python", "java", "csharp"])
        #expect(TandockSyntaxRegistry.language(forPath: "unknown.tandock") == nil)
        #expect(TandockSyntaxHighlighter().tokens(in: "plain text", path: "unknown.tandock").isEmpty)
    }

    @Test("large source highlighting completes without truncating the final line")
    func largeSource() {
        let source = (1...20_000).map { "let value\($0) = \($0) // 中文" }.joined(separator: "\n")
        let tokens = TandockSyntaxHighlighter().tokens(in: source, path: "large.swift")
        #expect(tokens.count >= 60_000)
        #expect(tokens.allSatisfy { NSMaxRange($0.range) <= (source as NSString).length })
    }

    @Test("preview routing matches markdown SVG and raster image parity")
    func previewRouting() {
        #expect(TandockPreviewKind.resolve(path: "README.md") == .markdown)
        #expect(TandockPreviewKind.resolve(path: "icon.SVG") == .svg)
        for ext in ["png", "jpg", "jpeg", "gif", "webp", "bmp", "ico", "avif", "apng"] {
            #expect(TandockPreviewKind.resolve(path: "image.\(ext)") == .image)
        }
        #expect(TandockPreviewKind.resolve(path: "main.swift") == .source)
    }

    @Test("image payload is retained even when a damaged image happens to be UTF-8")
    func imagePayload() throws {
        let container = FileManager.default.temporaryDirectory.appendingPathComponent("tandock-preview-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: container) }
        try FileManager.default.createDirectory(at: container, withIntermediateDirectories: true)
        let broken = Data("not-an-image".utf8)
        try broken.write(to: container.appendingPathComponent("broken.png"))
        let snapshot = try TandockEditorFileService().readFile(root: container, relativePath: "broken.png")
        #expect(snapshot.previewData == broken)
        #expect(TandockNativeImageDecoder.decode(snapshot.previewData ?? Data()) == nil)
    }

    @Test("markdown renders native block structure and ignores embedded HTML")
    func markdown() {
        let source = """
        # Heading

        Text with **bold**, ~~strike~~, and [link](https://example.com).

        - [x] done
        - [ ] pending

        | Name | Value |
        | --- | --- |
        | 中文 | 1 |

        <script>alert('unsafe')</script>
        """
        let rendered = TandockMarkdownRenderer().render(source)
        #expect(rendered.string.contains("Heading\n\n"))
        #expect(rendered.string.contains("☑︎ done"))
        #expect(rendered.string.contains("☐ pending"))
        #expect(rendered.string.contains("│ Name │ Value │"))
        #expect(!rendered.string.contains("script"))
        #expect(!rendered.string.contains("**"))
    }

    @Test("valid bitmap and SVG decode while damaged data fails closed")
    @MainActor
    func nativeImages() throws {
        let png = try #require(Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII="))
        let svg = Data("<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"20\" height=\"20\"><rect width=\"20\" height=\"20\" fill=\"red\"/></svg>".utf8)
        #expect(TandockNativeImageDecoder.decode(png) != nil)
        #expect(TandockNativeImageDecoder.decode(svg) != nil)
        #expect(TandockNativeImageDecoder.decode(Data("broken".utf8)) == nil)
        #expect(TandockNativeImageDecoder.decode(Data("<svg><broken>".utf8)) == nil)
    }
}
