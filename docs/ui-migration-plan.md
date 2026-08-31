# UI 迁移计划 — 从预览稿到 React 实现

> 预览稿:`spikes/ui-redesign/index.html`
> 原则:未实现后端能力的入口一律 **disabled + tooltip 说明**,不做假数据。

## 现状与目标的差距

| 区域 | 现状 | 目标 |
|---|---|---|
| 顶栏 | 项目 tab + 搜索 + 设置 | 红绿灯留白、tab 带状态点/计数、溢出下拉、收件箱 |
| 侧边栏 | agent 图标过滤 + 历史会话扫描列表 | 计数角标、活跃会话 + 状态点 + pane 序号、实心新建按钮 |
| 中栏 | TerminalPane 多 pane + 顶栏 LayoutSwitcher 下拉 | 布局条(4 图标) + 面板开关 + 焦点环 + 内嵌空状态编辑器 |
| 右栏 | 互斥 tab(files/editor/terminal/changes/todos) | 可堆叠卡片 + 面板目录(插件式) + 绑定聚焦会话 |
| 设置 | 整屏 SettingsScreen | Dialog,4 组 12 页 |
| 缺失 | — | 项目总览屏、底部状态栏、分组命令面板 |

## 后端已有 / 缺失

**已有**:项目与会话 CRUD、PTY、布局模式、worktree(`worktree_path`/`WorktreeCloseState`)、
git diff + checkpoint review、todos + MCP、jsonl 扫描与搜索、hook 通知(`AgentTurnComplete`)、
用量、LSP、主题(10 套)、⌘K/⌘,/⌘B/⌘O/⌘1-4 快捷键。

**已有(补充发现)**:`sessionLight()` 已提供 4 态 `running`/`waiting`/`done`/`error`
(`waiting` = agent 回合结束、等你),`projectActivity()` 已做项目级汇总 —— 顶栏 tab 已在用。
预览稿的状态点与收件箱**可以真实实现**,颜色映射:

| 预览稿 | 现有 | 视觉 |
|---|---|---|
| working | running | 琥珀呼吸 |
| blocked | waiting | 红色脉冲(最需注意) |
| done | done | 绿色 |
| error | error | 红色实心 |
| idle | 无活跃会话 | 空心 |

**缺失(入口先 disabled)**:
1. 实时工具活动行(需 `PreToolUse` hook)—— 会话行的"▸ Bash …"
2. 收件箱里"agent 在问什么"的具体内容(需 transcript 提取)
3. diff 行级批注回传 agent
4. ntfy 手机推送
5. 快捷键重绑定
6. worktree 高级选项(软链目录、setup 脚本)

## 阶段与状态

### P0 基础层 ✅
- [x] `@base-ui/react` 1.0.0(与 @lobehub/ui 内嵌版本对齐,避免双拷贝)
- [x] `src/redesign.css` 令牌层:动效(`--ease`/`--t-*`)、状态色(`--st-*`,由主题色派生,10 套主题自动适配)、工具栏几何(46px 栏 / 30px 按钮 / 15px 图标)
- [x] `src/lib/sessionStatus.ts`:`SessionLight` → `working/blocked/done/error/idle` 映射 + 注意力排序
- [x] `StatusDot`、`IconButton`、`PanelCard` 基础组件
- [x] `prefers-reduced-motion` 全局降级

### P1 顶栏 ✅
- [x] 项目 tab 状态点改用统一状态系统
- [x] tab 会话计数徽章(有 blocked 时变红并显示待处理数)
- [x] **等你处理收件箱**(Base UI Popover):列出所有 `waiting` 会话,点击跳转;⇧⌘A 唤起
- [x] 布局下拉从顶栏移除(下沉到画布工具条)
- 说明:红绿灯留白不需要 —— 窗口用原生标题栏

### P2 侧边栏 ✅
- [x] agent 过滤胶囊加会话计数角标
- [x] **活跃会话区**:agent 图标 + 标题 + 面板序号徽章 + 状态点,按注意力排序
- [x] 已在画布上的会话显示琥珀色指示条

### P3 画布工具条 ✅
- [x] 侧栏折叠按钮(与 ⌘B 同步)——**仅在侧栏收起时出现**,展开时它在侧栏自己的工具条里
- [x] 5 个布局图标内联(替代原下拉),无多面板时灰显
- [x] 右侧面板开关 + 面板目录 popover

