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
    paneCapReached: "That's the {{count}}-pane limit — close one first",
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
