import Foundation

public struct YCodeLSPFrameParser: Sendable {
    private var buffer = Data()

    public init() {}

    public mutating func append(_ data: Data) throws -> [Data] {
        buffer.append(data)
        var messages: [Data] = []
        while let delimiter = buffer.range(of: Data("\r\n\r\n".utf8)) {
            let headerData = buffer[..<delimiter.lowerBound]
            guard let headers = String(data: headerData, encoding: .utf8) else {
                throw YCodeLSPError.invalidResponse("消息头不是 UTF-8")
            }
            guard let lengthLine = headers.split(separator: "\n").first(where: {
                $0.lowercased().hasPrefix("content-length:")
            }), let length = Int(lengthLine.split(separator: ":", maxSplits: 1)[1].trimmingCharacters(in: .whitespacesAndNewlines)), length >= 0 else {
                throw YCodeLSPError.invalidResponse("缺少 Content-Length")
            }
            let bodyStart = delimiter.upperBound
            guard buffer.count - bodyStart >= length else { break }
            let bodyEnd = bodyStart + length
            messages.append(buffer.subdata(in: bodyStart..<bodyEnd))
            buffer.removeSubrange(0..<bodyEnd)
        }
        return messages
    }
}

public actor YCodeLSPClient {
    public typealias EventHandler = @Sendable (YCodeLSPEvent) async -> Void

    public let serverID: String
    public let projectID: String
    public let rootURL: URL

    private let manifest: YCodeLSPServerManifest
    private let installation: YCodeLSPInstallation
    private let eventHandler: EventHandler
    private var process: Process?
    private var stdinHandle: FileHandle?
    private var stdoutHandle: FileHandle?
    private var stderrHandle: FileHandle?
    private var parser = YCodeLSPFrameParser()
    private var nextID = 1
    private var pending: [Int: CheckedContinuation<YCodeJSONValue, Error>] = [:]
    private var timeoutTasks: [Int: Task<Void, Never>] = [:]
    private var tokenTypes: [String] = []
    private var tokenModifiers: [String] = []
    private var exited = false
    private var stderrTail = ""

    public init(
        manifest: YCodeLSPServerManifest,
        installation: YCodeLSPInstallation,
        projectID: String,
        rootURL: URL,
        eventHandler: @escaping EventHandler = { _ in }
    ) {
        self.serverID = manifest.id
        self.projectID = projectID
        self.rootURL = rootURL
        self.manifest = manifest
        self.installation = installation
        self.eventHandler = eventHandler
    }

    deinit {
        process?.terminationHandler = nil
        if process?.isRunning == true { process?.terminate() }
        stdinHandle?.closeFile()
        stdoutHandle?.readabilityHandler = nil
        stderrHandle?.readabilityHandler = nil
    }

    public var isRunning: Bool { process?.isRunning == true && !exited }

    public func start(timeout: TimeInterval = 30) async throws {
        guard process == nil else { return }
        guard FileManager.default.isExecutableFile(atPath: installation.binaryURL.path) else {
            throw YCodeLSPError.notInstalled(serverID)
        }

        let serverRoot = installation.binaryURL.deletingLastPathComponent()
        let args = manifest.commandArguments.map {
            $0.replacingOccurrences(of: "${SERVER_DIR}", with: serverRoot.path)
                .replacingOccurrences(of: "${PROJECT_ID}", with: projectID)
        }
        let shell = ProcessInfo.processInfo.environment["SHELL"].flatMap { $0.isEmpty ? nil : $0 } ?? "/bin/zsh"
        let command = (["exec", YCodeAgentLauncher.shellQuote(installation.binaryURL.path)] + args.map(YCodeAgentLauncher.shellQuote))
            .joined(separator: " ")
        let process = Process()
        let stdin = Pipe()
        let stdout = Pipe()
        let stderr = Pipe()
        process.executableURL = URL(fileURLWithPath: shell)
        process.arguments = ["-l", "-c", command]
        process.currentDirectoryURL = rootURL
        var environment = ProcessInfo.processInfo.environment
        for (key, value) in manifest.commandEnvironment { environment[key] = value }
        process.environment = environment
        process.standardInput = stdin
        process.standardOutput = stdout
        process.standardError = stderr
        self.process = process
        stdinHandle = stdin.fileHandleForWriting

        try process.run()
        exited = false

        let stdoutHandle = stdout.fileHandleForReading
        self.stdoutHandle = stdoutHandle
        stdoutHandle.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            if data.isEmpty {
                handle.readabilityHandler = nil
            } else {
                Task { await self?.consume(data) }
            }
        }
        let stderrHandle = stderr.fileHandleForReading
        self.stderrHandle = stderrHandle
        stderrHandle.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            if data.isEmpty {
                handle.readabilityHandler = nil
            } else {
                Task { await self?.consumeStderr(data) }
            }
        }
        process.terminationHandler = { [weak self] process in
            Task { await self?.processDidExit(process.terminationStatus) }
        }

        let response = try await request(method: "initialize", params: initializeParams(), timeout: timeout)
        if let legend = response["capabilities"]?["semanticTokensProvider"]?["legend"] {
            tokenTypes = legend["tokenTypes"]?.arrayValue?.compactMap(\.stringValue) ?? []
            tokenModifiers = legend["tokenModifiers"]?.arrayValue?.compactMap(\.stringValue) ?? []
        }
        try notify(method: "initialized", params: .object([:]))
    }

    public func didOpen(uri: String, languageID: String, version: Int, text: String) throws {
        try notify(method: "textDocument/didOpen", params: .object([
            "textDocument": .object([
                "uri": .string(uri), "languageId": .string(languageID),
                "version": .number(Double(version)), "text": .string(text)
            ])
        ]))
    }

    public func didChange(uri: String, version: Int, text: String) throws {
        try notify(method: "textDocument/didChange", params: .object([
            "textDocument": .object(["uri": .string(uri), "version": .number(Double(version))]),
            "contentChanges": .array([.object(["text": .string(text)])])
        ]))
    }

    public func didClose(uri: String) throws {
        try notify(method: "textDocument/didClose", params: .object([
            "textDocument": .object(["uri": .string(uri)])
        ]))
    }

    public func semanticTokens(uri: String) async throws -> [YCodeLSPSemanticToken] {
        let response = try await request(
            method: "textDocument/semanticTokens/full",
            params: .object(["textDocument": .object(["uri": .string(uri)])]),
            timeout: 20
        )
        let data: [Int]
        if response == .null { return [] }
        if let values = response["data"]?.arrayValue {
            data = values.compactMap(\.intValue)
        } else {
            throw YCodeLSPError.invalidResponse("semanticTokens 缺少 data")
        }
        return Self.decodeSemanticTokens(data, tokenTypes: tokenTypes, tokenModifiers: tokenModifiers)
    }

    public func definition(uri: String, line: Int, utf16Character: Int) async throws -> [YCodeLSPDefinitionLocation] {
        let response = try await request(
            method: "textDocument/definition",
            params: .object([
                "textDocument": .object(["uri": .string(uri)]),
                "position": .object(["line": .number(Double(line)), "character": .number(Double(utf16Character))])
            ]),
            timeout: 20
        )
        return Self.decodeDefinitions(response)
    }

    public func shutdown() async {
        if isRunning {
            _ = try? await request(method: "shutdown", params: .null, timeout: 2)
            try? notify(method: "exit", params: .null)
            try? await Task.sleep(for: .milliseconds(100))
        }
        if process?.isRunning == true { process?.terminate() }
        failAll(YCodeLSPError.serverExited(serverID))
    }

    public static func decodeSemanticTokens(
        _ data: [Int],
        tokenTypes: [String],
        tokenModifiers: [String]
    ) -> [YCodeLSPSemanticToken] {
        guard data.count.isMultiple(of: 5) else { return [] }
        var line = 0
        var character = 0
        var result: [YCodeLSPSemanticToken] = []
        for index in stride(from: 0, to: data.count, by: 5) {
            let deltaLine = data[index]
            line += deltaLine
            character = deltaLine == 0 ? character + data[index + 1] : data[index + 1]
            let typeIndex = data[index + 3]
            guard data[index + 2] > 0, tokenTypes.indices.contains(typeIndex) else { continue }
            let bitset = data[index + 4]
            let modifiers = tokenModifiers.enumerated().compactMap { offset, name in
                bitset & (1 << offset) == 0 ? nil : name
            }
            result.append(.init(
                line: line,
                utf16Character: character,
                length: data[index + 2],
                type: tokenTypes[typeIndex],
                modifiers: modifiers
            ))
        }
        return result
    }

    public static func decodeDefinitions(_ value: YCodeJSONValue) -> [YCodeLSPDefinitionLocation] {
        if value == .null { return [] }
        let candidates = value.arrayValue ?? [value]
        return candidates.compactMap { item in
            let uri = item["uri"]?.stringValue ?? item["targetUri"]?.stringValue
            let range = item["range"] ?? item["targetSelectionRange"] ?? item["targetRange"]
            guard let uri,
                  let start = range?["start"], let end = range?["end"],
                  let startLine = start["line"]?.intValue,
                  let startCharacter = start["character"]?.intValue,
                  let endLine = end["line"]?.intValue,
                  let endCharacter = end["character"]?.intValue else { return nil }
            return .init(
                uri: uri, startLine: startLine, startUTF16Character: startCharacter,
                endLine: endLine, endUTF16Character: endCharacter
            )
        }
    }

    private func initializeParams() -> YCodeJSONValue {
        let rootURI = rootURL.absoluteURL.absoluteString
        let types = [
            "namespace", "type", "class", "enum", "interface", "struct", "typeParameter",
            "parameter", "variable", "property", "enumMember", "event", "function", "method",
            "macro", "keyword", "modifier", "comment", "string", "number", "regexp", "operator", "decorator"
        ].map(YCodeJSONValue.string)
        return .object([
            "processId": .number(Double(ProcessInfo.processInfo.processIdentifier)),
            "rootUri": .string(rootURI),
            "workspaceFolders": .array([.object(["uri": .string(rootURI), "name": .string(rootURL.lastPathComponent)])]),
            "capabilities": .object([
                "general": .object(["positionEncodings": .array([.string("utf-16")])]),
                "textDocument": .object([
                    "synchronization": .object(["dynamicRegistration": .bool(false), "didSave": .bool(false)]),
                    "definition": .object(["linkSupport": .bool(true)]),
                    "semanticTokens": .object([
                        "requests": .object(["full": .bool(true)]),
                        "tokenTypes": .array(types), "tokenModifiers": .array([]),
                        "formats": .array([.string("relative")]),
                        "overlappingTokenSupport": .bool(false), "multilineTokenSupport": .bool(false)
                    ]),
                    "publishDiagnostics": .object(["relatedInformation": .bool(false)])
                ]),
                "workspace": .object(["workspaceFolders": .bool(true), "configuration": .bool(true)])
            ]),
            "clientInfo": .object(["name": .string("ycode-native"), "version": .string(YCodeBuildInfo.version)]),
            "initializationOptions": .null
        ])
    }

    private func request(method: String, params: YCodeJSONValue, timeout: TimeInterval) async throws -> YCodeJSONValue {
        guard isRunning else { throw YCodeLSPError.serverExited(serverID) }
        let id = nextID
        nextID += 1
        return try await withCheckedThrowingContinuation { continuation in
            pending[id] = continuation
            do {
                try send(.object([
                    "jsonrpc": .string("2.0"), "id": .number(Double(id)),
                    "method": .string(method), "params": params
                ]))
                timeoutTasks[id] = Task { [weak self] in
                    try? await Task.sleep(for: .seconds(timeout))
                    await self?.timeoutRequest(id: id, method: method)
                }
            } catch {
                pending.removeValue(forKey: id)
                continuation.resume(throwing: error)
            }
        }
    }

    private func notify(method: String, params: YCodeJSONValue) throws {
        guard isRunning else { throw YCodeLSPError.serverExited(serverID) }
        try send(.object([
            "jsonrpc": .string("2.0"), "method": .string(method), "params": params
        ]))
    }

    private func send(_ value: YCodeJSONValue) throws {
        guard let stdinHandle else { throw YCodeLSPError.serverExited(serverID) }
        let body = try JSONEncoder().encode(value)
        var framed = Data("Content-Length: \(body.count)\r\n\r\n".utf8)
        framed.append(body)
        try stdinHandle.write(contentsOf: framed)
    }

    private func consume(_ data: Data) {
        do {
            for body in try parser.append(data) {
                let value = try JSONDecoder().decode(YCodeJSONValue.self, from: body)
                handle(value)
            }
        } catch {
            failAll(error)
        }
    }

    private func handle(_ message: YCodeJSONValue) {
        let id = message["id"]?.intValue
        let method = message["method"]?.stringValue
        if let id, method == nil {
            timeoutTasks.removeValue(forKey: id)?.cancel()
            guard let continuation = pending.removeValue(forKey: id) else { return }
            if let error = message["error"], error != .null {
                continuation.resume(throwing: YCodeLSPError.serverError(error["message"]?.stringValue ?? "未知错误"))
            } else {
                continuation.resume(returning: message["result"] ?? .null)
            }
            return
        }
        if let id, let method {
            let result: YCodeJSONValue
            if method == "workspace/configuration" {
                let count = message["params"]?["items"]?.arrayValue?.count ?? 0
                result = .array(Array(repeating: .null, count: count))
            } else if method == "workspace/workspaceFolders" {
                result = .array([.object(["uri": .string(rootURL.absoluteString), "name": .string(rootURL.lastPathComponent)])])
            } else {
                result = .null
            }
            try? send(.object(["jsonrpc": .string("2.0"), "id": .number(Double(id)), "result": result]))
            return
        }
        if method == "textDocument/publishDiagnostics" {
            let params = message["params"] ?? .object([:])
            let uri = params["uri"]?.stringValue ?? ""
            let diagnostics = params["diagnostics"]?.arrayValue?.compactMap { item -> YCodeLSPDiagnostic? in
                guard let message = item["message"]?.stringValue else { return nil }
                return .init(
                    message: message,
                    severity: item["severity"]?.intValue,
                    line: item["range"]?["start"]?["line"]?.intValue,
                    utf16Character: item["range"]?["start"]?["character"]?.intValue
                )
            } ?? []
            Task { await eventHandler(.diagnostics(uri: uri, serverID: serverID, items: diagnostics)) }
        }
    }

    private func timeoutRequest(id: Int, method: String) {
        timeoutTasks.removeValue(forKey: id)
        let error: YCodeLSPError = stderrTail.isEmpty
            ? .timedOut(method)
            : .serverError("\(method) 超时；stderr：\(stderrTail)")
        pending.removeValue(forKey: id)?.resume(throwing: error)
    }

    private func consumeStderr(_ data: Data) {
        stderrTail += String(decoding: data, as: UTF8.self)
        if stderrTail.count > 4_096 { stderrTail = String(stderrTail.suffix(4_096)) }
    }

    private func processDidExit(_ exitCode: Int32) {
        guard !exited else { return }
        exited = true
        failAll(YCodeLSPError.serverExited(serverID))
        Task { await eventHandler(.serverExited(serverID: serverID, projectID: projectID, exitCode: exitCode)) }
    }

    private func failAll(_ error: Error) {
        for task in timeoutTasks.values { task.cancel() }
        timeoutTasks.removeAll()
        let continuations = pending.values
        pending.removeAll()
        for continuation in continuations { continuation.resume(throwing: error) }
    }
}
