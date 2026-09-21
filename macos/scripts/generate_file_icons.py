#!/usr/bin/env python3
"""生成文件树用的 material-icon-theme 图标表。

非原生版（src/lib/fileIcons.ts）在浏览器里按需加载 1238 个 SVG；原生版没有这个条件，
所以挑一份覆盖常见项目的子集内嵌进源码，其余回退到主题自带的默认 file / folder 图标。

用法：python3 macos/scripts/generate_file_icons.py
输出：macos/YCodeApp/Sources/YCodeApp/YCodeFileIcons.swift
"""

import json
import pathlib
import re
import sys

ROOT = pathlib.Path(__file__).resolve().parents[2]
THEME = ROOT / "node_modules" / "material-icon-theme"
OUT = ROOT / "macos" / "YCodeApp" / "Sources" / "YCodeApp" / "YCodeFileIcons.swift"

# 与 YCodeSyntaxRegistry 的语言清单对齐，再补上日常会遇到的资源与配置类型
EXTENSIONS = [
    "swift", "rs", "go", "py", "rb", "java", "kt", "kts", "scala", "dart", "php", "lua", "pl", "r",
    "hs", "clj", "cljs", "ex", "exs", "erl", "jl", "zig", "c", "h", "cc", "cpp", "hpp", "m", "mm",
    "cs", "fs", "vb", "sh", "bash", "zsh", "fish", "ps1", "bat",
    "ts", "tsx", "js", "jsx", "mjs", "cjs", "vue", "svelte", "astro",
    "json", "jsonc", "json5", "yaml", "yml", "toml", "ini", "cfg", "conf", "env", "properties",
    "xml", "svg", "html", "htm", "css", "scss", "sass", "less",
    "md", "markdown", "mdx", "txt", "pdf", "csv", "tsv", "sql", "graphql", "gql", "proto",
    "png", "jpg", "jpeg", "gif", "webp", "ico", "icns", "mp3", "wav", "mp4", "mov", "webm",
    "zip", "tar", "gz", "7z", "dmg", "lock", "log", "diff", "patch", "makefile", "gradle",
    "plist", "entitlements", "xcconfig", "pbxproj", "storyboard", "xib", "wasm", "ipynb",
]

FILENAMES = [
    "package.json", "package-lock.json", "bun.lock", "bun.lockb", "yarn.lock", "pnpm-lock.yaml",
    "cargo.toml", "cargo.lock", "package.swift", "go.mod", "go.sum", "gemfile", "rakefile",
    "dockerfile", "docker-compose.yml", "makefile", "cmakelists.txt", "justfile",
    "readme.md", "license", "changelog.md", "contributing.md", "codeowners",
    ".gitignore", ".gitattributes", ".editorconfig", ".env", ".env.local",
    "tsconfig.json", "vite.config.ts", "webpack.config.js", "eslint.config.js", ".eslintrc",
    ".prettierrc", "tailwind.config.js", "babel.config.js", "jest.config.js", "info.plist",
]

FOLDERS = [
    "src", "source", "lib", "app", "apps", "components", "views", "pages", "hooks", "utils",
    "test", "tests", "spec", "__tests__", "e2e", "docs", "doc", "examples", "scripts", "tools",
    "config", "assets", "images", "img", "fonts", "styles", "css", "public", "static",
    "dist", "build", "out", "target", "node_modules", "vendor", "crates", "packages",
    ".git", ".github", ".vscode", ".idea", "macos", "ios", "android", "web", "server", "client",
    "api", "core", "shared", "types", "models", "controllers", "services", "migrations",
    "resources", "templates", "locales", "i18n", "plugins", "themes", "temp", "tmp", "logs",
]


def compact(svg: str) -> str:
    svg = re.sub(r"<\?xml[^>]*\?>", "", svg)
    svg = re.sub(r"<!--.*?-->", "", svg, flags=re.S)
    svg = re.sub(r">\s+<", "><", svg)
    return re.sub(r"\s+", " ", svg).strip()


