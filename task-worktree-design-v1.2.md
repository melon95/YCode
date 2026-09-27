# Task-Worktree 架构设计文档 v1.2

**多 Agent 协作的隔离模型:Task = Todo 的原地演进**

| 文档状态 | 设计定稿候选 v1.2(取代 v1.1 与迁移方案 v1,单一事实来源) |
|---|---|
| 日期 | 2026-07-06 |
| 决策 | 采纳 Task 级隔离;**Task 由 project_todos 原地演进而来,不新建实体** |

### 相对 v1.1 的关键变更

| # | 变更 | 原因 |
|---|---|---|
| 1 | **推翻「新建 tasks 表、todo 引用」,改为 todo 原地演进为 Task** | todo 已具备状态机/时间戳/归档/MCP,正是 Task 的全部管理半身;两表引用会制造双状态机对账问题(todo 说 done、分支未合并,谁信谁) |
| 2 | 状态轴统一为原 `todo/doing/done`,取消 `open/merged/closed`,终结方式收进 `outcome` | 一根状态轴,人和 agent 永远看到同一状态,零对账 |
| 3 | 新增四条「状态-工程联动规则」(§6.2) | 定义勾选/归档/子任务与 worktree 的关系 |
| 4 | MCP 策略明确为「扩展不替换」+ 不可逆动作人工确认边界 | 保护已有 agent 习惯;安全 |
| 5 | schema 吸收迁移方案修正:`base_branch` 可空(应用层强制)、新增 `origin` 列 | detached 遗留不猜、回填行可区分 |
| 6 | 迁移 0011 改为 `RENAME` + 加列 + 兼容 VIEW | 不建新表,现存 todo 零改动即成为无附件 Task |

---

## 1. 背景

### 1.1 现状(session 为中心 + todo 独立)

- **worktree 挂在 session 上**:`sessions` 三列(`worktree_path` / `branch=ycode/<ulid>` / `base_branch`),共享模式全 NULL;`projects.isolate_sessions` 项目级开关;worktree 存 `<data_dir>/worktrees/<project_id>/<session_id>`,刻意在所有 repo 之外。create 时 `worktree add -b` + lock,失败回滚;merge 走 `--no-ff` 且要求主工作树干净并在 base_branch 上;关闭走两步确认(`WorktreeCloseState` 警告 → stash → 双 force 删 worktree → 分支 fail-closed 仅在完全合并时删)。history/usage/search 依赖 `worktree_paths_for_project`(含已归档行)跨 cwd 扫描。
- **todo 独立一套**:`project_todos` 项目级清单,`todo/doing/done` 状态 + doing/done 时间戳、按周归档、组内拖拽排序;人经 TodoPanel、agent 经 ycode-mcp sidecar(rmcp/UDS)读写。**此刻只是看板,不驱动任何实际工作。**
- **关键不变量**:已提交的工作永不被销毁;未提交改动 teardown 前 stash。

### 1.2 真实缺陷

1. 同一任务无法多 agent 协作(分裂成多 worktree/分支,事后手动对账);
2. `ycode/<ulid>` 分支堆积且不可读(已被迫加删已合并分支对冲);
3. 合并碎片化,一个逻辑任务 N 次合并;
4. todo 是孤儿,不承载工程语义;
5. worktree 生命周期 == session,关 session 状态即消失。

### 1.3 两个核心洞察

- **当前隔离模型是新方案的退化特例**:「一个隔离 session 拥有一个 worktree」≡「一个只含一个 session 的 Task」。演进 = 把隔离重心从 session 上移到 Task,git 原语几乎全复用(§11 继承资产)。
- **todo 已经把 Task 的「管理半身」建好了**(状态、时间戳、归档、排序、MCP 通道),缺的只是「工程半身」(branch/worktree/session)。正确动作不是在旁边建一个 Task 实体去引用它,而是把工程半身作为**可空附件**长在它身上。「不是每个 todo 都值得 worktree」的顾虑由 `worktree_path` 可空解决,不需要两个实体。

---

## 2. 迁移前必须先修的两个 P0(与 Task 无关,立即做)

