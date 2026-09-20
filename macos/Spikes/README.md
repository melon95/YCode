# M0.3 原生终端验证程序

SwiftTerm 1.20.0 + 原生 PTY 的隔离验证程序，不是正式 YCode 应用。

```sh
swift test
./script/build_and_run.sh --headless
./script/build_and_run.sh --soak 600
./script/build_and_run.sh --verify
```

带窗口模式默认启动登录 shell；也可把真实 CLI 及参数放在命令末尾：

```sh
./script/build_and_run.sh run codex
./script/build_and_run.sh run claude
```

可见验收：

1. 按 `⌘4` 打印 ANSI、中文、Emoji、链接和 OSC 标题样本。
2. 用中文输入法输入并回车；复制输出后用 `⌘V` 粘贴。
3. 启动 `vim` 等全屏 TUI，检查绘制、方向键和退出。
4. 运行 `sleep 60` 后按 `⌃C`，确认提示符恢复。
5. 按 `⌘2` 执行 20 次视图销毁/重建，确认状态栏 PID 不变且旧输出可见。
6. 按 `⌘5` 把当前窗口内容保存为 `/tmp/ycode-m03-terminal-NN.png`。
