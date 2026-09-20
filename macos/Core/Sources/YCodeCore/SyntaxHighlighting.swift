import Foundation

public enum YCodePreviewKind: String, Sendable {
    case source
    case markdown
    case image
    case svg

    public static func resolve(path: String) -> Self {
        let name = path.split(separator: "/").last.map(String.init)?.lowercased() ?? path.lowercased()
        let ext = name.split(separator: ".").last.map(String.init) ?? ""
        switch ext {
        case "md", "markdown": return YCodePreviewKind.markdown
        case "svg": return YCodePreviewKind.svg
        case "png", "jpg", "jpeg", "gif", "webp", "bmp", "ico", "avif", "apng": return YCodePreviewKind.image
        default: return YCodePreviewKind.source
        }
    }
}

public struct YCodeSyntaxLanguageGroup: Equatable, Sendable {
    public let id: String
    public let extensions: [String]
    public let filenames: [String]
    public let indentWidth: Int
    public let verificationSample: String

    public init(
        id: String,
        extensions: [String] = [],
        filenames: [String] = [],
        indentWidth: Int = 2,
        verificationSample: String
    ) {
        self.id = id
        self.extensions = extensions
        self.filenames = filenames
        self.indentWidth = indentWidth
        self.verificationSample = verificationSample
    }
}

public enum YCodeSyntaxTokenKind: String, Sendable {
    case keyword
    case string
    case comment
    case number
    case property
    case heading
    case addition
    case deletion
    case metadata
}

public struct YCodeSyntaxToken: Equatable, Sendable {
    public let range: NSRange
    public let kind: YCodeSyntaxTokenKind

    public init(range: NSRange, kind: YCodeSyntaxTokenKind) {
        self.range = range
        self.kind = kind
    }
}

