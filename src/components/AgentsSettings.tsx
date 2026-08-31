// Agents settings: what's configured, plus a way to add any CLI by name.
//
// There used to be a second card listing thirteen known agents to add from.
// It was a static list, not a scan — it advertised Goose and Kilo Code to
// people who had neither installed, and the two that ship by default were
// already configured, so the whole block was noise. 现在的「已检测到」分组
// 是真正的扫描:对一小份已知 agent CLI 名单逐个跑 `probe_command`(即
// `which`),只列出 PATH 里确实存在、且尚未配置的那些。
//
// Holds no IPC state of its own for the config — the parent owns the staged
// ConfigView and we mutate via `onChange`. The PATH probe is read-only.

import { useEffect, useState } from "react";
import { probeCommand } from "../lib/ipc";
import type { AgentLaunchProfileView, ConfigView } from "../lib/types";
import { useEscapeGuard } from "../lib/useEscapeGuard";
import { AgentIcon } from "./AgentIcon";
import {
  SettingAction,
  SettingCard,
  SettingChip,
  SettingGroupLabel,
  SettingRow,
  SettingValue,
} from "./ui/SettingControls";

interface Props {
  config: ConfigView;
  onChange: (next: ConfigView) => void;
}

/// 已知的 agent CLI 名单,用来做 PATH 探测。只包含「装了它就八成想接进来」
/// 的独立 CLI —— 探测是逐个 `which`,名单短一点,页面打开时的开销就小一点。
/// `icon` 必须是 AgentIcon 白名单里的 key,不在白名单会退回首字母占位。
const KNOWN_AGENTS: ReadonlyArray<{
  command: string;
  displayName: string;
  icon: string | null;
}> = [
  { command: "gemini", displayName: "Gemini CLI", icon: "GeminiCLI" },
  { command: "cursor-agent", displayName: "Cursor Agent", icon: null },
  { command: "aider", displayName: "Aider", icon: null },
  { command: "goose", displayName: "Goose", icon: null },
];

/// 命令名 → introspect 解析器 id。合法取值以 `ycode-introspect` crate 里
/// 实现的解析器为准(目前只有 "claude" 与 "codex",见 crate 的
/// `AgentKind` 注释与 ycode-config 的默认配置)。用户删掉默认的
/// Claude Code / Codex 配置后再手动加回来时,靠这份映射把 introspect
/// 绑定补回去 —— 否则 transcript 历史与 resume 都会失效。
const INTROSPECT_BY_COMMAND: Readonly<Record<string, string>> = {
  claude: "claude",
  codex: "codex",
};

/// 按命令的 basename 推断 introspect id;比如 `/usr/local/bin/claude`
/// 也能匹配上。没有对应解析器的命令返回 null。
function introspectFor(command: string): string | null {
  const base = command.split("/").pop() ?? command;
  return INTROSPECT_BY_COMMAND[base] ?? null;
}

