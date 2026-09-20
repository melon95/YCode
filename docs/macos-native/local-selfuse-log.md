# 本地自用期记录

起算日：2026-09-20（`cutover.sh adopt --local` 执行当日）
解除 M5.5 冻结的条件：连续日常自用满 4 周（至 **2026-10-18**）且期间零回退。

任一次 `cutover.sh rollback --local` 都会**重置计时**，并须在下表记录原因。

## 环境

| 项 | 值 |
|---|---|
| 正式应用 | `/Applications/YCode.app`，原生 0.2.3（203），bundle id `dev.ycode.app` |
| 数据目录 | `~/Library/Application Support/dev.ycode.ycode` |
| 回退锚点 | `~/ycode-baseline/20260920-local-selfuse/`（14 projects / 196 sessions，`integrity_check=ok`） |
| 切换快照 | `~/Library/Application Support/dev.ycode.ycode.cutover-snapshot/`（含旧版 0.6.0 与 adopt 时刻数据） |
| 旧版位置 | `…cutover-snapshot/YCode Legacy Live.app`（0.6.0），**不留在 `/Applications`**，符合单向规则 |

## 未解决问题

| 编号 | 问题 | 状态 | 处理 |
|---|---|---|---|
| L-01 | `/usr/local/bin/ycode` 为断链，指向旧版路径 `Contents/Resources/binaries/ycode-cli`；`ycode` 命令不可用 | 待用户操作 | 应用内"设置 → 集成 → 安装命令行工具"执行一次，需在系统授权框确认。修复后复核 IN.7–IN.9 |

## 日常记录

每次遇到问题追加一行。没有问题的日子不必记，但回退必须记。

| 日期 | 现象 | 影响 | 处理 / 是否回退 |
|---|---|---|---|
| 2026-09-20 | 切换当日，见上方 L-01 | `ycode` 命令不可用，不影响 GUI 使用 | 未回退 |

## 观察重点

本地自用期要盯的是 M5.2 未能覆盖的长尾——短时探针和两小时长测都证明不了的那些：

1. **跨天运行的资源趋势**：长测只有 2 小时，日常使用是连续多天。留意 physical footprint 是否随天数单调上升。
2. **真实项目规模下的编辑器**：M5.2 的大文件回归只测了 705 KB 的 `package-lock.json` 与 1.1 MB 夹具文件。
3. **真实 Agent 长会话**：探针用的是可控 shim，日常是真实 Claude/Codex 的长上下文会话。
4. **历史数据持续增长**：P4 阈值基于 S-large 当时的规模，JSONL 每天都在增加。搜索变慢时按 M0.2 口径复测，不要凭感觉调阈值。
5. **多窗口 + 多项目并发**：V06/V07 是逐项走查，不是长时间并发使用。