public enum YCodeSyntaxRegistry {
    /// FS.8 的唯一正式清单：16 个原生语言包组 + 23 个旧 StreamLanguage 组。
    public static let groups: [YCodeSyntaxLanguageGroup] = [
        .init(id: "javascript", extensions: ["js", "jsx", "mjs", "cjs"], verificationSample: "const answer = 42"),
        .init(id: "typescript", extensions: ["ts", "tsx"], verificationSample: "interface User { name: string }"),
        .init(id: "json", extensions: ["json", "jsonc", "json5"], verificationSample: "{\"enabled\": true}"),
        .init(id: "markdown", extensions: ["md", "markdown"], verificationSample: "# Heading"),
        .init(id: "rust", extensions: ["rs"], indentWidth: 4, verificationSample: "fn main() { let value = 1; }"),
        .init(id: "python", extensions: ["py"], indentWidth: 4, verificationSample: "def greet(name): return name"),
        .init(id: "java", extensions: ["java"], indentWidth: 4, verificationSample: "public class Main {}"),
        .init(id: "csharp", extensions: ["cs", "csx"], indentWidth: 4, verificationSample: "public class Program {}"),
        .init(id: "sql", extensions: ["sql", "ddl", "dml"], verificationSample: "SELECT name FROM users"),
        .init(id: "go", extensions: ["go"], verificationSample: "package main\nfunc main() {}"),
        .init(id: "cpp", extensions: ["c", "h", "cc", "cpp", "cxx", "c++", "hpp", "hh", "hxx"], verificationSample: "class Widget { public: int value; };"),
        .init(id: "php", extensions: ["php", "phtml"], verificationSample: "<?php function greet() { return true; }"),
        .init(id: "css", extensions: ["css", "scss", "less"], verificationSample: ".item { color: red; }"),
        .init(id: "html", extensions: ["html", "htm"], verificationSample: "<main class=\"page\">Hello</main>"),
        .init(id: "yaml", extensions: ["yaml", "yml"], verificationSample: "enabled: true"),
        .init(id: "xml", extensions: ["xml", "svg", "xsd", "xsl", "xslt", "plist"], verificationSample: "<node key=\"value\"/>"),
        .init(id: "ruby", extensions: ["rb", "rake", "gemspec", "podspec"], filenames: ["gemfile", "rakefile", "podfile", "brewfile", "vagrantfile", "guardfile"], verificationSample: "class Greeter; def call; end; end"),
        .init(id: "kotlin", extensions: ["kt", "kts"], verificationSample: "data class User(val name: String)"),
        .init(id: "scala", extensions: ["scala", "sc"], verificationSample: "object Main { def run = true }"),
        .init(id: "dart", extensions: ["dart"], verificationSample: "class App { final value = true; }"),
        .init(id: "objective-c", extensions: ["m", "mm"], verificationSample: "@interface Widget : NSObject @end"),
        .init(id: "swift", extensions: ["swift"], verificationSample: "struct User { let name: String }"),
        .init(id: "lua", extensions: ["lua"], verificationSample: "local function greet() return true end"),
        .init(id: "perl", extensions: ["pl", "pm"], verificationSample: "sub greet { return 1; }"),
        .init(id: "r", extensions: ["r"], verificationSample: "function(value) { return(value) }"),
        .init(id: "haskell", extensions: ["hs"], verificationSample: "module Main where\nmain = let value = True in value"),
        .init(id: "clojure", extensions: ["clj", "cljs", "cljc", "edn"], verificationSample: "(defn greet [name] name)"),
        .init(id: "powershell", extensions: ["ps1", "psm1", "psd1"], verificationSample: "function Get-Value { return $true }"),
        .init(id: "groovy", extensions: ["groovy", "gradle"], verificationSample: "class App { def value = true }"),
        .init(id: "julia", extensions: ["jl"], verificationSample: "function greet(name) return name end"),
        .init(id: "elm", extensions: ["elm"], verificationSample: "module Main exposing (main)"),
        .init(id: "erlang", extensions: ["erl", "hrl"], verificationSample: "-module(main).\n-export([start/0])."),
        .init(id: "scheme", extensions: ["scm", "ss"], verificationSample: "(define (greet name) name)"),
        .init(id: "protobuf", extensions: ["proto"], verificationSample: "message User { string name = 1; }"),
        .init(id: "diff", extensions: ["diff", "patch"], verificationSample: "+added line"),
        .init(id: "toml", extensions: ["toml"], verificationSample: "name = \"ycode\""),
        .init(id: "properties", extensions: ["ini", "cfg", "conf", "properties", "env", "editorconfig"], verificationSample: "enabled=true"),
        .init(id: "shell", extensions: ["sh", "bash", "zsh", "ksh", "fish", "bashrc", "zshrc", "profile", "bash_profile"], verificationSample: "if true; then echo \"ok\"; fi"),
        .init(id: "dockerfile", filenames: ["dockerfile", "dockerfile.*"], verificationSample: "FROM swift:latest\nRUN echo ok")
    ]

    public static func language(forPath path: String) -> YCodeSyntaxLanguageGroup? {
        let name = path.split(separator: "/").last.map(String.init)?.lowercased() ?? path.lowercased()
        if name == "dockerfile" || name.hasPrefix("dockerfile.") {
            return groups.first { $0.id == "dockerfile" }
        }
        if let filenameMatch = groups.first(where: { $0.filenames.contains(name) }) {
            return filenameMatch
        }
        let ext: String
        if let dot = name.lastIndex(of: ".") {
            ext = String(name[name.index(after: dot)...])
        } else {
            ext = name
        }
        return groups.first { $0.extensions.contains(ext) }
    }
}

public struct YCodeSyntaxHighlighter: Sendable {
    public init() {}

    public func tokens(in source: String, path: String) -> [YCodeSyntaxToken] {
        guard let language = YCodeSyntaxRegistry.language(forPath: path), !source.isEmpty else { return [] }
        let text = source as NSString
        var tokens = lexicalTokens(in: text, languageID: language.id)
        tokens.append(contentsOf: structuralTokens(in: source, text: text, languageID: language.id))
        return tokens.filter { $0.range.location >= 0 && NSMaxRange($0.range) <= text.length }
    }

