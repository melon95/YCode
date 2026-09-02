// Settings → 集成:how ycode talks to the agents, in one place.
//
// These three blocks used to be scattered — hook installers and MCP
// registration buried inside the notifications page, the `ycode` shell
// command behind a nav entry labelled 「终端」. They belong together: each one
// is ycode reaching into something outside itself (an agent's config dir,
// /usr/local/bin, the OS URL handler), and each takes effect the moment you
// click rather than on Save.
//
// That last point is why none of this lives in the staged `ConfigView`. The
// backend writes the agent's own files; there is nothing for "取消" to roll
// back, so the buttons say what they did via a toast instead.

import { useCallback, useEffect, useMemo, useState } from "react";
import { toast } from "../lib/toast";
import { platform } from "@tauri-apps/plugin-os";
import {
  agentHookStatus,
  agentInstallCodexChain,
  agentInstallHook,
  agentUninstallHook,
  cliInstall,
  cliStatus,
  cliUninstall,
  mcpInstall,
  mcpStatus,
  mcpUninstall,
  type AgentPatchStatus,
  type CliInstallStatus,
  type McpStatus,
} from "../lib/ipc";
import { useStore } from "../lib/store";
import { AgentIcon } from "./AgentIcon";
import {
  SettingAction,
  SettingCard,
  SettingChip,
  SettingGroupLabel,
  SettingNote,
  SettingRow,
  SettingValue,
} from "./ui/SettingControls";

type HookAgent = "claude" | "codex";

const AGENT_LABEL: Record<HookAgent, string> = {
  claude: "Claude Code",
  codex: "Codex",
};
const AGENT_ICON: Record<HookAgent, string> = {
  claude: "ClaudeCode",
  codex: "Codex",
};
/// Where each agent's patch lands. Shown as its own row because "what did
/// ycode write to my machine" is the first question this page has to answer.
const AGENT_TARGET: Record<HookAgent, string> = {
  claude: "~/.claude/settings.json",
  codex: "~/.codex/config.toml",
};
/// How we edited it. Separate from the path so the path itself stays short
/// enough to render without being ellipsised away.
const AGENT_TARGET_NOTE: Record<HookAgent, string> = {
  claude: "以 _ycode_managed 标记我们写的那一段",
  codex: "保留你原有的 notify",
};
/// The events each installed hook actually reports. Hard-coded because they
/// are a property of the patch we write, not something the backend returns.
const AGENT_EVENTS: Record<HookAgent, string[]> = {
  claude: ["Stop"],
  codex: ["notify"],
};

export function IntegrationsSettings() {
  // Only the agents the user actually configured, and only the two the
  // backend can patch. Listing a fixed claude/codex/gemini trio meant the
  // page advertised integrations for CLIs that weren't installed — and kept
  // showing Codex after someone removed it from the catalogue.
  const agents = useStore((s) => s.agents);
  const hookAgents = useMemo(
    () =>
      agents
        .map((a) => a.introspect)
        .filter((i): i is HookAgent => i === "claude" || i === "codex")
        .filter((i, idx, all) => all.indexOf(i) === idx),
    [agents],
  );

  return (
    <div className="settings-section">
      <h2>集成</h2>
      <p className="settings-lede">
        ycode 如何与 agent 通信。<b>只观测,不干预</b> —— 这些集成不会阻塞、批准或改写
        agent 的行为。
      </p>

      <SettingGroupLabel>Hook · 状态与事件来源</SettingGroupLabel>
      <SettingCard>
        {hookAgents.length === 0 ? (
          <SettingRow
            name="没有可接入的 agent"
            desc="目前只有 Claude Code 和 Codex 提供了可读的回合结束事件"
          />
        ) : (
          hookAgents.map((a) => <HookRows key={a} agent={a} />)
        )}
      </SettingCard>
      <SettingNote>
        Hook 只用来读取会话状态与工具活动。helper 在任何失败路径都返回 0,
        <b>ycode 未运行时不会影响你的 agent</b>。首次改写前会在原文件旁写一份
        <code> .ycode.bak</code> 备份。
      </SettingNote>

      <SettingGroupLabel>MCP · 供 agent 调用的能力</SettingGroupLabel>
      <SettingCard>
        {hookAgents.map((a) => (
          <McpRow key={a} agent={a} />
        ))}
        <SettingRow name="传输">
          <SettingValue align="end">
            ycode-mcp sidecar · Unix domain socket
          </SettingValue>
        </SettingRow>
      </SettingCard>
      <SettingNote>
        注册后 agent 可通过 <code>list_todos</code> / <code>add_todo</code> /{" "}
        <code>update_todo</code> / <code>delete_todo</code> 读写当前项目的待办。
        项目由 agent 所在的终端推断,不需要项目 id。
      </SettingNote>

      <SettingGroupLabel>系统</SettingGroupLabel>
      <SettingCard>
        <CliRow />
        <SettingRow
          name={
            <>
              处理 <code>ycode://</code> 深链接
            </>
          }
          desc="点击 ycode:// 链接时唤起本应用"
        >
          <SettingChip tone="on" title="由 tauri-plugin-deep-link 在启动时注册">
            已注册
          </SettingChip>
        </SettingRow>
      </SettingCard>
    </div>
  );
}

