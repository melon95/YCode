# Tandock macOS Native

应用与辅助程序均使用 Swift，工程位于本目录；`Spikes/` 保留 M0 组件验证证据。开发版本号来自 `VERSION`，无需根目录前端依赖。

```sh
cd macos
swift test
scripts/build_and_run.sh run
```

其他入口：

- `scripts/build_and_run.sh build`：构建并打包，不启动。
- `scripts/build_and_run.sh verify`：构建、启动并检查进程与签名。
- 输出应用：`dist/Tandock.app`。
- 构建日志：`dist/build.log`。

开发构建默认使用钥匙串中唯一的 `Apple Development` 证书，主程序、辅助程序和 Sparkle 嵌套代码统一签名。没有开发证书时会提示并使用 ad-hoc 签名；有多个开发证书时需显式选择：

```sh
DEV_SIGNING_IDENTITY="Apple Development: Your Name (XXXXXXXXXX)" scripts/build_and_run.sh build
```

也可指定证书 SHA-1；`DEV_SIGNING_IDENTITY=-` 可显式使用 ad-hoc 签名。开发签名不代表已完成 Developer ID 分发签名或公证。

开发版使用 `dev.ycode.native.dev`，不得直接读写旧版 `~/Library/Application Support/dev.ycode.ycode`。M1.2 的迁移验证只使用一致性备份副本。

## 会话启动耗时日志

新建、导入历史和恢复会话会自动记录分段耗时。运行包含日志改动的新构建后，日志位于当前数据目录的 `logs/session-startup.log`：

- 默认开发版：`~/Library/Application Support/dev.ycode.native.dev/logs/session-startup.log`。
- 默认发布版：`~/Library/Application Support/dev.ycode.ycode/logs/session-startup.log`。
- 指定 `--data-root` 时使用该目录。文件到 2 MiB 后轮转为 `.log.1`，只保留一份备份。
- 同时写入系统日志，subsystem 为 `dev.tandock`，category 为 `session-startup`。

启动不再每次跑登录 shell。Tandock 启动时在后台用 `$SHELL -l -i -c` 解析一次 rc 之后的环境变量，以及 rc 设置的 `ulimit -n`/`umask`，按项目目录缓存在内存里。新建、历史导入和恢复会话会用快照里的 PATH 找到 agent 的绝对路径，直接 spawn；如果 rc 设置了 `ulimit -n`/`umask`，则先经不读 rc 的 `/bin/sh` 补上这两项再 exec。某个项目还没有自己的快照时，最多等 0.5 秒它解析完，等不到就先用 home 目录的快照。每次启动后都会在后台刷新快照（同一目录 30 秒内只刷新一次），所以改了 rc 后，要等这次刷新完成之后的启动才生效。快照里找不到命令时，会强制重新解析一次再判断；重新解析也失败，就交给旧的登录 shell 路径判断。从没成功解析过（超时 10 秒、失败，或 shell 不在 zsh/bash/sh/dash/ksh/fish/tcsh/csh 之列）时，退回旧的 `$SHELL -l -i -c 'exec …'` 路径；已有旧快照时继续用旧快照。解析期间会设置 `TANDOCK_RESOLVING_ENVIRONMENT=1`，rc 里可以据此跳过 tmux 自动 attach 之类的逻辑；超时后会连同 rc 拉起的子进程整组结束。

检查点（initial 和每轮）在每个仓库自己的后台串行队列里生成，initial 优先级更高，不再阻塞主线程和启动；未安装 Xcode 命令行工具时直接跳过，不会弹安装对话框。停止/归档会取消待启动请求，多窗口恢复同一会话会合并请求。

按 `run` 关联同一次启动；`elapsed_ms` 是从服务入口开始的单调时钟累计耗时，两个事件相减就是中间等待时间。`checkpoint.end/failed` 在后台完成时记录，带 `duration_ms`；失败带 `reason`（只有错误类型，不含路径）。

主要事件：`metadata.persisted/loaded`、`checkpoint.queued/end/failed`、`shell_env.hit scope=project|home age_s=`、`shell_env.resolve scope=project waited_for_project=true`、`shell_env.miss`、`shell_env.resolve`、`shell_env.fallback reason=`、`shell_env.retry_after_missing`、`exec.direct`（补 ulimit/umask 时为 `exec.direct process_attributes=applied`）、`probe.begin/end`（仅回退路径）、`proxy.begin/end`、`runtime_init.begin/end`、`pty_start.begin/end`、`first_view.attached`、`first_output.consumed`、`first_output.fed_to_view`。新建会话还记录 `ui_reload` 和 `canvas.requested`；恢复的 `pool_restart` 包括等待旧进程停止的时间。

新增阶段用于定位进程启动后的等待：

- `shell.ready_before_exec_observed`：登录/交互 shell 已执行完启动脚本，即将执行 `exec Agent`。shell 内建命令写入临时标记，由后台队列观察；不额外启动进程、不往 PTY 写标记。时间包含文件通知调度延迟，不等于子进程的精确时间戳，也不保证 exec 成功。只在回退到登录 shell 路径时出现，且仅用于 sh/bash/zsh/dash/ksh；直接 spawn 或其他 shell 记录 `shell.marker_skipped`。
- `first_output.delegate_received` → `first_output.consumed`：输出进入 Tandock 后等待合并处理的时间。SwiftTerm 的回调本身已在主线程上，所以这不是内核首次读到字节的时间。
- `first_screen_text.detected`：终端解析后首次出现非空白文字，纯 OSC/CSI 控制序列不算；不记录文字内容。文字仍可能来自 shell 提示或错误，不等于 Agent 就绪。
- `output.volume`：累计输出达到 128、1024、4096、65536 字节的时间点，帮助识别很早出现控制序列、稍后才出现大量内容的情况。
- `main_queue.lag` / `main_queue.summary`：启动后最多 30 秒，每 250 毫秒采样主线程响应；超过 100 毫秒单独记录。汇总包含已完成采样的 `max_delay_ms` 和尚未响应的 `pending_ms`，主线程卡住时最多只排队一个采样。进程退出时提前结束，临时标记自动清理。

`pty_start.end` 到 shell 标记主要反映 shell 初始化；标记到首次文字之间结合主线程延迟判断：主线程响应正常而文字迟迟未到，更指向 Agent/CLI 启动；如果 `pending_ms` 或 `max_delay_ms` 很大，则主线程调度也参与了等待。采样不能替代逐字节的 PTY 读事件测量。`fed_to_view` 仅表示已送入视图，不代表画面已渲染。日志不记录对话、终端输出正文、命令参数、环境变量值或项目路径，写文件在后台执行。

## 文档入口

- [文档索引](../docs/README.md)、[产品范围](../docs/tandock-feature-spec.md)和[验收清单](../docs/bdd-iteration-plan.md)。
- [发布指南](../docs/macos-native/github-release.md)：通用包、Developer ID、公证和 Sparkle；开发签名不能代替这些验证。
- [迁移记录](../docs/macos-native/README.md)：旧数据兼容、切换与回退证据，仅对应各自记录时的环境。

当前依赖为 SwiftTerm、swift-markdown、Sparkle、TOMLKit，准确版本见 `Package.swift` 与 `Package.resolved`。原生编辑器不再包含 LSP。

需关注面板验证：`swift test --build-system native --disable-sandbox`。当前 Xcode 若缺少可选 Metal 工具链，可用 `YCODE_SWIFT_BUILD_SYSTEM=native scripts/build_and_run.sh build` 构建，验证记录见 [实施记录](../docs/attention-panel-validation.md)。
