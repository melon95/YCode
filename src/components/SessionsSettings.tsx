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

import type {
  CheckpointSettingsView,
  ConfigView,
  SessionOpenModeView,
  WorktreeCloseActionView,
  WorktreeSettingsView,
} from "../lib/types";
import {
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

const CLOSE_OPTIONS: ReadonlyArray<ChipOption<WorktreeCloseActionView>> = [
  { value: "ask", label: "每次询问" },
  { value: "merge", label: "合并" },
  { value: "discard", label: "丢弃" },
];

const OPEN_MODE_OPTIONS: ReadonlyArray<ChipOption<SessionOpenModeView>> = [
  { value: "replace_focused", label: "替换当前面板" },
  { value: "new_pane", label: "并排新面板" },
];

/// `null` is "keep everything" on the wire; the chip values are strings
/// because a picker's identity has to be a string.
const KEEP_OPTIONS: ReadonlyArray<ChipOption<string>> = [
  { value: "20", label: "20" },
  { value: "50", label: "50" },
  { value: "unlimited", label: "不限" },
];

const IDLE_OPTIONS: ReadonlyArray<ChipOption<string>> = [
  { value: "off", label: "关" },
  { value: "30m", label: "30 分钟" },
  { value: "2h", label: "2 小时" },
];

export function SessionsSettings({ config, onChange }: Props) {
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
    <div className="settings-section">
      <h2>会话</h2>
      <p className="settings-lede">
        agent 会话的隔离方式、检查点与落点。生命周期相关的几项还没有实现。
      </p>

      <SettingGroupLabel>生命周期</SettingGroupLabel>
      <SettingCard>
        <SettingRow
          name="关闭窗口时保留 PTY"
          desc="让 agent 在后台继续跑,重开应用时接回"
          pendingReason="需要把 PTY 从窗口生命周期里剥离出来,是独立的一摊工作"
        >
          <SettingToggle label="关闭窗口时保留 PTY" checked={false} disabled />
        </SettingRow>
        <SettingRow
          name="回收空闲会话进程"
          desc="空闲超时后结束进程,下次打开用 --resume 恢复上下文"
          pendingReason="需要空闲计时与 resume 编排,尚未实现"
        >
          <SettingChips label="回收空闲会话进程" options={IDLE_OPTIONS} value="off" disabled />
        </SettingRow>
        <SettingRow
          name="自动归档已完成会话"
          desc="仍可在历史中搜索与恢复"
          pendingReason="需要后台清理任务,尚未实现"
        >
          <SettingChips label="自动归档已完成会话" options={IDLE_OPTIONS} value="off" disabled />
        </SettingRow>
      </SettingCard>

      <SettingGroupLabel>Worktree 隔离</SettingGroupLabel>
      <SettingCard>
        <SettingRow
          name="新项目默认开启隔离"
          desc="每个会话独立分支与工作目录,互不干扰。已有项目保持各自的设置"
        >
          <SettingToggle
            label="新项目默认开启隔离"
            checked={config.worktree.isolate_by_default}
            onChange={(v) => setWorktree("isolate_by_default", v)}
          />
        </SettingRow>
        <SettingRow name="分支名前缀" desc="会话 id 会接在后面">
          <input
            className="settings-input"
            value={config.worktree.branch_prefix}
            spellCheck={false}
            aria-label="分支名前缀"
            placeholder="ycode/"
            onChange={(e) => setWorktree("branch_prefix", e.target.value)}
          />
        </SettingRow>
        <SettingRow name="关闭 worktree 时">
          <SettingChips
            label="关闭 worktree 时"
            options={CLOSE_OPTIONS}
            value={config.worktree.close_action}
            onChange={(v) => setWorktree("close_action", v)}
          />
        </SettingRow>
        <SettingRow
          name="软链共享的目录"
          desc="避免每个 worktree 重装依赖"
          pendingReason="worktree 创建后的初始化流程尚未实现"
        >
          <SettingValue>node_modules · .venv · target</SettingValue>
        </SettingRow>
        <SettingRow
          name="创建后执行"
          desc="软链覆盖不到的初始化:拷贝 .env、代码生成、建本地数据库"
          pendingReason="worktree 创建后的初始化流程尚未实现"
        >
          <SettingValue>—</SettingValue>
        </SettingRow>
      </SettingCard>

      <SettingGroupLabel>检查点</SettingGroupLabel>
      <SettingCard>
        <SettingRow
          name="自动创建检查点"
          desc="每个 agent 回合前后各快照一次,可在「变更」面板里回看与回滚"
        >
          <SettingToggle
            label="自动创建检查点"
            checked={config.checkpoints.enabled}
            onChange={(v) => setCheckpoints("enabled", v)}
          />
        </SettingRow>
        <SettingRow
          name="每个会话保留数量"
          desc="超出后删除最旧的,连同它的 git ref"
        >
          <SettingChips
            label="每个会话保留数量"
            options={KEEP_OPTIONS}
            value={keepValue}
            disabled={!config.checkpoints.enabled}
            onChange={(v) =>
              setCheckpoints("keep", v === "unlimited" ? null : Number(v))
            }
          />
        </SettingRow>
      </SettingCard>

      <SettingGroupLabel>默认布局</SettingGroupLabel>
      <SettingCard>
        <SettingRow
          name="从侧边栏打开会话时"
          desc="「替换当前面板」不会改变面板数量"
        >
          <SettingChips
            label="从侧边栏打开会话时"
            options={OPEN_MODE_OPTIONS}
            value={config.session_open_mode}
            onChange={(session_open_mode) =>
              onChange({ ...config, session_open_mode })
            }
          />
        </SettingRow>
      </SettingCard>
    </div>
  );
}
