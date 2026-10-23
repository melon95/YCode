import AppKit
import SwiftUI
import TandockCore

/// 文件树的图标。用的是 material-icon-theme —— 跟非原生版同一套主题，
/// 所以同一个项目在两边看起来是一样的。认不出的类型回退到主题自带的默认 file / folder。
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
        // 先试复合扩展名（.d.ts、.test.tsx），再退回最后一段
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
