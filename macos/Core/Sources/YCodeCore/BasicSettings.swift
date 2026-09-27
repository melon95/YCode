import Foundation

public struct YCodeBasicSettings: Equatable, Sendable {
    public var notifications: YCodeNotificationSettings
    public var appearance: YCodeAppearanceSettings

    public init(
        notifications: YCodeNotificationSettings = YCodeNotificationSettings(),
        appearance: YCodeAppearanceSettings = YCodeAppearanceSettings()
    ) {
        self.notifications = notifications
        self.appearance = appearance
    }
}

public struct YCodeNotificationSettings: Equatable, Sendable {
    public var enabled: Bool
    public var onlyWhenUnfocused: Bool

    public init(enabled: Bool = true, onlyWhenUnfocused: Bool = true) {
        self.enabled = enabled
        self.onlyWhenUnfocused = onlyWhenUnfocused
    }
}

public enum YCodeNotificationPolicy {
    public static func shouldDeliver(settings: YCodeNotificationSettings, appIsActive: Bool) -> Bool {
        settings.enabled && (!settings.onlyWhenUnfocused || !appIsActive)
    }
}

public enum YCodeLocale: String, CaseIterable, Sendable {
    case zh
    case en
}

public struct YCodeFontSizes: Equatable, Sendable {
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

public struct YCodeThemeOption: Identifiable, Equatable, Sendable {
    public let id: String
    public let label: String
    public let systemColorScheme: String?
    public let background: String
    public let surface: String
    public let panel: String
    public let text: String
    public let textSoft: String
    public let accent: String
    public let terminal: YCodeTerminalTheme

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
        terminal: YCodeTerminalTheme
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

public struct YCodeTerminalTheme: Equatable, Sendable {
    public let background: String
    public let foreground: String
    public let cursor: String

    public init(background: String, foreground: String, cursor: String) {
        self.background = background
        self.foreground = foreground
        self.cursor = cursor
    }
}

public enum YCodeThemeCatalog {
    /// 只有浅色与深色两套配色，外加「跟随系统」。
    /// 值取自设计稿 §02 的 token —— 整个窗口（含终端画布）跟着系统外观走，
    /// 不存在一块不听系统话的区域，所以也不需要十套主题。
    public static let systemID = "system"
    public static let defaultID = systemID

    public static let light = YCodeThemeOption(
        id: "light", label: "Light", systemColorScheme: "light",
        background: "#ffffff", surface: "#f4f4f6", panel: "#fbfbfc",
        text: "#1d1d1f", textSoft: "#5a5a5e", accent: "#0b63e5",
        terminal: .init(background: "#ffffff", foreground: "#1d1d1f", cursor: "#0b63e5")
    )

    public static let dark = YCodeThemeOption(
        id: "dark", label: "Dark", systemColorScheme: "dark",
        background: "#1e1e20", surface: "#242426", panel: "#242426",
        text: "#f2f2f4", textSoft: "#b4b4b8", accent: "#4c8dff",
        terminal: .init(background: "#16181d", foreground: "#e8e8ea", cursor: "#4c8dff")
    )

    public static let options: [YCodeThemeOption] = [light, dark]

    public static func option(id: String) -> YCodeThemeOption? {
        options.first { $0.id == id }
    }

    /// 解析当前该用哪套。`system` 与任何旧的主题 id 都跟随系统外观。
    public static func resolve(id: String, prefersDark: Bool) -> YCodeThemeOption {
        switch id {
        case light.id: light
        case dark.id: dark
        default: prefersDark ? dark : light
        }
    }
}


public struct YCodeAppearanceSettings: Equatable, Sendable {
    public var theme: String
    public var locale: YCodeLocale
    public var fontSizes: YCodeFontSizes

    public init(
        theme: String = YCodeThemeCatalog.defaultID,
        locale: YCodeLocale = .zh,
        fontSizes: YCodeFontSizes = YCodeFontSizes()
    ) {
        self.theme = theme
        self.locale = locale
        self.fontSizes = fontSizes
    }
}

public final class YCodeConfigurationStore {
    public let configurationURL: URL

    public init(configurationURL: URL) {
        self.configurationURL = configurationURL
    }

    public func loadBasicSettings() throws -> YCodeBasicSettings {
        guard FileManager.default.fileExists(atPath: configurationURL.path) else {
            return YCodeBasicSettings()
        }
        let document = try PreservingJSONDocument(data: Data(contentsOf: configurationURL))
        var notifications = YCodeNotificationSettings()
        if case let .object(fields)? = document["notifications"] {
            if case let .bool(value)? = fields["enabled"] { notifications.enabled = value }
            if case let .bool(value)? = fields["only_when_unfocused"] { notifications.onlyWhenUnfocused = value }
        }
        let theme: String
        if case let .string(raw)? = document["theme"], !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            theme = raw
        } else {
            theme = YCodeThemeCatalog.defaultID
        }
        let locale: YCodeLocale
        if case let .string(raw)? = document["locale"] {
            locale = YCodeLocale(rawValue: raw) ?? .zh
        } else {
            locale = .zh
        }
        var fontSizes = YCodeFontSizes()
        if case let .object(fields)? = document["font_sizes"] {
            fontSizes = YCodeFontSizes(
                ui: Self.int(fields["ui"]) ?? fontSizes.ui,
                editor: Self.int(fields["editor"]) ?? fontSizes.editor,
                terminal: Self.int(fields["terminal"]) ?? fontSizes.terminal
            )
        }
        return YCodeBasicSettings(
            notifications: notifications,
            appearance: YCodeAppearanceSettings(theme: theme, locale: locale, fontSizes: fontSizes)
        )
    }