    private func lexicalTokens(in text: NSString, languageID: String) -> [YCodeSyntaxToken] {
        let keywords = Self.keywords[languageID] ?? []
        let lineComments = Self.lineCommentMarkers[languageID] ?? ["//"]
        let blockComments = Self.blockCommentMarkers[languageID] ?? [("/*", "*/")]
        var result: [YCodeSyntaxToken] = []
        var index = 0

        while index < text.length {
            if let marker = lineComments.first(where: { text.hasPrefix($0, at: index) }) {
                let end = text.range(of: "\n", options: [], range: NSRange(location: index, length: text.length - index)).location
                let length = end == NSNotFound ? text.length - index : end - index
                result.append(.init(range: NSRange(location: index, length: length), kind: .comment))
                index += max(length, marker.utf16.count)
                continue
            }
            if let marker = blockComments.first(where: { text.hasPrefix($0.0, at: index) }) {
                let searchStart = index + marker.0.utf16.count
                let found = text.range(of: marker.1, options: [], range: NSRange(location: searchStart, length: text.length - searchStart))
                let end = found.location == NSNotFound ? text.length : NSMaxRange(found)
                result.append(.init(range: NSRange(location: index, length: end - index), kind: .comment))
                index = end
                continue
            }

            let unit = text.character(at: index)
            if unit == 34 || unit == 39 || unit == 96 {
                let quote = unit
                var cursor = index + 1
                var escaped = false
                while cursor < text.length {
                    let current = text.character(at: cursor)
                    if current == quote, !escaped { cursor += 1; break }
                    escaped = current == 92 && !escaped
                    if current != 92 { escaped = false }
                    cursor += 1
                }
                result.append(.init(range: NSRange(location: index, length: cursor - index), kind: .string))
                index = cursor
                continue
            }

            if Self.isDigit(unit) {
                var cursor = index + 1
                while cursor < text.length {
                    let current = text.character(at: cursor)
                    guard Self.isDigit(current) || current == 46 || Self.isHexLetter(current) else { break }
                    cursor += 1
                }
                result.append(.init(range: NSRange(location: index, length: cursor - index), kind: .number))
                index = cursor
                continue
            }

            if Self.isIdentifierStart(unit) {
                var cursor = index + 1
                while cursor < text.length, Self.isIdentifierPart(text.character(at: cursor)) { cursor += 1 }
                let range = NSRange(location: index, length: cursor - index)
                let word = text.substring(with: range).lowercased()
                let normalized = word.hasPrefix("@") || word.hasPrefix("$") ? String(word.dropFirst()) : word
                if keywords.contains(word) || keywords.contains(normalized) {
                    result.append(.init(range: range, kind: .keyword))
                }
                index = cursor
                continue
            }
            index += 1
        }
        return result
    }

    private func structuralTokens(in source: String, text: NSString, languageID: String) -> [YCodeSyntaxToken] {
        var result: [YCodeSyntaxToken] = []
        if languageID == "markdown" {
            result += Self.matches(pattern: "(?m)^#{1,6}[ \\t]+.*$", in: source, kind: .heading)
        }
        if languageID == "html" || languageID == "xml" {
            result += Self.matches(pattern: "</?[A-Za-z][A-Za-z0-9:_-]*", in: source, kind: .keyword)
        }
        if ["yaml", "toml", "properties"].contains(languageID) {
            result += Self.matches(pattern: "(?m)^[ \\t]*[A-Za-z0-9_.-]+(?=[ \\t]*[:=])", in: source, kind: .property)
        }
        if languageID == "diff" {
            var location = 0
            for line in source.split(separator: "\n", omittingEmptySubsequences: false) {
                let value = String(line)
                let length = value.utf16.count
                let kind: YCodeSyntaxTokenKind?
                if value.hasPrefix("+") && !value.hasPrefix("+++") { kind = .addition }
                else if value.hasPrefix("-") && !value.hasPrefix("---") { kind = .deletion }
                else if value.hasPrefix("@@") || value.hasPrefix("diff ") || value.hasPrefix("+++") || value.hasPrefix("---") { kind = .metadata }
                else { kind = nil }
                if let kind { result.append(.init(range: NSRange(location: location, length: length), kind: kind)) }
                location += length + 1
            }
        }
        return result.filter { NSMaxRange($0.range) <= text.length }
    }

