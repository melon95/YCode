import Foundation
import TOMLKit

extension TandockAgentCustomizationService {
    public func setSkillEnabled(_ enabled: Bool, record: TandockSkillRecord, agent: TandockCustomizationAgent, project: URL?, environment: [String: String] = [:]) throws {
        guard hasSupportedConfigurationRoot(agent: agent, environment: environment) else { throw TandockCustomizationError.unsupportedConfigurationRoot }
        guard agent != .grok || project == nil else { throw TandockCustomizationError.unsupportedProjectSkills }
        guard try Data(contentsOf: record.directory.appendingPathComponent("SKILL.md")) == record.revision else { throw TandockCustomizationError.changedOnDisk }
        let urls = skillSettings(agent: agent, record: record, project: project, environment: environment)
        guard let url = urls.last else { throw TandockCustomizationError.invalidConfiguration }
        let revision = try read(url)
        switch agent {
        case .claude:
            var root = try jsonRoot(revision)
            var overrides = try jsonDictionary(root["skillOverrides"])
            overrides[record.name] = enabled ? "on" : "off"
            root["skillOverrides"] = overrides
            try write(jsonData(root), to: url, expected: revision)
        case .codex:
            let raw = revision.map { String(decoding: $0, as: UTF8.self) } ?? ""
            let root = try tomlObject(raw)
            var skills = try dictionary(root["skills"])
            var configs = try array(skills["config"])
            // Codex keys these overrides by the SKILL.md path, not its name.
            let file = record.directory.appendingPathComponent("SKILL.md")
            let index = configs.lastIndex { value in
                guard case let .object(entry) = value, case let .string(path)? = entry["path"] else { return false }
                return sameSkillPath(path, file: file, base: url.deletingLastPathComponent())
            }
            if let index {
                var entry = try dictionary(configs[index])
                entry["enabled"] = .bool(enabled)
                configs[index] = .object(entry)
            } else { configs.append(.object(["path": .string(file.path), "enabled": .bool(enabled)])) }
            skills["config"] = .array(configs)
            let updated = try TandockMCPTableEditor.replacingTopLevel("skills", value: .object(skills), in: raw)
            try write(Data(updated.utf8), to: url, expected: revision)
        case .grok:
            let raw = revision.map { String(decoding: $0, as: UTF8.self) } ?? ""
            // Preserve the other globally disabled skill names.
            var effective: [String: JSONValue] = [:]
            for source in urls {
                if let data = try read(source) {
                    let table = try dictionary(tomlObject(String(decoding: data, as: UTF8.self))["skills"])
                    effective.merge(table) { _, new in new }
                }
            }
            var disabled = try stringArray(effective["disabled"])
            disabled.removeAll { $0 == record.name }
            if !enabled { disabled.append(record.name) }
            var own = try dictionary(tomlObject(raw)["skills"])
            own["disabled"] = .array(disabled.map(JSONValue.string))
            let updated = try TandockMCPTableEditor.replacingTopLevel("skills", value: .object(own), in: raw)
            try write(Data(updated.utf8), to: url, expected: revision)
        case .pi:
            var root = try jsonRoot(revision)
            let existing = root["skills"]
            guard existing == nil || existing is [String] else { throw TandockCustomizationError.invalidConfiguration }
            var patterns = existing as? [String] ?? []
            let file = record.directory.appendingPathComponent("SKILL.md")
            patterns.removeAll { pattern in
                guard pattern.hasPrefix("+") || pattern.hasPrefix("-") else { return false }
                return samePiSkillPath(String(pattern.dropFirst()), file: file, base: record.root.deletingLastPathComponent())
            }
            // Pi's exact +/- paths override glob exclusions. Leave all other
            // resource settings and package selections unchanged.
            patterns.append((enabled ? "+" : "-") + file.path)
            root["skills"] = patterns
            try write(jsonData(root), to: url, expected: revision)
        }
    }