export function AgentsSettings({ config, onChange }: Props) {
  // Inline "custom agent" form state. Lets users add any CLI not in the
  // catalog without re-introducing the full per-agent editor.
  const [adding, setAdding] = useState(false);
  const [customName, setCustomName] = useState("");
  const [customCommand, setCustomCommand] = useState("");

  // PATH 里探测到的已知 agent 命令集合;`null` 表示还在扫。只扫一次 ——
  // PATH 在应用运行期间基本不会变,变了重开设置页即可。
  const [detected, setDetected] = useState<Set<string> | null>(null);

  useEffect(() => {
    let cancelled = false;
    Promise.all(
      KNOWN_AGENTS.map((k) =>
        probeCommand(k.command)
          .then((ok) => (ok ? k.command : null))
          // 探测失败(比如测试环境没有 Tauri)按「没找到」处理,
          // 不让整个分组因此报错。
          .catch(() => null),
      ),
    ).then((hits) => {
      if (cancelled) return;
      setDetected(new Set(hits.filter((c): c is string => c !== null)));
    });
    return () => {
      cancelled = true;
    };
  }, []);

  function deleteAgent(idx: number) {
    const agents = config.agents.slice();
    agents.splice(idx, 1);
    onChange({ ...config, agents });
  }

  const configuredIds = new Set(config.agents.map((a) => a.id));
  // 排除已配置的按命令比,而不是按 id —— 用户自定义添加的 gemini 可能有
  // 任意 id,但命令相同就不该再在「已检测到」里重复出现。
  const configuredCommands = new Set(config.agents.map((a) => a.command));
  const detectedRows =
    detected === null
      ? null
      : KNOWN_AGENTS.filter(
          (k) => detected.has(k.command) && !configuredCommands.has(k.command),
        );

  /// 把探测到的 agent 一键加进已配置分组。走同一条 staged-config 路径,
  /// 保存时才落盘。
  function addDetected(k: (typeof KNOWN_AGENTS)[number]) {
    const agent: AgentLaunchProfileView = {
      id: uniqueId(kebab(k.command), configuredIds),
      display_name: k.displayName,
      command: k.command,
      args: [],
      env: {},
      icon: k.icon,
      icon_variant: null,
      color: null,
      introspect: introspectFor(k.command),
    };
    onChange({ ...config, agents: [...config.agents, agent] });
  }

  function confirmCustom() {
    const command = customCommand.trim();
    if (!command) return;
    const name = customName.trim();
    const id = uniqueId(kebab(name || command), configuredIds);
    const agent: AgentLaunchProfileView = {
      id,
      display_name: name || null,
      command,
      args: [],
      env: {},
      icon: null,
      icon_variant: null,
      color: null,
      introspect: introspectFor(command),
    };
    onChange({ ...config, agents: [...config.agents, agent] });
    setCustomName("");
    setCustomCommand("");
    setAdding(false);
  }

  function cancelCustom() {
    setCustomName("");
    setCustomCommand("");
    setAdding(false);
  }

  // Let Escape close the inline editor before the settings workspace itself.
  useEscapeGuard(cancelCustom, adding);

  return (
    <div className="settings-section">
      <h2>Agent 目录</h2>
      <p className="settings-lede">
        新建会话时可以选择的 agent。命令要能在 PATH 里找到 ——
        找不到的会自动从新建会话的选择器里隐藏。
      </p>

      <SettingGroupLabel>已配置 · {config.agents.length}</SettingGroupLabel>
      <SettingCard>
        {config.agents.length === 0 && (
          <SettingRow
            name="还没有配置任何 agent"
            desc="用下面的自定义 agent 加一个"
          />
        )}
        {config.agents.map((agent, idx) => {
          const label = agent.display_name || agent.id;
          return (
            <SettingRow
              key={agent.id}
              name={label}
              icon={
                <AgentIcon
                  icon={agent.icon}
                  variant={agent.icon_variant}
                  fallbackChar={label}
                  size={22}
                />
              }
            >
              <SettingValue align="end">{agent.command}</SettingValue>
              {agent.introspect && (
                <SettingChip title="ycode 能读取这个 agent 的会话记录">
                  历史可读
                </SettingChip>
              )}
              <SettingAction
                label={`移除 ${label}`}
                tone="danger"
                onClick={() => deleteAgent(idx)}
              >
                <TrashIcon />
              </SettingAction>
            </SettingRow>
          );
        })}
      </SettingCard>

      {/* 只在真的扫到东西时才出现 —— 空分组只会引人去想「为什么没检测到」,
          而答案(PATH 里没有)页首已经说过了。 */}
      {detectedRows !== null && detectedRows.length > 0 && (
        <>
          <SettingGroupLabel>已检测到 · {detectedRows.length}</SettingGroupLabel>
          <SettingCard>
            {detectedRows.map((k) => (
              <SettingRow
                key={k.command}
                name={k.displayName}
                desc="PATH 中找到,尚未配置"
                icon={
                  <AgentIcon
                    icon={k.icon}
                    variant={null}
                    fallbackChar={k.displayName}
                    size={22}
                  />
                }
              >
                <SettingValue align="end">{k.command}</SettingValue>
                <SettingAction
                  label={`添加 ${k.displayName}`}
                  onClick={() => addDetected(k)}
                >
                  <PlusIcon />
                </SettingAction>
              </SettingRow>
            ))}
          </SettingCard>
        </>
      )}

      <SettingCard>
        {adding ? (
          <SettingRow
            name="自定义 agent"
            desc="任何能在终端里跑的 CLI 都可以加进来"
          >
            <input
              type="text"
              className="settings-input"
              placeholder="显示名(可选)"
              aria-label="显示名"
              value={customName}
              autoFocus
              onChange={(e) => setCustomName(e.target.value)}
              onKeyDown={(e) => {
                if (e.key === "Enter") confirmCustom();
              }}
            />
            <input
              type="text"
              className="settings-input"
              placeholder="PATH 中的命令"
              aria-label="命令"
              value={customCommand}
              onChange={(e) => setCustomCommand(e.target.value)}
              onKeyDown={(e) => {
                if (e.key === "Enter") confirmCustom();
              }}
            />
            <SettingAction
              label="确认添加"
              disabled={!customCommand.trim()}
              onClick={confirmCustom}
            >
              <CheckIcon />
            </SettingAction>
            <SettingAction label="取消" onClick={cancelCustom}>
              <CloseIcon />
            </SettingAction>
          </SettingRow>
        ) : (
          <SettingRow
            name="自定义 agent"
            desc="任何能在终端里跑的 CLI 都可以加进来"
          >
            <SettingAction
              label="添加自定义 agent"
              onClick={() => setAdding(true)}
            >
              <PlusIcon />
            </SettingAction>
          </SettingRow>
        )}
      </SettingCard>
    </div>
  );
}

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
function CheckIcon() {
  return (
    <svg width="15" height="15" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2.2" strokeLinecap="round" strokeLinejoin="round" aria-hidden>
      <path d="m5 13 4 4L19 7" />
    </svg>
  );
}
function CloseIcon() {
  return (
    <svg width="15" height="15" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2" strokeLinecap="round" aria-hidden>
      <path d="M6 6l12 12M18 6 6 18" />
    </svg>
  );
}

/** kebab-case an arbitrary string for use as an agent id. */
function kebab(s: string): string {
  return (
    s
      .toLowerCase()
      .replace(/[^a-z0-9]+/g, "-")
      .replace(/^-+|-+$/g, "") || "agent"
  );
}

/** Ensure `base` doesn't collide with an existing id; suffix -2, -3, … */
function uniqueId(base: string, taken: Set<string>): string {
  if (!taken.has(base)) return base;
  let n = 2;
  while (taken.has(`${base}-${n}`)) n++;
  return `${base}-${n}`;
}
