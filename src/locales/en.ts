// English strings.
//
// Structure mirrors `zh.ts` exactly — same keys, same order. A type test
// (`i18n.test.ts`) fails the build if the two ever drift, so a key added
// on one side can't silently fall back to the other language.
//
// On tone: the Chinese copy in this app talks like a person, not a manual
// ("所有 agent 都在忙自己的事" is a shrug, not a status code). Translating
// it into flat product-speak would lose the thing that makes it read as
// written by someone. These aim for the same register in English.

export default {
  status: {
    working: "Working",
    blocked: "Needs you",
    done: "Done",
    exited: "Ended",
    error: "Failed",
    idle: "Idle",
  },

  common: {
    cancel: "Cancel",
    confirm: "Confirm",
    save: "Save",
    delete: "Delete",
    remove: "Remove",
    close: "Close",
    refresh: "Refresh",
    retry: "Retry",
    loading: "Loading…",
    starting: "Starting…",
    none: "None",
    off: "Off",
    enabled: "Enabled",
    unlimited: "Unlimited",
    always: "Always",
    project: "Project",
    branch: "Branch",
    command: "Command",
    commit: "Commit",
    global: "Global",
    permanent: "Permanent",
  },

  time: {
    justNow: "just now",
    // Abbreviated on purpose: these sit in a sidebar sub-row and a card
    // corner where "27 minutes ago" would push the title out. The unit
    // letter doesn't inflect, so both plural branches read the same.
    minutesAgo_one: "{{count}}m ago",
    minutesAgo_other: "{{count}}m ago",
    hoursAgo_one: "{{count}}h ago",
    hoursAgo_other: "{{count}}h ago",
    daysAgo_one: "{{count}}d ago",
    daysAgo_other: "{{count}}d ago",
  },

  statusBar: {
    mainRepo: "main repo",
    mainRepoOn: "main repo/{{branch}}",
    noWorktree: "no worktree",
    // Chinese needs a measure word here ("N 个X"); English just juxtaposes.
    // Keeping this a template rather than concatenating at the call site is
    // what lets the two languages disagree about word order.
    //
    // The status label is already a whole word ("Working", "Needs you"), so
    // neither branch pluralises it — the count carries the number. Both
    // branches exist because English declares two plural categories and
    // i18next looks up the matching one.
    sessionCount_one: "{{count}} {{label}}",
    sessionCount_other: "{{count}} {{label}}",
  },

  inbox: {
    title: "Needs you",
    open_one: "{{count}} session needs you (⇧⌘A)",
    open_other: "{{count}} sessions need you (⇧⌘A)",
    empty: "Nothing waiting on you (⇧⌘A)",
    emptyBody: "Every agent is off doing its own thing — nothing waiting on you.",
    justFinished: "Just finished",
    footnote:
      "ycode only tells you who's waiting — approvals still happen in the agent's own terminal",
  },

  sidebar: {
    openProject: "Open project",
    openProjectHint: "Open project (⌘O)",
    overviewHint: "All projects (⇧⌘P)",
    newSession: "New session",
    newSessionHint: "New session — open the agent picker",
    pickRepoDir: "Choose a repository folder",
    noProjects: "No projects yet. Add one with “Open project” above.",
    noAgentSelected: "No agent selected yet.",
    older: "Older",
    createProjectFailed: "Couldn't create the project: {{error}}",
    startSessionFailed: "Couldn't start the {{agent}} session: {{error}}",
    paneCapReached_one: "That's the {{count}}-pane limit — close one first",
    paneCapReached_other: "That's the {{count}}-pane limit — close one first",
    noAgentForId: "No agent configured with the id “{{id}}”",
    noAgentForResume:
      "No agent configured that can resume a “{{agent}}” session. Add one in Settings.",
    noResumableId: "This transcript has no resumable session id yet.",
    moreActions: "More actions for {{name}}",
    archive: "Archive",
    scanning: "Scanning…",
    scanFailed: "Couldn't scan transcripts — this list may be incomplete",
    olderHint: "Older sessions — open one to pick it back up",
    recent7d: "Last 7 days",
    noSessionsInProject: "No sessions in this project yet.",
    onWorktree: "Running in its own git worktree",
    paneNo: "Pane {{n}}",
  },

  pane: {
    renameHint: "{{title}} — double-click to rename",
    rename: "Rename session",
    close: "Close session",
    closeHint: "Close session (ends the process)",
    closePicker: "Close picker",
    waiting: "Waiting",
    newSession: "New session",
    merge: "Merge",
    merging: "Merging…",
    mergeTo: "Merge into {{base}}",
    mergeConfirmTitle: "Merge into {{base}}?",
    mergeConfirmBody:
      "Merges this agent's branch into “{{base}}” in the main worktree. The main worktree must already have “{{base}}” checked out with no uncommitted changes.",
    mergeBackTo: "Merge this agent's branch back into {{base}}",
    onBranch: "Running on {{branch}} in its own worktree",
  },

  ui: {
    showSessions: "Show session list",
    hideSessions: "Hide session list",
    confirmOk: "OK",
    switchProject: "Switch project",
    resizePanel: "Resize panel",
    allAgents: "All agents",
    filterBy: "Filter: {{label}}",
    filterAgentAria: "Agent filter — currently {{label}}",
    workspaceTarget: "Workspace target",
    workspaceTargetHint:
      "Which checkout Files, Editor, Changes, LSP and Terminal point at",
    pending: "Not yet built",
    session: "Session",
  },

  editor: {
    closeDirtyTitle: "Close {{name}}? It has unsaved changes",
    closeDirtyBody: "Edits since the last save will be discarded.",
    discardEdits: "Discard changes",
    saveBeforeSwitch:
      "Save or close your edited files before switching workspaces.",
    deleteTitle: "Delete {{name}}?",
    deleteDirBody: "The folder and everything in it is deleted for good.",
    deleteFileBody: "The file is deleted from disk for good.",
  },

  session: {
    closeFailed: "Couldn't close: {{error}}",
    thisSession: "this session",
    itsBranch: "its branch",
    baseBranch: "the base branch",
    closeTitle: "Close “{{label}}”?",
    closeBody: "The agent's process will be terminated.",
    removeWorktreeTitle: "Remove this agent's worktree?",
    removeWorktree: "Remove worktree",
    // Three separate messages rather than one assembled sentence: uncommitted
    // changes and unmerged commits are different losses, and a stitched-up
    // sentence reads badly when only one of them applies.
    dirtyAndUnmerged_one:
      "The agent has stopped. Its worktree has uncommitted changes, plus {{count}} commit not yet merged into {{base}}. Removing the worktree discards the uncommitted changes; the branch “{{branch}}” survives but is orphaned (no worktree, no longer listed in the UI). Merge first to keep everything.",
    dirtyAndUnmerged_other:
      "The agent has stopped. Its worktree has uncommitted changes, plus {{count}} commits not yet merged into {{base}}. Removing the worktree discards the uncommitted changes; the branch “{{branch}}” survives but is orphaned (no worktree, no longer listed in the UI). Merge first to keep everything.",
    dirtyOnly:
      "The agent has stopped. Its worktree has uncommitted changes, and removing the worktree throws them away — commit or merge first to keep them.",
    unmergedOnly_one:
      "The agent has stopped. The branch “{{branch}}” has {{count}} commit not yet merged into {{base}}. Removing the worktree keeps the branch but orphans it (no longer listed in the UI) — merge first to keep the work visible.",
    unmergedOnly_other:
      "The agent has stopped. The branch “{{branch}}” has {{count}} commits not yet merged into {{base}}. Removing the worktree keeps the branch but orphans it (no longer listed in the UI) — merge first to keep the work visible.",
  },

  project: {
    deleteTitle: "Delete “{{name}}”?",
    repoUntouched:
      "The repository at {{path}} is left alone — its files and branches stay exactly as they are.",
    sessionsClosed_one: "{{count}} session will be closed and archived{{suffix}}.",
    sessionsClosed_other: "{{count}} sessions will be closed and archived{{suffix}}.",
    worktreesTornDown_one:
      ", {{count}} of them tearing down a worktree (uncommitted changes are lost)",
    worktreesTornDown_other:
      ", {{count}} of them tearing down worktrees (uncommitted changes are lost)",
    reAddHint: "You can add it back later with “Open project”.",
    deleted: "Deleted “{{name}}”",
    deleteFailed: "Couldn't delete: {{error}}",
  },

  picker: {
    newSessionIn: "New session · ",
    noAgents: "No agents configured. Edit",
    noAgentsAdd: "to add one.",
    notOnPath: "{{command}} — not on PATH",
    historyReadable: "History readable",
    notInstalled: "Not installed",
    worktreeHint:
      "Each agent gets its own branch and working directory, so parallel runs don't overwrite each other",
  },

  settings: {
    general: {
      title: "General",
      lede: "Startup behaviour and the window.",
      startup: "Open on launch",
      startupDesc:
        "“Resume” goes straight to the workspace if you left sessions running, otherwise to the project overview",
      startupResume: "Resume",
      startupOverview: "Project overview",
      startupBlank: "Blank",
      windowState: "Remember window position and size",
      windowStateDesc: "Recorded on quit, restored next launch",
      windowStateBy: "Written by tauri-plugin-window-state when the window closes",
      locale: "Language",
      localeDesc: "“Match system” follows your operating system's language",
      matchSystem: "Match system",
    },
  },
} as const;
