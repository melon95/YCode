import Foundation
import YCodeCore

if CommandLine.arguments.contains("--version") {
    print("ycode-mcp \(YCodeBuildInfo.version)")
    exit(0)
}

let environment = ProcessInfo.processInfo.environment
let dataRoot = YCodeDataRootResolver.resolve(environment: environment)
let repository: YCodeTodoRepository
do {
    repository = try YCodeTodoRepository(databaseURL: dataRoot.appendingPathComponent("ycode.db"))
} catch {
    FileHandle.standardError.write(Data("ycode-mcp: \(displayError(error))\n".utf8))
    exit(1)
}

let terminalID = environment["YCODE_TERMINAL_ID"]
let cwd = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)

while let line = readLine(strippingNewline: true) {
    guard !line.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
          let data = line.data(using: .utf8),
          let request = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
        writeResponse(errorResponse(id: nil, code: -32700, message: "Parse error"))
        continue
    }
    guard request["jsonrpc"] as? String == "2.0", let method = request["method"] as? String else {
        writeResponse(errorResponse(id: request["id"], code: -32600, message: "Invalid Request"))
        continue
    }
    guard let id = request["id"] else { continue }
    let parameters = request["params"] as? [String: Any] ?? [:]
    switch method {
    case "initialize":
        let requestedVersion = parameters["protocolVersion"] as? String ?? "2024-11-05"
        writeResponse(successResponse(id: id, result: [
            "protocolVersion": requestedVersion,
            "capabilities": ["tools": [:]],
            "serverInfo": ["name": "ycode-todos", "version": YCodeBuildInfo.version],
            "instructions": "Manage the current YCode project's todo list. The project is inferred from the current terminal; never ask for a project id."
        ]))
    case "ping":
        writeResponse(successResponse(id: id, result: [:]))
    case "tools/list":
        writeResponse(successResponse(id: id, result: ["tools": toolDefinitions()]))
    case "tools/call":
        let name = parameters["name"] as? String ?? ""
        let arguments = parameters["arguments"] as? [String: Any] ?? [:]
        writeResponse(successResponse(id: id, result: callTool(name: name, arguments: arguments)))
    default:
        writeResponse(errorResponse(id: id, code: -32601, message: "Method not found: \(method)"))
    }
}

private func toolDefinitions() -> [[String: Any]] {
    [
      [
        "name": "list_todos",
        "description": "List all todo items for the current project, including status, ordering, and timestamps.",
        "inputSchema": ["type": "object", "properties": [:], "additionalProperties": false]
    ],
    [
        "name": "add_todo",
        "description": "Add a todo to the current project. It starts in todo status at the end of the list.",
        "inputSchema": [
            "type": "object",
            "properties": ["title": ["type": "string", "description": "The todo text"]],
            "required": ["title"],
            "additionalProperties": false
        ]
    ],
    [
        "name": "update_todo",
        "description": "Update a todo title and/or status. Status is todo, doing, or done.",
        "inputSchema": [
            "type": "object",
            "properties": [
                "id": ["type": "string"],
                "title": ["type": "string"],
                "status": ["type": "string", "enum": ["todo", "doing", "done"]]
            ],
            "required": ["id"],
            "additionalProperties": false
        ]
    ],
    [
        "name": "delete_todo",
        "description": "Delete a todo from the current project by id.",
        "inputSchema": [
            "type": "object",
            "properties": ["id": ["type": "string"]],
            "required": ["id"],
            "additionalProperties": false
        ]
      ]
    ]
}

private func callTool(name: String, arguments: [String: Any]) -> [String: Any] {
    do {
        let projectID = try repository.resolveProjectID(terminalID: terminalID, cwd: cwd)
        let value: Any
        switch name {
        case "list_todos":
            value = try repository.list(projectID: projectID)
        case "add_todo":
            guard let title = arguments["title"] as? String else { throw MCPInputError("add_todo requires `title`") }
            value = try repository.create(projectID: projectID, title: title)
        case "update_todo":
            guard let id = arguments["id"] as? String else { throw MCPInputError("update_todo requires `id`") }
            let title = arguments["title"] as? String
            let status = arguments["status"] as? String
            guard title != nil || status != nil else {
                throw MCPInputError("update_todo requires at least one of `title` or `status`")
            }
            value = try repository.update(id: id, title: title, statusRaw: status)
        case "delete_todo":
            guard let id = arguments["id"] as? String else { throw MCPInputError("delete_todo requires `id`") }
            try repository.delete(id: id)
            value = NSNull()
        default:
            throw MCPInputError("Unknown tool: \(name)")
        }
        return toolResult(text: encodedText(value), isError: false)
    } catch {
        return toolResult(text: displayError(error), isError: true)
    }
}

private struct MCPInputError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

private func encodedText(_ value: Any) -> String {
    if let todo = value as? YCodeTodo {
        let data = try? JSONEncoder.sorted.encode(todo)
        return data.map { String(decoding: $0, as: UTF8.self) } ?? "null"
    }
    if let todos = value as? [YCodeTodo] {
        let data = try? JSONEncoder.sorted.encode(todos)
        return data.map { String(decoding: $0, as: UTF8.self) } ?? "[]"
    }
    return "null"
}

private func toolResult(text: String, isError: Bool) -> [String: Any] {
    ["content": [["type": "text", "text": text]], "isError": isError]
}

private func displayError(_ error: Error) -> String {
    if let localized = error as? LocalizedError, let description = localized.errorDescription {
        return description
    }
    return String(describing: error)
}

private func successResponse(id: Any, result: Any) -> [String: Any] {
    ["jsonrpc": "2.0", "id": normalizedID(id), "result": result]
}

private func errorResponse(id: Any?, code: Int, message: String) -> [String: Any] {
    ["jsonrpc": "2.0", "id": normalizedID(id), "error": ["code": code, "message": message]]
}

private func normalizedID(_ id: Any?) -> Any {
    guard let id, !(id is NSNull) else { return NSNull() }
    return id
}

private func writeResponse(_ response: [String: Any]) {
    guard let data = try? JSONSerialization.data(withJSONObject: response, options: [.sortedKeys]) else { return }
    FileHandle.standardOutput.write(data)
    FileHandle.standardOutput.write(Data([0x0A]))
}

private extension JSONEncoder {
    static var sorted: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }
}