**P0-1 `delete_project` 打破关键不变量**:现状强删所有 worktree、不 stash,静默销毁未提交改动。修复:删前对各 worktree 跑 `WorktreeCloseState` 弹汇总警告,或统一 stash(stash 挂共享 `.git`,项目删了仍在 repo 里)。

**P0-2 teardown 的 stash 缺恢复路径**:裸 `git stash` 自动文案,用户不知其存在、无法对应回来源。修复:stash 带 message(`ycode: task <id> / branch <branch>`)+ 关闭确认 UI 明示「未提交改动已存入 stash」及恢复方式。

---

## 3. 设计目标与非目标

### 目标

- 一个 Task 一个 worktree 一条可读分支,Task 内 session(任意 agent)共享同一工作树;
- **todo 即 Task**:同一实体、同一状态轴、同一面板,工程能力为可选附件;
- 合并收敛为一任务一次(未来一 PR);worktree 生命周期与 Task 对齐;
- 保留 ad-hoc(session 可不挂 Task 直接用主工作区);
- ycode-mcp 升级为 Task API,agent 可管理任务乃至自建子任务。

### 非目标

- 不做同一 worktree 内的真并行写(并发的正确粒度是 worktree,不是其中的文件);
- 不追踪人类在 worktree 内的具体操作(只做 HEAD 变化检测);
- v1 不做远端 push + PR(Phase 4)。

---

## 4. 数据模型

### 4.1 统一实体

```
tasks(由 project_todos 原地演进,RENAME + 加列)
├── 原 todo 资产(全保留,现存行零改动)
│   ├── id / project_id / title
│   ├── status              -- todo / doing / done(唯一状态轴)
│   ├── doing_at / done_at
│   ├── sort_order          -- 组内拖拽
│   └── archived_week       -- 按周归档
├── 层级
│   └── parent_id           -- 可空;子任务 = 新行 + parent_id(§6.2 规则4)
├── 工程附件(全部可空;全 NULL = 纯清单项)
│   ├── slug                -- 建分支时生成一次,永不更新
│   ├── branch              -- ycode/<slug>-<ulid后缀>
│   ├── base_branch         -- schema 可空(detached 遗留),应用层对新建强制非空
│   ├── worktree_path       -- 归档后永久保留供扫描(§4.3)
│   ├── merge_strategy      -- squash(默认)/ no-ff
│   ├── active_writer_session_id  -- 应用层写锁(git worktree lock 不承担写锁,只防 prune)
│   ├── last_known_head     -- 人类介入检测
│   ├── port_base           -- 端口段
│   └── outcome             -- merged / discarded / NULL(§5)
└── origin                  -- user / migrated(回填行标记)

sessions
├── task_id                 -- 可空;NULL = ad-hoc 共享模式
└── mode                    -- normal / resume
(移除依赖:worktree_path / branch / base_branch 三列停止读取,0012 清理)

projects.isolate_sessions   -- 废弃(§6.1 语义7)
```

### 4.2 分支命名

`ycode/<task-slug>-<ulid后缀>`:slug 从标题生成一次、永不更新(改标题不 rename 分支);中文走拼音,失败截断 ulid 兜底;ulid 后缀防碰撞(继承全 ULID 经验)。

### 4.3 tasks 行永不硬删

历史 jsonl 以 worktree 路径编码落在 `~/.claude/projects` 下,扫描依赖能查到历史 `worktree_path`(踩过 `encode_cwd` 静默失效的坑)。**周归档本来就是软删,与此天然对齐**:规则收敛为「归档行的 `worktree_path` 永久保留,归档视图即扫描数据源的一部分;任何路径不 DELETE tasks 行」。

---

## 5. 状态模型:一根轴 + 一个终结方式 + 推导的工程展示态

| 层 | 内容 | 性质 |
|---|---|---|
| 状态轴 | `todo → doing → done`(原 todo 状态机,唯一真相) | 人和 agent 共同读写 |
| 终结方式 | `outcome`:done 时若有附件,记 `merged` 或 `discarded` | 结清流程写入(§6.2 规则2) |
| 工程展示态 | 有无分支徽标、ahead/behind、写锁占用者 | **从附件字段推导,不是第二个状态机** |

