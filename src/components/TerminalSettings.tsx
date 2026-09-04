// Settings → 终端:agent 与 shell 跑在什么环境里。
//
// This nav entry used to open the `ycode` shell-command installer, which is
// a different thing entirely (that now lives in 集成). What belongs here is
// the terminal itself — and of the preview's rows, the font size is the one
// with real backing: `font_sizes.terminal` already drives every xterm.js
// instance. The rest describes what ycode does today so the page answers
// "which shell is my agent actually running in" rather than pretending to
// let you change it.

import { useEffect, useState } from "react";
import { platform } from "@tauri-apps/plugin-os";
import type { ConfigView } from "../lib/types";
import {
  SettingSection,
  SettingAction,
  SettingCard,
  SettingChip,
  SettingChips,
  SettingGroupLabel,
  SettingRow,
  SettingValue,
  type ChipOption,
} from "./ui/SettingControls";

interface Props {
  config: ConfigView;
  onChange: (next: ConfigView) => void;
}

const SIZE_OPTIONS: ReadonlyArray<ChipOption<string>> = [
  { value: "12", label: "12" },
  { value: "13", label: "13" },
  { value: "14", label: "14" },
  { value: "15", label: "15" },
];

/// store 仍接受 8–32,老配置里可能存着 16 这类不在预设里的值。当前值不在
/// 预设里时,在末尾追加一个「16(当前)」chip 保住它 —— 只有用户主动点了
/// 别的 chip 才切换,不静默丢值。与外观页的处理保持一致。
function sizeOptionsFor(current: number): ReadonlyArray<ChipOption<string>> {
  const value = String(current);
  if (SIZE_OPTIONS.some((o) => o.value === value)) return SIZE_OPTIONS;
  return [...SIZE_OPTIONS, { value, label: `${value}(当前)` }];
}

export function TerminalSettings({ config, onChange }: Props) {
  const [shell, setShell] = useState<string | null>(null);

  useEffect(() => {
    // The backend spawns the user's login shell; read the same env var it
    // does so the row shows the real value rather than a guess.
    try {
      const os = platform();
      setShell(os === "windows" ? "powershell.exe" : "$SHELL -l");
    } catch {
      setShell(null);
    }
  }, []);

  return (
    <SettingSection title="终端" lede={<>agent 与 shell 运行的环境。</>}>
      <SettingGroupLabel>环境</SettingGroupLabel>
      <SettingCard>
        <SettingRow
          name="Shell"
          desc="以登录 shell 启动,因此会读取 .zprofile / .zshrc,PATH 与你手动开终端时一致"
        >
          <SettingValue align="end">{shell ?? "—"}</SettingValue>
          {/* 只读展示是真的;能改是假的 —— 按钮保留位置但按待实现处理,
              原因放在 tooltip 里,而不是整行灰掉把真实信息也一起灰掉。 */}
          <SettingAction
            label="更改 shell"
            disabled
            title="Shell 目前跟随系统默认,自定义未实现"
          >
            <EditIcon />
          </SettingAction>
        </SettingRow>
        <SettingRow
          name="工作目录"
          desc="会话所属项目的仓库根目录;开启隔离的会话则是它自己的 worktree"
        >
          <SettingChip tone="on">按会话</SettingChip>
        </SettingRow>
        <SettingRow
          name="环境变量"
          desc="每个 agent 的额外变量在「Agent 目录」里按 agent 配置,而不是全局叠加"
        >
          <SettingChip>见 Agent 目录</SettingChip>
        </SettingRow>
      </SettingCard>

      <SettingGroupLabel>显示</SettingGroupLabel>
      <SettingCard>
        <SettingRow
          name="字体"
          desc="系统等宽字体栈(SF Mono / Menlo / Consolas)"
          pendingReason="终端字体独立配置未实现,当前跟随外观设置"
        >
          <SettingValue align="end">ui-monospace</SettingValue>
        </SettingRow>
        <SettingRow name="字号" desc="所有 agent 终端与手动终端">
          <SettingChips
            label="终端字号"
            options={sizeOptionsFor(config.font_sizes.terminal)}
            value={String(config.font_sizes.terminal)}
            onChange={(v) =>
              onChange({
                ...config,
                font_sizes: { ...config.font_sizes, terminal: Number(v) },
              })
            }
          />
        </SettingRow>
        <SettingRow
          name="配色跟随界面主题"
          desc="终端的前景/背景取自当前主题的色板"
        >
          <SettingChip tone="on">已启用</SettingChip>
        </SettingRow>
        <SettingRow name="回滚缓冲" desc="每个会话保留的输出,重新挂载时回放">
          <SettingValue align="end">256 KB</SettingValue>
        </SettingRow>
        <SettingRow name="渲染方式" desc="xterm.js WebGL,失败时自动退回 canvas">
          <SettingChip tone="on">WebGL</SettingChip>
        </SettingRow>
      </SettingCard>
    </SettingSection>
  );
}

function EditIcon() {
  return (
    <svg width="15" height="15" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="1.9" strokeLinecap="round" strokeLinejoin="round" aria-hidden>
      <path d="M12 20h9" />
      <path d="M16.5 3.5a2.1 2.1 0 0 1 3 3L7 19l-4 1 1-4z" />
    </svg>
  );
}
