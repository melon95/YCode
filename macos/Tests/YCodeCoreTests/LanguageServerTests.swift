import Foundation
import Testing
@testable import YCodeCore

@Suite("Native language server support")
struct LanguageServerTests {
    @Test("catalog preserves all six accepted server manifests")
    func catalog() {
        #expect(YCodeLSPCatalog.manifests.map(\.id) == [
            "rust-analyzer", "typescript-language-server", "pyright", "gopls", "jdtls", "omnisharp"
        ])
        #expect(YCodeLSPCatalog.manifest(for: "View.tsx")?.languageID(for: "View.tsx") == "typescriptreact")
        #expect(YCodeLSPCatalog.manifest(for: "script.py")?.id == "pyright")
        #expect(YCodeLSPCatalog.manifest(for: "unknown.ycode") == nil)
    }

    @Test("framing accepts fragmented and adjacent messages")
    func framing() throws {
        let first = Data("{\"one\":1}".utf8)
        let second = Data("{\"two\":2}".utf8)
        let wire = frame(first) + frame(second)
        var parser = YCodeLSPFrameParser()
        #expect(try parser.append(wire.prefix(9)).isEmpty)
        let messages = try parser.append(wire.dropFirst(9))
        #expect(messages == [first, second])
    }

    @Test("semantic token deltas and definition response shapes decode")
    func decoding() {
        let tokens = YCodeLSPClient.decodeSemanticTokens(
            [0, 3, 4, 0, 1, 1, 2, 5, 1, 0],
            tokenTypes: ["function", "variable"],
            tokenModifiers: ["declaration"]
        )
        #expect(tokens == [
            .init(line: 0, utf16Character: 3, length: 4, type: "function", modifiers: ["declaration"]),
            .init(line: 1, utf16Character: 2, length: 5, type: "variable", modifiers: [])
        ])
        let definition: YCodeJSONValue = .array([.object([
            "targetUri": .string("file:///tmp/value.swift"),
            "targetSelectionRange": .object([
                "start": .object(["line": .number(2), "character": .number(4)]),
                "end": .object(["line": .number(2), "character": .number(9)])
            ])
        ])])
        #expect(YCodeLSPClient.decodeDefinitions(definition).first == .init(
            uri: "file:///tmp/value.swift", startLine: 2, startUTF16Character: 4,
            endLine: 2, endUTF16Character: 9
        ))
    }

    @Test("installation is staged, persisted and removed without partial success")
    func installationLifecycle() async throws {
        let root = try temporaryDirectory("lsp-install")
        defer { try? FileManager.default.removeItem(at: root) }
        try YCodeNativeDatabase.prepare(at: root.appendingPathComponent("ycode.db"))
        let manifest = YCodeLSPServerManifest(
            id: "fixture", displayName: "Fixture", description: "fixture",
            languageByExtension: [".fixture": "fixture"], homepage: "https://example.invalid",
            installPlan: .githubGzip(repo: "unused/unused", arm64Asset: "unused", x86Asset: "unused", binaryName: "fixture"),
            commandArguments: [], commandEnvironment: [:], requiredCommands: [], adoptSystemCommand: "/usr/bin/true"
        )
        let recorder = ProgressRecorder()
        let installer = YCodeLSPInstaller(dataRoot: root)
        let installation = try await installer.install(manifest: manifest) { await recorder.append($0) }
        #expect(FileManager.default.isExecutableFile(atPath: installation.binaryURL.path))
        #expect(await recorder.values.map(\.stage) == [.resolving, .finalizing])
        let repository = try YCodeLSPInstallationRepository(databaseURL: root.appendingPathComponent("ycode.db"))
        try repository.upsert(installation)
        #expect(try repository.get("fixture") == installation)
        try installer.uninstall(serverID: "fixture")
        try repository.delete("fixture")
        #expect(try repository.get("fixture") == nil)
    }

    @Test("missing installer requirement fails before creating an install record")
    func missingRequirement() async throws {
        let root = try temporaryDirectory("lsp-missing")
        defer { try? FileManager.default.removeItem(at: root) }
        let manifest = YCodeLSPServerManifest(
            id: "missing", displayName: "Missing", description: "missing",
            languageByExtension: [".x": "x"], homepage: "https://example.invalid",
            installPlan: .go(package: "invalid", binaryName: "missing"),
            commandArguments: [], commandEnvironment: [:], requiredCommands: ["ycode-command-that-does-not-exist"], adoptSystemCommand: nil
        )
        await #expect(throws: YCodeLSPError.requirementsMissing(["ycode-command-that-does-not-exist"])) {
            try await YCodeLSPInstaller(dataRoot: root).install(manifest: manifest) { _ in }
        }
    }

    @Test("directory installation records never appear runnable")
    func directoryInstallationRecordIsRejected() async throws {
        let root = try temporaryDirectory("lsp-directory-record")
        defer { try? FileManager.default.removeItem(at: root) }
        let invalidBinary = root.appendingPathComponent("typescript-language-server", isDirectory: true)
        try FileManager.default.createDirectory(at: invalidBinary, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: invalidBinary.path)

        let repository = try YCodeLSPInstallationRepository(databaseURL: root.appendingPathComponent("ycode.db"))
        try repository.upsert(.init(
            serverID: "typescript-language-server",
            version: "broken",
            binaryURL: invalidBinary,
            installedAtMilliseconds: 1
        ))

        let service = try YCodeLanguageServerService(dataRoot: root)
        let status = try await service.manifestStatuses().first { $0.manifest.id == "typescript-language-server" }
        #expect(status?.installation == nil)
        let source = root.appendingPathComponent("main.ts")
        try Data("export const value = 1\n".utf8).write(to: source)
        #expect(try await service.openDocument(
            projectID: "fixture", projectRoot: root, fileURL: source,
            text: "export const value = 1\n", version: 1
        ) == false)
    }

    @Test("stdio client performs open change semantic definition diagnostics and close")
    func clientRoundTrip() async throws {
        let root = try temporaryDirectory("lsp-client")
        defer { try? FileManager.default.removeItem(at: root) }
        let script = try fakeServerCopy(into: root)
        let log = root.appendingPathComponent("messages.jsonl")
        let manifest = YCodeLSPServerManifest(
            id: "fake", displayName: "Fake", description: "fake",
            languageByExtension: [".swift": "swift"], homepage: "https://example.invalid",
            installPlan: .go(package: "unused", binaryName: "unused"),
            commandArguments: [], commandEnvironment: ["YCODE_FAKE_LSP_LOG": log.path], requiredCommands: [], adoptSystemCommand: nil
        )
        let installation = YCodeLSPInstallation(serverID: "fake", version: "1", binaryURL: script, installedAtMilliseconds: 1)
        let events = EventRecorder()
        let client = YCodeLSPClient(manifest: manifest, installation: installation, projectID: "project", rootURL: root) {
            await events.append($0)
        }
        do {
            try await client.start(timeout: 3)
        } catch {
            let serverLog = (try? String(contentsOf: log, encoding: .utf8)) ?? "<no log>"
            Issue.record("start failed: \(error); server log: \(serverLog)")
            throw error
        }
        let uri = root.appendingPathComponent("main.swift").absoluteString
        try await client.didOpen(uri: uri, languageID: "swift", version: 1, text: "let value = call()")
        try await client.didChange(uri: uri, version: 2, text: "let value = changed()")
        let tokens = try await client.semanticTokens(uri: uri)
        #expect(tokens.count == 2)
        let definitions = try await client.definition(uri: uri, line: 0, utf16Character: 14)
        #expect(definitions.first?.startUTF16Character == 3)
        try await client.didClose(uri: uri)
        try? await Task.sleep(for: .milliseconds(100))
        #expect(await events.values.contains { if case .diagnostics(_, _, let items) = $0 { items.first?.message == "fake warning" } else { false } })
        await client.shutdown()
        let methods = try String(contentsOf: log, encoding: .utf8)
        #expect(methods.contains("textDocument/didOpen"))
        #expect(methods.contains("\"version\": 2"))
        #expect(methods.contains("textDocument/didClose"))
    }

    private func frame(_ body: Data) -> Data {
        Data("Content-Length: \(body.count)\r\n\r\n".utf8) + body
    }

    private func temporaryDirectory(_ name: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("ycode-\(name)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func fakeServerCopy(into root: URL) throws -> URL {
        let source = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Fixtures/fake_lsp.py")
        let destination = root.appendingPathComponent("fake_lsp.py")
        try FileManager.default.copyItem(at: source, to: destination)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: destination.path)
        return destination
    }
}

private actor ProgressRecorder {
    private(set) var values: [YCodeLSPInstallProgress] = []
    func append(_ value: YCodeLSPInstallProgress) { values.append(value) }
}

private actor EventRecorder {
    private(set) var values: [YCodeLSPEvent] = []
    func append(_ value: YCodeLSPEvent) { values.append(value) }
}
