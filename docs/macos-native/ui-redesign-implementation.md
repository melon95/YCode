# 原生 UI 升级实施记录

设计稿：`docs/ui-native-redesign.html`（09 节「控件去向对照」与「实施顺序建议」是验收清单）
实施日期：2026-09-20 · 分支 `feat/macos-native`

全部改动都在 `macos/YCodeApp`，没有动 `YCodeCore`、没有改数据模型，与后续 pi 形态迁移不冲突。

## 按稿子的八步

| 步骤 | 状态 | 落点 |
| --- | --- | --- |
| 1 · 侧栏合一 | 完成 | 新增 `WorkspaceSidebarView.swift`；`NavigationSplitView` 三列改两列，项目是可折叠组标题，会话是组里的行，宽 238（200–320） |
| 2 · 清空详情页 | 完成 | `YCodeNativeApp.projectDetail` 只剩 `TerminalWorkspaceView` + `StatusBarView`，标题行/PID/会话 ID/四个按钮全部移出 |
| 3 · 工具栏瘦身 | 完成 | 七按钮 → 布局分段控件、⌘K、检查器开关（收件箱后来按要求去掉）；项目管理进侧栏右键菜单 |
| 4 · 状态 token | 完成 | 新增 `YCodeDesignSystem.swift`：`YCodeSessionPresence`（运行中／等你／未在运行）+ `YCodeStatusDot`，侧栏行、窗格头、收件箱三处复用 |
| 5 · 检查器 | 完成 | 右侧固定 302（260–460），tab 互斥，⌘1–4 切换、⌥⌘→ 收起；`selectInspectorTab` 保证一次只开一个 |
| 5b · 历史归位 | 完成 | 历史改挂侧栏各项目组下的折叠区，点一条即 resume；`HistoryPanelView.swift` 删除 |
| 5c · 新建会话 | 完成 | 删 `NewAgentSessionView` sheet，新增 `NewSessionPickerView.swift`：agent 横排、title 传空串（名字来自 CLI）、底部一行 worktree + 分支；⌘N、空会话、空窗格是同一个组件 |
| 6 · 状态栏 | 做了又按要求撤掉 | 先做了 26 px 的 `StatusBarView`（分支、改动数、会话计数、PID、终端字号、agent），实际用下来每一格都能在别处找到：会话数在侧栏组标题与过滤 chip 上、终端字号在设置 › 外观、PID 与 agent 在会话信息（⌘I）、分支在变更面板头部。整条删除，设计稿 §03 标注 7 就此落空 |
| 7 · 字阶复原 | 完成 | 根视图 `.font(.system(size:))` 换成 `.dynamicTypeSize`，设置 › 外观改三档（紧凑／标准／宽松，写回 13/14/16） |
| 8 · 空状态 | 完成 | 无项目、无变更、无待办、历史为空、搜索无结果按 §07 文案基准重写；「项目无会话」「画布无会话」换成 agent 选择器 |

文件树图标换成 material-icon-theme：跟非原生版 `src/lib/fileIcons.ts` 同一套主题，同一个项目在两边看起来一样。`macos/scripts/generate_file_icons.py` 从 `macos/Resources/IconSources/file-icons.json` 读取已提取的子集（182 个图标，122 KB）并生成 `YCodeFileIcons.swift`；2026-09-27 清理旧前端后不再依赖 `node_modules`，认不出的类型回退主题自带的默认 file / folder。整套 1238 个图标有 5 MB，不值得全量进仓库。

lock 文件的语法高亮：`bun.lock` / `Cargo.lock` 这类没有可识别的扩展名，`YCodeSyntaxRegistry.language(forPath:)` 直接返回 nil，所以编辑器一个 token 都没有。给 json / toml / yaml 三组补了 `filenames` 映射（bun.lock、deno.lock、flake.lock、composer.lock、Cargo.lock、poetry.lock、uv.lock、pnpm-lock.yaml 等），已有的 registryMapping 测试会覆盖它们。