### P4 右栏堆叠卡片 ✅
- [x] store 新增 `openPanels: RightTab[]` + `togglePanelOpen`,按项目持久化
- [x] `PanelCard`:标题 + 绑定 chip + 放大(solo)+ 关闭
- [x] 面板可同时显示;关闭的卡片保持挂载隐藏(终端 PTY 与文件树扫描都不能重挂)
- [x] 面板宿主从绝对定位改为流内布局
- [x] 移除右栏重复的 tab 条(只保留打开文件的 tab)

### P5 设置 Dialog ✅
- [x] 整屏 → 浮层 dialog(900×640,背景模糊,esc/点击遮罩关闭)
- [x] 4 组 13 项导航,**全部可点** —— 不再有灰显的整页
- [x] 新增 `PanelsSettings`(面板清单)、`KeyboardSettings`(现有快捷键一览)
- [x] 顶栏项目 tab 不再出现在设置里(消除"这是项目设置吗"的误导)

### P6 其它 ✅/部分
- [x] 底部状态栏:当前项目、worktree 数、全局状态计数
- [x] 命令面板加"会话/项目/命令"三类动作,空查询即列出待处理会话
- [x] **项目总览屏**(⇧⌘P / 命令面板):卡片网格,按注意力排序(blocked → 最近活动 → 用户 tab 顺序);
  每张卡片带状态点、参与的 agent 图标、会话形态条(一段一个会话)、会话数 / worktree 数 / 仓库路径;
  打开时隐藏顶栏项目 tab —— 它是跨项目界面,顶着某个项目的 tab 会造成和旧设置页一样的语境误导

### P7 设置页全量改造(2026-08-30)

上一轮只做了 dialog 外壳,13 个页面的内容仍是旧样式 + 大量英文,其中 4 页灰显点不进去。
这一轮把内容也做完了。

**新增卡片控件层** `src/components/ui/SettingControls.tsx` —— 预览稿每页都由同一组形状拼成:
`SettingRow` / `SettingToggle` / `SettingChips` / `SettingValue` / `SettingChip` /
`SettingAction` / `SettingGroupLabel` / `SettingCard` / `SettingNote`。
`pendingReason` 是其中的关键约定:传了就灰显 + 打「待实现」+ 用原因做 tooltip,
比删掉那一行更能回答用户带着来的问题。

**后端新增 config 字段**(`ycode-config`,全部 `#[serde(default)]`,老 config.json 平滑升级):

| 字段 | 生效点 |
|---|---|
| `startup` | `App.tsx` 首次加载时选工作区还是项目总览 |
| `worktree.branch_prefix` | `service.rs` 的 `WorktreeSettings::branch_for()` |
| `worktree.isolate_by_default` | `create_project` 后按偏好置位 |
| `worktree.close_action` | 已有的 `WorktreeCloseState` 流程 |
| `checkpoints.enabled` / `keep` | `capture_session_checkpoint` 前置开关 + 新写的 `prune_for_session` |
| `session_open_mode` | store 的 `openSessionInLayout` |

`session_open_mode` 默认取 `new_pane` 而不是我最初写的 `replace_focused` ——
它是 ycode 一直以来的行为,把一个行为做成可配置不该顺手改掉所有现有安装的默认。

**页面归属重排**:
- 新建**集成**页,收纳 hook 接入 / MCP 注册 / `ycode` CLI / 深链接 —— 这四块后端早就齐了
  (`agentHookStatus`/`mcpStatus`/`cliStatus`),只是散落在通知页和「终端」页里
- 导航「终端」原本打开的是 `ycode` 命令行安装页(错配),现在指向新建的 `TerminalSettings`
- 「自动隐藏顶栏」从外观移到通用 —— 藏一根横条是窗口行为,不是外观
- 通知页瘦身,只留"要不要打断我"

**不加的东西**:界面语言(没有 i18n 框架)、空闲会话回收 / 自动归档 / 关窗保留 PTY
(各自需要独立的进程生命周期逻辑)、遥测开关(ycode 本来就不收集,数据页直接陈述事实)。
这些留在页面上灰显并写明原因。

