# 本地自用期记录

起算日：2026-09-20（`cutover.sh adopt --local` 执行当日）
原 M5.5 冻结条件为连续日常自用满 4 周（至 **2026-10-18**）且零回退；2026-09-27 用户明确要求提前清理旧源码，已覆盖该源码保留条件。日常自用问题仍在本文件记录。

任一次 `cutover.sh rollback --local` 都会**重置计时**，并须在下表记录原因。

## 环境

| 项 | 值 |
|---|---|
| 正式应用 | `/Applications/YCode.app`，原生 0.3.4（314），bundle id `dev.ycode.app`；历次备份在 `macos/dist/backup/` |
| 数据目录 | `~/Library/Application Support/dev.ycode.ycode` |
| 回退锚点 | `~/ycode-baseline/20260920-local-selfuse/`（14 projects / 196 sessions，`integrity_check=ok`） |
| 切换快照 | `~/Library/Application Support/dev.ycode.ycode.cutover-snapshot/`（含旧版 0.6.0 与 adopt 时刻数据） |
| 旧版位置 | `…cutover-snapshot/YCode Legacy Live.app`（0.6.0），**不留在 `/Applications`**，符合单向规则 |

## 未解决问题

| 编号 | 问题 | 状态 | 处理 |
|---|---|---|---|
| L-01 | `/usr/local/bin/ycode` 为断链，指向旧版路径 `Contents/Resources/binaries/ycode-cli`；`ycode` 命令不可用 | 待用户操作 | 应用内"设置 → 集成 → 安装命令行工具"执行一次，需在系统授权框确认。修复后复核 IN.7–IN.9 |
| L-02 | **M5.2 可视走查的测试夹具泄漏进正式数据库**：两条 `项目二`（`/private/tmp/ycode-m52-visual.0m1YJj/项目二`，创建于 2026-09-20 10:50:13 与 10:50:45），并有 5 个会话挂在 `/private/tmp/%` 路径的夹具项目下 | 待确认清理 | 与 M5.4 记录的 09-18 `YCODE_DATA_ROOT` 误用是**两次独立事件**：本次发生在 09-20 上午，说明 V01 走查中至少有一次操作未真正隔离数据根。清理前需确认这 5 个会话不含真实历史 |
| L-03 | 同一路径可被重复添加为多个项目：两条 `internal-frontend` 均指向 `/Users/melon/work/lessen/internal-frontend`，分别创建于 2026-07-29 09:31 与 2026-08-07 16:27 | 观察中 | 属旧版即存在的行为（两次添加都早于原生版切换），非迁移引入。需确认是产品有意允许还是缺少去重校验；若判定为缺陷，按 PR.1 补验收场景 |
| L-04 | 项目总览把内部里程碑编号暴露到用户界面：File Tree Width 一行显示 `180 px (active since M4.1)` | 待修 | "M4.1" 是迁移计划的步骤编号，不应出现在正式界面。菜单栏的 `Migration` 菜单是否应在正式包中呈现，一并确认 |

## 日常记录

每次遇到问题追加一行。没有问题的日子不必记，但回退必须记。

| 日期 | 现象 | 影响 | 处理 / 是否回退 |
|---|---|---|---|
| 2026-09-20 | 切换当日，见上方 L-01 | `ycode` 命令不可用，不影响 GUI 使用 | 未回退 |
| 2026-09-21 | 原生包没有应用图标（Dock／访达都是系统占位图）；项目右键菜单没有「移除项目」入口 | 图标是观感问题；移除项目只能改数据库 | 两处都已修，重打 0.3.1（build 311）装进 /Applications，0.3.0 备份在 `macos/dist/backup/YCode-0.3.0.app`。未回退 |
| 2026-09-21 | 文件树每秒全量重扫一遍项目目录：本仓库剪掉 `.git`/`node_modules`/`target` 后仍有 4.3 万条，单次 walk 实测约 700 ms | 文件卡开着就等于常驻一个后台线程在走 inode，还把 43k 条数组每秒推给 SwiftUI | 改成按展开懒加载（`listChildren` 只列一层）+ FSEvents（`YCodeDirectoryWatcher`）驱动刷新，轮询整段删除；跳过名单缩到只剩 `.git`。重打 0.3.2（build 312） |
| 2026-09-21 | 待办复选框点不动（空心方框只有 1.5 pt 描边可命中）；副行相对时间每秒跳一次 | 勾不上却能取消已完成，读起来像逻辑错乱 | 补 `contentShape` 并放大命中区到 20×20，点击改三态循环；相对时间粒度降到分钟（一分钟内「刚刚」）。同在 0.3.2 |
| 2026-09-21 | 设置里「会话」「通用」两页全是点不动或名不副实的控件（XX.1–XX.3 三个禁用开关；「恢复最近工作区」恢复不了任何东西） | 用户被教着忽略整页设置 | 两页整页删除，`YCodeStartupMode` 连同 `initialProjectID(mode:)` 一起从 Core 移除，启动恒定为「有最近项目就进它」。0.3.3（build 313） |
| 2026-09-22 | 侧栏两套身份：同一条对话活着时是「会话」、退出后变成「历史会话」，两处各列一遍；过滤 chip 挤在列表上方占一整行；会话只能归档不能删 | 用户要在两个列表之间找同一条对话；归档实为「永久堆积」，jsonl 无法清理 | jsonl 历史在启动时一次性导入为会话（>14 天直接落归档档位，标题跟随 jsonl 刷新，用户改过名的不覆盖），侧栏「历史会话」整节删除；chip 换成顶栏漏斗菜单（状态 活跃/已归档/全部 · 排序 · 显示空项目）；新增删除会话（jsonl 一并移入废纸篓）；无标题的空壳会话默认不列；画布顶栏不再重复聚焦会话名。0.3.4（build 314），0.3.3 备份在 `macos/dist/backup/YCode-0.3.3.app`，装前数据锚点 `~/ycode-baseline/20260922-180052-pre-0.3.4/`（14 projects / 196 sessions，`integrity_check=ok`）。首启导入后 331 sessions（122 活跃 / 209 归档）。未回退 |
| 2026-09-21 | 归档是单向的：归档后会话在界面上再也找不回来，只能改 SQLite | 「归档」实为「永久隐藏」，名不副实 | 加 `unarchiveSession`（Core + 侧栏「已归档」过滤 chip + 右键取消归档）。Codex 有自己的 `codex archive/unarchive`，归档时后台同步一次（不阻塞）；Claude Code 没有归档概念，状态仍以 ycode 的 `archived_at` 为准。0.3.3（build 313） |

## 观察重点

本地自用期要盯的是 M5.2 未能覆盖的长尾——短时探针和两小时长测都证明不了的那些：

1. **跨天运行的资源趋势**：长测只有 2 小时，日常使用是连续多天。留意 physical footprint 是否随天数单调上升。
2. **真实项目规模下的编辑器**：M5.2 的大文件回归只测了 705 KB 的 `package-lock.json` 与 1.1 MB 夹具文件。
3. **真实 Agent 长会话**：探针用的是可控 shim，日常是真实 Claude/Codex 的长上下文会话。
4. **历史数据持续增长**：P4 阈值基于 S-large 当时的规模，JSONL 每天都在增加。搜索变慢时按 M0.2 口径复测，不要凭感觉调阈值。
5. **多窗口 + 多项目并发**：V06/V07 是逐项走查，不是长时间并发使用。