def main() -> int:
    if not THEME.exists():
        print(f"missing {THEME}; run bun/npm install first", file=sys.stderr)
        return 1

    manifest = json.loads((THEME / "dist" / "material-icons.json").read_text(encoding="utf-8"))
    by_extension = manifest["fileExtensions"]
    by_filename = manifest["fileNames"]
    by_folder = manifest["folderNames"]
    by_folder_open = manifest["folderNamesExpanded"]
    by_language = manifest.get("languageIds", {})

    # material-icon-theme 把一部分常见扩展名留给 VS Code 的语言注册表，
    # 这里跟 src/lib/fileIcons.ts 一样手工补上。
    language_fallback = {
        "ts": "typescript", "mts": "typescript", "cts": "typescript",
        "js": "javascript", "cjs": "javascript", "mjs": "javascript",
        "html": "html", "htm": "html", "css": "css", "json": "json", "jsonc": "json",
        "md": "markdown", "markdown": "markdown", "xml": "xml", "yaml": "yaml", "yml": "yaml",
        "sh": "shellscript", "bash": "shellscript", "zsh": "shellscript",
        "py": "python", "rb": "ruby", "php": "php", "sql": "sql", "swift": "swift",
        "java": "java", "kt": "kotlin", "go": "go", "rs": "rust", "c": "c", "cpp": "cpp",
    }

    extension_map: dict[str, str] = {}
    for ext in EXTENSIONS:
        icon = by_extension.get(ext) or by_language.get(language_fallback.get(ext, ""), None)
        if icon:
            extension_map[ext] = icon

    filename_map = {name: by_filename[name] for name in FILENAMES if name in by_filename}
    folder_map = {name: by_folder[name] for name in FOLDERS if name in by_folder}
    folder_open_map = {name: by_folder_open[name] for name in FOLDERS if name in by_folder_open}

    defaults = {
        "file": manifest["file"],
        "folder": manifest["folder"],
        "folderExpanded": manifest["folderExpanded"],
    }

    wanted = set(extension_map.values()) | set(filename_map.values())
    wanted |= set(folder_map.values()) | set(folder_open_map.values()) | set(defaults.values())

    svgs: dict[str, str] = {}
    for name in sorted(wanted):
        path = THEME / "icons" / f"{name}.svg"
        if not path.exists():
            print(f"skip {name}: no svg", file=sys.stderr)
            continue
        svgs[name] = compact(path.read_text(encoding="utf-8"))

    def table(name: str, mapping: dict[str, str], comment: str) -> list[str]:
        lines = [f"    /// {comment}", f"    static let {name}: [String: String] = ["]
        for key in sorted(mapping):
            if mapping[key] in svgs:
                lines.append(f'        "{key}": "{mapping[key]}",')
        lines.append("    ]")
        lines.append("")
        return lines

    out = [
        "// 由 macos/scripts/generate_file_icons.py 生成，请勿手改。",
        "// 图标来自 material-icon-theme（MIT），与非原生版 src/lib/fileIcons.ts 同一套主题。",
        "",
        "enum YCodeFileIconCatalog {",
        f'    static let defaultFile = "{defaults["file"]}"',
        f'    static let defaultFolder = "{defaults["folder"]}"',
        f'    static let defaultFolderExpanded = "{defaults["folderExpanded"]}"',
        "",
    ]
    out += table("byExtension", extension_map, "扩展名 → 图标名")
    out += table("byFileName", filename_map, "整个文件名 → 图标名（package.json 这类）")
    out += table("byFolder", folder_map, "文件夹名 → 图标名")
    out += table("byFolderExpanded", folder_open_map, "展开态的文件夹图标")
    out += ["    /// 图标名 → SVG", "    static let svg: [String: String] = ["]
    for name in sorted(svgs):
        out.append(f'        "{name}": """')
        out.append(f"        {svgs[name]}")
        out.append('        """,')
    out += ["    ]", "}", ""]

    OUT.write_text("\n".join(out), encoding="utf-8")
    size = OUT.stat().st_size // 1024
    print(f"wrote {OUT}: {len(svgs)} icons, {size} KB")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
