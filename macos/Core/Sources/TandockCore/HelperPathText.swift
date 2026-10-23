import Foundation

enum HelperPathText {
    static func tomlEscaped(_ value: String) -> String {
        var escaped = ""
        for character in value {
            switch character {
            case "\\": escaped += "\\\\"
            case "\"": escaped += "\\\""
            case "\n": escaped += "\\n"
            case "\r": escaped += "\\r"
            case "\t": escaped += "\\t"
            default: escaped.append(character)
            }
        }
        return escaped
    }

    static func parseTOMLString(_ raw: String) -> String? {
        let value = raw.trimmingCharacters(in: .whitespaces)
        if value.count >= 2, value.hasPrefix("'"), value.hasSuffix("'") {
            return String(value.dropFirst().dropLast())
        }
        guard value.hasPrefix("\""), let data = value.data(using: .utf8) else { return nil }
        return try? JSONSerialization.jsonObject(with: data, options: .fragmentsAllowed) as? String
    }

    static func leadingPath(ofCommand command: String) -> (path: String, rest: Substring)? {
        let trimmed = command.drop { $0 == " " }
        if trimmed.first == "'" {
            var path = ""
            var index = trimmed.index(after: trimmed.startIndex)
            while index < trimmed.endIndex {
                if trimmed[index] == "'" {
                    let escape = trimmed[index...].prefix(4)
                    if escape == "'\\''" {
                        path.append("'")
                        index = trimmed.index(index, offsetBy: 4)
                        continue
                    }
                    return (path, trimmed[trimmed.index(after: index)...])
                }
                path.append(trimmed[index])
                index = trimmed.index(after: index)
            }
            return nil
        }
        guard let first = trimmed.split(separator: " ", maxSplits: 1).first else { return nil }
        return (String(first), trimmed[first.endIndex...])
    }

    static func shellQuoted(_ value: String) -> String {
        "'\(value.replacingOccurrences(of: "'", with: "'\\''"))'"
    }

    static func tomlSpellings(of path: String) -> [String] {
        let plain = tomlEscaped(path)
        let jsonEscaped = tomlEscaped(path.replacingOccurrences(of: "/", with: "\\/"))
        return plain == jsonEscaped ? [plain] : [jsonEscaped, plain]
    }

    static func replacingTOMLSpellings(of old: String, with new: String, in text: String) -> String {
        zip(tomlSpellings(of: old), tomlSpellings(of: new)).reduce(text) { result, pair in
            result.replacingOccurrences(of: pair.0, with: pair.1)
        }
    }
}
