// Two settings pages introduced by the redesign.
//
// Both are read-only. That's deliberate: the underlying features
// (rebindable hotkeys, installable panels) don't exist yet, and a page that
// honestly lists what *is* wired beats either an empty section or a set of
// controls that silently do nothing.

import {
  FolderTree,
  GitCompare,
  Globe,
  ListChecks,
  TerminalSquare,
  type LucideIcon,
} from "lucide-react";
import {
  SettingSection,
  SettingCard,
  SettingChip,
  SettingGroupLabel,
  SettingNote,
  SettingRow,
} from "./ui/SettingControls";

interface PanelRow {
  icon: LucideIcon;
  name: string;
  desc: string;
  state: "builtin" | "on" | "pending";
}

const PANELS: PanelRow[] = [
  {
    icon: TerminalSquare,
    name: "终端",
    desc: "在项目目录里开一个 shell",
    state: "builtin",
  },
  {
    icon: FolderTree,
    name: "文件",
    desc: "文件树 · CodeMirror 编辑器 · LSP",
    state: "on",
  },
  {
    icon: GitCompare,
    name: "变更",
    desc: "工作区 diff · 检查点回顾",
    state: "on",
  },
  {
    icon: ListChecks,
    name: "待办",
    desc: "项目待办 · agent 可经 MCP 读写",
    state: "on",
  },
  {
    icon: Globe,
    name: "浏览器",
    desc: "预览本地 dev server",
    state: "pending",
  },
];

export function PanelsSettings() {
  return (
    <SettingSection
      title="面板"
      lede={
        <>
  右侧工作面板。终端是内置面板;面板可以同时打开并堆叠,每个项目记住自己
          的组合。
        </>
      }
    >
      <SettingCard>
        {PANELS.map((p) => {
          const Icon = p.icon;
          return (
            <SettingRow
              key={p.name}
              name={p.name}
              desc={p.desc}
              icon={<Icon aria-hidden size={15} />}
              pendingReason={
                p.state === "pending" ? "浏览器面板尚未实现" : undefined
              }
            >
              {p.state === "builtin" && <SettingChip>内置</SettingChip>}
              {p.state === "on" && <SettingChip tone="on">已启用</SettingChip>}
            </SettingRow>
          );
        })}
      </SettingCard>
      <SettingNote>
        面板可插拔:未实现的条目会在支持后自动出现在画布工具条的开关里,
        不需要另行启用。
      </SettingNote>
    </SettingSection>
  );
}

/// Mirrors `lib/hotkeys.tsx`. Kept as a hand-maintained list rather than
/// derived from the handler, because the handler is a switch over key codes
/// with no table to read — deriving it would mean restructuring working code
/// for a display concern.
const SHORTCUT_GROUPS: Array<{
  title: string;
  items: Array<{ keys: string; label: string }>;
}> = [
  {
    title: "全局",
    items: [
      { keys: "⌘K", label: "命令面板 · 跨会话搜索" },
      { keys: "⌘O", label: "打开项目" },
      { keys: "⇧⌘P", label: "项目总览" },
      { keys: "⇧⌘A", label: "等你处理收件箱" },
      { keys: "⌘,", label: "设置" },
    ],
  },
  {
    title: "会话",
    items: [
      { keys: "⌘N", label: "用当前 agent 新建会话" },
      { keys: "⇧⌘N", label: "打开新建会话选择器" },
      { keys: "⌘T", label: "用第一个可用 agent 新建会话" },
      { keys: "⌘W", label: "归档当前会话(需确认)" },
      { keys: "⌘[ / ⌘]", label: "上一个 / 下一个会话" },
      { keys: "⇧⌘[ / ⇧⌘]", label: "上一个 / 下一个项目" },
    ],
  },
  {
    title: "布局",
    items: [
      { keys: "⌘B", label: "显示 / 隐藏会话列表" },
      { keys: "⇧⌘B", label: "显示 / 隐藏右侧面板" },
      { keys: "⌘J", label: "聚焦右侧终端" },
      { keys: "⌘1 – ⌘4", label: "切换右侧面板" },
      { keys: "⇧⌘1 – ⇧⌘4", label: "聚焦第 N 个 agent 面板" },
    ],
  },
];

export function KeyboardSettings() {
  return (
    <SettingSection title="键盘快捷键" lede={<>当前生效的绑定。重新绑定尚未实现。</>}>
      {SHORTCUT_GROUPS.map((group) => (
        <div className="settings-group" key={group.title}>
          <SettingGroupLabel>{group.title}</SettingGroupLabel>
          <SettingCard>
            {group.items.map((s) => (
              <SettingRow key={s.keys} name={s.label}>
                <kbd className="flex-none font-mono text-[10.5px] text-text-soft border border-rule-strong border-b-2 rounded-[5px] py-0.5 px-[7px] bg-panel">{s.keys}</kbd>
              </SettingRow>
            ))}
          </SettingCard>
        </div>
      ))}
    </SettingSection>
  );
}