agent 图标：来自 `@lobehub/icons`（与 `src/components/AgentIcon.tsx` 同源）。认识的品牌取**彩色的裸 glyph** —— Claude 用 `Color`，Codex 用 `Inner`（`Color` 那版自带渐变底板，跟 Claude 的裸 glyph 并排会一个有底色一个没有，底板在侧栏 13px 下也会糊成色斑），Gemini 取 `Gemini/Color`；其余 agent 用 `Mono` 单色兜底，跟随前景色。设计稿只取 `ic-ycode`（新建会话卡片顶部的应用标志）。图标组件的 path 与 defs 渐变已规范化为 SVG，保存在 `macos/Resources/IconSources/agent-icons.json`；`macos/scripts/generate_agent_icons.py` 从该本地数据生成 `YCodeAgentIcons.swift`，`YCodeAgentIconView` 交给 NSImage 解码。两个坑：SVGO 压缩过的 arc flag（`a6.1 6.1 0 013.0-.4`）CoreSVG 解析不了，要展开成带空格的形式；`fill-rule` 写在 `<svg>` 上不被继承，要落到每个 `<path>` 上 —— 否则图标会糊成一团。侧栏会话行、窗格头、新建会话选择器、设置 › Agent 四处共用。

新建会话卡片里 agent 的命令名（`claude` / `codex`）按要求去掉了，只留显示名。

变更面板：先在设计稿里补了一节 **§03b 变更面板**（三种状态 + 5 条决策），再照它实现 —— 一列到底的内联 diff（文件头 + 每块 hunk，hunk 头上带「暂存」），头部一行（摘要 + 「全部暂存」+ ⋯ 菜单，分支/Fetch/Pull/Push/刷新/检查点都在菜单里），底部一条常驻提交条（输入框 + 「提交 N 个文件」）。去掉了「变更／检查点」分段控件（检查器 tab 之下不该再来一层）和底部并排的四个按钮（暂存/丢弃改成挂在文件行上，作用对象才清楚）。左右分栏也去掉了：302 px 放不下 `minWidth 210 + 260`，diff 的文字会被列表盖掉。逐块暂存由 `YCodeUnifiedDiff` 切出 `fileHeader + hunk` 拼成补丁走 `git apply --cached`。

待办面板：同样先补了设计稿 **§03c 待办面板**（有待办／行菜单／空 三种状态 + 5 条决策），再实现 —— 删掉顶部三个巨型计数（分组标题自己带计数，头部只留「N 项未完成」+ ⋯ 菜单），输入行收成 28 px（＋ 与 ↵ 是提示不是按钮，回车即存），行右侧只在 hover 时出一个 ⋯（状态胶囊与上下箭头去掉，状态由所在分组表达，排序走菜单里的上移／下移），已完成默认折叠。副行从「添加于 17 秒前」改成「进行中 · 2 分钟前」「已完成 · 昨天」，队列里的条目不写副行。设计稿里副行是「agent 标为进行中」这类「谁动的」，但 `YCodeTodo` 没有 actor 字段，动它要改 Core，所以先只写状态与时间。

主题收敛成三档：浅色 / 深色 / 跟随系统。原来的 10 套配色（foundry、midnight、forest…）删掉，只留设计稿 §02 那两套 token；`YCodeThemeCatalog.resolve(id:prefersDark:)` 负责解析，旧配置里的主题 id 一律回落到跟随系统。顺带修掉一条黑边：根视图原先铺 `Color(hex: theme.background)`，而 foundry 的背景是深色、`systemColorScheme` 又是 nil（跟随系统），于是浅色外观下整套 UI 是浅的、窗口底色是黑的，从检查器左缘的缝隙里露出来一条。窗口底色改回 `windowBackgroundColor`。

检查器的 tab 条挂在系统给检查器预留的那条工具栏区里（`.toolbar` 声明在 inspector 的内容上），所以它和左边的工具栏按钮在同一水平线上，顶部不留空条。踩过两个坑：用 `ignoresSafeArea` 把自绘的 tab 条顶进那块区域，点击会被窗口 titlebar 接走；徽标带胶囊底会把工具栏 item 挤成「…」，改成纯数字加 `fixedSize()`。

检查器交给系统的 `.inspector`（macOS 14）：开合动画、分隔条拖拽、宽度约束都由 AppKit 管，和左边 `NavigationSplitView` 侧栏是同一套行为，自绘的分隔条与拖拽代码因此删掉（`NavigationSplitView` 本身最多三列、第三列语义是 detail，撑不起右侧这一栏）。`WorkspaceInspectorView` 只管 tab 条与四个面板，初始宽度沿用迁移过来的 `fileTreeWidth`。