v1.1 的 `open/merged/closed` 取消。映射:open ≈ doing;merged/closed 收进 `done + outcome`。没有双状态机,就没有对账。

---

## 6. 锁死语义与联动规则

### 6.1 七条核心语义(写代码前定死)

1. **隔离边界 = Task。** 同 Task 的 session 共享一份工作树,ycode 不在其间加隔离;但不等于允许并发写(语义 4)。
2. **resume 是启动方式,不是 agent 类型。** `session.mode=resume`,无特殊 worktree 逻辑;`restart_session` 天然映射至此。
3. **Task 的工程附件可选;合并目标是 base_branch,不一定是 main。** ad-hoc 共享模式继续支持;支持 feature 分支上开子任务。
4. **Task 内写并发 = 串行接力(v1),写锁在应用层。** 同一时刻一个 active 写 session(`active_writer_session_id`);`git worktree lock` 只防 prune,不是写锁,两者不得混淆。理由:并发 `git add/commit` 撞 `.git/index.lock`、A 跑测试时 B 改文件结论静默失效——「两个终端开同目录」对人成立(会错开操作),对 agent 不成立。只读 session v1.5;真并行上推为子任务(规则 4),永不用文件锁在同一棵树里模拟并发。
5. **teardown 只绑定显式结清动作,不绑定 session 计数。** 「最后一个 session 关闭」不触发(用户可能还要 review/跑 CI/明天继续);session 崩溃不影响任务状态。现有两步关闭确认(WorktreeCloseState 警告 → stash → 双 force 删 → 分支 fail-closed 保留)整体上移到结清;session 关闭变轻:只触发 HANDOFF 更新。孤儿对冲:定期回收「分支已完全合并且已结清」的残留 worktree(与现有删已合并分支机制合并实现)。
6. **detached HEAD 下禁止工程化任务。** `task_start_work` 要求 HEAD 在分支上,否则提示先 checkout;历史 detached 遗留行保留 base_branch=NULL 并禁用自动合并(§10.3),不做回填猜测(猜错分支比禁用危险)。
7. **废弃 `projects.isolate_sessions`。** 隔离与否由「session 是否挂任务」的显式动作决定;不选「新 session 自动包任务」——会批量制造无意义任务,复刻分支堆积老问题。迁移后对开着开关的项目一次性提示。

### 6.2 四条状态-工程联动规则(todo 与 worktree 的接缝,同样锁死)

1. **工程化是显式动作,不随状态自动发生。** agent 把某项拨到 doing 不自动建 worktree(否则批量整理清单 = 批量制造 worktree)。建 worktree 走 `task_start_work`(人点按钮 / agent 显式调用),该动作附带拨到 doing。
2. **done 必须过结清检查。** 无附件项:直接勾掉,与今天无异。有附件项:done = 走完成流程——合并成功(`outcome=merged`)或显式放弃(触发两步关闭流程,`outcome=discarded`)。**不允许「分支还挂着的 done」**。这是把现有两步关闭确认自然嫁接到勾选动作上。
3. **周归档跳过带活附件的行。** 归档扫描遇到 `worktree_path` 非空且未结清(outcome IS NULL)的行:跳过并标记,不静默归档——否则 worktree 活着、条目从视图消失,成为新形态孤儿。
4. **子任务 = 一条新行 + `parent_id`。** 拖拽排序在同层内生效,看板天然长出层级;agent 经 MCP 自建子任务 = 插入行 + 对其调 `task_start_work`,与语义 4「并行上推为子任务」严丝合缝。

---

## 7. 多 Agent 工作方式

### 7.1 分层原则

> worktree 解决「任务之间」的隔离;「任务之内」多 agent 靠串行接力 + 交接机制。混淆这两层是返工的根源。

### 7.2 任务间:worktree 硬隔离

