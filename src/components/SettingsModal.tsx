// Standalone settings workspace. The component keeps the existing staged
// config lifecycle, but presents it as a first-class screen instead of a
// modal layered over the coding workspace.

import { useEffect, useRef, useState } from "react";
import {
  Bell,
  Bot,
  ChartPie,
  CircleArrowDown,
  Code2,
  Database,
  Keyboard,
  Layers,
  Monitor,
  PanelRight,
  Plug,
  Search,
  SlidersHorizontal,
  TerminalSquare,
  X,
  type LucideIcon,
} from "lucide-react";
import { toast } from "@heroui/react";
import {
  agentHookStatus,
  cliStatus,
  getConfig,
  mcpStatus,
  resetConfig,
  saveConfig,
} from "../lib/ipc";
import { useStore } from "../lib/store";
import type { ConfigView } from "../lib/types";
import { confirmDialog } from "../lib/confirm";
import { useEscapeGuard } from "../lib/useEscapeGuard";
import { AgentsSettings } from "./AgentsSettings";
import { AppearanceSettings } from "./AppearanceSettings";
import { DataSettings } from "./DataSettings";
import { GeneralSettings } from "./GeneralSettings";
import { IntegrationsSettings } from "./IntegrationsSettings";
import { LanguagesSettings } from "./LanguagesSettings";
import { NotificationsSettings } from "./NotificationsSettings";
import { SessionsSettings } from "./SessionsSettings";
import { TerminalSettings } from "./TerminalSettings";
import { UpdatesSettings } from "./UpdatesSettings";
import { UsageSettings } from "./UsageSettings";
import { KeyboardSettings, PanelsSettings } from "./PanelsSettings";

type SectionId =
  | "general"
  | "sessions"
  | "panels"
  | "agents"
  | "integrations"
  | "notifications"
  | "usage"
  | "terminal"
  | "languages"
  | "appearance"
  | "keyboard"
  | "data"
  | "about";

interface NavItem {
  id: SectionId;
  label: string;
  icon: LucideIcon;
  /// Sections whose backing feature doesn't exist yet still appear — dimmed
  /// and unclickable — because "not yet" is a more useful answer than an
  /// absent entry when someone goes looking for a setting.
  pending?: boolean;
}

/// Grouped by *what you are configuring*, not by which component happens to
/// render it. The old flat list mixed a monitoring dashboard (Usage) in with
/// real settings and buried the hook wiring inside Notifications, even though
/// hooks drive session status too.
const NAV_GROUPS: Array<{ title: string; items: NavItem[] }> = [
  {
    title: "工作区",
    items: [
      { id: "general", label: "通用", icon: SlidersHorizontal },
      { id: "sessions", label: "会话", icon: Layers },
      { id: "panels", label: "面板", icon: PanelRight },
    ],
  },
  {
    title: "Agent",
    items: [
      { id: "agents", label: "Agent 目录", icon: Bot },
      { id: "integrations", label: "集成", icon: Plug },
      { id: "notifications", label: "通知", icon: Bell },
      { id: "usage", label: "用量", icon: ChartPie },
    ],
  },
  {
    title: "编辑与终端",
    items: [
      { id: "terminal", label: "终端", icon: TerminalSquare },
      { id: "languages", label: "编辑器与语言", icon: Code2 },
    ],
  },
  {
    title: "应用",
    items: [
      { id: "appearance", label: "外观", icon: Monitor },
      { id: "keyboard", label: "键盘快捷键", icon: Keyboard },
      { id: "data", label: "数据与隐私", icon: Database },
      { id: "about", label: "关于", icon: CircleArrowDown },
    ],
  },
];

interface Props {
  onClose: () => void;
}

