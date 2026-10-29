import Foundation

public struct TandockBasicSettings: Equatable, Sendable {
    public var notifications: TandockNotificationSettings
    public var appearance: TandockAppearanceSettings
    public var sessions: TandockSessionSettings

    public init(
        notifications: TandockNotificationSettings = TandockNotificationSettings(),
        appearance: TandockAppearanceSettings = TandockAppearanceSettings(),
        sessions: TandockSessionSettings = TandockSessionSettings()
    ) {
        self.notifications = notifications
        self.appearance = appearance
        self.sessions = sessions
    }
}

public struct TandockSessionSettings: Equatable, Sendable {
    public var confirmBeforeClose: Bool

    public init(confirmBeforeClose: Bool = true) {
        self.confirmBeforeClose = confirmBeforeClose
    }
}

public struct TandockNotificationSettings: Equatable, Sendable {
    public var enabled: Bool
    public var onlyWhenUnfocused: Bool

    public init(enabled: Bool = true, onlyWhenUnfocused: Bool = true) {
        self.enabled = enabled
        self.onlyWhenUnfocused = onlyWhenUnfocused
    }
}

public enum TandockNotificationPolicy {
    public static func shouldDeliver(settings: TandockNotificationSettings, appIsActive: Bool) -> Bool {
        settings.enabled && (!settings.onlyWhenUnfocused || !appIsActive)
    }
}

public enum TandockLocale: String, CaseIterable, Sendable {
    case zh
    case en
}

public struct TandockFontSizes: Equatable, Sendable {
    public var ui: Int
    public var editor: Int
    public var terminal: Int

    public init(ui: Int = 14, editor: Int = 14, terminal: Int = 13) {
        self.ui = Self.clamp(ui)
        self.editor = Self.clamp(editor)
        self.terminal = Self.clamp(terminal)
    }

    public static func clamp(_ value: Int) -> Int { min(32, max(8, value)) }
}

public struct TandockThemeOption: Identifiable, Equatable, Sendable {
    public let id: String
    public let label: String
    public let systemColorScheme: String?
    public let background: String
    public let surface: String
    public let panel: String
    public let text: String
    public let textSoft: String
    public let accent: String
    public let terminal: TandockTerminalTheme

    public init(
        id: String,
        label: String,
        systemColorScheme: String?,
        background: String,
        surface: String,
        panel: String,
        text: String,
        textSoft: String,
        accent: String,
        terminal: TandockTerminalTheme
    ) {
        self.id = id
        self.label = label
        self.systemColorScheme = systemColorScheme
        self.background = background
        self.surface = surface
        self.panel = panel
        self.text = text
        self.textSoft = textSoft
        self.accent = accent
        self.terminal = terminal
    }
}

public struct TandockTerminalTheme: Equatable, Sendable {
    public let background: String
    public let foreground: String
    public let cursor: String
    /// The 16 ANSI colors in order (black…white, then bright black…bright white), tuned for `background`.
    public let ansi: [String]

    public init(background: String, foreground: String, cursor: String, ansi: [String] = []) {
        self.background = background
        self.foreground = foreground
        self.cursor = cursor
        self.ansi = ansi
    }
}

public enum TandockThemeCatalog {
    public static let systemID = "system"
    public static let defaultID = systemID

    public static let light = TandockThemeOption(
        id: "light", label: "Light", systemColorScheme: "light",
        background: "#efeef4", surface: "#fcfcfe", panel: "#fcfcfe",
        text: "#16133a", textSoft: "#6a6787", accent: "#ff5a4e",
        terminal: .init(
            background: "#fcfcfe", foreground: "#16133a", cursor: "#ff5a4e",
            // White and bright white stay light: TUIs on light terminals paint them as backgrounds.
            ansi: [
                "#16133a", "#c4302b", "#1f7a3e", "#8a5a00", "#2f55c7", "#8d3fb0", "#12707d", "#d9d7e3",
                "#5d5a7a", "#b8322c", "#21733c", "#7d5200", "#2a4fbf", "#8a3aad", "#0f6875", "#f3f2f8"
            ]
        )
    )

