# YCode macOS Native

应用与辅助程序均使用 Swift，工程位于本目录；`Spikes/` 保留 M0 组件验证证据。开发版本号来自 `VERSION`，无需根目录前端依赖。

```sh
cd macos
swift test
scripts/build_and_run.sh run
```

其他入口：

- `scripts/build_and_run.sh build`：构建并打包，不启动。
- `scripts/build_and_run.sh verify`：构建、启动并检查进程与签名。
- 输出应用：`dist/YCode.app`。
- 构建日志：`dist/build.log`。

开发构建默认使用钥匙串中唯一的 `Apple Development` 证书，主程序、辅助程序和 Sparkle 嵌套代码统一签名。没有开发证书时会提示并使用 ad-hoc 签名；有多个开发证书时需显式选择：

```sh
DEV_SIGNING_IDENTITY="Apple Development: Your Name (XXXXXXXXXX)" scripts/build_and_run.sh build
```

也可指定证书 SHA-1；`DEV_SIGNING_IDENTITY=-` 可显式使用 ad-hoc 签名。开发签名不代表已完成 Developer ID 分发签名或公证。

开发版使用 `dev.ycode.native.dev`，不得直接读写旧版 `~/Library/Application Support/dev.ycode.ycode`。M1.2 的迁移验证只使用一致性备份副本。

## 文档入口

- [文档索引](../docs/README.md)、[产品范围](../docs/ycode-feature-spec.md)和[验收清单](../docs/bdd-iteration-plan.md)。
- [发布指南](../docs/macos-native/github-release.md)：通用包、Developer ID、公证和 Sparkle；开发签名不能代替这些验证。
- [迁移记录](../docs/macos-native/README.md)：旧数据兼容、切换与回退证据，仅对应各自记录时的环境。

当前依赖为 SwiftTerm、swift-markdown、Sparkle、TOMLKit，准确版本见 `Package.swift` 与 `Package.resolved`。原生编辑器不再包含 LSP。
