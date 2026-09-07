// Settings → 会话:worktree 隔离、检查点、新会话落点。
//
// The rows that are live here all had their backing behaviour already —
// they were just hard-coded. The branch prefix was `format!("ycode/{id}")`
// in service.rs; the checkpoint cap didn't exist and now prunes on capture.
//
// The lifecycle group is deliberately inert. Reclaiming idle processes and
// auto-archiving are not settings, they are features with their own timers,
// resume semantics and failure modes — a switch that stores `true` and
// changes nothing would be worse than a greyed row that says why.

import type { TFunction } from "i18next";
import { useTranslation } from "react-i18next";
import type {
  CheckpointSettingsView,
  ConfigView,
  SessionOpenModeView,
  WorktreeCloseActionView,
  WorktreeSettingsView,
} from "../lib/types";
import {
  SettingSection,
  SettingCard,
  SettingChips,
  SettingGroupLabel,
  SettingRow,
  SettingToggle,
  SettingValue,
  type ChipOption,
} from "./ui/SettingControls";

interface Props {
  config: ConfigView;
  onChange: (next: ConfigView) => void;
}

/// 选项表存的是 `[值, 词条 key]`,渲染时才翻译 —— 模块级常量在 i18next
/// init 之前求值,直接存译文会把启动语言烙进去。`chips()` 是那一步转换。
///
/// 纯数字的档位(20 / 50)没有词条:它们在任何语言里都是同一个数字,
/// 为它们编一条词条只是给自己找一个可以译错的地方。
type Choice<T extends string> = readonly [value: T, labelKey: string];

function chips<T extends string>(
  choices: ReadonlyArray<Choice<T>>,
  t: TFunction,
): ReadonlyArray<ChipOption<T>> {
  return choices.map(([value, key]) => ({ value, label: t(key) }));
}

const CLOSE_CHOICES: ReadonlyArray<Choice<WorktreeCloseActionView>> = [
  ["ask", "settings.sessions.ask"],
  ["merge", "settings.sessions.merge"],
  ["discard", "settings.sessions.discard"],
];

const OPEN_MODE_CHOICES: ReadonlyArray<Choice<SessionOpenModeView>> = [
  ["replace_focused", "settings.sessions.replaceFocused"],
  ["new_pane", "settings.sessions.newPane"],
];

/// `null` is "keep everything" on the wire; the chip values are strings
/// because a picker's identity has to be a string.
function keepOptions(t: TFunction): ReadonlyArray<ChipOption<string>> {
  return [
    { value: "20", label: "20" },
    { value: "50", label: "50" },
    { value: "unlimited", label: t("common.unlimited") },
  ];
}

const IDLE_CHOICES: ReadonlyArray<Choice<string>> = [
  ["off", "common.off"],
  ["30m", "settings.sessions.idle30m"],
  ["2h", "settings.sessions.idle2h"],
];

const idleOptions = (t: TFunction) => chips(IDLE_CHOICES, t);

