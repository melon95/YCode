import AppKit
import SwiftUI
import TandockCore

enum TandockProjectPalette {
    private static let hexes = ["1A7F6C", "6A5AE0", "A8620F", "2A5FD0", "B8447A", "5F7A1F", "4F5D75", "8A4B2E"]

    static func hex(for projectID: String) -> String {
        var hash: UInt64 = 0xcbf29ce484222325
        for byte in projectID.utf8 {
            hash = (hash ^ UInt64(byte)) &* 0x100000001b3
        }
        return hexes[Int(hash % UInt64(hexes.count))]
    }

    static func color(for projectID: String) -> Color {
        let hex = hex(for: projectID)
        return Color.tandockDynamic(light: hex, dark: hex)
    }

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

struct TandockProjectBadge: View {
    let projectID: String
    let name: String
    var showsName = true
    var maxNameWidth: CGFloat = 120

    var body: some View {
        HStack(spacing: 4) {
            if showsName {
                Text(name)
                    .font(.system(size: 9.5, weight: .semibold))
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: maxNameWidth, alignment: .leading)
            } else {
                Text(TandockProjectPalette.initial(of: name))
                    .font(.system(size: 8, weight: .bold))
                    .frame(width: 11, height: 11)
                    .background(Color.white.opacity(0.28), in: RoundedRectangle(cornerRadius: 3, style: .continuous))
            }
        }
        .foregroundStyle(Color.white)
        .padding(.leading, showsName ? 6 : 4)
        .padding(.trailing, showsName ? 6 : 4)
        .frame(height: 16)
        .background(TandockProjectPalette.color(for: projectID), in: RoundedRectangle(cornerRadius: 5, style: .continuous))
        .fixedSize()
        .help(name)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(name)
    }
}

struct TandockProjectDot: View {
    let projectID: String
    var size: CGFloat = 9

    var body: some View {
        RoundedRectangle(cornerRadius: size / 3, style: .continuous)
            .fill(TandockProjectPalette.color(for: projectID))
            .frame(width: size, height: size)
            .accessibilityHidden(true)
    }
}