**其余 7 页**全部改成卡片行 + 中文化:Agent 目录、外观(主题网格保留,字号改分段选择)、
通知、用量、编辑器与语言、面板、键盘快捷键、关于。删除 `CommandLineSettings.tsx`。

### P8 侧边栏两个列表合并(2026-08-30)

**问题**:侧边栏有「会话」和「历史会话」两块,用户问"不是一个东西吗"。查库发现他是对的 ——
ycode 项目 25 条会话里 0 条还在跑、18 条无标题(全渲染成 "Claude Code")、去重后只有 18 个,
最旧的 59 天前。应用一重启 PTY 全没,上面那块就退化成第二个历史列表。

**根因有两层**:

1. resume 会插一行新的 `sessions` 记录(`SessionView.id` 是窗口本地 ULID,每次 resume 滚动),
   老行留下且 title 为空 —— 一个会话最多占了 4 行
2. 空 title 的行退化显示 agent 名,于是一列全是 "Claude Code"

`Sidebar.tsx` 里原本有条注释说"去重需要 SessionStart hook";那判断是错的 ——
23/25 条已经带着 `agent_session_id`,和扫描出来的 `session_id` 直接就能 join。

**修法**:新增 `lib/sessionList.ts`,按 CLI 会话 id 合并两个数据源(这是唯一能跨 resume
存活的身份),输出一个列表,分三组渲染:

| 组 | 内容 |
|---|---|
| 等你处理 | `waiting`,红框置顶 |
| 进行中 | 有活的 PTY |
| 最近 7 天 / 更早 | 按时间,「更早」默认折叠 |

一行可以来自任一侧或两侧:DB 侧带 worktree 与面板序号,transcript 侧带标题。
标题优先级:用户改的名 → CLI 报的 thread name → transcript 首条消息 → agent 名。
点击行为对用户是一件事("打开这个会话"),内部按有无 DB 行分流到 open 或 resume。

顺带修了两处:
- 过滤胶囊的角标改为数合并后的行 —— 之前一个会话 resume 四次就被数四次(23 实为 16)
- `ycode-introspect` 的 claude 标题提取跳过 CLI 注入的前导块
  (`<local-command-caveat>` / `<command-name>` 等),它让四个不相干的会话顶着同一个标题;
  codex 那边本来就有同类处理(`extract_title_skips_agents_md_prepend`),claude 漏了

`lib/sessionList.test.ts` 10 项覆盖去重、join、标题优先级、排序与分组。

### P9 逐屏补完(2026-08-30 晚)

把预览稿的五个屏又过了一遍,补上之前只做了外壳、没做内容的地方。

**中栏 agent pane** —— `redesign.css` 里原本一条 `pane-header` 规则都没有,这块从没被改造过:

| 项 | 之前 | 现在 |
|---|---|---|
| 焦点指示 | header 左缘 2px accent 竖条 | 整个 pane 1.5px 琥珀内环 + header 淡琥珀底 |
| 面板序号 | 无 | `[1]` 徽章,与侧边栏的面板角标呼应 |
| worktree | 无样式的裸文本 | `⌥ 分支名` 描边 chip |
| 文案 | Close session / Merge / double-click to rename | 全部中文 |

焦点环换成整环而非一条边:四个 pane 并排时,"哪个接收我的键盘"要能在网格任意位置看出来,
而原来那条竖条在读终端底部时可能已经滚出视野。用琥珀而不是 accent —— 与状态点、
侧边栏的"在画布上"指示条同一套语言。

**命令面板** —— 空查询时会话占满 30 行,把「项目」「命令」两组挤到了屏幕外,等于它们不存在。
会话收敛到 8 条(输入即过滤全集,并没有变得不可达),补上预览稿的底部操作提示条与中文占位符。

**项目总览** —— 补上预览稿的筛选胶囊(全部 / 等你处理 / 进行中 / 最近)。计数为 0 时不显示数字,
「等你处理」只在真有内容时着色 —— 常亮的红色胶囊会失去"看这里"的含义。