1. **repo 外存放**(沿用):新任务用 `<data_dir>/worktrees/<project_id>/<task_id>`;迁移遗留用旧 session 路径原地不动(§10.2)。
2. **依赖与构建产物显式化(v1 必做)**:worktree 不共享 `node_modules`/`target`/venv,冷启动装依赖是延迟税。方案:`task_start_work` 后自动执行项目级 **setup hook**;文档推荐 pnpm 硬链接、`CARGO_TARGET_DIR` 共享缓存。
3. **端口段隔离**:每任务分配 `port_base`,注入 session 环境变量,避免多任务 dev server 撞端口。

### 7.3 任务内:三种模式取舍

| 模式 | 决策 |
|---|---|
| A. 串行接力(一写,换 agent 不换场地) | ✅ v1:写锁 + UI 状态,零正确性风险,覆盖最高频场景(Claude 干一半换 Codex、白天 agent 晚上人) |
| B. 并行读 + 单写(review/问答 session) | ✅ v1.5 |
| C. 真并行写同一棵树 | ❌ 永不做;上推为子任务 |

### 7.4 交接机制(HANDOFF):结构化存任务、经 MCP 读写

多 agent 协作的真正瓶颈在上下文不在文件:接手者不知道目标、试过什么、为何放弃方案 X、哪些测试已知红。从 git log+diff 反推又慢又错。四段结构存在任务上(不用 worktree 内文件——不依赖文件约定、天然不进 PR diff、UI 可直接展示):

1. 目标与验收标准(建任务时生成,基本不变);
2. 当前进度与下一步(每 session 结束更新);
3. 已放弃路径及原因(防重蹈覆辙,价值最大);
4. 已知问题(哪些测试红着、哪些预期内)。

**系统层强制闭环**:session 启动自动注入 agent 初始上下文;session 结束提示/强制经 MCP 更新,不依赖 agent 自觉。

**人也是一种 session**:任务记 `last_known_head`,agent session 启动时 diff 当前 HEAD,发现来历不明的 commit/未提交改动时先审阅再动手——挡掉「agent 覆盖人手改动」一类事故。

### 7.5 合并模型:免主工作树 + 默认 squash(两处修正现有实现)

- **干掉「主工作树干净且在 base_branch 上」前置条件**(当前最大摩擦,任务模型下合并更频繁会被放大):`.git` 共享,可临时 `git worktree add --detach` 一个 checkout 到 base_branch 的一次性 worktree,在其中 merge、推进 ref、拆掉;主工作区全程不被打扰。
- **默认 squash,`--no-ff` 降为任务级选项**:agent 被鼓励高频 commit,no-ff 会把脏 commit 原样带进 base。squash 兑现「过程可追溯(分支上)+ 历史整洁(base 上)」。冲突保持 `merge --abort` 回滚。

### 7.6 提交纪律与同步

- agent 小步频繁 commit;message 前缀标身份 `[claude]`/`[codex]`/`[human]`;合并时 squash 成语义化 commit。
- 任务生命周期长、base 持续前进(任务模型**新引入的成本**):面板常驻 ahead/behind,超阈值提示;「同步」= 本地 rebase / 已推远端则 merge base(避免 force-push,政策留 Phase 4);**冲突解决可派发为 agent session**——差异化点而非负担。

---

## 8. MCP:扩展而非替换

todo 工具集已是 agent 入口,原则:**旧工具签名不动,新能力加新工具**,不破坏已有 agent 提示词/习惯。

| 类别 | 工具 | 说明 |
|---|---|---|
| 保留 | 现有增删改状态/排序 | 行为不变,纯清单路径完全无感 |
| 新增 | `task_start_work` | 建 worktree+分支(过 detached 检查、跑 setup hook、分配端口段),拨 doing,返回 cwd |
| 新增 | `task_get_context` | 目标/验收标准/HANDOFF 四段 |
| 新增 | `task_update_handoff` | session 结束闭环调用 |
| 新增 | `task_finish` | **只能发起结清请求**;合并/放弃的确认留给 UI 上的人 |
| 新增 | `task_create_subtask` | 插行 + parent_id,可选连调 start_work |

**安全边界(现在锁死)**:合并、放弃 worktree 这类不可逆动作,agent 经 MCP 只能请求,不能单方面执行。

