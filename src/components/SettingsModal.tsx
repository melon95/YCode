// Standalone settings workspace. The component keeps the existing staged
// config lifecycle, but presents it as a first-class screen instead of a
// modal layered over the coding workspace.

import { useEffect, useRef, useState } from "react";
import { IconButton } from "./ui/IconButton";
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
import { toast } from "../lib/toast";
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

/// 页脚的取消 / 保存。两颗只差配色,几何必须一致 —— 分开写迟早会飘。
const FOOTER_ACTION = `min-w-[102px] min-h-[38px] px-[18px] border rounded-sm
  text-[13px] font-[560] cursor-pointer
  transition-[background-color,border-color,color] duration-[var(--t-fast)] ease-smooth
  disabled:cursor-default disabled:opacity-42`.replace(/\s+/g, " ");

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
      className="fixed inset-0 z-180 flex items-center justify-center
        bg-[rgba(0,0,0,0.22)] backdrop-blur-[10px] animate-fade-in"
      onMouseDown={(e) => {
        if (e.target === e.currentTarget) void handleClose();
      }}
    >
      <section
        className="w-[900px] max-w-[92vw] h-[640px] max-h-[86vh] flex flex-col
          bg-panel border border-rule-strong rounded-2xl shadow-menu
          overflow-hidden animate-dialog-in"
        aria-label="设置"
        role="dialog"
        aria-modal
      >
        <header className="flex-none h-toolbar flex items-center gap-[9px] pr-3 pl-4 border-b border-rule">
          <span className="text-[13px] font-semibold text-text">设置</span>
          <span className="flex-auto" />
          <span
            className={`text-[13px] ${dirty ? "text-accent-soft" : "text-muted"}`}
          >
            {dirty ? "有未保存的更改" : ""}
          </span>
          <IconButton
            size="sm"
            onClick={() => void handleClose()}
            title="关闭 (esc)"
            aria-label="关闭设置"
          >
            <X aria-hidden size={15} />
          </IconButton>
        </header>

        <div className="flex-1 min-h-0 flex">
          <aside className="w-[210px] flex-none border-r border-rule pt-3 px-2.5 pb-[18px] overflow-y-auto bg-surface">
            <div
              className="flex items-center gap-2 mb-3 py-[7px] px-2.5 border border-rule
                rounded-[9px] text-whisper
                transition-colors duration-[var(--t-fast)] ease-smooth
                focus-within:border-rule-strong [&>svg]:flex-none"
            >
              <Search aria-hidden size={13} />
              {/* WebKit 给 type=search 自带一个清除小叉,和描边风格打架。 */}
              <input
                type="search"
                className="flex-1 min-w-0 bg-none border-none outline-none text-text text-[12.5px]
                  placeholder:text-whisper
                  [&::-webkit-search-cancel-button]:hidden"
                placeholder="搜索设置…"
                aria-label="搜索设置"
                value={navQuery}
                onChange={(e) => setNavQuery(e.target.value)}
              />
            </div>
            <nav aria-label="设置分区">
              {visibleGroups.map((group) => (
                <div className="[&+&]:mt-3.5" key={group.title}>
                  <div className="pt-1 px-2.5 pb-1.5 text-[8.5px] font-bold tracking-caps uppercase text-whisper">
                    {group.title}
                  </div>
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
                        className={`w-full flex items-center gap-2.5 py-[7px] px-2.5 border-none
                          rounded-md text-[12.5px] text-left cursor-pointer
                          transition-[background-color,color] duration-[var(--t-fast)] ease-smooth
                          not-disabled:hover:bg-panel-raised not-disabled:hover:text-text
                          disabled:opacity-45 disabled:cursor-not-allowed ${
                            section === item.id
                              ? "bg-panel-raised text-text font-semibold"
                              : "bg-transparent text-muted"
                          }`
                          .replace(/\s+/g, " ")
                          .trim()}
                        aria-current={section === item.id ? "page" : undefined}
                        disabled={item.pending}
                        title={item.pending ? `${item.label} — 尚未实现` : undefined}
                        onClick={() => setSection(item.id)}
                      >
                        <Icon aria-hidden size={16} />
                        <span>{item.label}</span>
                        {/* 未接入集成的计数角标。用 working 琥珀色 ——
                            它是「有事待办」,不是 blocked 那种「正在拦着你」。 */}
                        {warn !== null && (
                          <span
                            className="ml-auto font-mono text-[8px] font-bold
                              bg-st-working-badge text-st-working rounded-[99px] py-[1.5px] px-[5.5px]"
                            title={`${warn} 个集成未接入`}
                          >
                            {warn}
                          </span>
                        )}
                        {item.pending && (
                          <span className="ml-auto font-mono text-[8px] text-whisper border border-rule rounded-[4px] py-px px-1">
                            待实现
                          </span>
                        )}
                      </button>
                    );
                  })}
                </div>
              ))}
              {/* 过滤后一无所有时的占位,免得侧栏空得像坏了。 */}
              {navQuery.trim() !== "" && visibleGroups.length === 0 && (
                <div className="p-2.5 text-[12px] text-whisper">没有匹配的设置项</div>
              )}
            </nav>
          </aside>

          <main className="flex-1 min-w-0 overflow-y-auto">
            {loading || !staged ? (
              <div className="p-[60px] text-center font-display italic text-[16px] text-subtle [font-variation-settings:'opsz'_36,'SOFT'_100]">
                读取设置中…
              </div>
            ) : (
              <div className="pt-[22px] px-[26px] pb-[30px]">
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

        <footer className="flex-none flex items-center gap-2 py-2.5 px-4 border-t border-rule bg-surface">
          <button
            type="button"
            className={`justify-self-start min-h-[34px] px-2.5 rounded-sm border-0 bg-transparent
              text-muted text-[13px] cursor-pointer
              not-disabled:hover:text-text not-disabled:hover:bg-control-hover
              disabled:cursor-default disabled:opacity-42`
              .replace(/\s+/g, " ")}
            onClick={() => void handleReset()}
            disabled={saving || loading}
          >
            恢复默认
          </button>
          <span className="flex-auto" />
          <button
            type="button"
            className={`${FOOTER_ACTION} border-rule-strong bg-surface text-text-soft
              not-disabled:hover:text-text not-disabled:hover:bg-control-hover`
              .replace(/\s+/g, " ")}
            onClick={() => void handleClose()}
            disabled={saving}
          >
            取消
          </button>
          <button
            type="button"
            // `#07101f` 是迁移前就写死在 design-system.css 里的字面量,不是
            // `--text-on-accent`(白)。原样保留 —— 换成令牌会把这颗按钮的
            // 文字从深靛蓝变成白色,是视觉改动,不该混在这次迁移里。
            className={`${FOOTER_ACTION} border-accent bg-accent text-[#07101f]
              not-disabled:hover:border-accent-strong not-disabled:hover:bg-accent-strong
              not-disabled:hover:text-[#07101f]
              disabled:border-rule-strong disabled:bg-panel-raised disabled:text-muted`
              .replace(/\s+/g, " ")}
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
