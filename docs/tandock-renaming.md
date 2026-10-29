# Tandock 更名说明

产品由 YCode 更名为 **Tandock**。应用名为 `Tandock.app`，介绍语为「多个 Agent，一个工作台」。

## 已统一的名称

- macOS 界面、通知、关于和更新窗口的中英文文案。
- Swift 包、模块、类型和源码目录：`TandockCore`、`TandockApp`、`TandockEditorSupport` 等。
- 命令行及辅助程序：`tandock`、`tandock-mcp`、`tandock-notify`、`tandock-migrate`。
- 深链：`tandock://activate`、`tandock://open?...`。
- 发布包：`Tandock-<版本>.zip`；本地开发产物：`macos/dist/Tandock.app`。
- README、功能与开发文档、网站文案、介绍视频和字幕资源名称。

## 为升级兼容而保留的标识

以下字符串是已有数据或外部配置的身份，保留原值，不代表产品仍使用旧名称：

| 标识 | 保留原因 |
|---|---|
| `dev.ycode.app`、`dev.ycode.native.dev` | 保持正式与开发应用的更新、设置和通知身份 |
| `dev.ycode.ycode`、`ycode.db` | 继续读取已有项目、会话、待办和设置 |
| `YCODE_*` 环境变量、CLI socket 和内部通知命名空间 | 保持已有脚本、Agent hook 和进程通信兼容 |
| `ycode-todos`、`_ycode_managed`、`ycode-managed*` | 识别原有 MCP/hook 注册，避免重复安装或误删其他配置 |
| `.ycode.bak`、`.ycode-backups`、旧窗口布局和导入键 | 继续识别已有备份和布局；新的 Agent 配置备份统一写到 `~/Library/Application Support/Tandock/config-backups/`，每个文件保留最近 5 份 |
| `ycode://` | 兼容已有深链；新链接使用 `tandock://` |

应用包内保留旧辅助程序名称作为符号链接。若升级时手动移动或重命名了应用所在路径，需要在设置中重新注册 MCP/hook；新的终端命令可在「设置 → 集成」安装为 `tandock`。

## 远端与历史材料

GitHub 仓库仍是 `melon95/YCode`；更新源继续指向该仓库。网站继续使用现有 `ycode-website` Worker 和 `ycode.agentscience.com.cn` 域名。这些是实际存在的远端资源，不能仅替换本地字符串来完成迁移。

README 与网站里的原生应用截图仍是 0.7.0 的历史界面，可能显示旧名称；程序生成的双语介绍视频使用 Tandock。原有应用图标保持不变。

本次更名更新源码与本地产物；GitHub 仓库更名、网站部署和新版发布属于后续操作。
