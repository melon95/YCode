<p align="center">
  <img src="macos/Resources/AppIcon.svg" width="88" alt="YCode 图标">
</p>

<h1 align="center">YCode</h1>

<p align="center">简体中文 · <a href="README.en.md">English</a></p>

<p align="center">把 Agent、代码和变更放在同一个工作台。</p>
<p align="center">macOS 14+ · Swift / SwiftUI / AppKit · Apple Silicon / Intel</p>
<p align="center">
  <a href="https://github.com/melon95/YCode/releases/latest">下载 YCode</a> ·
  <a href="#快速开始">快速开始</a> ·
  <a href="#从源码构建">从源码构建</a> ·
  <a href="LICENSE">MIT License</a>
</p>

![YCode 原生工作台：项目侧栏、新建会话、待办与文件面板](docs/assets/overview.png)

YCode 是 macOS 原生多 Agent 工作台。通过独立 PTY 运行 Claude Code、Codex、Pi 或自定义 CLI，在一个窗口里管理项目和会话、查看文件、审阅 Git 变更、跟进待办。Agent 的交互保留在真实终端中。

## 工作台里有什么

- **项目与会话**：按项目组织会话，搜索、过滤、归档与恢复；项目也可在独立窗口中打开。
- **多会话画布**：最多同时显示 4 个会话，切换布局和焦点，保留各自的终端进程。
- **可组合面板**：文件、变更、待办和项目终端可同时打开，调整排列与宽度。
- **文件与编辑**：文件树、预览与固定标签、基础语法高亮、手动编辑和保存，支持 Markdown、SVG 与图片预览，处理外部文件修改冲突。
- **Git 审阅**：内联 diff、目录树视图、逐块暂存、提交、分支切换及 Fetch / Pull / Push，也可查看会话检查点。
- **待办与集成**：按队列、进行中和已完成管理任务；提供 MCP 待办工具、Agent hook 与系统通知。历史搜索和用量统计依赖对应 Agent 的本地记录。
- **原生外观**：浅色、深色与跟随系统，中英文界面，独立调整界面、编辑器和终端字号。

### 文件与代码

在终端会话旁查看目录和源文件，直接完成小幅修改。

![文件树与 Swift 源码基础语法高亮](docs/assets/files.png)

### Git 变更

按文件浏览差异，在工作区变更视图中暂存并提交；需要时展开目录树定位文件。

![Git 变更面板中的 Swift 和 Markdown 文件差异](docs/assets/changes.png)

> 截图来自原生版 0.7.0 的英文界面，使用独立的 Welcome 演示项目与英文待办数据。

## 快速开始

1. 从 [GitHub Releases](https://github.com/melon95/YCode/releases/latest) 下载原生 macOS ZIP，解压后将 `YCode.app` 拖入「应用程序」。发布包为 Apple Silicon / Intel 通用版本。
2. 安装并登录需要使用的 Agent CLI。YCode 默认提供 Claude Code 和 Codex 配置；Pi 和其他 CLI 可在「设置 → Agent」中添加，命令、参数和环境变量按工具要求配置。
3. 按 `⌘O` 添加本地项目目录。需要查看变更和提交时，选择 Git 仓库。
4. 按 `⌘N`，选择 Agent 开始会话；用顶部按钮打开文件、变更、待办或项目终端。
5. 按 `⌘K` 搜索会话、待办、历史内容和可用动作。正式发行版可通过 YCode 菜单中的「检查更新」获取后续版本。

YCode 不包含 Agent CLI、模型服务或订阅。各 Agent 的运行依赖、登录和费用由对应工具提供。

### 常用快捷键

| 快捷键 | 操作 |
|---|---|
| `⌘O` | 添加项目 |
| `⌘N` | 新建会话 |
| `⌘K` | 命令面板 |
| `⌘B` | 显示 / 隐藏项目侧栏 |
| `⌘1` / `⌘2` / `⌘3` / `⌘4` | 开关文件 / 变更 / 待办 / 终端面板 |
| `⌥⌘→` | 显示 / 隐藏面板区 |
| `⇧⌘1` — `⇧⌘4` | 聚焦对应会话窗格 |
| `⌘F` | 搜索当前终端 |
| `⌘S` | 保存编辑的文件 |
| `⇧⌘O` | 在独立窗口打开项目 |

### 当前范围

当前维护 macOS 原生版本。编辑器定位为文件查看、基础语法高亮与手动编辑保存，不提供 LSP、语义诊断或定义跳转。新建会话中的 worktree 隔离入口尚未接入；请使用普通项目会话。

旧 Tauri 版本与原生版使用不同的更新协议，首次升级需手动安装原生版。开发包使用独立的数据目录，且不启用正式更新源。

## 从源码构建

需要 macOS 14 及以上、带 Swift 6 工具链的 Xcode，以及可用的 `git`。

```sh
git clone https://github.com/melon95/YCode.git
cd YCode/macos
swift test
scripts/build_and_run.sh run
```

| 命令（在 `macos/` 下执行） | 用途 |
|---|---|
| `swift test` | 运行 Swift 测试 |
| `scripts/build_and_run.sh build` | 构建并打包 |
| `scripts/build_and_run.sh run` | 构建并启动 |
| `scripts/build_and_run.sh verify` | 构建、启动并检查进程与签名 |

产物为 `macos/dist/YCode.app`，构建日志为 `macos/dist/build.log`。开发版本号取自 `macos/VERSION`，构建编号来自 Git 提交。

默认使用本机唯一的 Apple Development 证书；没有证书时回退到 ad-hoc 签名，多个证书时需通过 `DEV_SIGNING_IDENTITY` 指定。开发签名不等于 Developer ID 分发签名或公证。更多开发说明见 [macos/README.md](macos/README.md)。

应用使用 Swift Package 管理 SwiftTerm、swift-markdown 和 Sparkle，不需要 Node 前端依赖。外部 Agent 仍需要各自的运行环境。

## 工程与文档

| 路径 | 用途 |
|---|---|
| `macos/YCodeApp/` | SwiftUI / AppKit 界面 |
| `macos/Core/` | 项目、会话、PTY、SQLite、历史、Git 与协议服务 |
| `macos/EditorSupport/` | 原生编辑与语法高亮 |
| `macos/Helpers/` | Swift CLI、MCP 和通知辅助程序 |
| `macos/Resources/` | 应用资源、图标源数据和许可证 |
| `macos/Tests/` | 单元测试与验证工具 |
| `macos/scripts/` | 构建、打包、迁移与回归脚本 |
| `docs/` | 功能说明、设计资料和迁移记录 |

- [GitHub 构建与更新发布](docs/macos-native/github-release.md)：CI、签名、公证、Releases 与 Sparkle 更新配置。
- [文件查看与手动编辑](docs/macos-native/manual-editor-scope.md)：编辑器的当前功能范围。
- [原生 UI 实施记录](docs/macos-native/ui-redesign-implementation.md)：工作台布局与交互演进。
- [旧实现清理记录](docs/macos-native/M5.5-legacy-removal.md)：Tauri / React / Rust 历史代码与备份说明。

历史迁移文档保留当时的路径与验收记录，当前功能以本 README 和现有实现为准。

## License

[MIT](LICENSE)。第三方图标来源与许可见 [IconSources](macos/Resources/IconSources/README.md)，许可证随应用一并打包。