export function SettingsScreen({ onClose }: Props) {
  const setAgents = useStore((s) => s.setAgents);
  const setFontSizes = useStore((s) => s.setFontSizes);
  const setTheme = useStore((s) => s.setTheme);
  const setAutoHideTopBar = useStore((s) => s.setAutoHideTopBar);
  const setSessionOpenMode = useStore((s) => s.setSessionOpenMode);
  const [staged, setStaged] = useState<ConfigView | null>(null);
  const [original, setOriginal] = useState<ConfigView | null>(null);
  const [section, setSection] = useState<SectionId>("agents");
  const [loading, setLoading] = useState(true);
  const [saving, setSaving] = useState(false);
  // 导航过滤词。只过滤左侧列表,不碰右侧内容 —— 当前分区即使被过滤掉,
  // 内容区也保持不变,免得输入过程中页面跳来跳去。
  const [navQuery, setNavQuery] = useState("");
  // 「集成」项的角标:未接入的集成数(hook / MCP / ycode 命令)。`null` =
  // 还没查完或查失败,此时不显示角标 —— 宁缺毋假。
  const [integrationsWarn, setIntegrationsWarn] = useState<number | null>(null);

  const onCloseRef = useRef(onClose);
  useEffect(() => {
    onCloseRef.current = onClose;
  }, [onClose]);

  useEffect(() => {
    let cancelled = false;
    getConfig()
      .then((cfg) => {
        if (cancelled) return;
        setStaged(cfg);
        setOriginal(cfg);
      })
      .catch((err) => {
        if (cancelled) return;
        toast.danger(`读取配置失败:${err}`);
        onCloseRef.current();
      })
      .finally(() => {
        if (!cancelled) setLoading(false);
      });
    return () => {
      cancelled = true;
    };
  }, []);

  // 打开设置时查一次集成状态,给「集成」导航项挂角标 = 未接入的集成数。
  // 这些命令都只是读本地文件 / 查符号链接,足够轻量。单项查询失败按 0
  // 计(状态未知就不指控它「未接入」);全部失败角标自然不出现。
  useEffect(() => {
    if (!original) return;
    const hookAgents = [
      ...new Set(
        original.agents
          .map((a) => a.introspect)
          .filter((i): i is "claude" | "codex" => i === "claude" || i === "codex"),
      ),
    ];
    const probes: Array<Promise<number>> = [
      // `ycode` 命令:未装 / 失效 / 被占用都算一件待办。
      cliStatus()
        .then((s) => (s.kind === "installed" ? 0 : 1))
        .catch(() => 0),
      ...hookAgents.map((a) =>
        agentHookStatus(a)
          .then((s) => (s.kind === "installed" ? 0 : 1))
          .catch(() => 0),
      ),
      ...hookAgents.map((a) =>
        mcpStatus(a)
          .then((s) => (s === "installed" ? 0 : 1))
          .catch(() => 0),
      ),
    ];
    let cancelled = false;
    Promise.all(probes).then((counts) => {
      if (cancelled) return;
      setIntegrationsWarn(counts.reduce((a, b) => a + b, 0));
    });
    return () => {
      cancelled = true;
    };
    // 只看初次加载的配置;staged 的编辑不该反复触发探测。
  }, [original]);

  const dirty =
    staged !== null && original !== null && !sameConfig(staged, original);

  const visibleGroups = filterNavGroups(navQuery);

  useEscapeGuard(() => void handleClose());

  async function handleClose() {
    if (dirty) {
      const ok = await confirmDialog({
        title: "放弃未保存的更改?",
        message: "设置里还有没保存的改动。",
        confirmLabel: "放弃",
        destructive: true,
      });
      if (!ok) return;
      if (original && original.theme !== useStore.getState().theme) {
        setTheme(original.theme);
      }
    }
    onClose();
  }

  async function handleSave() {
    if (!staged || saving) return;
    setSaving(true);
    try {
      const refreshed = await saveConfig(staged);
      setAgents(refreshed);
      setFontSizes(staged.font_sizes);
      setTheme(staged.theme);
      setAutoHideTopBar(staged.auto_hide_top_bar);
      setSessionOpenMode(staged.session_open_mode);
      setOriginal(staged);
      toast.success("设置已保存");
      onClose();
    } catch (err) {
      toast.danger(`保存失败:${err}`);
    } finally {
      setSaving(false);
    }
  }

  async function handleReset() {
    const ok = await confirmDialog({
      title: "恢复默认设置?",
      message: "会用出厂默认覆盖你的配置文件,自定义内容将丢失。",
      confirmLabel: "恢复默认",
      destructive: true,
    });
    if (!ok) return;
    try {
      const refreshed = await resetConfig();
      setAgents(refreshed);
      const cfg = await getConfig();
      setStaged(cfg);
      setOriginal(cfg);
      setFontSizes(cfg.font_sizes);
      setTheme(cfg.theme);
      setAutoHideTopBar(cfg.auto_hide_top_bar);
      setSessionOpenMode(cfg.session_open_mode);
      toast.success("已恢复默认设置");
    } catch (err) {
      toast.danger(`恢复默认失败:${err}`);
    }
  }

  return (
    // Settings floats over the workspace rather than replacing it. Keeping
    // the terminals visible behind the dialog is the point: a setting you
    // change here (theme, font size, panel) shows its effect immediately,
    // and there is no "how do I get back" question to answer.
    <div
      className="settings-mask"
      onMouseDown={(e) => {
        if (e.target === e.currentTarget) void handleClose();
      }}
    >
      <section className="settings-dialog" aria-label="设置" role="dialog" aria-modal>
        <header className="settings-dialog-head">
          <span className="sd-title">设置</span>
          <span className="toolbar-spacer" />
          <span className={`settings-save-state${dirty ? " dirty" : ""}`}>
            {dirty ? "有未保存的更改" : ""}
          </span>
          <button
            type="button"
            className="icon-btn2 icon-btn2-sm"
            onClick={() => void handleClose()}
            title="关闭 (esc)"
            aria-label="关闭设置"
          >
            <X aria-hidden size={15} />
          </button>
        </header>

        <div className="settings-body">
          <aside className="settings-sidebar">
            <div className="settings-search">
              <Search aria-hidden size={13} />
              <input
                type="search"
                placeholder="搜索设置…"
                aria-label="搜索设置"
                value={navQuery}
                onChange={(e) => setNavQuery(e.target.value)}
              />
            </div>
            <nav className="settings-nav" aria-label="设置分区">
              {visibleGroups.map((group) => (
                <div className="settings-nav-group" key={group.title}>
                  <div className="settings-nav-title">{group.title}</div>
                  {group.items.map((item) => {
                    const Icon = item.icon;
                    const warn =
                      item.id === "integrations" &&
                      integrationsWarn !== null &&
                      integrationsWarn > 0
                        ? integrationsWarn
                        : null;
                    return (
                      <button
                        key={item.id}
                        type="button"
                        className={
                          `settings-nav-item${section === item.id ? " active" : ""}` +
                          (item.pending ? " pending" : "")
                        }
                        aria-current={section === item.id ? "page" : undefined}
                        disabled={item.pending}
                        title={item.pending ? `${item.label} — 尚未实现` : undefined}
                        onClick={() => setSection(item.id)}
                      >
                        <Icon aria-hidden size={16} />
                        <span>{item.label}</span>
                        {warn !== null && (
                          <span
                            className="settings-nav-warn"
                            title={`${warn} 个集成未接入`}
                          >
                            {warn}
                          </span>
                        )}
                        {item.pending && <span className="nav-pending">待实现</span>}
                      </button>
                    );
                  })}
                </div>
              ))}
              {navQuery.trim() !== "" && visibleGroups.length === 0 && (
                <div className="settings-nav-empty">没有匹配的设置项</div>
              )}
            </nav>
          </aside>

          <main className="settings-main">
            {loading || !staged ? (
              <div className="settings-loading">读取设置中…</div>
            ) : (
              <div className="settings-content">
                {section === "general" && (
                  <GeneralSettings config={staged} onChange={setStaged} />
                )}
                {section === "sessions" && (
                  <SessionsSettings config={staged} onChange={setStaged} />
                )}
                {section === "agents" && (
                  <AgentsSettings config={staged} onChange={setStaged} />
                )}
                {section === "integrations" && <IntegrationsSettings />}
                {section === "appearance" && (
                  <AppearanceSettings config={staged} onChange={setStaged} />
                )}
                {section === "terminal" && (
                  <TerminalSettings config={staged} onChange={setStaged} />
                )}
                {section === "languages" && <LanguagesSettings />}
                {section === "usage" && <UsageSettings />}
                {section === "notifications" && (
                  <NotificationsSettings config={staged} onChange={setStaged} />
                )}
                {section === "data" && <DataSettings />}
                {section === "about" && <UpdatesSettings onClose={handleClose} />}
                {section === "panels" && <PanelsSettings />}
                {section === "keyboard" && <KeyboardSettings />}
              </div>
            )}
          </main>
        </div>

        <footer className="settings-footer">
          <button
            type="button"
            className="settings-reset"
            onClick={() => void handleReset()}
            disabled={saving || loading}
          >
            恢复默认
          </button>
          <span className="toolbar-spacer" />
          <button
            type="button"
            className="settings-action"
            onClick={() => void handleClose()}
            disabled={saving}
          >
            取消
          </button>
          <button
            type="button"
            className="settings-action primary"
            onClick={() => void handleSave()}
            disabled={!dirty || saving}
          >
            {saving ? "保存中…" : "保存"}
          </button>
        </footer>
      </section>
    </div>
  );
}

function sameConfig(a: ConfigView, b: ConfigView): boolean {
  return JSON.stringify(a) === JSON.stringify(b);
}

/// 按导航项标题(和组名)过滤左侧列表。匹配组名时整组保留 —— 搜「应用」
/// 应该给出该组全部四项,而不是空手而归。空查询原样返回。
function filterNavGroups(query: string): typeof NAV_GROUPS {
  const q = query.trim().toLowerCase();
  if (!q) return NAV_GROUPS;
  return NAV_GROUPS.map((group) => {
    if (group.title.toLowerCase().includes(q)) return group;
    const items = group.items.filter((item) =>
      item.label.toLowerCase().includes(q),
    );
    return { ...group, items };
  }).filter((group) => group.items.length > 0);
}
