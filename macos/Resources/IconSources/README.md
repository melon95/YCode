# 图标源数据

原生应用的 SVG 图标与文件映射保存在本目录的 JSON 中，生成脚本只需 Python 3，无需安装前端依赖。更新 JSON 后运行：

```sh
python3 macos/scripts/generate_agent_icons.py
python3 macos/scripts/generate_file_icons.py
```

- `agent-icons.json`：7 个品牌图标、320 个单色图标。应用标志来自 `docs/ui-native-redesign.html`；Agent 图标来自 `@lobehub/icons` 5.18.0，已规范化 SVG path。
- `file-icons.json`：182 个 SVG 及扩展名、文件名、文件夹名映射，来自 `material-icon-theme` 5.34.0。
- 两个上游项目均为 MIT 许可，完整许可保存在相邻的 `*-LICENSE.txt`；构建时随应用打包。

2026-09-27 从已有 Swift 图标表提取数据，并验证重新生成的 Swift 数据与提取前完全一致。