未跟踪文件能预览了：`git diff` 对未跟踪文件没有输出，所以 `YCodeGitService.diffUntracked` 走 `--no-index` 跟 `/dev/null` 比一次（它发现差异时退出码是 1，要当正常结果收下），未跟踪的整个目录（git status 报成 `foo/`）则列出 `ls-files --others` 的清单。

侧栏点一行会话是并排开一格（`.newPane`）：已经在画布上就聚焦过去，还有空位就并排，满 4 格才替换当前焦点格 —— 并排是 ycode 的核心差异，点第二个会话不该盖掉第一个。

点一行会话就接着跑：会话永远可以 resume，所以侧栏点一行（以及收件箱点一条）会话没在跑时直接 `restartSession`，不再先给一屏「这个会话没在跑」让人再点一次。`resumingSessionIDs` 防重复启动，窗格在这期间显示「正在接着跑…」；那一屏只剩下 resume 失败或 agent 自己退出后才会出现。

变更列表的一行回到旧版形式：状态标 + **文件名** + 灰色目录 + `+2 −0` 计数，hover 时计数让位给「暂存／丢弃」（设计稿 §03b 的 `.fhd:hover .ct{display:none}`，也是非原生版 `ChangesPanel.tsx` 一直以来的样子）。我原先铺的是完整路径加常驻按钮，扫一列文件时读不出重点。计数需要 `git diff --numstat HEAD`，为此给 `YCodeGitService` 加了 `lineStats`（Core 的第二处只读改动）。

画布是格位模型：`CanvasPane` 要么是一个会话，要么是 agent 选择器。⌘N 只是在画布上多占一格（满 4 格时占用焦点格），其它会话照常在跑，不会被盖住；画布本来就空时整块就是选择器。

设置窗按 macOS 惯例收拾了一遍：页名只在窗口标题栏上（内容区不再重复一个大标题）、去掉侧栏折叠按钮、跟随 app 的深浅色与强调色，底部的「保存／取消」整条去掉 —— macOS 的设置是即时生效的，现在改完就写盘、主窗口立刻跟上（`hasChanges` / `cancel()` 随之删除），「恢复默认」移到「关于与诊断」页底部。

收件箱按要求去掉了（先简化功能）：`AttentionInboxView.swift`、工具栏按钮、菜单栏「关注」与 ⇧⌘A 全部移除。**hook 事件本身保留** —— 「等你」这个状态还要喂侧栏的状态点、过滤 chip 与状态栏计数，系统通知也照常发；只是不再有一个跨项目的收件箱界面。设计稿 §05 标注 1 的那块因此暂时落空。

另外实现的：⌘K 命令面板（`CommandPaletteView.swift`，会话／待办／历史全文／动作四组）、会话信息浮层（`SessionInfoView.swift`，⌘I）、菜单栏 `Migration` 菜单删除（⇧⌘I 的构建信息并入设置 › 关于与诊断）、设置页按用户心智分组（通用／Agent／系统）并新增诊断段（数据目录、文件树宽度、架构、最近一次错误、［复制诊断信息］）。

## 与稿子的差异

| 项 | 差异 | 原因 |
| --- | --- | --- |
| 检查器 tab 数 | 四个（文件／变更／待办／终端），稿子是三个 | 现在的 `.terminal` 面板挂的是项目 shell 工作区（可分屏的普通 shell，不是 agent 会话），去掉入口等于下线功能；保留为第四个 tab |
| 项目右键菜单「重命名…」 | 未做 | `ProjectWorkspaceRepository` 没有 rename，做它要动 Core |
| 会话右键菜单「删除…」 | 只有「归档」 | Core 只有 `archiveSession`，归档后会话进历史区，可重新打开 |
| 新建会话的 worktree 开关 | 渲染了，勾选后提示「原生版还没接入」 | `YCodeAgentSessionService` 对隔离项目直接抛错，worktree 是后续里程碑 |
| 设置 › 权限与信任 | 未做 | 没有对应的数据与实现 |
| 设置 › 外观的「侧栏显示所属 agent」「启动恢复布局」 | 未做 | 需要新的持久化字段，会动 Core 的 settings 模型 |
| ⌘K 的「打开文件 ›」动作 | 未做 | 需要跨项目文件索引，属于新功能 |

## 2026-09-21 补漏

