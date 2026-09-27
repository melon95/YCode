# 会话标题实时同步（2026-09-27）

## 实现

- 监听 Claude/Codex/pi 会话目录及 Codex `session_index.jsonl`，400 ms 合并变化；已知文件按增量读取标题，新增文件再扫描发现。启动、窗口重新激活、唤醒时对账。
- Claude 读取最后一条 `custom-title.customTitle`，改名以 `O_APPEND` 追加官方 SDK 使用的元数据格式；不重写对话。
- Codex 通过本机 `codex app-server` 的 `thread/name/set` 改名，再用 `thread/read` 确认；实时读取该 CLI 更新的名称索引。不直接修改 Codex 数据库或 rollout。
- pi 新启动/恢复会话自动加载标题扩展；YCode 的请求调用运行中 pi 的 `setSessionName()`，同步内存、文件及标题事件。扩展回传原生 ID、路径、名称，CLI 自己改名也能回传。已退出会话追加 `session_info`。
- 待写回名称与已确认名称分开保存；改名串行执行，旧扫描/旧请求不能确认较新的请求。成功后解除本地覆盖，继续接受 CLI 的后续改名。
- 写回失败保留名称，侧栏显示未同步标记，菜单提供重试。无原生 ID/文件的新会话在发现元数据后重试。
- 新建 pi 通过扩展绑定原生 ID；Claude 使用创建时的 ID；Codex 优先匹配本进程持有的 rollout，hook 的原生 ID 作为补充，不按“最近会话”猜测。尚未绑定的活动 Codex 会话不会重复导入为另一条历史。
- 同一 CLI 的多个配置保留原会话所属配置；不同 CLI 的相同 ID 不混用。
- OSC 标题只作临时显示后备，不把运行状态/目录作为正式会话名写回。

## 验证

- 完整 Swift 测试：122 项通过（31 XCTest + 91 Swift Testing）；包含真实 Codex CLI 0.154.0 的隔离目录改名、读回及 rollout 不变检查。
- pi 真实 RPC 进程加载同一扩展：YCode 请求改名成功，原进程内存读到新名；再经 `set_session_name` 改名，状态文件回传，JSONL 中两个名字顺序正确。无模型请求。
- 原生隔离窗口：外部 Claude 标题记录变化约 0.77 秒落库，侧栏可见更新；通过侧栏菜单改名成功写回 `custom-title`，未同步状态清除；随后外部再改名约 0.80 秒更新侧栏和画布名称。
- `git diff --check` 通过，YCodeApp 构建通过。
- macOS 文件事件在工具沙箱内未送达；沙箱外完整测试与界面验证通过。pi 扩展对文件监听异常提供单文件轮询回退，避免监听失败导致 CLI 退出。

## 边界

- 已经运行且未加载扩展的旧 pi 会话需要重启后才能通过进程内接口改名；超时会显示未同步，不把文件写入冒充实时成功。
- Claude/Codex 的持久化名称及 YCode 显示已覆盖；另一个已经打开的 CLI 自身标题栏是否即时刷新，仍取决于 CLI 是否重新读取元数据，本轮未证明所有版本都支持。不会向用户正在编辑的输入框注入 `/rename`。
- Codex 名称索引格式已用 0.154.0 实测；后续 CLI 存储格式变化需要更新读取适配。
- `YCODE_HISTORY_HOME` 供隔离验证使用，默认仍读取当前用户的 CLI 历史。
- 本轮未安装到 `/Applications`，未提交 Git。测试日志位于 `/tmp/ycode-title-final-tests.log`。

参考：[Codex app-server](https://learn.chatgpt.com/docs/app-server)、[Claude 会话管理](https://platform.claude.com/cookbook/claude-agent-sdk-05-building-a-session-browser)。pi 依据本机安装包的公开扩展 API 与 `session-manager` / `agent-session` 实现验证。
