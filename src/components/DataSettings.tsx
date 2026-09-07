// Settings → 数据与隐私。
//
// Mostly a read-only page, and that is the point: the honest answer to
// "what does ycode keep about me" is a list of paths on this machine. The
// preview drew telemetry toggles here; ycode collects nothing, so a pair of
// permanently-off switches would imply a capability that doesn't exist.
// The page states the fact instead.

import { useEffect, useState } from "react";
import { Trans, useTranslation } from "react-i18next";
import { appDataDir } from "@tauri-apps/api/path";
import { useStore } from "../lib/store";
import { revealInFinder } from "../lib/ipc";
import {
  chips,
  SettingSection,
  SettingAction,
  SettingCard,
  SettingChip,
  SettingChips,
  SettingGroupLabel,
  SettingNote,
  SettingRow,
  SettingValue,
} from "./ui/SettingControls";

/// Which transcript directory each introspect parser scans. Mirrors the
/// scanners in `ycode-introspect` — these are read-only reads of the agent's
/// own files, never writes.
const TRANSCRIPT_DIR: Record<string, string> = {
  claude: "~/.claude",
  codex: "~/.codex",
};

export function DataSettings() {
  const { t } = useTranslation();
  const [dataDir, setDataDir] = useState<string | null>(null);
  const sessions = useStore((s) => s.sessions);
  const projects = useStore((s) => s.projects);
  const agents = useStore((s) => s.agents);

  useEffect(() => {
    let cancelled = false;
    appDataDir()
      .then((d) => {
        if (!cancelled) setDataDir(d);
      })
      // Outside Tauri (tests) the path API throws; the row just stays on its
      // placeholder rather than taking the page down.
      .catch(() => {});
    return () => {
      cancelled = true;
    };
  }, []);

  const sessionCount = Object.keys(sessions).length;
  const projectCount = Object.keys(projects).length;
  const transcriptDirs = [
    ...new Set(
      agents
        .map((a) => a.introspect && TRANSCRIPT_DIR[a.introspect])
        .filter((d): d is string => Boolean(d)),
    ),
  ];

  return (
    <SettingSection
      title={t("settings.data.title")}
      lede={<>{t("settings.data.lede")}</>}
    >
      <SettingGroupLabel>{t("settings.data.localStorage")}</SettingGroupLabel>
      <SettingCard>
        <SettingRow
          name={t("settings.data.appData")}
          desc={t("settings.data.appDataDesc")}
        >
          <SettingValue align="end" title={dataDir ?? undefined}>
            {dataDir ?? t("settings.data.reading")}
          </SettingValue>
          <SettingAction
            label={t("settings.data.revealInFinder")}
            disabled={!dataDir}
            onClick={
              dataDir
                ? () => {
                    void revealInFinder(dataDir);
                  }
                : undefined
            }
          >
            <FolderIcon />
          </SettingAction>
        </SettingRow>
        <SettingRow
          name={t("settings.data.transcriptSource")}
          desc={t("settings.data.transcriptSourceDesc")}
        >
          <SettingValue align="end">
            {transcriptDirs.length > 0 ? transcriptDirs.join(" · ") : "—"}
          </SettingValue>
        </SettingRow>
        <SettingRow
          name={t("settings.data.indexed")}
          desc={t("settings.data.indexedDesc")}
        >
          <SettingValue align="end">
            {t("settings.data.indexedCount", {
              sessions: sessionCount,
              projects: projectCount,
            })}
          </SettingValue>
        </SettingRow>
        <SettingRow
          name={t("settings.data.searchIndex")}
          desc={t("settings.data.searchIndexDesc")}
          pendingReason={t("settings.data.searchIndexPending")}
        >
          <SettingAction label={t("settings.data.rebuildIndex")} disabled>
            <RefreshIcon />
          </SettingAction>
        </SettingRow>
      </SettingCard>

      <SettingGroupLabel>{t("settings.data.retention")}</SettingGroupLabel>
      <SettingCard>
        <SettingRow
          name={t("settings.data.historyRetention")}
          desc={t("settings.data.historyRetentionDesc")}
          pendingReason={t("settings.data.historyRetentionPending")}
        >
          <SettingChips
            label={t("settings.data.historyRetention")}
            options={chips(
              [
                ["90d", "settings.data.days90"],
                ["1y", "settings.data.year1"],
                ["forever", "common.permanent"],
              ],
              t,
            )}
            value="forever"
            disabled
          />
        </SettingRow>
      </SettingCard>
      <SettingNote>
        <Trans i18nKey="settings.data.checkpointNote" components={{ 1: <b /> }} />
      </SettingNote>

      <SettingGroupLabel>{t("settings.data.telemetry")}</SettingGroupLabel>
      <SettingCard>
        <SettingRow
          name={t("settings.data.anonymousStats")}
          desc={t("settings.data.anonymousStatsDesc")}
        >
          <SettingChip tone="on">{t("settings.data.notCollected")}</SettingChip>
        </SettingRow>
        <SettingRow
          name={t("settings.data.crashReports")}
          desc={t("settings.data.crashReportsDesc")}
        >
          <SettingChip tone="on">{t("settings.data.notCollected")}</SettingChip>
        </SettingRow>
      </SettingCard>
      <SettingNote>
        <Trans i18nKey="settings.data.networkNote" components={{ 1: <b /> }} />
      </SettingNote>

      <SettingGroupLabel>{t("settings.data.cleanup")}</SettingGroupLabel>
      <SettingCard tone="danger">
        <SettingRow
          name={t("settings.data.clearAll")}
          desc={t("settings.data.clearAllDesc")}
          pendingReason={t("settings.data.clearAllPending")}
        >
          <SettingAction label={t("settings.data.clearAll")} tone="danger" disabled>
            <TrashIcon />
          </SettingAction>
        </SettingRow>
      </SettingCard>
    </SettingSection>
  );
}

function FolderIcon() {
  return (
    <svg width="15" height="15" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="1.9" strokeLinecap="round" strokeLinejoin="round" aria-hidden>
      <path d="M3 7a2 2 0 0 1 2-2h4l2 2h8a2 2 0 0 1 2 2v8a2 2 0 0 1-2 2H5a2 2 0 0 1-2-2z" />
    </svg>
  );
}
function TrashIcon() {
  return (
    <svg width="15" height="15" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="1.9" strokeLinecap="round" strokeLinejoin="round" aria-hidden>
      <path d="M3 6h18M8 6V4a1 1 0 0 1 1-1h6a1 1 0 0 1 1 1v2" />
      <path d="M19 6l-1 14a2 2 0 0 1-2 2H8a2 2 0 0 1-2-2L5 6" />
      <path d="M10 11v6M14 11v6" />
    </svg>
  );
}
function RefreshIcon() {
  return (
    <svg width="15" height="15" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="1.9" strokeLinecap="round" strokeLinejoin="round" aria-hidden>
      <path d="M21 12a9 9 0 1 1-3-6.7" />
      <path d="M21 4v5h-5" />
    </svg>
  );
}