---

## 9. UI:TodoPanel 原地长成任务看板

不新建面板。无附件行与今天一模一样;有附件行多出:分支徽标(沿用 pane 标题徽标的样式)、ahead/behind、展开后的 sessions 列表 + 写锁占用者 + 同步/结清按钮。ChangesPanel 按任务组织(替代按 session 分支打标签)。用户学习成本≈0——合并模型最大的产品红利:**不存在「todo 页」和「任务页」两个地方看同一件事**。

---

## 10. 迁移方案(0011,修订版)

### 10.0 总原则

1. **原地演进,不建新表**:`RENAME` + 加列,现存 todo 行零改动即成为无附件任务。
2. **磁盘 worktree 一个不动**:移动目录会同时打断 git worktree 的 gitdir 双向指针和 jsonl 路径编码。旧路径原样入库,新旧布局共存,一切按 DB 绝对路径寻址,任何代码不得从目录名反推归属。
3. 数据无损、行为有损点显式进 release notes(「关 session 不再拆 worktree」)。
4. SQLite 单事务,失败整体回退。

### 10.1 DDL

```sql
ALTER TABLE project_todos RENAME TO tasks;
ALTER TABLE tasks ADD COLUMN parent_id TEXT REFERENCES tasks(id);
ALTER TABLE tasks ADD COLUMN slug TEXT;
ALTER TABLE tasks ADD COLUMN branch TEXT;
ALTER TABLE tasks ADD COLUMN base_branch TEXT;
ALTER TABLE tasks ADD COLUMN worktree_path TEXT;
ALTER TABLE tasks ADD COLUMN merge_strategy TEXT NOT NULL DEFAULT 'squash';
ALTER TABLE tasks ADD COLUMN active_writer_session_id TEXT;
ALTER TABLE tasks ADD COLUMN last_known_head TEXT;
ALTER TABLE tasks ADD COLUMN port_base INTEGER;
ALTER TABLE tasks ADD COLUMN outcome TEXT;                       -- merged / discarded
ALTER TABLE tasks ADD COLUMN origin TEXT NOT NULL DEFAULT 'user';
CREATE INDEX idx_tasks_worktree ON tasks(worktree_path) WHERE worktree_path IS NOT NULL;

-- 兼容层:旧代码/回滚版本按旧表名读
CREATE VIEW project_todos AS SELECT * FROM tasks;

ALTER TABLE sessions ADD COLUMN task_id TEXT REFERENCES tasks(id);
ALTER TABLE sessions ADD COLUMN mode TEXT NOT NULL DEFAULT 'normal';
-- sessions 三列与 projects.isolate_sessions 保留不读,0012 清理
```

### 10.2 隔离 session 回填(同事务)

对每个 `sessions.worktree_path IS NOT NULL` 的行(**含已归档行**——history 扫描的数据来源,漏掉即 encode_cwd 式静默断档重演),插入 `origin='migrated'` 的 tasks 行:

- `title` = 会话标题,否则 `"迁移会话 " || substr(session.id, -6)`;`slug` 直接用 session ulid(分支已定名,slug 只服务新分支);
- `branch` / `base_branch` / `worktree_path` 原值搬入(含 base 为 NULL 的 detached 遗留);
- `session.task_id` 回指;`restart_session` 历史同 session 同行,1:1 天然成立,无需去重;
- 共享模式 session(三列全 NULL)不生成任务,`task_id=NULL`。

**状态推导**:

| 实况 | status / outcome / archived_week |
|---|---|
| session 活跃且 worktree 目录存在 | `doing` |
| 已归档,分支已删(当时 fully-merged 通过) | `done` / `merged` / 落当周(直接进归档视图,不扰当前看板) |
| 已归档,分支仍在(fail-closed 保留的未合并分支) | `done` / `discarded` / 落当周;分支保持保留 |
| worktree_path 有值但磁盘目录不存在(手动删过) | `done` / `discarded` / 落当周,记日志不报错 |

### 10.3 detached 遗留(base_branch NULL)