/* ---------- hooks ---------- */

function HookRows({ agent }: { agent: HookAgent }) {
  const [status, setStatus] = useState<AgentPatchStatus | null>(null);
  const [busy, setBusy] = useState(false);

  const refresh = useCallback(() => {
    agentHookStatus(agent)
      .then(setStatus)
      .catch((err) => toast.danger(`${AGENT_LABEL[agent]} hook 状态读取失败:${err}`));
  }, [agent]);

  useEffect(refresh, [refresh]);

  async function run(
    action: () => Promise<AgentPatchStatus>,
    success: string,
  ) {
    setBusy(true);
    try {
      const next = await action();
      setStatus(next);
      if (next.agent === "codex" && next.kind === "conflict_user_set") {
        toast.warning("Codex 已有自己的 notify —— 没有改动你的配置");
      } else {
        toast.success(success);
      }
    } catch (err) {
      toast.danger(`操作失败:${err}`);
      refresh();
    } finally {
      setBusy(false);
    }
  }

  const installed = status?.kind === "installed";
  const conflict =
    status?.agent === "codex" && status.kind === "conflict_user_set";
  const existing = (status?.agent === "codex" && status.existing) || [];

  return (
    <>
      <SettingRow
        name={AGENT_LABEL[agent]}
        icon={<AgentIcon icon={AGENT_ICON[agent]} fallbackChar={AGENT_LABEL[agent]} size={22} />}
        desc={
          conflict ? (
            <>
              你已在 <code>~/.codex/config.toml</code> 里设了{" "}
              <code>{existing.join(" ")}</code>。ycode 可以串在它前面,两者都会
              收到同一个事件;移除时会还原成你原来的设置。
            </>
          ) : undefined
        }
      >
        {status === null ? (
          <SettingChip>读取中…</SettingChip>
        ) : (
          <>
            {installed &&
              AGENT_EVENTS[agent].map((e) => (
                <SettingChip key={e} tone="on">
                  {e}
                </SettingChip>
              ))}
            {conflict && <SettingChip tone="warn">未接入</SettingChip>}
            {!installed && !conflict && <SettingChip>未接入</SettingChip>}
            {conflict ? (
              <SettingAction
                label="串接到现有 notify 之后"
                title="串接:两者都会收到事件"
                disabled={busy || existing.length === 0}
                onClick={() =>
                  void run(
                    () => agentInstallCodexChain(existing),
                    `${AGENT_LABEL[agent]} hook 已串接在你原有的 notify 之上`,
                  )
                }
              >
                <PlusIcon />
              </SettingAction>
            ) : installed ? (
              <SettingAction
                label="移除 hook"
                tone="danger"
                disabled={busy}
                onClick={() =>
                  void run(
                    () => agentUninstallHook(agent),
                    `${AGENT_LABEL[agent]} hook 已移除`,
                  )
                }
              >
                <TrashIcon />
              </SettingAction>
            ) : (
              <SettingAction
                label="接入 hook"
                disabled={busy}
                onClick={() =>
                  void run(
                    () => agentInstallHook(agent),
                    `${AGENT_LABEL[agent]} hook 已接入`,
                  )
                }
              >
                <PlusIcon />
              </SettingAction>
            )}
          </>
        )}
      </SettingRow>
      {installed && (
        <SettingRow
          name={<span className="settings-row-sub">写入位置</span>}
          desc={AGENT_TARGET_NOTE[agent]}
        >
          <SettingValue align="end" title={AGENT_TARGET[agent]}>
            {AGENT_TARGET[agent]}
          </SettingValue>
        </SettingRow>
      )}
    </>
  );
}

/* ---------- MCP ---------- */

function McpRow({ agent }: { agent: HookAgent }) {
  const [status, setStatus] = useState<McpStatus | null>(null);
  const [busy, setBusy] = useState(false);

  const refresh = useCallback(() => {
    mcpStatus(agent)
      .then(setStatus)
      .catch((err) => toast.danger(`${AGENT_LABEL[agent]} MCP 状态读取失败:${err}`));
  }, [agent]);

  useEffect(refresh, [refresh]);

  async function run(action: () => Promise<McpStatus>, success: string) {
    setBusy(true);
    try {
      setStatus(await action());
      toast.success(success);
    } catch (err) {
      toast.danger(`操作失败:${err}`);
    } finally {
      setBusy(false);
    }
  }

  return (
    <SettingRow
      name={AGENT_LABEL[agent]}
      desc="待办列表 · agent 可读取、新建、更新当前项目的待办"
      icon={<AgentIcon icon={AGENT_ICON[agent]} fallbackChar={AGENT_LABEL[agent]} size={22} />}
    >
      {status === null ? (
        <SettingChip>读取中…</SettingChip>
      ) : status === "installed" ? (
        <>
          <SettingChip tone="on">已注册</SettingChip>
          <SettingAction
            label="取消注册"
            tone="danger"
            disabled={busy}
            onClick={() =>
              void run(
                () => mcpUninstall(agent),
                `${AGENT_LABEL[agent]} 的待办 MCP 已移除`,
              )
            }
          >
            <TrashIcon />
          </SettingAction>
        </>
      ) : (
        <>
          <SettingChip>未注册</SettingChip>
          <SettingAction
            label="注册待办 MCP"
            disabled={busy}
            onClick={() =>
              void run(
                () => mcpInstall(agent),
                `${AGENT_LABEL[agent]} 的待办 MCP 已注册`,
              )
            }
          >
            <PlusIcon />
          </SettingAction>
        </>
      )}
    </SettingRow>
  );
}

