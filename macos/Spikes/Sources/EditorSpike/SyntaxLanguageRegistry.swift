import Foundation

enum SyntaxEngine: String, Sendable {
    case treeSitter
    case nativeScanner
}

struct SyntaxLanguageGroup: Sendable {
    let id: String
    let extensions: [String]
    let filenames: [String]
    let engine: SyntaxEngine
    let indentWidth: Int

    init(
        _ id: String,
        extensions: [String] = [],
        filenames: [String] = [],
        engine: SyntaxEngine = .treeSitter,
        indentWidth: Int = 2
    ) {
        self.id = id
        self.extensions = extensions
        self.filenames = filenames
        self.engine = engine
        self.indentWidth = indentWidth
    }
}

/// FS.8 的唯一原生清单。旧实现实际为 39 组（16 个 CodeMirror language
/// package 组 + 23 个 StreamLanguage 组），旧文档写成 37 是计数错误。
let syntaxLanguageGroups: [SyntaxLanguageGroup] = [
    .init("javascript", extensions: ["js", "jsx", "mjs", "cjs"]),
    .init("typescript", extensions: ["ts", "tsx"]),
    .init("json", extensions: ["json", "jsonc", "json5"]),
    .init("markdown", extensions: ["md", "markdown"]),
    .init("rust", extensions: ["rs"], indentWidth: 4),
    .init("python", extensions: ["py"], indentWidth: 4),
    .init("java", extensions: ["java"], indentWidth: 4),
    .init("csharp", extensions: ["cs", "csx"], indentWidth: 4),
    .init("sql", extensions: ["sql", "ddl", "dml"]),
    .init("go", extensions: ["go"]),
    .init("cpp", extensions: ["c", "h", "cc", "cpp", "cxx", "c++", "hpp", "hh", "hxx"]),
    .init("php", extensions: ["php", "phtml"]),
    .init("css", extensions: ["css", "scss", "less"]),
    .init("html", extensions: ["html", "htm"]),
    .init("yaml", extensions: ["yaml", "yml"]),
    .init("xml", extensions: ["xml", "svg", "xsd", "xsl", "xslt", "plist"]),
    .init("ruby", extensions: ["rb", "rake", "gemspec", "podspec"], filenames: ["gemfile", "rakefile", "podfile", "brewfile", "vagrantfile", "guardfile"]),
    .init("kotlin", extensions: ["kt", "kts"]),
    .init("scala", extensions: ["scala", "sc"]),
    .init("dart", extensions: ["dart"]),
    .init("objective-c", extensions: ["m", "mm"]),
    .init("swift", extensions: ["swift"]),
    .init("lua", extensions: ["lua"]),
    .init("perl", extensions: ["pl", "pm"]),
    .init("r", extensions: ["r"]),
    .init("haskell", extensions: ["hs"]),
    .init("clojure", extensions: ["clj", "cljs", "cljc", "edn"]),
    .init("powershell", extensions: ["ps1", "psm1", "psd1"]),
    .init("groovy", extensions: ["groovy", "gradle"]),
    .init("julia", extensions: ["jl"]),
    .init("elm", extensions: ["elm"]),
    .init("erlang", extensions: ["erl", "hrl"]),
    .init("scheme", extensions: ["scm", "ss"]),
    .init("protobuf", extensions: ["proto"]),
    .init("diff", extensions: ["diff", "patch"], engine: .nativeScanner),
    .init("toml", extensions: ["toml"]),
    .init("properties", extensions: ["ini", "cfg", "conf", "properties", "env", "editorconfig"], engine: .nativeScanner),
    .init("shell", extensions: ["sh", "bash", "zsh", "ksh", "fish", "bashrc", "zshrc", "profile", "bash_profile"]),
    .init("dockerfile", filenames: ["dockerfile", "dockerfile.*"])
]