    private static func matches(pattern: String, in source: String, kind: YCodeSyntaxTokenKind) -> [YCodeSyntaxToken] {
        guard let expression = try? NSRegularExpression(pattern: pattern) else { return [] }
        let range = NSRange(source.startIndex..<source.endIndex, in: source)
        return expression.matches(in: source, range: range).map { .init(range: $0.range, kind: kind) }
    }

    private static func isDigit(_ unit: unichar) -> Bool { unit >= 48 && unit <= 57 }
    private static func isHexLetter(_ unit: unichar) -> Bool { (unit >= 65 && unit <= 70) || (unit >= 97 && unit <= 102) }
    private static func isIdentifierStart(_ unit: unichar) -> Bool {
        unit == 36 || unit == 64 || unit == 95 || (unit >= 65 && unit <= 90) || (unit >= 97 && unit <= 122) || unit > 127
    }
    private static func isIdentifierPart(_ unit: unichar) -> Bool { isIdentifierStart(unit) || isDigit(unit) || unit == 45 }

    private static let lineCommentMarkers: [String: [String]] = [
        "python": ["#"], "ruby": ["#"], "perl": ["#"], "r": ["#"], "shell": ["#"], "dockerfile": ["#"],
        "powershell": ["#"], "yaml": ["#"], "toml": ["#"], "properties": ["#", ";"],
        "sql": ["--"], "lua": ["--"], "haskell": ["--"], "elm": ["--"], "erlang": ["%"],
        "clojure": [";"], "scheme": [";"], "html": [], "xml": [], "markdown": []
    ]

    private static let blockCommentMarkers: [String: [(String, String)]] = [
        "html": [("<!--", "-->")], "xml": [("<!--", "-->")], "markdown": [("<!--", "-->")],
        "haskell": [("{-", "-}")], "elm": [("{-", "-}")], "powershell": [("<#", "#>")],
        "julia": [("#=", "=#")], "objective-c": [("/*", "*/")]
    ]

