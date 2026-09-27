import Darwin
import Foundation

public struct YCodeFileEntry: Equatable, Identifiable, Sendable {
    public let path: String
    public let isDirectory: Bool
    public let isSymbolicLink: Bool

    public var id: String { path }

    public init(path: String, isDirectory: Bool, isSymbolicLink: Bool = false) {
        self.path = path
        self.isDirectory = isDirectory
        self.isSymbolicLink = isSymbolicLink
    }
}

public enum YCodeProjectFileError: LocalizedError, Equatable {
    case rootUnavailable(String)
    case invalidPath(String)
    case pathEscapesRoot(String)
    case notFound(String)
    case notFile(String)
    case alreadyExists(String)
    case operationFailed(action: String, path: String, message: String)

    public var errorDescription: String? {
        switch self {
        case let .rootUnavailable(path): "项目目录不可用：\(path)"
        case let .invalidPath(path): "无效的项目相对路径：\(path)"
        case let .pathEscapesRoot(path): "路径超出项目目录：\(path)"
        case let .notFound(path): "文件或目录不存在：\(path)"
        case let .notFile(path): "不是可打开的文件：\(path)"
        case let .alreadyExists(path): "目标已经存在：\(path)"
        case let .operationFailed(action, path, message): "\(action) \(path) 失败：\(message)"
        }
    }
}

public struct YCodeProjectFileService: Sendable {
    /// 只剪 `.git`。别的目录再大也照列 —— 树是按展开一层一层读的，
    /// 没展开的目录一次也不会被碰，`node_modules` 摆在那里不花钱。
    public static let skippedDirectoryNames: Set<String> = [".git"]

    public init() {}

    /// 列一层，不递归。`relativePath` 空字符串就是项目根。
    /// 整棵树一次读完在这个量级的仓库上是七百毫秒起步，而展开的通常就那么几层。
    public func listChildren(root: URL, relativePath: String = "") throws -> [YCodeFileEntry] {
        let root = try resolvedRoot(root)
        let directory = relativePath.isEmpty ? root : try directoryURL(root: root, relativePath: relativePath)
        let keys: Set<URLResourceKey> = [.isDirectoryKey, .isSymbolicLinkKey, .nameKey]
        let children: [URL]
        do {
            children = try FileManager.default.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: Array(keys),
                options: []
            )
        } catch {
            throw YCodeProjectFileError.operationFailed(
                action: "读取",
                path: relativePath.isEmpty ? root.path : relativePath,
                message: error.localizedDescription
            )
        }

