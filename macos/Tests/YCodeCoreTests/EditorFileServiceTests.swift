import Foundation
import Testing
@testable import YCodeCore

@Suite("Editor file service", .serialized)
struct EditorFileServiceTests {
    @Test("UTF-8 save compares disk contents and preserves executable permissions")
    func safeSave() throws {
        let fixture = try EditorFileFixture()
        defer { fixture.remove() }
        try fixture.write("脚本 file.sh", "first\n")
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fixture.url("脚本 file.sh").path)
        let service = YCodeEditorFileService()

        let opened = try service.readFile(root: fixture.root, relativePath: "脚本 file.sh")
        #expect(opened == YCodeEditorFileSnapshot(contents: "first\n", isBinary: false))
        let saved = try service.saveTextFile(
            root: fixture.root,
            relativePath: "脚本 file.sh",
            expectedContents: opened.contents,
            newContents: "中文 🎉\n"
        )
        #expect(saved.contents == "中文 🎉\n")
        #expect(try String(contentsOf: fixture.url("脚本 file.sh"), encoding: .utf8) == "中文 🎉\n")
        let attributes = try FileManager.default.attributesOfItem(atPath: fixture.url("脚本 file.sh").path)
        #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o755)
    }

    @Test("external edits are never overwritten without explicit permission")
    func conflict() throws {
        let fixture = try EditorFileFixture()
        defer { fixture.remove() }
        try fixture.write("A.txt", "base")
        let service = YCodeEditorFileService()
        let opened = try service.readFile(root: fixture.root, relativePath: "A.txt")
        try fixture.write("A.txt", "external")

        #expect(throws: YCodeEditorFileError.saveConflict(path: "A.txt", currentContents: "external")) {
            try service.saveTextFile(
                root: fixture.root,
                relativePath: "A.txt",
                expectedContents: opened.contents,
                newContents: "draft"
            )
        }
        #expect(try String(contentsOf: fixture.url("A.txt"), encoding: .utf8) == "external")

        try service.saveTextFile(
            root: fixture.root,
            relativePath: "A.txt",
            expectedContents: opened.contents,
            newContents: "draft",
            allowOverwrite: true
        )
        #expect(try String(contentsOf: fixture.url("A.txt"), encoding: .utf8) == "draft")
    }

    @Test("binary and escaping files cannot enter the text editor")
    func binaryAndSafety() throws {
        let fixture = try EditorFileFixture()
        defer { fixture.remove() }
        try Data([0x41, 0, 0x42]).write(to: fixture.url("binary.dat"))
        let service = YCodeEditorFileService()

        #expect(try service.readFile(root: fixture.root, relativePath: "binary.dat").isBinary)
        #expect(throws: YCodeProjectFileError.self) {
            _ = try service.readFile(root: fixture.root, relativePath: "../outside.txt")
        }
    }

    @Test("preview replacement pin dirty close and path changes match editor tabs")
    func tabs() {
        var tabs = YCodeEditorTabs()
        #expect(tabs.open("A.swift", preview: true) == nil)
        #expect(tabs.previewPath == "A.swift")
        #expect(tabs.open("B.swift", preview: true) == "A.swift")
        #expect(tabs.paths == ["B.swift"])
        tabs.markDirty("B.swift", dirty: true)
        #expect(tabs.previewPath == nil)
        #expect(tabs.dirtyPaths == ["B.swift"])
        tabs.open("folder/C.swift", preview: true)
        tabs.pin("folder/C.swift")
        tabs.select("B.swift")
        tabs.movePath(from: "folder", to: "renamed")
        #expect(tabs.paths == ["B.swift", "renamed/C.swift"])
        #expect(tabs.close("B.swift") == "renamed/C.swift")
        #expect(tabs.removePath("renamed") == ["renamed/C.swift"])
        #expect(tabs.paths.isEmpty)
        #expect(tabs.selectedPath == nil)
    }
}

private struct EditorFileFixture {
    let container: URL
    let root: URL

    init() throws {
        container = FileManager.default.temporaryDirectory
            .appendingPathComponent("ycode-editor-files-\(UUID().uuidString)", isDirectory: true)
        root = container.appendingPathComponent("项目 root", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    func url(_ path: String) -> URL { root.appendingPathComponent(path) }

    func write(_ path: String, _ contents: String) throws {
        try Data(contents.utf8).write(to: url(path), options: .atomic)
    }

    func remove() { try? FileManager.default.removeItem(at: container) }
}
