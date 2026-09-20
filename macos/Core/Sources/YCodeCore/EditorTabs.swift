import Foundation

public struct YCodeEditorTabs: Equatable, Sendable {
    public private(set) var paths: [String]
    public private(set) var selectedPath: String?
    public private(set) var previewPath: String?
    public private(set) var dirtyPaths: Set<String>

    public init(
        paths: [String] = [],
        selectedPath: String? = nil,
        previewPath: String? = nil,
        dirtyPaths: Set<String> = []
    ) {
        self.paths = paths
        self.selectedPath = paths.contains(selectedPath ?? "") ? selectedPath : paths.first
        self.previewPath = paths.contains(previewPath ?? "") ? previewPath : nil
        self.dirtyPaths = dirtyPaths.intersection(paths)
    }

    @discardableResult
    public mutating func open(_ path: String, preview: Bool) -> String? {
        if paths.contains(path) {
            selectedPath = path
            if !preview, previewPath == path { previewPath = nil }
            return nil
        }

        if preview, let previewPath, let index = paths.firstIndex(of: previewPath) {
            paths[index] = path
            dirtyPaths.remove(previewPath)
            self.previewPath = path
            selectedPath = path
            return previewPath
        }

        paths.append(path)
        selectedPath = path
        if preview { previewPath = path }
        return nil
    }

    public mutating func select(_ path: String) {
        guard paths.contains(path) else { return }
        selectedPath = path
    }

    public mutating func pin(_ path: String) {
        guard previewPath == path else { return }
        previewPath = nil
    }

    public mutating func markDirty(_ path: String, dirty: Bool) {
        guard paths.contains(path) else { return }
        if dirty {
            dirtyPaths.insert(path)
            if previewPath == path { previewPath = nil }
        } else {
            dirtyPaths.remove(path)
        }
    }

    @discardableResult
    public mutating func close(_ path: String) -> String? {
        guard let index = paths.firstIndex(of: path) else { return selectedPath }
        paths.remove(at: index)
        dirtyPaths.remove(path)
        if previewPath == path { previewPath = nil }
        if selectedPath == path {
            selectedPath = paths.indices.contains(index) ? paths[index] : paths.last
        }
        return selectedPath
    }

    public mutating func movePath(from oldPath: String, to newPath: String) {
        func moved(_ path: String) -> String {
            if path == oldPath { return newPath }
            if path.hasPrefix(oldPath + "/") { return newPath + path.dropFirst(oldPath.count) }
            return path
        }
        paths = paths.map(moved)
        selectedPath = selectedPath.map(moved)
        previewPath = previewPath.map(moved)
        dirtyPaths = Set(dirtyPaths.map(moved))
    }

    @discardableResult
    public mutating func removePath(_ path: String) -> Set<String> {
        let removed = Set(paths.filter { $0 == path || $0.hasPrefix(path + "/") })
        guard !removed.isEmpty else { return [] }
        let oldSelected = selectedPath
        paths.removeAll(where: removed.contains)
        dirtyPaths.subtract(removed)
        if let previewPath, removed.contains(previewPath) { self.previewPath = nil }
        if let oldSelected, removed.contains(oldSelected) { selectedPath = paths.first }
        return removed
    }
}
