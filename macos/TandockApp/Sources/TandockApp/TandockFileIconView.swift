import AppKit
import SwiftUI
import TandockCore

struct TandockFileIconView: View {
    let name: String
    let isDirectory: Bool
    var isExpanded = false
    var size: CGFloat = 15

    var body: some View {
        Group {
            if let image = TandockFileIconRenderer.image(named: iconName) {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
            } else {
                Image(systemName: isDirectory ? "folder.fill" : "doc")
                    .foregroundStyle(isDirectory ? Color.tandockAccent : Color.secondary)
            }
        }
        .frame(width: size, height: size)
    }

    private var iconName: String {
        let lower = name.lowercased()
        if isDirectory {
            if isExpanded, let open = TandockFileIconCatalog.byFolderExpanded[lower] { return open }
            if let folder = TandockFileIconCatalog.byFolder[lower] { return folder }
            return isExpanded ? TandockFileIconCatalog.defaultFolderExpanded : TandockFileIconCatalog.defaultFolder
        }
        if let exact = TandockFileIconCatalog.byFileName[lower] { return exact }
        let pieces = lower.split(separator: ".").map(String.init)
        if pieces.count > 2, let compound = TandockFileIconCatalog.byExtension[pieces.suffix(2).joined(separator: ".")] {
            return compound
        }
        if let last = pieces.last, pieces.count > 1, let match = TandockFileIconCatalog.byExtension[last] {
            return match
        }
        return TandockFileIconCatalog.defaultFile
    }
}

@MainActor
enum TandockFileIconRenderer {
    private static var cache: [String: NSImage] = [:]

    static func image(named name: String) -> NSImage? {
        if let cached = cache[name] { return cached }
        guard let svg = TandockFileIconCatalog.svg[name],
              let data = svg.data(using: .utf8),
              let image = NSImage(data: data) else { return nil }
        cache[name] = image
        return image
    }
}