**项目右键菜单缺「移除项目…」**：工具栏瘦身时项目管理动作搬进右键菜单，只搬了新窗口／访达／终端／新建会话／折叠／上移下移，删项目的入口漏了 —— `WorkspaceModel.deleteSelectedProject()` 和 `YCodeNativeApp` 里的确认框一直都在，就是没有地方能触发。菜单末尾补一条 destructive 的「移除项目…」（`onRemoveProject` 回调 → `pendingDelete` → 原有确认框），和上移／下移一样在独立项目窗口里禁用（那个窗口锁在这个项目上，删掉会让窗口悬空）。

**应用图标**：`macos/Resources/YCodeApp-Info.plist` 没有 `CFBundleIconFile`，两个打包脚本也没往 bundle 里拷图标，所以原生包一直是系统默认的白色占位图。沿用非原生版 Tauri 那套 logo（`src-tauri/icons/icon.icns`，10 个尺寸齐全），复制成 `macos/Resources/AppIcon.icns`（矢量源 `AppIcon.svg` 一并留着），plist 补 `CFBundleIconFile` / `CFBundleIconName`，`build_and_run.sh` 与 `package_release.sh` 各加一行拷贝。注意 Launch Services 会缓存旧的通用图标，换过之后要 `lsregister -f <app>` 才看得到新图标。

## 验证

- `swift build`：通过
- `swift test`：81 个测试、18 个套件全部通过
- `macos/scripts/build_and_run.sh`：实机启动，侧栏／检查器／状态栏／agent 选择器渲染正常

**顶栏那条空带与面板区的浮动卡片**：三处一起改。

1. `.ignoresSafeArea(.container, edges: .top)` 原先挂在 `NavigationSplitView` 上 —— 这层修饰不传进两列里，于是侧栏和 detail 各自仍带着一条标题栏高度（28）的安全区：画布顶栏被压到 44+28，而 `.background(Color)` 会自己渗进安全区，所以那 28 看上去是顶栏的一部分，实际是一条什么都放不下的空带。改成分别挂在侧栏内容和 detail 的 `HStack` 上。
2. 面板区原先是「chrome 底 + 8 的内边距 + 圆角 10 的浮动卡」，四周因此各留一道灰槽，卡头也就没法跟画布顶栏对齐。按设计稿 §07 的稿面改成齐边的分段：卡铺满整列，卡与卡、列与列之间只有一条分隔线，`panelAreaWidth` 不再加那 8。**每列第一张卡的卡头高度取 44**（其余仍是 30），于是顶栏下面那条横线横穿画布与面板区、中间不断档 —— 这正是 §04 要的「全窗顶上只有这一条横向元素」。
3. 顶栏控件统一成一套：新增 `YCodeIconButtonStyle`（26×24 圆角命中区，hover 浮一层底、开着时上强调色底）。四个面板开关原先是 `.toggleStyle(.button)`，系统给每个图标套一个带描边的胶囊，四块厚砖挨着站，跟旁边 `.plain` 的侧栏／⌘K 图标不是一套语言；布局分段控件改 `.controlSize(.small)`，开关组内间距收到 2，组与组之间才留 6。卡头的 ✕ 也换成同一套（20×20）。

齐边之后补的三处：**卡与卡之间恢复 5 px 隔条**（设计稿 §07 的 `.grip`）—— 只留一条 1 px 的线时，上一张卡的最后一行看起来像直接续在下一张的卡头上；5 px 既有「距离」又不破坏列首卡头与画布顶栏的那条通栏线。**整列折叠时卡头会浮在列正中**：折叠后每张卡都是固定高度，`VStack` 在一列 `.infinity` 的空间里把它们垂直居中了，上下各一片空白。改成「全折叠时垫一个 `Spacer(minLength: 0)`」（有卡展开时不垫，否则 Spacer 会跟展开的卡平分高度）；同时把面板列的底色从白换成 chrome，收起来之后露出的那片空白属于「这儿没东西」，跟卡里的内容区（白）不是一回事。
**列与列之间也换成同一根 5 px 隔条**（原先是 1 px `Divider`）：两列各自装着一屏内容，一条发丝线隔不开，左列的 `+98 −1` 和右列的正文会连成一片；`panelAreaWidth` 相应按 `panelGrip × (列数 − 1)` 算。画布与面板区之间那条仍是 1 px —— 它是可拖的分隔条，跟侧栏那条同一套。