export function SessionsSettings({ config, onChange }: Props) {
  const { t } = useTranslation();
  function setWorktree<K extends keyof WorktreeSettingsView>(
    key: K,
    value: WorktreeSettingsView[K],
  ) {
    onChange({ ...config, worktree: { ...config.worktree, [key]: value } });
  }
  function setCheckpoints<K extends keyof CheckpointSettingsView>(
    key: K,
    value: CheckpointSettingsView[K],
  ) {
    onChange({
      ...config,
      checkpoints: { ...config.checkpoints, [key]: value },
    });
  }

  const keepValue =
    config.checkpoints.keep == null ? "unlimited" : String(config.checkpoints.keep);

  return (
    <SettingSection
      title={t("settings.sessions.title")}
      lede={<>{t("settings.sessions.lede")}</>}
    >
      <SettingGroupLabel>{t("settings.sessions.lifecycle")}</SettingGroupLabel>
      <SettingCard>
        <SettingRow
          name={t("settings.sessions.keepPty")}
          desc={t("settings.sessions.keepPtyDesc")}
          pendingReason={t("settings.sessions.keepPtyPending")}
        >
          <SettingToggle label={t("settings.sessions.keepPty")} checked={false} disabled />
        </SettingRow>
        <SettingRow
          name={t("settings.sessions.reapIdle")}
          desc={t("settings.sessions.reapIdleDesc")}
          pendingReason={t("settings.sessions.reapIdlePending")}
        >
          <SettingChips
            label={t("settings.sessions.reapIdle")}
            options={idleOptions(t)}
            value="off"
            disabled
          />
        </SettingRow>
        <SettingRow
          name={t("settings.sessions.autoArchive")}
          desc={t("settings.sessions.autoArchiveDesc")}
          pendingReason={t("settings.sessions.autoArchivePending")}
        >
          <SettingChips
            label={t("settings.sessions.autoArchive")}
            options={idleOptions(t)}
            value="off"
            disabled
          />
        </SettingRow>
      </SettingCard>

      <SettingGroupLabel>{t("settings.sessions.worktreeIsolation")}</SettingGroupLabel>
      <SettingCard>
        <SettingRow
          name={t("settings.sessions.isolateNew")}
          desc={t("settings.sessions.isolateNewDesc")}
        >
          <SettingToggle
            label={t("settings.sessions.isolateNew")}
            checked={config.worktree.isolate_by_default}
            onChange={(v) => setWorktree("isolate_by_default", v)}
          />
        </SettingRow>
        <SettingRow
          name={t("settings.sessions.branchPrefix")}
          desc={t("settings.sessions.branchPrefixDesc")}
        >
          <input
            className="flex-none w-[150px] h-control-sm px-2 border border-rule rounded-sm bg-panel text-text font-mono text-[11.5px] outline-none transition-colors duration-[var(--t-fast)] ease-smooth hover:border-rule-strong focus:border-accent placeholder:text-subtle"
            value={config.worktree.branch_prefix}
            spellCheck={false}
            aria-label={t("settings.sessions.branchPrefix")}
            placeholder="ycode/"
            onChange={(e) => setWorktree("branch_prefix", e.target.value)}
          />
        </SettingRow>
        <SettingRow name={t("settings.sessions.onCloseWorktree")}>
          <SettingChips
            label={t("settings.sessions.onCloseWorktree")}
            options={chips(CLOSE_CHOICES, t)}
            value={config.worktree.close_action}
            onChange={(v) => setWorktree("close_action", v)}
          />
        </SettingRow>
        <SettingRow
          name={t("settings.sessions.symlinkShared")}
          desc={t("settings.sessions.symlinkSharedDesc")}
          pendingReason={t("settings.sessions.postCreatePending")}
        >
          <SettingValue>node_modules · .venv · target</SettingValue>
        </SettingRow>
        <SettingRow
          name={t("settings.sessions.postCreate")}
          desc={t("settings.sessions.postCreateDesc")}
          pendingReason={t("settings.sessions.postCreatePending")}
        >
          <SettingValue>—</SettingValue>
        </SettingRow>
      </SettingCard>

      <SettingGroupLabel>{t("settings.sessions.checkpoints")}</SettingGroupLabel>
      <SettingCard>
        <SettingRow
          name={t("settings.sessions.autoCheckpoint")}
          desc={t("settings.sessions.autoCheckpointDesc")}
        >
          <SettingToggle
            label={t("settings.sessions.autoCheckpoint")}
            checked={config.checkpoints.enabled}
            onChange={(v) => setCheckpoints("enabled", v)}
          />
        </SettingRow>
        <SettingRow
          name={t("settings.sessions.keepPerSession")}
          desc={t("settings.sessions.keepPerSessionDesc")}
        >
          <SettingChips
            label={t("settings.sessions.keepPerSession")}
            options={keepOptions(t)}
            value={keepValue}
            disabled={!config.checkpoints.enabled}
            onChange={(v) =>
              setCheckpoints("keep", v === "unlimited" ? null : Number(v))
            }
          />
        </SettingRow>
      </SettingCard>

      <SettingGroupLabel>{t("settings.sessions.defaultLayout")}</SettingGroupLabel>
      <SettingCard>
        <SettingRow
          name={t("settings.sessions.openFromSidebar")}
          desc={t("settings.sessions.openFromSidebarDesc")}
        >
          <SettingChips
            label={t("settings.sessions.openFromSidebar")}
            options={chips(OPEN_MODE_CHOICES, t)}
            value={config.session_open_mode}
            onChange={(session_open_mode) =>
              onChange({ ...config, session_open_mode })
            }
          />
        </SettingRow>
      </SettingCard>
    </SettingSection>
  );
}
