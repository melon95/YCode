# GitHub 构建与更新发布

## 当前流程

- `macOS CI`：分支推送、PR、手动触发，执行 Swift 测试、发布元数据测试、图标一致性检查，构建并验证 arm64 + x86_64 通用候选包，再以一次性密钥验证更新清单与篡改拒绝。产物在 Actions Artifacts；无更新配置、ad-hoc 签名，不当作正式发行版。
- `macOS Release`：推送 `vX.Y.Z` 标签或手动选择已有稳定标签。标签必须与 `macos/VERSION` 一致，高于已发布稳定版本，且不得覆盖公开 Release。
- 发布任务依次完成测试、导入临时签名钥匙串、通用架构构建、Developer ID 签名、安全时间戳、Apple 公证与装订、包级验收、生成 appcast、使用工程内公钥独立验证 Ed25519 签名，最后上传到 draft 并发布。
- 正式附件为 `YCode-X.Y.Z.zip`、`appcast.xml`、`SHA256SUMS`。Release 在附件全部上传成功前保持 draft；失败重试仅允许覆盖同标签 draft 附件。
- 发布构建号为 `100000 + github.run_number`，同一次运行重试保持一致；不要删除重建该工作流后沿用旧计数。应用显示版本来自稳定标签。
- 公钥固定在 `macos/Resources/SparklePublicKey.txt`；私钥不能提交到 Git，也不能每次发布重新生成。轮换密钥需要单独设计旧客户端迁移。

更新源：`https://github.com/melon95/YCode/releases/latest/download/appcast.xml`。清单里的 ZIP 链接固定到具体版本标签，避免“检查时一个版本、下载时另一个版本”。目前只发布完整更新，不生成差分包。每一个最新稳定 Release 都必须附带 appcast，不要把无 appcast 的旧平台包设为 latest。

## 一次性配置

仓库 Settings → Secrets and variables → Actions → Repository secrets：

| Secret | 内容 |
|---|---|
| `APPLE_CERTIFICATE_P12_BASE64` | 含私钥的 Developer ID Application `.p12` 的 Base64 编码 |
| `APPLE_CERTIFICATE_PASSWORD` | 导出该 `.p12` 时设置的非空密码 |
| `APPLE_ID` | 付费 Apple Developer 账号的 Apple ID |
| `APPLE_TEAM_ID` | 证书对应团队的 10 位 Team ID |
| `APPLE_APP_PASSWORD` | Apple 账号生成的 App 专用密码，供 notarytool 公证 |
| `SPARKLE_PRIVATE_KEY` | Sparkle `generate_keys -x` 导出的文件原文；与工程公钥匹配 |

Xcode → Settings → Accounts → 选择团队 → Manage Certificates → 创建 **Developer ID Application**。若无法创建，检查付费会员状态、团队权限，或请 Account Holder 操作。现有 Apple Development / Apple Distribution 证书不能替代。导出时必须包含私钥，仅导出 `.cer` 不够。

这些值只放 GitHub Secrets，勿贴到聊天、README 或工作流明文。GitHub runner 上使用随机密码临时钥匙串；任务无论成功失败都清理临时证书、钥匙串和 Sparkle 密钥文件。旧 `TAURI_SIGNING_PRIVATE_KEY` 不参与新流程。

本机 YCode 专用 Sparkle 密钥保存在钥匙串账户 `ycode-sparkle`。如需备份，用官方 `generate_keys --account ycode-sparkle -x <安全路径>` 导出到安全位置；私钥文件不应留在工作树。

## 发版

1. 修改 `macos/VERSION`，例如下一版 `0.7.0`，合并经过 CI 的原生代码。
2. 推送相同版本标签，例如 `v0.7.0`。仅创建标签会启动发布，不能拿测试标签试发正式版本。
3. 在 Actions 查看 `macOS Release`；成功后 GitHub Releases 出现 ZIP、appcast 与校验文件。
4. 首次原生发行版需手动安装一次。旧 Tauri 使用不同更新协议；本地开发包使用不同 bundle ID 且未启用更新，都不会自动升级到此原生发行版。
5. 在首个正式原生包中点击“检查更新”，下一次正式发版后验证提示、下载、安装、重启及数据保留。

本机正式发布（已安装 Developer ID 证书并配置公证 profile）：

```sh
VERSION=0.7.0 BUILD_NUMBER=100001 \
SIGNING_IDENTITY='Developer ID Application: Your Name (TEAMID)' \
NOTARY_PROFILE=ycode-notary bash macos/scripts/package_release.sh release

SPARKLE_PRIVATE_KEY_FILE=/secure/path/ycode-sparkle.key \
bash macos/scripts/generate_appcast.sh \
  macos/dist/release/YCode.app macos/dist/release/YCode-0.7.0.zip melon95/YCode
```

公证、签名或更新签名验证失败时禁止发布；普通 CI 可以在没有任何 Apple 凭据的情况下独立通过。