**侧栏顶栏也归到 44**：红绿灯原先靠 `.padding(.top, 38)` 让位 —— 那一行右边一整条空着没用上，而且 38 ≠ 44，左栏的第一条横线比画布、面板区高出 6。改成侧栏自己画一条 44 的顶栏（左边留 `trafficLightWidth` 70 给红绿灯），**搜索框搬进那一行**，过滤 chip 上移一行，顶栏底下补一条 `Divider` —— 于是那条横线横穿三栏。`trafficLightInset: 38` 随之换成 `trafficLightWidth: 70`。

**面板卡的折叠去掉了**：卡头不再有 chevron，点卡头不再折叠，右键菜单里的「折叠／展开」和 `collapsedPanels` 状态一并删除（`collapsePanel` / `expandPanel` 两条文案也删了）。理由是收起来的卡只剩一条占着高度的卡头，既没省出空间也没少一次点击 —— 要腾地方直接 ✕ 关掉，顶栏那个开关再点亮就回来。上一条记的「整列折叠时垫 Spacer」因此也不需要了。

**卡头一行装完，面板自己的工具条并进去**：原先是「卡头（名字 + ✕）」下面再来一条面板自己的工具条 —— 文件面板尤其明显，卡头底下是一整条只装四个图标的横条。改成卡头由面板自己画：`YCodePanelHeaderSpec`（面板、计数、高度、关闭／上移／下移）从 `WorkspaceInspectorView` 传下去，面板用 `YCodePanelHeader(spec:) { 自己的动作 }` 把按钮摆在同一行。数据是往下流的，不用 PreferenceKey 把子视图的按钮往上抛（那条路要给 `AnyView` 造一个 `Equatable` 壳，还得保证 token 覆盖按钮依赖的每一个状态，漏一个就是点了没反应的按钮）。

- 文件：新建文件／新建文件夹／刷新／访达 四个按钮上卡头，`fileToolbar` 整条删除；loading 的小菊花也挪进去。
- 编辑器（点开一个文件之后）：回文件树、保存上卡头；LSP 徽标、跳定义、预览／源码切换属于「当前这篇文档」不是面板，留在下面一条，而且**那条只在有内容时才出现**（`hasDocumentBar`）。原先常驻的「未保存／已保存」去掉了 —— 标签页上的橙点和卡头上禁用的保存按钮已经在说同一件事。
- 变更：⋯、「全部暂存」和对比范围（`main → feat/…`）全在卡头上。范围面包屑一开始留在下面单独一条，但那条除了它什么都没有、白占 28 的高度；它会变长，所以给它 `layoutPriority(-1)`，窄的时候先截它，名字和右边的动作不动。
- 待办：⋯ 上卡头，原先那条只装一句「N 项未完成」+ ⋯ 的头部整条删除 —— 未完成条数就是卡头上那个计数。
- 卡头左边加了一枚面板图标（20×20 圆角底），跟画布顶栏上那个开关是同一个符号。

⋯ 菜单走 `.menuStyle(.button)` + `YCodeIconButtonStyle`，不用 `.borderlessButton`：后者不认 label 上的 `foregroundStyle`，会把 ⋯ 染成强调色蓝，一排灰图标里就它是蓝的。

**终端面板改成标签页**：原先是可分屏的窗格树，每格顶上一条窗格头（Shell N + 分屏菜单 + ✕）。现在卡头上是一排标签（终端 1 / 终端 2 …）+ ＋，一次显示一格。Core 的 `YCodeProjectShellWorkspace` 分屏树**没动**（它有测试覆盖），＋ 仍走 `split(paneID:direction:.right)`，只是界面上把多出来的格子表现为一个标签；`WorkspaceModel` 新增 `shellSelection`（按项目记住在看哪一格）、`selectShellPane`、`addShellPane`，关掉当前格时先挑一个邻居再关，免得停在一个已经没有的 id 上。分屏的入口暂时没有了。

**画布顶栏的布局分段控件不收成 `.small`**：它会矮过旁边 24 的图标按钮，一排控件里就它塌下去一截。

**待办卡头上的 ⋯ 去掉了**：三条全是重复的 ——「刷新待办」（待办本来就在轮询）、「显示已完成」（列表里「已完成」那组自己就能展开）、「N 个未完成」（就是卡头上那个计数）。连带删掉 `WorkspaceModel.todoStatus`（设完没人读）、没有调用者的 `refreshTodos()`，以及 `refreshTodos` / `showCompleted` / `hideCompleted` / `noTodos` / `unfinishedTodosFormat` 五条文案。