保留 NULL,该任务合并入口禁用,UI 提示「创建于游离 HEAD,无法自动合并,请手动处理分支 `<branch>`」。不猜 main/master——猜错会把 commit 合进错误分支,比禁用危险。

### 10.4 isolate_sessions 收尾

列不动、代码停读;开着开关的项目首次打开弹一次性提示:「自动隔离已由任务取代:开始任务即获得独立分支,普通会话默认在主工作区」。

### 10.5 代码切换点(与 0011 同版本)

1. `worktree_paths_for_project` 改查 `tasks.worktree_path`(含归档行)——最先切、最必须验证;
2. `git_branch` / merge 入口按 task_id;merge 前置条件重写(§7.5);
3. `create_session` 隔离块拆除:不再建 worktree,带 task_id 则 cwd=task.worktree_path;
4. `archive_session` 不再触发 teardown,teardown 挂到结清动作;
5. TodoPanel 读写经新列(旧工具签名不变);watcher/WorkspaceMatcher 零改动(路径没动)。

---

## 11. 发布、回滚与验证

### 11.1 两个 release 当灰度(单机应用没有灰度基础设施)

- **Release A = 0011 + 读路径切换,行为不变**:UI 无看板变化,migrated 行默认折叠/已入归档;对 migrated doing 任务,关 session 仍引导走旧式「关闭任务」流程。目的:把 schema/读路径风险与行为/UX 风险拆开,扫描断档类问题在此暴露且回滚干净。
- **Release B = 任务行为 + UX**:`task_start_work`、写锁、免主工作树合并、HANDOFF 闭环、结清流程、看板进化。此时 0011 已稳定,B 只有行为风险。

### 11.2 回滚

- 0011 纯增量 + `project_todos` VIEW 兜底 → **回滚 = 装回旧版应用,无需 down migration**:旧代码经 VIEW 读 todo(原列全在)、经 sessions 三列读 worktree(原值未动),tasks 新列被无视。
- 已知损失(进 release notes):回滚后 A/B 期间新建的任务附件对旧版不可见(worktree/分支仍在磁盘和 repo 里,数据不丢,可 `git worktree list` 找回);A 阶段行为未变,该窗口几乎不产生新附件——分两个 release 的另一收益。
- ⚠️ 需验证旧版本对 VIEW 的写路径:SQLite 简单 VIEW 不可直接 INSERT/UPDATE。若旧代码写 `project_todos`,VIEW 需配 INSTEAD OF 触发器,或接受「回滚期间 todo 只读」并写进 notes——**Release A 前必须实测旧二进制跑在新库上的读写行为**,这是本方案唯一的回滚紧点。
- 0012(DROP sessions 三列 + isolate_sessions + 兼容层)至少等 B 稳定一个版本周期,并自带真正的 down 脚本。

### 11.3 验证 checklist

1. 行数守恒:`count(旧 sessions where worktree_path not null)` == `count(tasks where origin='migrated')`;现存 todo 行数不变、内容逐行相等。
2. 引用完整:sessions.task_id 指向存在且 project_id 一致的任务;无两 session 指向同一 migrated 任务。
3. **扫描等价(最关键)**:迁移前后 `worktree_paths_for_project` 逐项目结果集完全相等;做成自动化测试,用真实迁移前 DB 快照当 fixture——encode_cwd 教训的直接兑现。
4. 状态抽查:migrated 行的 status/outcome 与磁盘、分支实况一致。
5. 冒烟:对一个 migrated doing 任务执行合并、对另一个执行放弃,验证 stash 保护、fail-closed 留分支、历史 jsonl 仍可扫描。
6. 旧二进制回滚实测(§11.2 的紧点)。
7. detached 遗留行:合并入口禁用、文案正确。

---

## 12. 继承资产清单(直接上移、无需重设计)

