# YCode

macOS 原生多 Agent 工作台，使用 Swift、SwiftUI 和 AppKit。通过独立 PTY 运行 Claude Code、Codex、Gemini 或自定义 CLI，提供项目与会话管理、历史搜索、文件编辑、Git 变更和通知集成。

## 构建与运行

需要 macOS 14 及以上、带 Swift 6 工具链的 Xcode，以及可用的 `git`。使用 Agent 时需另外安装对应 CLI。

```sh
cd macos
swift test
scripts/build_and_run.sh run
```

- 只构建：`macos/scripts/build_and_run.sh build`。
- 产物：`macos/dist/YCode.app`，显示名称为 **YCode**。
- 开发构建版本：`macos/VERSION`；构建编号由当前 Git 提交生成。
- 默认使用本机唯一的 Apple Development 证书；可通过 `DEV_SIGNING_IDENTITY` 指定身份，`-` 表示 ad-hoc。
- 构建与运行不依赖旧 React、Tauri 或 Rust 工程，也不需要安装 Node 前端依赖。外部 Agent 可能仍需要各自的运行环境。

编辑器提供文件查看、基础语法高亮、手动编辑与保存，以及 Markdown/图片预览。不集成语言服务器、语义诊断或定义跳转。

## 工程结构

| 路径 | 用途 |
|---|---|
| `macos/YCodeApp/` | SwiftUI/AppKit 界面 |
| `macos/Core/` | 项目、会话、PTY、SQLite、历史、Git 与协议服务 |
| `macos/EditorSupport/` | 原生编辑与语法高亮 |
| `macos/Helpers/` | Swift CLI、MCP 和通知辅助程序 |
| `macos/Resources/` | 应用资源、图标源数据和许可证 |
| `macos/Tests/` | 单元测试与验证工具 |
| `macos/scripts/` | 构建、打包、迁移与回归脚本 |
| `docs/` | 功能说明、设计资料和迁移记录 |

Swift Package 管理 SwiftTerm、swift-markdown 和 Sparkle 依赖。图标已经嵌入 Swift 源码；需要更新时，用 Python 3 运行 `macos/scripts/generate_agent_icons.py` 和 `generate_file_icons.py`，无需前端包管理器。

## 发布与历史

原生发布入口为 `macos/scripts/package_release.sh`，支持 prepare、release 和 notarize。开发者签名不等于 Developer ID 分发签名或公证；正式发布条件见 [签名发布记录](docs/macos-native/M5.3-release-update-signing.md)。分支/PR 的 CI 测试并生成通用候选包；稳定版本标签触发签名、公证和 GitHub Releases 发布，配置见 [GitHub 发布指南](docs/macos-native/github-release.md)。

旧的 Tauri/React/Rust 应用和多平台构建入口已从当前工作树移除。历史代码仍可通过 Git 定位，清理前的本地修改另有备份；详见 [旧实现清理记录](docs/macos-native/M5.5-legacy-removal.md)。历史验收文档中的旧路径保留为追溯依据。

## License

[MIT](LICENSE)。图标上游许可位于 `macos/Resources/IconSources/`，随应用一并打包。
