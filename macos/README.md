# YCode macOS Native

正式原生工程从 M1.1 起位于本目录；`Spikes/` 只保留 M0 组件验证证据。

```sh
cd macos
swift test
scripts/build_and_run.sh run
```

其他入口：

- `scripts/build_and_run.sh build`：构建并打包，不启动。
- `scripts/build_and_run.sh verify`：构建、启动并检查进程与签名。
- 输出应用：`dist/YCode Native Dev.app`。
- 构建日志：`dist/build.log`。

开发版使用 `dev.ycode.native.dev`，不得直接读写旧版 `~/Library/Application Support/dev.ycode.ycode`。M1.2 的迁移验证只使用一致性备份副本。