    private static let keywords: [String: Set<String>] = [
        "javascript": ["async", "await", "break", "case", "catch", "class", "const", "continue", "default", "delete", "do", "else", "export", "extends", "false", "finally", "for", "from", "function", "if", "import", "in", "instanceof", "let", "new", "null", "of", "return", "static", "super", "switch", "this", "throw", "true", "try", "typeof", "undefined", "var", "while", "yield"],
        "typescript": ["any", "as", "async", "await", "boolean", "class", "const", "declare", "enum", "export", "extends", "false", "from", "function", "if", "implements", "import", "interface", "keyof", "let", "namespace", "never", "new", "null", "number", "private", "protected", "public", "readonly", "return", "satisfies", "static", "string", "this", "true", "type", "typeof", "undefined", "unknown", "void"],
        "json": ["true", "false", "null"],
        "rust": ["as", "async", "await", "break", "const", "continue", "crate", "dyn", "else", "enum", "extern", "false", "fn", "for", "if", "impl", "in", "let", "loop", "match", "mod", "move", "mut", "pub", "ref", "return", "self", "static", "struct", "super", "trait", "true", "type", "unsafe", "use", "where", "while"],
        "python": ["and", "as", "assert", "async", "await", "break", "class", "continue", "def", "del", "elif", "else", "except", "false", "finally", "for", "from", "global", "if", "import", "in", "is", "lambda", "none", "nonlocal", "not", "or", "pass", "raise", "return", "true", "try", "while", "with", "yield"],
        "java": ["abstract", "boolean", "break", "case", "catch", "class", "const", "continue", "default", "do", "double", "else", "enum", "extends", "false", "final", "finally", "float", "for", "if", "implements", "import", "instanceof", "int", "interface", "long", "native", "new", "null", "package", "private", "protected", "public", "return", "short", "static", "strictfp", "super", "switch", "synchronized", "this", "throw", "throws", "transient", "true", "try", "void", "volatile", "while"],
        "csharp": ["abstract", "as", "async", "await", "base", "bool", "break", "case", "catch", "class", "const", "continue", "decimal", "default", "delegate", "do", "else", "enum", "event", "explicit", "extern", "false", "finally", "fixed", "for", "foreach", "if", "implicit", "in", "int", "interface", "internal", "is", "lock", "namespace", "new", "null", "object", "operator", "out", "override", "params", "private", "protected", "public", "readonly", "ref", "return", "sealed", "static", "string", "struct", "switch", "this", "throw", "true", "try", "typeof", "using", "var", "virtual", "void", "while"],
        "sql": ["alter", "and", "as", "asc", "begin", "between", "by", "case", "commit", "create", "delete", "desc", "distinct", "drop", "else", "end", "exists", "false", "from", "full", "group", "having", "in", "index", "inner", "insert", "into", "is", "join", "left", "like", "limit", "not", "null", "on", "or", "order", "outer", "primary", "references", "right", "rollback", "select", "set", "table", "then", "true", "union", "unique", "update", "values", "view", "when", "where", "with"],
        "go": ["break", "case", "chan", "const", "continue", "default", "defer", "else", "fallthrough", "false", "for", "func", "go", "goto", "if", "import", "interface", "map", "nil", "package", "range", "return", "select", "struct", "switch", "true", "type", "var"],
        "cpp": ["alignas", "auto", "bool", "break", "case", "catch", "char", "class", "const", "constexpr", "continue", "default", "delete", "do", "double", "else", "enum", "explicit", "extern", "false", "float", "for", "friend", "if", "inline", "int", "long", "namespace", "new", "noexcept", "nullptr", "operator", "private", "protected", "public", "return", "short", "signed", "sizeof", "static", "struct", "switch", "template", "this", "throw", "true", "try", "typedef", "typename", "union", "unsigned", "using", "virtual", "void", "volatile", "while"],
        "php": ["abstract", "and", "array", "as", "break", "callable", "case", "catch", "class", "clone", "const", "continue", "declare", "default", "do", "echo", "else", "elseif", "endfor", "endforeach", "endif", "endswitch", "extends", "false", "final", "finally", "fn", "for", "foreach", "function", "global", "if", "implements", "include", "instanceof", "interface", "namespace", "new", "null", "or", "private", "protected", "public", "require", "return", "static", "switch", "throw", "trait", "true", "try", "use", "while", "yield"],
        "css": ["color", "display", "font", "grid", "height", "import", "media", "padding", "position", "transform", "transition", "var", "width"],
        "yaml": ["true", "false", "null", "yes", "no"],
        "ruby": ["alias", "and", "begin", "break", "case", "class", "def", "defined", "do", "else", "elsif", "end", "ensure", "false", "for", "if", "in", "module", "next", "nil", "not", "or", "redo", "rescue", "retry", "return", "self", "super", "then", "true", "undef", "unless", "until", "when", "while", "yield"],
        "kotlin": ["as", "break", "by", "catch", "class", "companion", "const", "continue", "data", "do", "else", "enum", "false", "final", "finally", "for", "fun", "if", "import", "in", "interface", "internal", "is", "lateinit", "null", "object", "open", "operator", "out", "override", "package", "private", "protected", "public", "return", "sealed", "suspend", "this", "throw", "true", "try", "typealias", "val", "var", "when", "while"],
        "scala": ["abstract", "case", "catch", "class", "def", "do", "else", "extends", "false", "final", "finally", "for", "forSome", "if", "implicit", "import", "lazy", "match", "new", "null", "object", "override", "package", "private", "protected", "return", "sealed", "super", "this", "throw", "trait", "true", "try", "type", "val", "var", "while", "with", "yield"],
        "dart": ["abstract", "as", "assert", "async", "await", "break", "case", "catch", "class", "const", "continue", "covariant", "default", "deferred", "do", "dynamic", "else", "enum", "export", "extends", "extension", "external", "factory", "false", "final", "finally", "for", "function", "get", "hide", "if", "implements", "import", "in", "interface", "is", "late", "library", "mixin", "new", "null", "on", "operator", "part", "required", "return", "set", "show", "static", "super", "switch", "sync", "this", "throw", "true", "try", "typedef", "var", "void", "while", "with", "yield"],
        "objective-c": ["autoreleasepool", "catch", "class", "dynamic", "encode", "end", "finally", "implementation", "interface", "optional", "private", "property", "protected", "protocol", "public", "required", "selector", "synchronized", "synthesize", "throw", "try"],
        "swift": ["actor", "associatedtype", "async", "await", "break", "case", "catch", "class", "continue", "defer", "deinit", "do", "else", "enum", "extension", "false", "fileprivate", "for", "func", "guard", "if", "import", "in", "init", "inout", "internal", "is", "let", "nil", "nonisolated", "open", "operator", "private", "protocol", "public", "repeat", "rethrows", "return", "self", "some", "static", "struct", "subscript", "super", "switch", "throw", "throws", "true", "try", "typealias", "var", "where", "while"],
        "lua": ["and", "break", "do", "else", "elseif", "end", "false", "for", "function", "goto", "if", "in", "local", "nil", "not", "or", "repeat", "return", "then", "true", "until", "while"],
        "perl": ["continue", "do", "else", "elsif", "for", "foreach", "given", "if", "last", "local", "my", "next", "package", "redo", "require", "return", "state", "sub", "unless", "until", "use", "when", "while"],
        "r": ["break", "else", "false", "for", "function", "if", "in", "inf", "na", "nan", "next", "null", "repeat", "return", "true", "while"],
        "haskell": ["case", "class", "data", "default", "deriving", "do", "else", "foreign", "if", "import", "in", "infix", "instance", "let", "module", "newtype", "of", "then", "true", "type", "where"],
        "clojure": ["def", "defn", "do", "fn", "if", "let", "loop", "nil", "quote", "recur", "throw", "true", "try", "var"],
        "powershell": ["begin", "break", "catch", "class", "continue", "data", "do", "dynamicparam", "else", "elseif", "end", "enum", "exit", "false", "filter", "finally", "for", "foreach", "from", "function", "if", "in", "param", "process", "return", "switch", "throw", "trap", "true", "try", "until", "while", "workflow"],
        "groovy": ["abstract", "as", "assert", "break", "case", "catch", "class", "const", "continue", "def", "default", "do", "else", "enum", "extends", "false", "final", "finally", "for", "goto", "if", "implements", "import", "in", "instanceof", "interface", "native", "new", "null", "package", "private", "protected", "public", "return", "static", "strictfp", "super", "switch", "synchronized", "this", "throw", "throws", "trait", "transient", "true", "try", "var", "void", "volatile", "while"],
        "julia": ["baremodule", "begin", "break", "catch", "const", "continue", "do", "else", "elseif", "end", "export", "false", "finally", "for", "function", "global", "if", "import", "let", "local", "macro", "module", "quote", "return", "struct", "true", "try", "using", "while"],
        "elm": ["alias", "as", "case", "else", "exposing", "false", "if", "import", "in", "infix", "let", "module", "of", "port", "then", "true", "type", "where"],
        "erlang": ["after", "and", "andalso", "band", "begin", "bnot", "bor", "bsl", "bsr", "bxor", "case", "catch", "cond", "div", "end", "fun", "if", "let", "not", "of", "or", "orelse", "receive", "rem", "try", "when", "xor"],
        "scheme": ["and", "begin", "case", "cond", "define", "delay", "do", "else", "if", "lambda", "let", "letrec", "or", "quasiquote", "quote", "set", "syntax-rules", "unquote"],
        "protobuf": ["bool", "bytes", "double", "enum", "extend", "extensions", "false", "fixed32", "fixed64", "float", "import", "int32", "int64", "map", "message", "oneof", "option", "optional", "package", "public", "repeated", "required", "reserved", "returns", "rpc", "service", "sfixed32", "sfixed64", "sint32", "sint64", "stream", "string", "syntax", "to", "true", "uint32", "uint64"],
        "shell": ["case", "do", "done", "elif", "else", "esac", "export", "fi", "for", "function", "if", "in", "local", "readonly", "return", "select", "then", "time", "true", "until", "while"],
        "dockerfile": ["add", "arg", "cmd", "copy", "entrypoint", "env", "expose", "from", "healthcheck", "label", "maintainer", "onbuild", "run", "shell", "stopsignal", "user", "volume", "workdir"]
    ]
}

private extension NSString {
    func hasPrefix(_ prefix: String, at location: Int) -> Bool {
        let length = prefix.utf16.count
        guard location >= 0, location + length <= self.length else { return false }
        return substring(with: NSRange(location: location, length: length)) == prefix
    }
}
