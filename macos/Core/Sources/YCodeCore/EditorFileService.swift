import Darwin
import Foundation

public struct YCodeEditorFileSnapshot: Equatable, Sendable {
    public let contents: String
    public let isBinary: Bool
    public let previewData: Data?

    public init(contents: String, isBinary: Bool, previewData: Data? = nil) {
        self.contents = contents
        self.isBinary = isBinary
        self.previewData = previewData
    }
}

public enum YCodeEditorFileError: LocalizedError, Equatable {
    case binaryFile(String)
    case saveConflict(path: String, currentContents: String)
    case operationFailed(action: String, path: String, message: String)

    public var errorDescription: String? {
        switch self {
        case let .binaryFile(path): "二进制文件不能作为文本编辑：\(path)"
        case let .saveConflict(path, _): "文件已在磁盘上改变，未覆盖：\(path)"
        case let .operationFailed(action, path, message): "\(action) \(path) 失败：\(message)"
        }
    }
}

public struct YCodeEditorFileService: Sendable {
    private let projectFiles = YCodeProjectFileService()

    public init() {}

    public func readFile(root: URL, relativePath: String) throws -> YCodeEditorFileSnapshot {
        let url = try projectFiles.existingFileURL(root: root, relativePath: relativePath)
        do {
            let data = try Data(contentsOf: url, options: .mappedIfSafe)
            let previewData = YCodePreviewKind.resolve(path: relativePath) == .image ? data : nil
            let head = data.prefix(8_192)
            guard !head.contains(0), let contents = String(data: data, encoding: .utf8) else {
                return YCodeEditorFileSnapshot(contents: "", isBinary: true, previewData: previewData)
            }
            return YCodeEditorFileSnapshot(contents: contents, isBinary: false, previewData: previewData)
        } catch let error as YCodeProjectFileError {
            throw error
        } catch {
            throw YCodeEditorFileError.operationFailed(
                action: "读取",
                path: relativePath,
                message: error.localizedDescription
            )
        }
    }

    @discardableResult
    public func saveTextFile(
        root: URL,
        relativePath: String,
        expectedContents: String,
        newContents: String,
        allowOverwrite: Bool = false
    ) throws -> YCodeEditorFileSnapshot {
        let url = try projectFiles.existingFileURL(root: root, relativePath: relativePath)
        let current = try readFile(root: root, relativePath: relativePath)
        guard !current.isBinary else { throw YCodeEditorFileError.binaryFile(relativePath) }
        guard allowOverwrite || current.contents == expectedContents else {
            throw YCodeEditorFileError.saveConflict(path: relativePath, currentContents: current.contents)
        }

        let fileManager = FileManager.default
        let temporary = url.deletingLastPathComponent()
            .appendingPathComponent(".\(url.lastPathComponent).ycode-\(UUID().uuidString).tmp")
        defer { try? fileManager.removeItem(at: temporary) }

        do {
            let attributes = try fileManager.attributesOfItem(atPath: url.path)
            try Data(newContents.utf8).write(to: temporary, options: .withoutOverwriting)
            if let permissions = attributes[.posixPermissions] {
                try fileManager.setAttributes([.posixPermissions: permissions], ofItemAtPath: temporary.path)
            }
            let status = temporary.path.withCString { source in
                url.path.withCString { destination in Darwin.rename(source, destination) }
            }
            guard status == 0 else {
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
            return YCodeEditorFileSnapshot(contents: newContents, isBinary: false)
        } catch {
            throw YCodeEditorFileError.operationFailed(
                action: "保存",
                path: relativePath,
                message: error.localizedDescription
            )
        }
    }
}