    public static let dark = TandockThemeOption(
        id: "dark", label: "Dark", systemColorScheme: "dark",
        background: "#21252b", surface: "#282c34", panel: "#282c34",
        text: "#d7dae0", textSoft: "#9da5b4", accent: "#ff7d72",
        terminal: .init(
            background: "#282c34", foreground: "#abb2bf", cursor: "#ffc83d",
            // One Dark, including its background; bright black uses its newer comment gray so dim text stays readable.
            ansi: [
                "#282c34", "#e06c75", "#98c379", "#e5c07b", "#61afef", "#c678dd", "#56b6c2", "#abb2bf",
                "#7f848e", "#e06c75", "#98c379", "#d19a66", "#61afef", "#c678dd", "#56b6c2", "#ffffff"
            ]
        )
    )

    public static let options: [TandockThemeOption] = [light, dark]

    public static func option(id: String) -> TandockThemeOption? {
        options.first { $0.id == id }
    }

    public static func resolve(id: String, prefersDark: Bool) -> TandockThemeOption {
        switch id {
        case light.id: light
        case dark.id: dark
        default: prefersDark ? dark : light
        }
    }
}


public struct TandockAppearanceSettings: Equatable, Sendable {
    public var theme: String
    public var locale: TandockLocale
    public var fontSizes: TandockFontSizes

    public init(
        theme: String = TandockThemeCatalog.defaultID,
        locale: TandockLocale = .zh,
        fontSizes: TandockFontSizes = TandockFontSizes()
    ) {
        self.theme = theme
        self.locale = locale
        self.fontSizes = fontSizes
    }
}

public final class TandockConfigurationStore {
    public let configurationURL: URL

    public init(configurationURL: URL) {
        self.configurationURL = configurationURL
    }

