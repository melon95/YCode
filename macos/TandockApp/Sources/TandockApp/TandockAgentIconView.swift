import AppKit
import SwiftUI
import TandockCore

struct TandockAgentIconView: View {
    let profile: TandockAgentProfile?
    var size: CGFloat = 14
    var tint: Color?

    var body: some View {
        Group {
            switch TandockAgentIconRenderer.resolve(icon: profile?.icon) {
            case let .brand(image):
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
            case let .mono(image):
                Image(nsImage: image)
                    .resizable()
                    .renderingMode(.template)
                    .aspectRatio(contentMode: .fit)
                    .foregroundStyle(tint ?? brandTint ?? Color.primary)
            case let .symbol(name):
                Image(systemName: name)
                    .font(.system(size: size * 0.92))
                    .foregroundStyle(tint ?? brandTint ?? Color.primary)
            case .letter:
                Text(String((profile?.resolvedDisplayName ?? "?").prefix(1)).uppercased())
                    .font(.system(size: size * 0.72, weight: .semibold))
                    .foregroundStyle(tint ?? brandTint ?? Color.primary)
            }
        }
        .frame(width: size, height: size)
    }

    private var brandTint: Color? {
        if let raw = profile?.color, let color = NSColor(hex: raw) { return Color(nsColor: color) }
        switch profile?.icon {
        case "ClaudeCode", "Claude", "Anthropic": return Color.tandockDynamic(light: "C15F3C", dark: "D97757")
        case "GeminiCLI", "Gemini", "Google": return Color.tandockDynamic(light: "1A73E8", dark: "6BA1FF")
        default: return Color.tandockDynamic(light: "2F6FED", dark: "6BA1FF")
        }
    }
}

@MainActor
enum TandockAgentIconRenderer {
    enum Resolved {
        case brand(NSImage)
        case mono(NSImage)
        case symbol(String)
        case letter
    }

    private static var cache: [String: NSImage] = [:]
    private static var symbolExists: [String: Bool] = [:]

    static var tandockLogo: NSImage? { brand(for: "tandock") }

    static func resolve(icon: String?) -> Resolved {
        guard let icon, !icon.isEmpty else { return .letter }
        if let image = brand(for: icon) { return .brand(image) }
        if let image = mono(for: icon) { return .mono(image) }
        if isSymbol(icon) { return .symbol(icon) }
        return .letter
    }

    static func brand(for key: String?) -> NSImage? {
        guard let key, let svg = TandockAgentIconCatalog.brand[key] else { return nil }
        return decode(key: "brand-" + key, svg: svg, template: false)
    }

    static func mono(for key: String?) -> NSImage? {
        guard let key, let svg = TandockAgentIconCatalog.mono[key] else { return nil }
        return decode(key: "mono-" + key, svg: svg, template: true)
    }

    static func isSymbol(_ name: String) -> Bool {
        guard !name.isEmpty else { return false }
        if let known = symbolExists[name] { return known }
        let exists = NSImage(systemSymbolName: name, accessibilityDescription: nil) != nil
        symbolExists[name] = exists
        return exists
    }

    private static func decode(key: String, svg: String, template: Bool) -> NSImage? {
        if let cached = cache[key] { return cached }
        guard let data = svg.data(using: .utf8), let image = NSImage(data: data) else { return nil }
        image.isTemplate = template
        cache[key] = image
        return image
    }
}