**侧边栏新建按钮** —— 之前点了直接用过滤胶囊选中的 agent 建会话;预览稿点它是打开 agent 选择器
(`newsess-btn` → `go('new')`)。改成打开选择器,kbd 标注同步改为 ⇧⌘N。
过滤胶囊是**视图**控件,拿它当隐式启动目标意味着同一个按钮的行为取决于你几分钟前点过的某个胶囊。
⌘N 的快捷路径保留不变。

**标题提取继续**:`<local-command-stdout>` 也会被当成首条用户消息(`/model` 的回显让一批会话
titled "Set model to …"),改成 `<local-command-` 前缀匹配。更进一步,`/goal 继续完成迁移计划`
这类带参数的斜杠命令,现在从 `<command-args>` 里取用户真正写的那句话当标题 ——
跳过整条的话,得到的会是命令展开后的 prompt 模板,那对每个用过该命令的会话都是同一段。

### P10 验收比对后的补完(2026-08-31)

用 agent 对预览稿做了一轮全量逐屏验收,发现一批「预览稿有、实现没有、也没按
disabled 原则标注」的缺口,以及两处勾选项与实际行为不符。这一轮全部补上:

**承诺过但没做到的四条(验收报告的「高优先级」)**:

1. **项目总览不再隐藏整条顶栏** —— 之前 overview 打开时 `TopBar` 整个不渲染,
   搜索 / 收件箱 / 设置在该屏全部不可达。改为顶栏常驻、只藏项目 tab 条
   (`overviewActive` prop),总览屏底部也补上状态栏(`.app-overview-host` 列布局,
   总览从绝对定位改为流内填充)。
2. **变更面板真正跟随中栏焦点 pane**(P4 勾选项落实)—— 优先级:锁定 > 跟随
   `activeId`(须属于当前项目)> 回落 target picker。配套「锁定到当前会话」按钮
   (启用了一直闲置的 `PanelCard.actions`),chip 与 tooltip 如实注明来源。
3. **状态栏主仓库分支显示出来了** —— 之前无 worktree 时硬编码「主仓库」,
   `gitBranch` 从未被调用;现在切项目 / 切回主仓库时取一次 HEAD,显示
   「主仓库/分支名」,失败静默回落。
4. **顶栏项目切换下拉**(预览稿 `.ptab-more`/`.pswitch`)—— tab 条右端的折叠
   入口,列「空闲项目」(无活跃会话的项目,带分支名)+「全部项目总览 ⇧⌘P」
   「打开项目… ⌘O」两条动作。只列空闲项目:有会话的项目 tab 上已有状态点,
   重复列出会稀释「这里是被遗忘的项目」的含义。

**违反「未实现一律 disabled + tooltip」原则的缺口,全部补齐**:

- 设置页:提示音 / Dock 角标 / Shell 更改 / 终端字体 / 缩进参考线 / 界面密度 /
  搜索索引重建 / 保留策略 / 更新通道 / 自动下载,均按 `pendingReason` 约定灰显;
  「已检测到」agent 分组做成**真扫描**(`probeCommand` 探测 PATH,查到未配置的
  CLI 给「添加」按钮,查不到整组不出现);「更新日志」做成真链接;设置导航补
  搜索框(真实过滤)与「集成」项的未接入计数角标(真实数据,查询失败宁缺毋假)
- 收件箱补「刚刚完成」分组:`done` 灯 + 最近一小时,最多 5 条,压低透明度
- 变更 / 待办卡片头补文件数 / 未完成数 `count`(经 store 的 `changesFileCount`
  共享,画布工具条的 changes 开关也拿到了角标 —— 面板关闭时清 null,角标消失,
  语义是「没有可信数据」而非 0)
- 总览卡片补:分支名(`gitBranch` 并发取)、空闲摘要行(「空闲 · 上次会话 N 天前」,
  用已算出的 `lastActivityMs`)、hover 快捷新建、「＋ 打开项目…」虚线卡(仅
  「全部」筛选下显示)
- 命令面板:状态文案中文化、⌘⏎ 在新面板打开(复用 `appendSessionToLayout`)、
  「切换布局:并排两栏」命令、`@` 前缀只看会话、作用域标签;`#` 与 `>` 语义重复
  不加;「显示/隐藏会话列表」命令跳过 —— sidebarRef 在 WorkspaceCanvas 手里,
  没有现成通道,不值得为一条命令加一条事件总线
