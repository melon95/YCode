// Two settings pages introduced by the redesign.
//
// Both are read-only. That's deliberate: the underlying features
// (rebindable hotkeys, installable panels) don't exist yet, and a page that
// honestly lists what *is* wired beats either an empty section or a set of
// controls that silently do nothing.

import { useTranslation } from "react-i18next";
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
  /// 词条 key —— PANELS 是模块级常量,在 i18next init 之前求值。
  nameKey: string;
  descKey: string;
  state: "builtin" | "on" | "pending";
}

const PANELS: PanelRow[] = [
  {
    icon: TerminalSquare,
    nameKey: "panels.terminal",
    descKey: "panels.terminalDesc",
    state: "builtin",
  },
  {
    icon: FolderTree,
    nameKey: "panels.files",
    descKey: "settings.panels.filesDesc",
    state: "on",
  },
  {
    icon: GitCompare,
    nameKey: "panels.changes",
    descKey: "panels.changesDesc",
    state: "on",
  },
  {
    icon: ListChecks,
    nameKey: "panels.todos",
    descKey: "panels.todosDesc",
    state: "on",
  },
  {
    icon: Globe,
    nameKey: "panels.browser",
    descKey: "panels.browserDesc",
    state: "pending",
  },
];

export function PanelsSettings() {
  const { t } = useTranslation();
  return (
    <SettingSection
      title={t("settings.panels.title")}
      lede={
        <>
          {t("settings.panels.lede")}
        </>
      }
    >
      <SettingCard>
        {PANELS.map((p) => {
          const Icon = p.icon;
          return (
            <SettingRow
              key={p.nameKey}
              name={t(p.nameKey)}
              desc={t(p.descKey)}
              icon={<Icon aria-hidden size={15} />}
              pendingReason={
                p.state === "pending" ? t("settings.panels.browserPending") : undefined
              }
            >
              {p.state === "builtin" && <SettingChip>{t("toolbar.builtin")}</SettingChip>}
              {p.state === "on" && <SettingChip tone="on">{t("common.enabled")}</SettingChip>}
            </SettingRow>
          );
        })}
      </SettingCard>
      <SettingNote>
        {t("settings.panels.footnote")}
      </SettingNote>
    </SettingSection>
  );
}

/// Mirrors `lib/hotkeys.tsx`. Kept as a hand-maintained list rather than
/// derived from the handler, because the handler is a switch over key codes
/// with no table to read — deriving it would mean restructuring working code
/// for a display concern.
const SHORTCUT_GROUPS: Array<{
  titleKey: string;
  items: Array<{ keys: string; labelKey: string }>;
}> = [
  {
    titleKey: "settings.keyboard.groupGlobal",
    items: [
      { keys: "⌘K", labelKey: "settings.keyboard.palette" },
      { keys: "⌘O", labelKey: "settings.keyboard.openProject" },
      { keys: "⇧⌘P", labelKey: "settings.keyboard.overview" },
      { keys: "⇧⌘A", labelKey: "settings.keyboard.inbox" },
      { keys: "⌘,", labelKey: "settings.keyboard.settings" },
    ],
  },
  {
    titleKey: "settings.keyboard.groupSession",
    items: [
      { keys: "⌘N", labelKey: "settings.keyboard.newWithCurrent" },
      { keys: "⇧⌘N", labelKey: "settings.keyboard.openPicker" },
      { keys: "⌘T", labelKey: "settings.keyboard.newWithFirst" },
      { keys: "⌘W", labelKey: "settings.keyboard.archiveCurrent" },
      { keys: "⌘[ / ⌘]", labelKey: "settings.keyboard.prevNextSession" },
      { keys: "⇧⌘[ / ⇧⌘]", labelKey: "settings.keyboard.prevNextProject" },
    ],
  },
  {
    titleKey: "settings.keyboard.groupLayout",
    items: [
      { keys: "⌘B", labelKey: "settings.keyboard.toggleSidebar" },
      { keys: "⇧⌘B", labelKey: "settings.keyboard.toggleRight" },
      { keys: "⌘J", labelKey: "settings.keyboard.focusTerminal" },
      { keys: "⌘1 – ⌘4", labelKey: "settings.keyboard.switchPanel" },
      { keys: "⇧⌘1 – ⇧⌘4", labelKey: "settings.keyboard.focusNthPane" },
    ],
  },
];

export function KeyboardSettings() {
  const { t } = useTranslation();
  return (
    <SettingSection
      title={t("settings.keyboard.title")}
      lede={<>{t("settings.keyboard.lede")}</>}
    >
      {SHORTCUT_GROUPS.map((group) => (
        <div className="settings-group" key={group.titleKey}>
          <SettingGroupLabel>{t(group.titleKey)}</SettingGroupLabel>
          <SettingCard>
            {group.items.map((s) => (
              <SettingRow key={s.keys} name={t(s.labelKey)}>
                <kbd className="flex-none font-mono text-[10.5px] text-text-soft border border-rule-strong border-b-2 rounded-[5px] py-0.5 px-[7px] bg-panel">{s.keys}</kbd>
              </SettingRow>
            ))}
          </SettingCard>
        </div>
      ))}
    </SettingSection>
  );
}
