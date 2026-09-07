// 简体中文词条。
//
// key 的分段规则:`<面>.<物>`,面用界面区域(sidebar / statusBar /
// settings…),不用组件文件名 —— 组件会被拆合改名,而「侧栏」这个位置
// 不会。共享词汇(状态名、通用动词)提到顶层 `status` / `common`,免得
// 同一个词在五个面下各写一遍、改的时候漏掉三个。
//
// 带 `_one` / `_other` 后缀的是 i18next 的复数形式。中文没有复数变化,
// 两个分支写一样的字即可 —— 保留分支是为了让英文那边能正确变形,
// 而不是中文这边真的需要区分。

export default {
  status: {
    working: "进行中",
    blocked: "等你处理",
    done: "已完成",
    exited: "已结束",
    error: "出错",
    idle: "空闲",
  },

  common: {
    cancel: "取消",
    confirm: "确认",
    save: "保存",
    delete: "删除",
    remove: "移除",
    close: "关闭",
    refresh: "刷新",
    retry: "重试",
    loading: "加载中…",
    starting: "启动中…",
    none: "无",
    off: "关",
    enabled: "已启用",
    unlimited: "不限",
    always: "总是",
    project: "项目",
    branch: "分支",
    command: "命令",
    commit: "提交",
    global: "全局",
    permanent: "永久",
  },

  time: {
    justNow: "刚刚",
    minutesAgo_other: "{{count}} 分钟前",
    hoursAgo_other: "{{count}} 小时前",
    daysAgo_other: "{{count}} 天前",
  },

  statusBar: {
    mainRepo: "主仓库",
    mainRepoOn: "主仓库/{{branch}}",
    noWorktree: "无 worktree",
    // 「3 个进行中」。状态名由 status.* 传进来,这里只管数字与量词的
    // 摆法 —— 中文是「N 个X」,英文是「N X」,两边语序不同。
    //
    // 传了 `count` 就会走 i18next 的复数解析,必须给出该语言的全部
    // 复数类别,否则查不到词条、直接漏出 key。中文只有 `_other`。
    sessionCount_other: "{{count}} 个{{label}}",
  },

  inbox: {
    title: "等你处理",
    open_one: "{{count}} 个会话等你处理 (⇧⌘A)",
    open_other: "{{count}} 个会话等你处理 (⇧⌘A)",
    empty: "没有等待处理的会话 (⇧⌘A)",
    emptyBody: "所有 agent 都在忙自己的事 —— 没有等你的会话。",
    justFinished: "刚刚完成",
    footnote: "ycode 只告诉你谁在等 —— 批准仍在 agent 自己的终端里完成",
  },

  sidebar: {
    openProject: "打开项目",
    openProjectHint: "打开项目 (⌘O)",
    overviewHint: "全部项目总览 (⇧⌘P)",
    newSession: "新建会话",
    newSessionHint: "新建会话 —— 打开 agent 选择器",
    pickRepoDir: "选择项目仓库目录",
    noProjects: "还没有项目。用顶栏的「打开项目」添加一个。",
    noAgentSelected: "还没有选中 agent。",
    older: "更早",
    createProjectFailed: "创建项目失败:{{error}}",
    startSessionFailed: "启动 {{agent}} 会话失败:{{error}}",
    paneCapReached_other: "已达 {{count}} 个面板上限,先关一个",
    noAgentForId: "没有 id 为「{{id}}」的 agent 配置",
    noAgentForResume: "没有能恢复「{{agent}}」会话的 agent 配置,请在设置里添加。",
    noResumableId: "这份 transcript 还没有可恢复的会话 id。",
    moreActions: "{{name}} 的更多操作",
    archive: "归档",
    scanning: "扫描中…",
    scanFailed: "扫描 transcript 失败,列表可能不全",
    olderHint: "更早的会话,点开可恢复继续",
    recent7d: "最近 7 天",
    noSessionsInProject: "这个项目还没有会话。",
    onWorktree: "运行在独立的 git worktree 里",
    paneNo: "面板 {{n}}",
  },

  pane: {
    renameHint: "{{title}} —— 双击可重命名",
    rename: "重命名会话",
    close: "关闭会话",
    closeHint: "关闭会话(会结束该进程)",
    closePicker: "关闭选择器",
    waiting: "等待中",
    newSession: "新建会话",
    merge: "合并",
    merging: "合并中…",
    mergeTo: "合并到 {{base}}",
    mergeConfirmTitle: "合并到 {{base}}?",
    mergeConfirmBody:
      "把这个 agent 的分支合并到主工作树的「{{base}}」。主工作树必须已检出「{{base}}」且没有未提交的改动。",
    mergeBackTo: "把这个 agent 的分支合并回 {{base}}",
    onBranch: "运行在独立 worktree 的分支 {{branch}} 上",
  },

  ui: {
    showSessions: "显示会话列表",
    hideSessions: "隐藏会话列表",
    confirmOk: "确定",
    switchProject: "切换项目",
    resizePanel: "调整面板高度",
    allAgents: "全部 agent",
    filterBy: "筛选:{{label}}",
    filterAgentAria: "agent 筛选 —— 当前 {{label}}",
    workspaceTarget: "工作区目标",
    workspaceTargetHint: "选择「文件、编辑器、变更、LSP、终端」所使用的 checkout",
    pending: "待实现",
    session: "会话",
  },

  editor: {
    closeDirtyTitle: "关闭 {{name}}?它有未保存的修改",
    closeDirtyBody: "自上次保存以来的编辑会被丢弃。",
    discardEdits: "丢弃修改",
    saveBeforeSwitch: "切换工作区前,请先保存或关闭已编辑的文件。",
    deleteTitle: "删除 {{name}}?",
    deleteDirBody: "目录及其全部内容会被永久删除。",
    deleteFileBody: "文件会从磁盘上永久删除。",
  },

  session: {
    closeFailed: "关闭失败:{{error}}",
    thisSession: "这个会话",
    itsBranch: "它的分支",
    baseBranch: "基准分支",
    closeTitle: "关闭「{{label}}」?",
    closeBody: "agent 的运行进程会被结束。",
    removeWorktreeTitle: "移除这个 agent 的 worktree?",
    removeWorktree: "移除 worktree",
    // 三种情形分开写而不是拼句子:未提交的改动和未合并的提交是两件不同
    // 的损失,拼接出来的句子在只有其中一种时会读着别扭。
    dirtyAndUnmerged_other:
      "agent 已停止。它的 worktree 有未提交的改动,另有 {{count}} 个提交尚未合并到 {{base}}。移除 worktree 会丢弃未提交的改动;分支「{{branch}}」会保留但成为孤儿分支(没有 worktree,不再显示在界面里)。想全部保留请先合并。",
    dirtyOnly:
      "agent 已停止。它的 worktree 有未提交的改动,移除 worktree 会把它们丢弃 —— 想保留请先提交或合并。",
    unmergedOnly_other:
      "agent 已停止。分支「{{branch}}」有 {{count}} 个提交尚未合并到 {{base}}。移除 worktree 会保留分支但使其成为孤儿(不再显示在界面里)—— 想让工作可见请先合并。",
  },

  project: {
    deleteTitle: "删除「{{name}}」?",
    repoUntouched: "仓库目录 {{path}} 不会被删除,里面的文件和分支都保持原样。",
    sessionsClosed_other: "{{count}} 个会话会被结束并归档{{suffix}}。",
    worktreesTornDown_other:
      ",其中 {{count}} 个的 worktree 会被拆掉(未提交的改动会丢失)",
    reAddHint: "之后可以用「打开项目」重新加回来。",
    deleted: "已删除「{{name}}」",
    deleteFailed: "删除失败:{{error}}",
  },

  picker: {
    newSessionIn: "新建会话 · ",
    noAgents: "没有配置任何 agent。编辑",
    noAgentsAdd: "添加一个。",
    notOnPath: "{{command}} — 不在 PATH 中",
    historyReadable: "历史可读",
    notInstalled: "未安装",
    worktreeHint: "每个 agent 拿到自己的分支与工作目录,并行时互不覆盖",
  },

  settings: {
    general: {
      title: "通用",
      lede: "启动行为与窗口。",
      startup: "启动时打开",
      startupDesc:
        "「智能恢复」= 上次留有活跃会话就直接回工作区,否则进项目总览",
      startupResume: "智能恢复",
      startupOverview: "项目总览",
      startupBlank: "空白",
      windowState: "记住窗口位置与大小",
      windowStateDesc: "退出时记录,下次原样打开",
      windowStateBy: "由 tauri-plugin-window-state 在窗口关闭时写入",
      locale: "界面语言",
      localeDesc: "「跟随系统」按操作系统的语言自动选择",
      matchSystem: "跟随系统",
    },
  },
} as const;
