// Settings → 关于:版本、更新、这个应用是什么。
//
// The background check on startup is owned by `UpdateNotice`; the button
// here covers the "I think there's a new version, let me look right now"
// case and surfaces the errors (offline, malformed feed) that the silent
// path swallows.

import { useEffect, useState } from "react";
import { Trans, useTranslation } from "react-i18next";
import { i18next } from "../lib/i18n";
import { toast } from "../lib/toast";
import { getVersion, getTauriVersion } from "@tauri-apps/api/app";
import { checkForUpdate } from "../lib/updater";
import { openUrl } from "../lib/ipc";
import {
  SettingSection,
  SettingAction,
  SettingCard,
  SettingChips,
  SettingGroupLabel,
  SettingNote,
  SettingRow,
  SettingToggle,
  SettingValue,
} from "./ui/SettingControls";

const REPO_URL = "https://github.com/melon95/YCode";
/// 每个 tag 的发布说明就是更新日志 —— 复用 GitHub Releases,不自己再造一页。
const RELEASES_URL = `${REPO_URL}/releases`;

export function UpdatesSettings({ onClose }: { onClose: () => void }) {
  const { t } = useTranslation();
  const [current, setCurrent] = useState<string>("…");
  const [tauri, setTauri] = useState<string>("…");
  const [checking, setChecking] = useState(false);

  useEffect(() => {
    let cancelled = false;
    getVersion()
      .then((v) => !cancelled && setCurrent(v))
      .catch(() => !cancelled && setCurrent(i18next.t("settings.about.unknown")));
    getTauriVersion()
      .then((v) => !cancelled && setTauri(v))
      .catch(() => !cancelled && setTauri(i18next.t("settings.about.unknown")));
    return () => {
      cancelled = true;
    };
  }, []);

  async function onCheck() {
    if (checking) return;
    setChecking(true);
    try {
      const update = await checkForUpdate();
      if (!update) {
        toast.success(t("settings.about.upToDate"));
        return;
      }
      // Reuse the same notice card rendered by `UpdateNotice` instead of
      // duplicating the install flow inside Settings. No extra toast here —
      // the card already announces the version and owns the install action.
      window.dispatchEvent(
        new CustomEvent("ycode:update-available", { detail: update }),
      );
      // Close Settings before the notice card appears. `UpdateNotice` renders
      // outside this modal's DOM subtree, so with Settings still open the first
      // click on "Install & restart" is judged an outside-press and merely
      // dismisses the modal — forcing a second click to actually install.
      onClose();
    } catch (err) {
      toast.danger(t("settings.about.checkFailed", { error: err }));
    } finally {
      setChecking(false);
    }
  }

  return (
    <SettingSection
      title={t("settings.about.title")}
      lede={
        <>
          {t("settings.about.lede")}
        </>
      }
    >
      <SettingGroupLabel>{t("settings.about.version")}</SettingGroupLabel>
      <SettingCard>
        <SettingRow name="ycode" desc={t("settings.about.ycodeDesc")}>
          <SettingValue align="end">v{current}</SettingValue>
          <SettingAction
            label={t("settings.about.checkUpdates")}
            disabled={checking}
            onClick={() => void onCheck()}
          >
            <RefreshIcon />
          </SettingAction>
        </SettingRow>
        <SettingRow name="Tauri">
          <SettingValue align="end">v{tauri}</SettingValue>
        </SettingRow>
        <SettingRow
          name={t("settings.about.channel")}
          desc={t("settings.about.channelDesc")}
          pendingReason={t("settings.about.channelPending")}
        >
          <SettingChips
            label={t("settings.about.channel")}
            options={[
              { value: "stable", label: t("settings.about.stable") },
              // 「Beta」是通道的名字,不翻译 —— 各语言都这么叫。
              { value: "beta", label: "Beta" },
            ]}
            value="stable"
            disabled
          />
        </SettingRow>
        <SettingRow
          name={t("settings.about.autoDownload")}
          desc={t("settings.about.autoDownloadDesc")}
          pendingReason={t("settings.about.autoDownloadPending")}
        >
          <SettingToggle label={t("settings.about.autoDownload")} checked={false} disabled />
        </SettingRow>
      </SettingCard>

      <SettingGroupLabel>{t("settings.about.project")}</SettingGroupLabel>
      <SettingCard>
        <SettingRow
          name={t("settings.about.changelog")}
          desc={t("settings.about.changelogDesc")}
        >
          <SettingAction
            label={t("settings.about.openChangelog")}
            onClick={() => {
              void openUrl(RELEASES_URL);
            }}
          >
            <ExternalIcon />
          </SettingAction>
        </SettingRow>
        <SettingRow
          name={t("settings.about.licenses")}
          desc={t("settings.about.licensesDesc")}
          pendingReason={t("settings.about.licensesPending")}
        >
          <SettingAction label={t("settings.about.viewLicenses")} disabled>
            <ExternalIcon />
          </SettingAction>
        </SettingRow>
        <SettingRow name={t("settings.about.repo")} desc={REPO_URL}>
          <SettingAction
            label={t("settings.about.openRepo")}
            onClick={() => {
              void openUrl(REPO_URL);
            }}
          >
            <ExternalIcon />
          </SettingAction>
        </SettingRow>
      </SettingCard>
      <SettingNote>
        <Trans i18nKey="settings.about.networkNote" components={{ 1: <b /> }} />
      </SettingNote>
    </SettingSection>
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
function ExternalIcon() {
  return (
    <svg width="15" height="15" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="1.9" strokeLinecap="round" strokeLinejoin="round" aria-hidden>
      <path d="M18 13v6a2 2 0 0 1-2 2H5a2 2 0 0 1-2-2V8a2 2 0 0 1 2-2h6" />
      <path d="M15 3h6v6M10 14 21 3" />
    </svg>
  );
}
