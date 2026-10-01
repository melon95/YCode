import AppKit
import SwiftUI
import YCodeCore

/// 跨项目画布里「这格属于哪个项目」的标识（设计稿 docs/canvas-cross-project.html §1）。
/// 颜色只是辅助：徽章永远带首字母图标和项目名，不靠颜色单独传达身份。
enum YCodeProjectPalette {
    /// 白字压在每一个底色上都 ≥ 4.5:1；刻意避开珊瑚，免得被误读成焦点色。
    private static let hexes = ["1A7F6C", "6A5AE0", "A8620F", "2A5FD0", "B8447A", "5F7A1F", "4F5D75", "8A4B2E"]

    /// 按项目 id 稳定取色。不能用 `hashValue`：它每次启动都不一样，项目色会跟着乱跳。
    static func hex(for projectID: String) -> String {
        var hash: UInt64 = 0xcbf29ce484222325
        for byte in projectID.utf8 {
            hash = (hash ^ UInt64(byte)) &* 0x100000001b3
        }
        return hexes[Int(hash % UInt64(hexes.count))]
    }

    static func color(for projectID: String) -> Color {
        let hex = hex(for: projectID)
        return Color.ycodeDynamic(light: hex, dark: hex)
    }

    /// 菜单标签里用的色块位图。`.borderlessButton` 的菜单只认图片标签，SwiftUI 形状会被丢掉。
    static func dotImage(for projectID: String, size: CGFloat = 9) -> NSImage {
        let color = NSColor(hex: hex(for: projectID)) ?? .systemGray
        let image = NSImage(size: NSSize(width: size, height: size), flipped: false) { rect in
            color.setFill()
            NSBezierPath(roundedRect: rect, xRadius: size / 3, yRadius: size / 3).fill()
            return true
        }
        image.isTemplate = false
        return image
    }

    static func initial(of name: String) -> String {
        name.trimmingCharacters(in: .whitespaces).first.map { String($0).uppercased() } ?? "?"
    }
}

/// 项目徽章：项目色底 + 首字母 + 项目名。`showsName == false` 时收成只剩图标（窄窗格）。
struct YCodeProjectBadge: View {
    let projectID: String
    let name: String
    var showsName = true
    var maxNameWidth: CGFloat = 96

    var body: some View {
        HStack(spacing: 4) {
            Text(YCodeProjectPalette.initial(of: name))
                .font(.system(size: 8, weight: .bold))
                .frame(width: 11, height: 11)
                .background(Color.white.opacity(0.28), in: RoundedRectangle(cornerRadius: 3, style: .continuous))
            if showsName {
                Text(name)
                    .font(.system(size: 9.5, weight: .semibold))
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(maxWidth: maxNameWidth, alignment: .leading)
                    .fixedSize(horizontal: true, vertical: false)
            }
        }
        .foregroundStyle(Color.white)
        .padding(.leading, 4)
        .padding(.trailing, showsName ? 6 : 4)
        .frame(height: 16)
        .background(YCodeProjectPalette.color(for: projectID), in: RoundedRectangle(cornerRadius: 5, style: .continuous))
        .fixedSize()
        .help(name)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(name)
    }
}

/// 项目色小方块：侧栏项目行、下拉框里的项目名前面用。
struct YCodeProjectDot: View {
    let projectID: String
    var size: CGFloat = 9

    var body: some View {
        RoundedRectangle(cornerRadius: size / 3, style: .continuous)
            .fill(YCodeProjectPalette.color(for: projectID))
            .frame(width: size, height: size)
            .accessibilityHidden(true)
    }
}