- pane header 的 `waiting` 态补文字 chip「等待中」(唯一需要用户行动的状态,
  值得一个词;其余状态保持安静的点)
- 侧边栏焦点会话补背景高亮(`.is-active`)—— 琥珀指示条回答「在不在画布上」,
  背景回答「键盘在谁那」,两件事
- composer 补底部提示行(预览稿 `.modal-foot`;「开始 ⏎」按钮不适用 —— 点
  agent 即启动,没有确认步骤)

**中文化收尾**:TopBar(删除确认 / 右键菜单 / tab tooltip)、CommandPalette、
TodoPanel、ChangesPanel、RightTerminalSplit、WorkspaceTargetPicker 的全部残留
英文;`SESSION_LIGHT_LABEL` 直接改为中文,删掉 Sidebar 里的重复中文映射。

**死代码清理**:删 `TopBar.tsx` 里从未被调用的英文 `NewSessionDialog`、
只剩测试 mock 引用的 `LayoutSwitcher.tsx`。

**验收报告中核实后不改的**:「全部面板关闭时右栏收起」其实早已实现
(`App.tsx` 订阅 `openPanels`);composer 额度条(需各 CLI 的配额数据源,无
后端支撑,不做假数据);会话行完成态摘要 / 收件箱具体问题(需 transcript
提取,已在 disabled 表);设置导航比预览稿多出的「用量」页保留 —— 它是有真实
数据的旧页面,删掉才是倒退。

## 仍为 disabled / 未实现的入口

| 入口 | 位置 | 原因 |
|---|---|---|
| 提示音 / Dock 角标 | 设置 → 通知 | 提示音播放未实现;Dock 角标需接入 macOS badge API |
| Shell 更改 / 终端字体 | 设置 → 终端 | Shell 跟随系统默认;字体跟随外观设置 |
| 缩进参考线 / 编辑器字体 | 设置 → 编辑器与语言 | CodeMirror 未接入配置;字体跟随外观 |
| 界面密度 | 设置 → 外观 | 密度令牌未接入,全局间距目前固定 |
| 搜索索引重建 / 保留策略 | 设置 → 数据与隐私 | 后端无索引重建 / 历史清理命令 |
| 更新通道 / 自动下载 | 设置 → 关于 | 更新器只有稳定版单源,且只提示不下载 |
| 额度条 | 新建会话 composer | 各 CLI 的配额数据无从获取,不做假数据 |
| 界面语言 | 设置 → 通用 | 文案全部硬编码为中文,没有接入 i18n 框架 |
| 关窗保留 PTY / 空闲回收 / 自动归档 | 设置 → 会话 | 各自需要独立的进程生命周期逻辑 |
| worktree 软链目录 / 创建后执行 | 设置 → 会话 | worktree 创建后的初始化流程未实现 |
| 需要你授权 / 运行出错 通知 | 设置 → 通知 | 前者需 `PreToolUse` hook,后者退出码还没接到通知里 |
| 免打扰(专注模式 / 节流) | 设置 → 通知 | macOS 无公开的专注模式查询接口;节流未实现 |
| 缩进 / 保存时格式化 | 设置 → 编辑器与语言 | CodeMirror 目前按文件推断,未做成配置项 |
| 清除全部本地数据 | 设置 → 数据与隐私 | 需要一个能安全停掉所有会话再删库的后端命令 |
| 浏览器面板 | 面板目录 / 设置 → 面板 | 未实现 |
| 快捷键重绑定 | 设置 → 键盘 | 只读展示当前绑定 |
| 实时工具活动行 | 会话行 | 需 `PreToolUse` hook(见 agent-hook-integration-spec) |
| 收件箱内"agent 在问什么" | 收件箱条目 | 需从 transcript 提取 |
| diff 行级批注回传 | 变更面板 | 未实现 |

每一条在界面上都灰显 + 打「待实现」+ 把上面这一列原因做成 tooltip。

## 验证
- `npm run typecheck` ✅
- `npm test` ✅ 16 文件 / 97 项
- `cargo test --workspace` ✅
- 启动应用逐屏截图核对 ✅(顶栏 / 侧边栏 / 工具条 / 堆叠卡片 / 设置 13 页 / 命令面板 / 项目总览)