**改名不再弹窗，就地改**：待办重命名和文件树的新建／重命名原先各弹一个 `.alert` —— 一个装着输入框的模态框，要先读标题才知道在改哪一条。现在：

- 待办：双击（或行菜单「重命名…」）把那一行的标题变成输入框，回车或点到别处提交，Esc 放弃，空标题当没改过。
- 文件树：新建时在**它将要待的位置**长出一行来写名字（父目录会先展开，草稿行插在该目录的第一个位置 —— 名字还没定，按名字排序无从谈起）；重命名同样把那一行的名字变成输入框。删除确认保留 —— 那是破坏性动作，该拦一下。

两处各有一个手势冲突要挡：文件行的 `onTapGesture { select }` 会吃掉点进输入框挪光标的那一下，所以正在改名的那行不接管点击；待办行的双击手势在输入框里选词时会再触发一次 `beginEditing`，把改了一半的标题重置回原样，所以同一条已经在改就不再进入。

`ProjectFileTreeView` 的列表模型随之从 `[ProjectFileTreeNode]` 换成 `[ProjectFileRow]`（真实条目 / 正在输入名字的草稿行两种）。

**面板区不再有最大宽度**：原先每列卡在 260–460，拖到 460 就拖不动了。现在往宽了不设上限，唯一的天花板是画布的最小宽（420）—— `maximumPanelAreaWidth = 可用宽 − canvasMinWidth − 1`，拖拽与「窗口变窄／多开一列」都走它，让步的是面板区不是画布。往窄了的下限从 260 降到 180。

这里踩了一个坑：可用宽度一开始是用 `.background { GeometryReader }` 量的，量到的是 `HStack` **自己撑开后**的宽度 —— 面板区一旦超宽，那个宽度就跟着变大，等于拿自己的结果给自己当上限，钳制永远不生效（实测把列宽默认值改成 2000，画布被整个挤出窗口左边）。改成 `GeometryReader` 套在外面量容器，并给 `HStack` 显式 `.frame(width: proxy.size.width)` 兜住第一帧。

**⌘B / 顶栏那个按钮收不起侧栏**：两列的 `NavigationSplitView` 里 `.doubleColumn` 的意思就是「两列都显示」，跟 `.all` 同义，原先在这两者之间来回切等于没切。改成 `.all ↔ .detailOnly`。侧栏收起后红绿灯会浮到画布顶栏左上角，所以顶栏的左内边距在收起态换成 `trafficLightWidth`，不然红绿灯压在第一个按钮上。

**变更面板加了文件树视图**：卡头左边那枚图标现在是个开关（`YCodePanelHeaderSpec` 多了 `iconIsOn` / `iconAction` / `iconHelp`，面板自己在传给卡头前填），亮起 = 左边一列按目录收成树、右边还是那份整列的文件流。点树里的一个文件 = 在右边展开它并滚过去（`ScrollViewReader` + 行上的 `.id(path)`）。树列宽取面板宽的 38%，夹在 150–320 之间。

树是从改动路径现搭的（`ChangeTreeNode` 前缀树 → 扁平化成 `[ChangeTreeRow]`），**单链目录压成一行**：`analytics/node_modules/.bin` 这种不压的话会摞出五六层只有一个孩子的空目录。目录行可折叠（`collapsedDirectories`）。

平铺一列在 157 个改动时，路径那一段全是重复前缀，看不出「这一轮动了哪几块」；收成树一眼就能看出来。默认仍是平铺 —— 面板默认宽 302，两列各 150 放不下东西，树视图是拖宽之后才划算的（宽度上限已经去掉了）。

顺带：`fileHeader` 里的行内动作与增删计数抽成了 `rowActions` / `lineStats`，树行和平铺行共用。

**卡头上的分支面包屑三次才调对尺寸**：`.borderlessButton` 的菜单会把卡头右边的空位全吃掉，画成一条横贯整栏的下拉框；`.fixedSize()` 能让它贴着文字走，但窄的时候它又不肯让，把名字和动作挤出去。最后是 `.menuStyle(.button)` + `.buttonStyle(.plain)` + 自己画 ⌄：既贴着文字，又能在窄的时候截断分支名。同时把卡头里的 `Spacer` 降成 `layoutPriority(-1)` —— 不降的话空位会先被 Spacer 抢走，明明放得下的面包屑也会被截断；计数那个 `Text` 补了 `.fixedSize()`，不然会被压成一列竖着的数字。