    public func saveBasicSettings(_ settings: YCodeBasicSettings) throws {
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
        try document.encodedData().write(to: configurationURL, options: .atomic)
    }

    public func loadAgentSettings() throws -> YCodeAgentSettings {
        guard FileManager.default.fileExists(atPath: configurationURL.path) else {
            return YCodeAgentSettings()
        }
        let document = try PreservingJSONDocument(data: Data(contentsOf: configurationURL))
        let agents: [YCodeAgentProfile]
        if case let .array(values)? = document["agents"] {
            agents = try values.map(Self.agent(from:))
        } else {
            agents = YCodeAgentCatalog.defaults
        }
        var seen = Set<String>()
        for agent in agents where !seen.insert(agent.id).inserted {
            throw YCodeAgentSettingsError.duplicateAgentID(agent.id)
        }
        var proxy = YCodeProxySettings()
        if case let .object(fields)? = document["proxy"] {
            if case let .string(raw)? = fields["mode"] { proxy.mode = YCodeProxyMode(rawValue: raw) ?? .system }
            if case let .string(value)? = fields["url"] { proxy.url = value }
            if case let .string(value)? = fields["no_proxy"] { proxy.noProxy = value }
        }
        return YCodeAgentSettings(agents: agents, proxy: proxy)
    }

    public func saveAgentSettings(_ settings: YCodeAgentSettings) throws {
        try writeSettingsDocument(basic: nil, agents: settings)
    }

    public func saveSettings(basic: YCodeBasicSettings, agents: YCodeAgentSettings) throws {
        try writeSettingsDocument(basic: basic, agents: agents)
    }

    private func writeSettingsDocument(basic: YCodeBasicSettings?, agents settings: YCodeAgentSettings) throws {
        var seen = Set<String>()
        for agent in settings.agents {
            let id = agent.id.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !id.isEmpty else { throw YCodeAgentSettingsError.invalidAgent("Agent 标识不能为空") }
            guard !agent.command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw YCodeAgentSettingsError.invalidAgent("Agent 命令不能为空")
            }
            guard seen.insert(id).inserted else { throw YCodeAgentSettingsError.duplicateAgentID(id) }
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
        }
        document["agents"] = .array(settings.agents.map(Self.jsonValue(from:)))
        var proxyFields: [String: JSONValue]
        if case let .object(existing)? = document["proxy"] { proxyFields = existing } else { proxyFields = [:] }
        proxyFields["mode"] = .string(settings.proxy.mode.rawValue)
        proxyFields["url"] = .string(settings.proxy.url)
        proxyFields["no_proxy"] = .string(settings.proxy.noProxy)
        document["proxy"] = .object(proxyFields)
        try document.encodedData().write(to: configurationURL, options: .atomic)
        // 命令可能刚被改过，probe 的缓存结论立刻作废。
        YCodeAgentLauncher.invalidateProbeCache()
    }

    private static let knownAgentKeys: Set<String> = [
        "id", "display_name", "command", "args", "env", "icon", "icon_variant", "color", "introspect"
    ]

    private static func agent(from value: JSONValue) throws -> YCodeAgentProfile {
        guard case let .object(fields) = value,
              case let .string(id)? = fields["id"],
              case let .string(command)? = fields["command"] else {
            throw YCodeAgentSettingsError.invalidAgent("Agent 配置缺少标识或命令")
        }
        return YCodeAgentProfile(
            id: id,
            displayName: string(fields["display_name"]),
            command: command,
            arguments: stringArray(fields["args"]),
            environment: stringDictionary(fields["env"]),
            icon: string(fields["icon"]),
            iconVariant: string(fields["icon_variant"]),
            color: string(fields["color"]),
            introspect: string(fields["introspect"]),
            unknownFields: fields.filter { !knownAgentKeys.contains($0.key) }
        )
    }

    private static func jsonValue(from agent: YCodeAgentProfile) -> JSONValue {
        var fields = agent.unknownFields
        fields["id"] = .string(agent.id)
        fields["display_name"] = agent.displayName.map(JSONValue.string) ?? .null
        fields["command"] = .string(agent.command)
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
        _ settings: YCodeNotificationSettings,
        to document: inout PreservingJSONDocument
    ) {
        var fields: [String: JSONValue]
        if case let .object(existing)? = document["notifications"] { fields = existing } else { fields = [:] }
        fields["enabled"] = .bool(settings.enabled)
        fields["only_when_unfocused"] = .bool(settings.onlyWhenUnfocused)
        document["notifications"] = .object(fields)
    }

    private static func writeAppearanceSettings(
        _ settings: YCodeAppearanceSettings,
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

/// 启动时进哪个项目。原来这里有三档「启动时显示」可选，但三档的差别只有
/// 「最近项目一个会话都没有时进不进去」，而「恢复最近工作区」又恢复不了任何东西
/// —— 画布布局只活在进程内。所以只留一条：有最近项目就进它，没有就给项目总览。
public func initialProjectID(recentProjectID: String?, projects: [ProjectRecord]) -> String? {
    let recent = recentProjectID.flatMap { id in projects.first(where: { $0.id == id }) }
    return recent?.id ?? projects.first?.id
}
