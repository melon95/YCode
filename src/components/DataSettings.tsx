// Settings → 数据与隐私。
//
// Mostly a read-only page, and that is the point: the honest answer to
// "what does ycode keep about me" is a list of paths on this machine. The
// preview drew telemetry toggles here; ycode collects nothing, so a pair of
// permanently-off switches would imply a capability that doesn't exist.
// The page states the fact instead.

import { useEffect, useState } from "react";
import { appDataDir } from "@tauri-apps/api/path";
import { useStore } from "../lib/store";
import { revealInFinder } from "../lib/ipc";
import {
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
    <div className="settings-section">
      <h2>数据与隐私</h2>
      <p className="settings-lede">
        所有数据都在本地。ycode 不代理 agent 的 API 流量,也不上传你的代码。
      </p>

      <SettingGroupLabel>本地存储</SettingGroupLabel>
      <SettingCard>
        <SettingRow name="应用数据" desc="项目、会话、待办、检查点索引">
          <SettingValue align="end" title={dataDir ?? undefined}>
            {dataDir ?? "读取中…"}
          </SettingValue>
          <SettingAction
            label="在访达中显示"
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
          name="Transcript 来源"
          desc="只读扫描 —— ycode 从不修改这些文件"
        >
          <SettingValue align="end">
            {transcriptDirs.length > 0 ? transcriptDirs.join(" · ") : "—"}
          </SettingValue>
        </SettingRow>
        <SettingRow name="已索引" desc="会话与项目的本地索引">
          <SettingValue align="end">
            {sessionCount} 个会话 · {projectCount} 个项目
          </SettingValue>
        </SettingRow>
        <SettingRow
          name="搜索索引"
          desc="命令面板的历史搜索用它;损坏时应能从 transcript 重建"
          pendingReason="索引重建命令未实现"
        >
          <SettingAction label="重建索引" disabled>
            <RefreshIcon />
          </SettingAction>
        </SettingRow>
      </SettingCard>

      <SettingGroupLabel>保留策略</SettingGroupLabel>
      <SettingCard>
        <SettingRow
          name="会话历史保留"
          desc="超期仅清理 ycode 的索引,不动 agent 的原始 transcript"
          pendingReason="保留策略清理任务未实现"
        >
          <SettingChips
            label="会话历史保留"
            options={[
              { value: "90d", label: "90 天" },
              { value: "1y", label: "1 年" },
              { value: "forever", label: "永久" },
            ]}
            value="forever"
            disabled
          />
        </SettingRow>
      </SettingCard>
      <SettingNote>
        检查点的保留数量已经是可用设置,在<b>「会话 → 检查点」</b>里调整,
        这里不再重复。
      </SettingNote>

      <SettingGroupLabel>遥测</SettingGroupLabel>
      <SettingCard>
        <SettingRow
          name="匿名使用统计"
          desc="ycode 没有埋点、没有分析 SDK,也没有可以打开它的开关"
        >
          <SettingChip tone="on">不收集</SettingChip>
        </SettingRow>
        <SettingRow name="崩溃报告" desc="崩溃日志只写在本地,不会外发">
          <SettingChip tone="on">不收集</SettingChip>
        </SettingRow>
      </SettingCard>
      <SettingNote>
        唯一的出网请求是<b>检查应用更新</b>(见「关于」页)。agent CLI 自己与模型
        服务商的通信不经过 ycode。
      </SettingNote>

      <SettingGroupLabel>清理</SettingGroupLabel>
      <SettingCard tone="danger">
        <SettingRow
          name="清除全部本地数据"
          desc="移除项目、会话索引与检查点。不会删除你的代码,也不会删除 agent 的 transcript"
          pendingReason="需要一个能安全停掉所有会话再删库的后端命令,尚未实现"
        >
          <SettingAction label="清除全部本地数据" tone="danger" disabled>
            <TrashIcon />
          </SettingAction>
        </SettingRow>
      </SettingCard>
    </div>
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