        var entries: [YCodeFileEntry] = []
        for child in children {
            guard let values = try? child.resourceValues(forKeys: keys) else { continue }
            let name = values.name ?? child.lastPathComponent
            let symbolicLink = values.isSymbolicLink == true
            let isDirectory = values.isDirectory == true && !symbolicLink
            if isDirectory, Self.skippedDirectoryNames.contains(name) { continue }
            entries.append(YCodeFileEntry(
                path: relativePath.isEmpty ? name : "\(relativePath)/\(name)",
                isDirectory: isDirectory,
                isSymbolicLink: symbolicLink
            ))
        }
        return entries.sorted { $0.path < $1.path }
    }

    public func createPath(root: URL, relativePath: String, isDirectory: Bool) throws {
        let root = try resolvedRoot(root)
        let target = try mutationURL(root: root, relativePath: relativePath)
        guard !existsIncludingSymbolicLink(target) else {
            throw YCodeProjectFileError.alreadyExists(relativePath)
        }
        do {
            if isDirectory {
                try FileManager.default.createDirectory(
                    at: target,
                    withIntermediateDirectories: false
                )
            } else {
                let descriptor = target.path.withCString {
                    Darwin.open($0, O_WRONLY | O_CREAT | O_EXCL, mode_t(0o644))
                }
                guard descriptor >= 0 else {
                    throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
                }
                Darwin.close(descriptor)
            }
        } catch let error as YCodeProjectFileError {
            throw error
        } catch {
            throw YCodeProjectFileError.operationFailed(
                action: isDirectory ? "创建目录" : "创建文件",
                path: relativePath,
                message: error.localizedDescription
            )
        }
    }

    public func renamePath(root: URL, from: String, to: String) throws {
        let root = try resolvedRoot(root)
        let source = try mutationURL(root: root, relativePath: from)
        let destination = try mutationURL(root: root, relativePath: to)
        guard existsIncludingSymbolicLink(source) else { throw YCodeProjectFileError.notFound(from) }
        if from == to { return }
        guard !existsIncludingSymbolicLink(destination) else {
            throw YCodeProjectFileError.alreadyExists(to)
        }
        do {
            try FileManager.default.moveItem(at: source, to: destination)
        } catch {
            throw YCodeProjectFileError.operationFailed(
                action: "重命名",
                path: "\(from) → \(to)",
                message: error.localizedDescription
            )
        }
    }

    public func deletePath(root: URL, relativePath: String) throws {
        let root = try resolvedRoot(root)
        let target = try mutationURL(root: root, relativePath: relativePath)
        guard existsIncludingSymbolicLink(target) else {
            throw YCodeProjectFileError.notFound(relativePath)
        }
        do {
            try FileManager.default.removeItem(at: target)
        } catch {
            throw YCodeProjectFileError.operationFailed(
                action: "删除",
                path: relativePath,
                message: error.localizedDescription
            )
        }
    }

    public func existingFileURL(root: URL, relativePath: String) throws -> URL {
        let root = try resolvedRoot(root)
        let candidate = try mutationURL(root: root, relativePath: relativePath)
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: candidate.path, isDirectory: &isDirectory) else {
            throw YCodeProjectFileError.notFound(relativePath)
        }
        guard !isDirectory.boolValue else { throw YCodeProjectFileError.notFile(relativePath) }
        let resolved = candidate.resolvingSymlinksInPath().standardizedFileURL
        guard contains(resolved, root: root) else {
            throw YCodeProjectFileError.pathEscapesRoot(relativePath)
        }
        return resolved
    }

    public func existingURL(root: URL, relativePath: String) throws -> URL {
        let root = try resolvedRoot(root)
        let candidate = try mutationURL(root: root, relativePath: relativePath)
        guard existsIncludingSymbolicLink(candidate) else {
            throw YCodeProjectFileError.notFound(relativePath)
        }
        return candidate
    }

    /// 列目录用的解析：必须落在根以内，而且确实是个目录。
    private func directoryURL(root: URL, relativePath: String) throws -> URL {
        let components = try validatedComponents(relativePath)
        let candidate = components.reduce(root) { partial, component in
            partial.appendingPathComponent(component, isDirectory: true)
        }.standardizedFileURL
        let resolved = candidate.resolvingSymlinksInPath().standardizedFileURL
        guard contains(resolved, root: root) else {
            throw YCodeProjectFileError.pathEscapesRoot(relativePath)
        }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: resolved.path, isDirectory: &isDirectory) else {
            throw YCodeProjectFileError.notFound(relativePath)
        }
        guard isDirectory.boolValue else { throw YCodeProjectFileError.notFound(relativePath) }
        return resolved
    }

    private func resolvedRoot(_ root: URL) throws -> URL {
        let resolved = root.standardizedFileURL.resolvingSymlinksInPath()
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: resolved.path, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            throw YCodeProjectFileError.rootUnavailable(root.path)
        }
        return resolved
    }

    private func mutationURL(root: URL, relativePath: String) throws -> URL {
        let components = try validatedComponents(relativePath)
        let candidate = components.reduce(root) { partial, component in
            partial.appendingPathComponent(component, isDirectory: false)
        }.standardizedFileURL
        let parent = candidate.deletingLastPathComponent()
        var parentIsDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: parent.path, isDirectory: &parentIsDirectory),
              parentIsDirectory.boolValue else {
            throw YCodeProjectFileError.notFound(parent.path)
        }
        let resolvedParent = parent.resolvingSymlinksInPath().standardizedFileURL
        guard contains(resolvedParent, root: root) else {
            throw YCodeProjectFileError.pathEscapesRoot(relativePath)
        }
        return candidate
    }

    private func validatedComponents(_ path: String) throws -> [String] {
        guard !path.isEmpty, !path.hasPrefix("/"), !path.contains("\0") else {
            throw YCodeProjectFileError.invalidPath(path)
        }
        let components = path.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard components.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }) else {
            throw YCodeProjectFileError.invalidPath(path)
        }
        return components
    }

    private func existsIncludingSymbolicLink(_ url: URL) -> Bool {
        (try? FileManager.default.attributesOfItem(atPath: url.path)) != nil
    }

    private func contains(_ candidate: URL, root: URL) -> Bool {
        let rootComponents = root.standardizedFileURL.pathComponents
        let candidateComponents = candidate.standardizedFileURL.pathComponents
        return candidateComponents.starts(with: rootComponents)
    }
}