    func applySkillStates(to records: inout [TandockSkillRecord], agent: TandockCustomizationAgent, project: URL?, environment: [String: String]) throws {
        var cache: [URL: [String: JSONValue]] = [:]
        for index in records.indices {
            let record = records[index]
            let urls = skillSettings(agent: agent, record: record, project: project, environment: environment)
            var effective: [String: JSONValue] = [:]
            for url in urls {
                let root: [String: JSONValue]
                if let cached = cache[url] { root = cached }
                else {
                    let data = try read(url)
                    root = try data.map { agent == .claude || agent == .pi ? try object($0) : try tomlObject(String(decoding: $0, as: UTF8.self)) } ?? [:]
                    cache[url] = root
                }
                if agent == .claude {
                    effective.merge(try dictionary(root["skillOverrides"])) { _, new in new }
                } else if agent == .pi { effective = root }
                else { effective.merge(try dictionary(root["skills"])) { _, new in new } }
            }
            switch agent {
            case .claude:
                records[index].enabled = effective[record.name] != .string("off")
                if case let .string(mode)? = effective[record.name], mode != "on" && mode != "off" { records[index].stateDetail = mode }
            case .codex:
                let configs = try array(effective["config"])
                let file = record.directory.appendingPathComponent("SKILL.md")
                for value in configs {
                    let config = try dictionary(value)
                    if case let .string(path)? = config["path"], sameSkillPath(path, file: file, base: urls[0].deletingLastPathComponent()) {
                        records[index].enabled = config["enabled"] != .bool(false)
                    }
                }
            case .grok:
                records[index].enabled = !(try stringArray(effective["disabled"])).contains(record.name)
            case .pi:
                let patterns = try stringArray(effective["skills"])
                let file = record.directory.appendingPathComponent("SKILL.md")
                var enabled = true
                for pattern in patterns where pattern.hasPrefix("!") {
                    let glob = String(pattern.dropFirst())
                    let escaped = NSRegularExpression.escapedPattern(for: glob)
                        .replacingOccurrences(of: "\\*\\*", with: ".*")
                        .replacingOccurrences(of: "\\*", with: "[^/]*")
                        .replacingOccurrences(of: "\\?", with: ".")
                    let base = record.root.deletingLastPathComponent().path + "/"
                    let candidates = [file.path, record.directory.path, record.directory.lastPathComponent,
                                      String(file.path.dropFirst(base.count)), String(record.directory.path.dropFirst(base.count))]
                    if candidates.contains(where: { $0.range(of: "^" + escaped + "$", options: .regularExpression) != nil }) { enabled = false }
                }
                for pattern in patterns where pattern.hasPrefix("+") {
                    if samePiSkillPath(String(pattern.dropFirst()), file: file, base: record.root.deletingLastPathComponent()) { enabled = true }
                }
                for pattern in patterns where pattern.hasPrefix("-") {
                    if samePiSkillPath(String(pattern.dropFirst()), file: file, base: record.root.deletingLastPathComponent()) { enabled = false }
                }
                records[index].enabled = enabled
            }
        }
    }

    private func skillSettings(agent: TandockCustomizationAgent, record: TandockSkillRecord, project: URL?, environment: [String: String]) -> [URL] {
        switch agent {
        case .claude:
            var urls = [configurationHome(agent: agent, environment: environment).appendingPathComponent("settings.json")]
            if let project {
                urls += [project.appendingPathComponent(".claude/settings.json"), project.appendingPathComponent(".claude/settings.local.json")]
            }
            return urls
        case .codex:
            // Path-specific overrides work for both global and project skills.
            return [configURL(agent: .codex, project: nil, environment: environment)]
        case .grok:
            // Grok ignores [skills] in project config files.
            return [configURL(agent: .grok, project: nil, environment: environment)]
        case .pi:
            if record.scope == .project, let project { return [project.appendingPathComponent(".pi/settings.json")] }
            return [configurationHome(agent: agent, environment: environment).appendingPathComponent("settings.json")]
        }
    }

    private func sameSkillPath(_ raw: String, file: URL, base: URL) -> Bool {
        let expanded = raw.hasPrefix("~/") ? home.appendingPathComponent(String(raw.dropFirst(2))) : raw.hasPrefix("/") ? URL(fileURLWithPath: raw) : base.appendingPathComponent(raw)
        let path = expanded.resolvingSymlinksInPath().path
        return path == file.resolvingSymlinksInPath().path || path == file.deletingLastPathComponent().resolvingSymlinksInPath().path
    }

    private func samePiSkillPath(_ raw: String, file: URL, base: URL) -> Bool {
        // Match Pi's exact filters against discovery paths, without resolving
        // symlinks: filtering one alias must not hide a still-enabled alias.
        let path = (raw.hasPrefix("./") || raw.hasPrefix(".\\") ? String(raw.dropFirst(2)) : raw)
            .replacingOccurrences(of: "\\", with: "/")
        let prefix = base.path + "/"
        let paths = [file.path, file.deletingLastPathComponent().path]
        return paths.contains(path) || paths.contains { $0.hasPrefix(prefix) && String($0.dropFirst(prefix.count)) == path }
    }

    private func array(_ value: JSONValue?) throws -> [JSONValue] {
        guard let value else { return [] }
        guard case let .array(values) = value else { throw TandockCustomizationError.invalidConfiguration }
        return values
    }
}

extension TandockMCPTableEditor {
    static func replacingTopLevel(_ key: String, value: JSONValue, in raw: String) throws -> String {
        func parsed(_ text: String) throws -> [String: JSONValue] {
            let json = try TOMLTable(string: text).convert(to: .json)
            guard case let .object(root) = try JSONDecoder().decode(JSONValue.self, from: Data(json.utf8)) else { throw TandockCustomizationError.invalidConfiguration }
            return root
        }
        var expected = try parsed(raw)
        expected[key] = value
        let lines = raw.components(separatedBy: "\n")
        var removed: Set<Int> = [], inSection = false, inRoot = true
        for (index, line) in lines.enumerated() {
            if let header = headerPath(line) { inSection = header.first == key; inRoot = false }
            if inSection { removed.insert(index) }
            else if inRoot && line.range(of: "^\\s*" + NSRegularExpression.escapedPattern(for: key) + "\\s*=", options: .regularExpression) != nil { removed.insert(index) }
        }
        var updated = lines.enumerated().filter { !removed.contains($0.offset) }.map(\.element).joined(separator: "\n")
        if !updated.isEmpty && !updated.hasSuffix("\n") { updated += "\n" }
        updated += "\n" + (try TOMLEncoder().encode([key: value]).convert(to: .toml)) + "\n"
        guard try parsed(updated) == expected else { throw TandockCustomizationError.invalidConfiguration }
        return updated
    }
}