## 与预览稿逐屏比对后的修正(2026-08-30)

对照 `spikes/ui-redesign/index.html` 截图核对,修了 11 处不一致:

| # | 问题 | 修法 |
|---|---|---|
| 1 | 侧边栏有 "AGENTS" 文字标题,缺 ALL 胶囊 | 去标题,加 ALL 并接上过滤 |
| 2 | 没有"等你处理"区块 | 加上,由 `waiting` 会话驱动并置顶 |
| 3 | `会话` 标题右侧显示数量(与胶囊角标重复) | 改为项目名 |
| 4 | 新建按钮在选择器可见时消失 | 常驻底部,改预览稿的实心样式 |
| 5 | 目标选择器被我放进了工具条 | 移回终端卡片的绑定位 —— 绑定标签本身就是控件 |
| 6 | 文件卡片缺绑定标签 | 补静态标签(可编辑的只留终端卡片一份) |
| 7 | 状态栏缺分支与版本号 | 补 `项目 · 主仓库/分支` 与 `v{version}`(从 package.json 注入) |
| 8 | 新建会话仍是旧的大卡片 + 英文 | 换成会话编辑器形态(无任务输入框,见下) |
| 9 | 侧边栏 agent 行 54px,与工具条 46px 不齐 | 统一到 `--toolbar-h`;徽章改用 `overflow: visible` 而非 padding 撑高 |
| 10 | 徽章被 `design-system.css` 的 `.app-workspace` 选择器裁掉 | 同前缀提高特异性覆盖,胶囊尺寸并入 30px 网格 |
| 11 | 会话列表被 40% 高度截断、按钮浮在半空 | 列表 `flex: 1` 填满,footer `margin-top: auto` 贴底 |

两处刻意偏离预览稿:

- **新建会话没有任务输入框** —— agent CLI 自己有输入框,前置一个意味着要往 PTY 注入文本:时机不可控,且丢掉 CLI 原生的 `/` 命令、`@` 引用、历史记录。这与"不替 agent 做决定"的边界一致。
- **布局图标 5 个而非 4 个** —— 多一个"上下堆叠",后端本来就支持。

一处行为变更:新建按钮常驻打破了原测试(旧行为是选择器可见时隐藏),已更新测试并在注释写明理由。

## 第二轮比对修正(2026-08-30 下午)

| # | 问题 | 修法 |
|---|---|---|
| 12 | agent 过滤条整行居中 | `design-system.css` 的 `.sidebar-header` 是 `flex-direction: column`,column 上的 `align-items:center` 是水平居中;补 `flex-direction: row` |
| 13 | 补 row 后过滤条又被甩到右边 | `styles.css` 的 `.sidebar-header` 带 `justify-content: space-between`,同样在 `.app-workspace` 作用域覆盖成 `flex-start` |
| 14 | 过滤胶囊没有边框、选中态是 accent 描边 | 按预览稿:常态 `1px solid var(--rule)`,选中用中性 `--panel-raised` + `--rule-strong`;accent 只留给计数角标 |
| 15 | 折叠按钮常驻画布工具条 | 还原预览稿:侧栏展开时按钮在**侧栏自己的工具条**首位,收起后才移交给画布工具条(抽出 `ui/SidebarToggle`) |
| 16 | 顶栏搜索入口是无框的英文文字 | 还原预览稿的 `.search-pill`:200px 描边胶囊、`--subtle` 淡色、⌘K 靠右端;900px 以下仍收成图标(需在 redesign 层重述该 media query,否则新规则会盖掉它) |
| 17 | 齿轮 hover 旋转 60°、尺寸 32px 圆形 | 与相邻的收件箱按钮统一到 30px / 8px 圆角 / 抬高背景 —— 相邻两个按钮不该用两套动效语言 |
| 18 | 顶栏残留英文 | 搜索入口、设置、打开项目、删除项目的文案与 tooltip 中文化;目录选择器标题与失败 toast 一并改 |

第 15 条推翻了上一轮"刻意偏离"的第一条 —— 当时的理由是"两处会是重复入口",但预览稿从来不同时显示两个:
控制某个面板显隐的按钮该贴着那个面板,面板没了才由邻居工具条接手。
