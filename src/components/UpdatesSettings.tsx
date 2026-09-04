// Settings → 关于:版本、更新、这个应用是什么。
//
// The background check on startup is owned by `UpdateNotice`; the button
// here covers the "I think there's a new version, let me look right now"
// case and surfaces the errors (offline, malformed feed) that the silent
// path swallows.

import { useEffect, useState } from "react";
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
  const [current, setCurrent] = useState<string>("…");
  const [tauri, setTauri] = useState<string>("…");
  const [checking, setChecking] = useState(false);

  useEffect(() => {
    let cancelled = false;
    getVersion()
      .then((v) => !cancelled && setCurrent(v))
      .catch(() => !cancelled && setCurrent("未知"));
    getTauriVersion()
      .then((v) => !cancelled && setTauri(v))
      .catch(() => !cancelled && setTauri("未知"));
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
        toast.success("已是最新版本");
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
      toast.danger(`检查更新失败:${err}`);
    } finally {
      setChecking(false);
    }
  }

  return (
    <SettingSection
      title="关于"
      lede={
        <>
  ycode 是一个通用的 AI CLI 工作台 —— 把 agent CLI 原样跑在 PTY 里,
          围绕它补上多会话、worktree 隔离、检查点与跨项目视图。
        </>
      }
    >
      <SettingGroupLabel>版本</SettingGroupLabel>
      <SettingCard>
        <SettingRow name="ycode" desc="启动几秒后会自动检查一次更新">
          <SettingValue align="end">v{current}</SettingValue>
          <SettingAction
            label="检查更新"
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
          name="更新通道"
          desc="Beta 更早拿到新功能,可能不稳定"
          pendingReason="更新器只有稳定版一个源,通道切换未实现"
        >
          <SettingChips
            label="更新通道"
            options={[
              { value: "stable", label: "稳定版" },
              { value: "beta", label: "Beta" },
            ]}
            value="stable"
            disabled
          />
        </SettingRow>
        <SettingRow
          name="自动下载更新"
          desc="发现新版本时后台下载,重启即生效"
          pendingReason="更新器目前只提示不下载,自动下载未实现"
        >
          <SettingToggle label="自动下载更新" checked={false} disabled />
        </SettingRow>
      </SettingCard>

      <SettingGroupLabel>项目</SettingGroupLabel>
      <SettingCard>
        <SettingRow name="更新日志" desc="每个版本的发布说明,在 GitHub Releases 上">
          <SettingAction
            label="在浏览器中打开更新日志"
            onClick={() => {
              void openUrl(RELEASES_URL);
            }}
          >
            <ExternalIcon />
          </SettingAction>
        </SettingRow>
        <SettingRow
          name="开源许可"
          desc="ycode 用到的第三方依赖及其许可证"
          pendingReason="许可清单页未生成"
        >
          <SettingAction label="查看开源许可" disabled>
            <ExternalIcon />
          </SettingAction>
        </SettingRow>
        <SettingRow name="源码仓库" desc={REPO_URL}>
          <SettingAction
            label="在浏览器中打开仓库"
            onClick={() => {
              void openUrl(REPO_URL);
            }}
          >
            <ExternalIcon />
          </SettingAction>
        </SettingRow>
      </SettingCard>
      <SettingNote>
        检查更新是 ycode 唯一的出网请求。其余数据都留在本机 —— 见
        <b>「数据与隐私」</b>。
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