/* ---------- ycode CLI ---------- */

/// Where the command lands, which differs enough per platform to be worth
/// stating — the user may want to inspect or remove it by hand.
function installHint(): string {
  let os: string;
  try {
    os = platform();
  } catch {
    // Outside Tauri (vitest/jsdom) the plugin throws.
    os = "macos";
  }
  if (os === "windows") {
    return "写入 %LOCALAPPDATA%\\YCode\\bin\\ycode.cmd 并把该目录加进用户 PATH。不需要管理员权限,装好后请开一个新终端。";
  }
  return "在 /usr/local/bin/ycode 建一个软链接。只有当该目录对你不可写时才会要求输入密码。";
}

function CliRow() {
  const [status, setStatus] = useState<CliInstallStatus | null>(null);
  const [busy, setBusy] = useState(false);

  const refresh = useCallback(
    () =>
      cliStatus()
        .then(setStatus)
        .catch((err) => toast.danger(`命令行状态读取失败:${err}`)),
    [],
  );

  useEffect(() => {
    void refresh();
  }, [refresh]);

  async function onInstall() {
    setBusy(true);
    try {
      const next = await cliInstall();
      setStatus(next);
      // `cli_install` reports the resulting state rather than throwing on a
      // partial outcome, so a non-`installed` result here is a success return
      // with a failure meaning — announcing "it's on your PATH" while
      // rendering a Repair button underneath would just be a lie.
      if (next.kind === "installed") {
        toast.success("`ycode` 已在 PATH 中 —— 开一个新终端试试");
      } else {
        toast.warning("安装未完成 —— 见下方状态");
      }
    } catch (err) {
      toast.danger(`安装失败:${err}`);
      // The failure may itself have changed what's on disk (a partial
      // elevated run), so re-read rather than trusting the stale value.
      await refresh();
    } finally {
      setBusy(false);
    }
  }

  async function onUninstall() {
    setBusy(true);
    try {
      setStatus(await cliUninstall());
      toast.success("`ycode` 命令已移除");
    } catch (err) {
      toast.danger(`移除失败:${err}`);
      await refresh();
    } finally {
      setBusy(false);
    }
  }

  const name = (
    <>
      <code>ycode</code> 命令行工具
    </>
  );
  const desc = (
    <>
      在任意终端用 <code>ycode .</code> 打开当前目录,<code>ycode src/main.rs</code>{" "}
      打开该文件所在仓库并聚焦它
    </>
  );

  if (status === null) {
    return (
      <SettingRow name={name} desc={desc}>
        <SettingChip>读取中…</SettingChip>
      </SettingRow>
    );
  }

  if (status.kind === "conflict") {
    return (
      <SettingRow name={name} desc={`${status.path} — ${status.detail}`}>
        {/* The path is occupied by something we didn't create, so there is no
            safe action to offer — but the user needs a way to re-read the
            state after clearing it by hand, and mount is otherwise the only
            trigger. */}
        <SettingChip tone="warn">被占用</SettingChip>
        <SettingAction label="重新检查" onClick={() => void refresh()}>
          <RefreshIcon />
        </SettingAction>
      </SettingRow>
    );
  }

  if (status.kind === "installed") {
    return (
      <SettingRow name={name} desc={desc}>
        <SettingChip tone="on" title={`${status.path} → ${status.target}`}>
          {status.path}
        </SettingChip>
        <SettingAction
          label="移除 ycode 命令"
          tone="danger"
          disabled={busy}
          onClick={() => void onUninstall()}
        >
          <TrashIcon />
        </SettingAction>
      </SettingRow>
    );
  }

  if (status.kind === "stale") {
    return (
      <SettingRow
        name={name}
        desc={`${status.path} 指向 ${status.target},那已不是当前这份构建`}
      >
        <SettingChip tone="warn">需修复</SettingChip>
        <SettingAction
          label="修复 ycode 命令"
          disabled={busy}
          onClick={() => void onInstall()}
        >
          <RefreshIcon />
        </SettingAction>
      </SettingRow>
    );
  }

  return (
    <SettingRow name={name} desc={installHint()}>
      <SettingChip>未安装</SettingChip>
      <SettingAction
        label="安装 ycode 命令"
        disabled={busy}
        onClick={() => void onInstall()}
      >
        <PlusIcon />
      </SettingAction>
    </SettingRow>
  );
}

/* ---------- glyphs ---------- */

function PlusIcon() {
  return (
    <svg width="15" height="15" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="1.9" strokeLinecap="round" aria-hidden>
      <path d="M12 5v14M5 12h14" />
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