    public func loadBasicSettings() throws -> TandockBasicSettings {
        guard FileManager.default.fileExists(atPath: configurationURL.path) else {
            return TandockBasicSettings()
        }
        let document = try PreservingJSONDocument(data: Data(contentsOf: configurationURL))
        var notifications = TandockNotificationSettings()
        if case let .object(fields)? = document["notifications"] {
            if case let .bool(value)? = fields["enabled"] { notifications.enabled = value }
            if case let .bool(value)? = fields["only_when_unfocused"] { notifications.onlyWhenUnfocused = value }
        }
        let theme: String
        if case let .string(raw)? = document["theme"], !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            theme = raw
        } else {
            theme = TandockThemeCatalog.defaultID
        }
        let locale: TandockLocale
        if case let .string(raw)? = document["locale"] {
            locale = TandockLocale(rawValue: raw) ?? .zh
        } else {
            locale = .zh
        }
        var fontSizes = TandockFontSizes()
        if case let .object(fields)? = document["font_sizes"] {
            fontSizes = TandockFontSizes(
                ui: Self.int(fields["ui"]) ?? fontSizes.ui,
                editor: Self.int(fields["editor"]) ?? fontSizes.editor,
                terminal: Self.int(fields["terminal"]) ?? fontSizes.terminal
            )
        }
        var sessions = TandockSessionSettings()
        if case let .object(fields)? = document["sessions"],
           case let .bool(value)? = fields["confirm_before_close"] {
            sessions.confirmBeforeClose = value
        }
        return TandockBasicSettings(
            notifications: notifications,
            appearance: TandockAppearanceSettings(theme: theme, locale: locale, fontSizes: fontSizes),
            sessions: sessions
        )
    }

    public func saveBasicSettings(_ settings: TandockBasicSettings) throws {
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: configurationURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        var document: PreservingJSONDocument
        if fileManager.fileExists(atPath: configurationURL.path) {
            document = try PreservingJSONDocument(data: Data(contentsOf: configurationURL))
        } else {
            document = try PreservingJSONDocument(data: Data("{}".utf8))
        }
        Self.writeNotificationSettings(settings.notifications, to: &document)
        Self.writeAppearanceSettings(settings.appearance, to: &document)
        Self.writeSessionSettings(settings.sessions, to: &document)
        try document.encodedData().write(to: configurationURL, options: .atomic)
    }

    public func loadAgentSettings() throws -> TandockAgentSettings {
        guard FileManager.default.fileExists(atPath: configurationURL.path) else {
            return TandockAgentSettings()
        }
        let document = try PreservingJSONDocument(data: Data(contentsOf: configurationURL))
        let agents: [TandockAgentProfile]
        if case let .array(values)? = document["agents"] {
            agents = try values.map(Self.agent(from:))
        } else {
            agents = TandockAgentCatalog.defaults
        }
        var seen = Set<String>()
        for agent in agents where !seen.insert(agent.id).inserted {
            throw TandockAgentSettingsError.duplicateAgentID(agent.id)
        }
        var proxy = TandockProxySettings()
        if case let .object(fields)? = document["proxy"] {
            if case let .string(raw)? = fields["mode"] { proxy.mode = TandockProxyMode(rawValue: raw) ?? .system }
            if case let .string(value)? = fields["url"] { proxy.url = value }
            if case let .string(value)? = fields["no_proxy"] { proxy.noProxy = value }
        }
        return TandockAgentSettings(agents: agents, proxy: proxy)
    }

    public func saveAgentSettings(_ settings: TandockAgentSettings) throws {
        try writeSettingsDocument(basic: nil, agents: settings)
    }

    public func saveSettings(basic: TandockBasicSettings, agents: TandockAgentSettings) throws {
        try writeSettingsDocument(basic: basic, agents: agents)
    }

    private func writeSettingsDocument(basic: TandockBasicSettings?, agents settings: TandockAgentSettings) throws {
        var seen = Set<String>()
        for agent in settings.agents {
            let id = agent.id.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !id.isEmpty else { throw TandockAgentSettingsError.invalidAgent("Agent 标识不能为空") }
            guard !agent.command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw TandockAgentSettingsError.invalidAgent("Agent 命令不能为空")
            }
            guard seen.insert(id).inserted else { throw TandockAgentSettingsError.duplicateAgentID(id) }
        }

        let fileManager = FileManager.default
        try fileManager.createDirectory(at: configurationURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        var document: PreservingJSONDocument
        if fileManager.fileExists(atPath: configurationURL.path) {
            document = try PreservingJSONDocument(data: Data(contentsOf: configurationURL))
        } else {
            document = try PreservingJSONDocument(data: Data("{}".utf8))
        }
        if let basic {
            Self.writeNotificationSettings(basic.notifications, to: &document)
            Self.writeAppearanceSettings(basic.appearance, to: &document)
            Self.writeSessionSettings(basic.sessions, to: &document)
        }
        document["agents"] = .array(settings.agents.map(Self.jsonValue(from:)))
        var proxyFields: [String: JSONValue]
        if case let .object(existing)? = document["proxy"] { proxyFields = existing } else { proxyFields = [:] }
        proxyFields["mode"] = .string(settings.proxy.mode.rawValue)
        proxyFields["url"] = .string(settings.proxy.url)
        proxyFields["no_proxy"] = .string(settings.proxy.noProxy)
        document["proxy"] = .object(proxyFields)
        try document.encodedData().write(to: configurationURL, options: .atomic)
        TandockAgentLauncher.invalidateProbeCache()
        TandockShellEnvironmentStore.shared.invalidate()
    }

    private static let knownAgentKeys: Set<String> = [
        "id", "display_name", "command", "enabled", "args", "env", "icon", "icon_variant", "color", "introspect"
    ]

    private static func agent(from value: JSONValue) throws -> TandockAgentProfile {
        guard case let .object(fields) = value,
              case let .string(id)? = fields["id"],
              case let .string(command)? = fields["command"] else {
            throw TandockAgentSettingsError.invalidAgent("Agent 配置缺少标识或命令")
        }
        return TandockAgentProfile(
            id: id,
            displayName: string(fields["display_name"]),
            command: command,
            enabled: fields["enabled"] != .bool(false),
            arguments: stringArray(fields["args"]),
            environment: stringDictionary(fields["env"]),
            icon: string(fields["icon"]),
            iconVariant: string(fields["icon_variant"]),
            color: string(fields["color"]),
            introspect: string(fields["introspect"]),
            unknownFields: fields.filter { !knownAgentKeys.contains($0.key) }
        )
    }

    private static func jsonValue(from agent: TandockAgentProfile) -> JSONValue {
        var fields = agent.unknownFields
        fields["id"] = .string(agent.id)
        fields["display_name"] = agent.displayName.map(JSONValue.string) ?? .null
        fields["command"] = .string(agent.command)
        fields["enabled"] = .bool(agent.enabled)
        fields["args"] = .array(agent.arguments.map(JSONValue.string))
        fields["env"] = .object(agent.environment.mapValues(JSONValue.string))
        fields["icon"] = agent.icon.map(JSONValue.string) ?? .null
        fields["icon_variant"] = agent.iconVariant.map(JSONValue.string) ?? .null
        fields["color"] = agent.color.map(JSONValue.string) ?? .null
        fields["introspect"] = agent.introspect.map(JSONValue.string) ?? .null
        return .object(fields)
    }

    private static func string(_ value: JSONValue?) -> String? {
        guard case let .string(result)? = value else { return nil }
        return result
    }

    private static func stringArray(_ value: JSONValue?) -> [String] {
        guard case let .array(values)? = value else { return [] }
        return values.compactMap(string)
    }

    private static func stringDictionary(_ value: JSONValue?) -> [String: String] {
        guard case let .object(values)? = value else { return [:] }
        return values.compactMapValues(string)
    }

    private static func int(_ value: JSONValue?) -> Int? {
        switch value {
        case let .number(raw)?:
            return Int(raw)
        case let .string(raw)?:
            return Int(raw)
        default:
            return nil
        }
    }

    private static func writeNotificationSettings(
        _ settings: TandockNotificationSettings,
        to document: inout PreservingJSONDocument
    ) {
        var fields: [String: JSONValue]
        if case let .object(existing)? = document["notifications"] { fields = existing } else { fields = [:] }
        fields["enabled"] = .bool(settings.enabled)
        fields["only_when_unfocused"] = .bool(settings.onlyWhenUnfocused)
        document["notifications"] = .object(fields)
    }

    private static func writeSessionSettings(
        _ settings: TandockSessionSettings,
        to document: inout PreservingJSONDocument
    ) {
        var fields: [String: JSONValue]
        if case let .object(existing)? = document["sessions"] { fields = existing } else { fields = [:] }
        fields["confirm_before_close"] = .bool(settings.confirmBeforeClose)
        document["sessions"] = .object(fields)
    }

    private static func writeAppearanceSettings(
        _ settings: TandockAppearanceSettings,
        to document: inout PreservingJSONDocument
    ) {
        document["theme"] = .string(settings.theme)
        document["locale"] = .string(settings.locale.rawValue)
        var fields: [String: JSONValue]
        if case let .object(existing)? = document["font_sizes"] { fields = existing } else { fields = [:] }
        fields["ui"] = .number(Double(settings.fontSizes.ui))
        fields["editor"] = .number(Double(settings.fontSizes.editor))
        fields["terminal"] = .number(Double(settings.fontSizes.terminal))
        document["font_sizes"] = .object(fields)
    }
}

public func initialProjectID(recentProjectID: String?, projects: [ProjectRecord]) -> String? {
    let recent = recentProjectID.flatMap { id in projects.first(where: { $0.id == id }) }
    return recent?.id ?? projects.first?.id
}