| 资产 | 处置 |
|---|---|
| repo 外 worktree 布局 | 新任务路径段 session_id → task_id;遗留原地不动 |
| 全 ULID 防同秒碰撞 | 变为 slug + ulid 后缀 |
| 失败回滚 `worktree_cleanup_blocking` | 原样 |
| 两步关闭确认 + WorktreeCloseState | 整体上移为结清流程(联动规则 2) |
| stash 保护未提交改动 | 原样 + P0-2 补 message/UI |
| `branch_fully_merged` fail-closed | 原样 |
| 非 git/空仓库回退共享模式 | 原样(`task_start_work` 同样检查) |
| jsonl watcher / WorkspaceMatcher / encode_cwd 修复 | 原样,路径来源换表 |
| restart_session | 映射为 mode=resume |
| todo 状态机/时间戳/归档/排序/MCP 通道 | **成为 Task 的管理半身,原样保留** |

---

## 13. 风险与开放问题

| # | 项 | 缓解/状态 |
|---|---|---|
| R1 | 磁盘占用上升(worktree 更长命 + 依赖副本) | setup hook + 共享缓存;孤儿回收;面板显示占用 |
| R2 | HANDOFF 质量依赖 agent 执行力 | MCP 强制闭环;人可手改 |
| R3 | 免主工作树合并的临时 worktree 泄漏 | 命名约定 + 启动清扫 |
| R4 | 长期分支同步冲突痛感 | 主动提示 + 冲突解决 agent 化 |
| R5 | 回滚期 VIEW 写路径不可用 | Release A 前实测旧二进制;必要时 INSTEAD OF 触发器(§11.2) |
| O1 | 只读 session 的技术保证(prompt 级软约束 vs fs 级硬约束) | v1.5 前决策 |
| O2 | 子任务合并流向(子→父分支?)与看板层级呈现 | Phase 3 前决策 |
| O3 | Phase 4 团队场景:分支保护/PR 模板/force-push | Phase 4 决策 |
| O4 | 端口段分配策略(静态段 vs 动态探测) | Phase 2 实现时定 |
| O5 | 归档视图中带 worktree 的历史行,扫描长期成本 | 观察;必要时对超龄行做扫描降频 |

---

## 14. 路线图

- **Phase 0**:P0-1、P0-2(不等迁移,立即)。
- **Phase 1(Release A)**:0011(RENAME+加列+VIEW+回填)、读路径切换、回滚实测,行为不变。
- **Phase 2(Release B)**:`task_start_work`(detached 检查/setup hook/端口段)、应用层写锁、结清流程(联动规则 2)、免主工作树合并+默认 squash、HANDOFF 闭环、MCP 新工具集。
- **Phase 3**:TodoPanel 看板进化(徽标/ahead-behind/sessions 展开/写锁可视化)、子任务层级、ChangesPanel 按任务组织。
- **Phase 4**:push+PR、force-push 政策。
- **0012**(B 稳定一周期后):DROP 旧列与兼容层,自带 down 脚本。

---

## 15. 决策摘要(TL;DR)

1. **Task = todo 原地演进**,不新建实体、不做引用——todo 的管理半身(状态/归档/排序/MCP)全保留,工程半身(branch/worktree)作为可空附件长上去;双状态机对账问题从根上不存在。
2. **一根状态轴** `todo/doing/done` + `outcome(merged/discarded)`;工程展示态从附件推导,不是第二个状态机。
3. **七条核心语义 + 四条联动规则**锁死:隔离边界=Task;resume 是启动方式;附件可选、合并目标 base_branch;串行接力+应用层写锁;teardown 只绑显式结清;detached 禁工程化;废弃 isolate_sessions;工程化显式动作;done 过结清;归档跳过活附件;子任务=新行+parent_id。
4. **MCP 扩展不替换**:旧工具签名不动;`task_start_work`/`get_context`/`update_handoff`/`finish`/`create_subtask` 新增;不可逆动作 agent 只能发起、人确认。
5. **迁移**:0011 = RENAME+加列+VIEW 兼容;磁盘零移动;含已归档 session 回填(history 命脉);detached 遗留禁自动合并不猜;两个 release 当灰度;回滚=装回旧版(唯一紧点:VIEW 写路径需实测)。
6. **合并模型修正**:免主工作树合并;默认 squash。
7. **验证核心**:迁移前后扫描结果集逐项目相等的自动化测试——encode_cwd 教训的制度化。
