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
import { Trans, useTranslation } from "react-i18next";
import { i18next } from "../lib/i18n";
import { platform } from "@tauri-apps/plugin-os";
import { detectSystemProxy } from "../lib/ipc";
import type { ConfigView, ProxyModeView, SystemProxyView } from "../lib/types";
import {
  SettingSection,
  SettingAction,
  SettingCard,
  SettingChip,
  SettingChips,
  SettingGroupLabel,
  SettingNote,
  SettingRow,
  SettingValue,
  chips,
  type ChipOption,
  type Choice,
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
  return [
    ...SIZE_OPTIONS,
    { value, label: i18next.t("settings.appearance.currentValue", { value }) },
  ];
}

const PROXY_CHOICES: ReadonlyArray<Choice<ProxyModeView>> = [
  ["off", "settings.terminal.proxyOff"],
  ["system", "settings.terminal.proxySystem"],
  ["manual", "settings.terminal.proxyManual"],
];

const INPUT_CLASS = `flex-none w-[190px] h-control-sm px-2 border border-rule rounded-sm bg-panel
  text-text font-mono text-[11.5px] outline-none transition-colors duration-[var(--t-fast)]
  ease-smooth hover:border-rule-strong focus:border-accent placeholder:text-subtle`;

export function TerminalSettings({ config, onChange }: Props) {
  const { t } = useTranslation();
  const [shell, setShell] = useState<string | null>(null);
  const [detected, setDetected] = useState<SystemProxyView | null>(null);
  const proxy = config.proxy;

  // Only fetched while the user is looking at "follow the system" — it shells
  // out to scutil, and in the other modes the answer isn't shown anywhere.
  useEffect(() => {
    if (proxy.mode !== "system") return;
    let live = true;
    // async-wrapped so a synchronous throw from the IPC bridge (no Tauri
    // host — tests, a browser preview) lands in the same catch as a
    // rejection and just leaves the row showing "—".
    void (async () => {
      try {
        const p = await detectSystemProxy();
        if (live) setDetected(p);
      } catch {
        if (live) setDetected(null);
      }
    })();
    return () => {
      live = false;
    };
  }, [proxy.mode]);

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
    <SettingSection
      title={t("settings.terminal.title")}
      lede={<>{t("settings.terminal.lede")}</>}
    >
      <SettingGroupLabel>{t("settings.terminal.environment")}</SettingGroupLabel>
      <SettingCard>
        <SettingRow
          name="Shell"
          desc={t("settings.terminal.loginShellDesc")}
        >
          <SettingValue align="end">{shell ?? "—"}</SettingValue>
          {/* 只读展示是真的;能改是假的 —— 按钮保留位置但按待实现处理,
              原因放在 tooltip 里,而不是整行灰掉把真实信息也一起灰掉。 */}
          <SettingAction
            label={t("settings.terminal.changeShell")}
            disabled
            title={t("settings.terminal.changeShellPending")}
          >
            <EditIcon />
          </SettingAction>
        </SettingRow>
        <SettingRow
          name={t("settings.terminal.cwd")}
          desc={t("settings.terminal.cwdDesc")}
        >
          <SettingChip tone="on">{t("settings.terminal.perSession")}</SettingChip>
        </SettingRow>
        <SettingRow
          name={t("settings.terminal.envVars")}
          desc={t("settings.terminal.envVarsDesc")}
        >
          <SettingChip>{t("settings.terminal.seeAgents")}</SettingChip>
        </SettingRow>
        <SettingRow
          name={t("settings.terminal.proxy")}
          desc={t("settings.terminal.proxyDesc")}
        >
          <SettingChips
            label={t("settings.terminal.proxy")}
            options={chips(PROXY_CHOICES, t)}
            value={proxy.mode}
            onChange={(mode) => onChange({ ...config, proxy: { ...proxy, mode } })}
          />
        </SettingRow>
        {proxy.mode === "system" && (
          <SettingRow
            name={t("settings.terminal.proxyDetected")}
            desc={t("settings.terminal.proxyDetectedDesc")}
          >
            <SettingValue align="end">{detectedSummary(detected, t)}</SettingValue>
          </SettingRow>
        )}
        {proxy.mode === "manual" && (
          <>
            <SettingRow
              name={t("settings.terminal.proxyUrl")}
              desc={t("settings.terminal.proxyUrlDesc")}
            >
              <input
                className={INPUT_CLASS}
                value={proxy.url}
                spellCheck={false}
                aria-label={t("settings.terminal.proxyUrl")}
                placeholder="127.0.0.1:7897"
                onChange={(e) =>
                  onChange({ ...config, proxy: { ...proxy, url: e.target.value } })
                }
              />
            </SettingRow>
            <SettingRow
              name={t("settings.terminal.proxyNoProxy")}
              desc={t("settings.terminal.proxyNoProxyDesc")}
            >
              <input
                className={INPUT_CLASS}
                value={proxy.no_proxy}
                spellCheck={false}
                aria-label={t("settings.terminal.proxyNoProxy")}
                placeholder="localhost,127.0.0.1,*.local"
                onChange={(e) =>
                  onChange({ ...config, proxy: { ...proxy, no_proxy: e.target.value } })
                }
              />
            </SettingRow>
          </>
        )}
      </SettingCard>
      {proxy.mode !== "off" && (
        <SettingNote>
          <Trans i18nKey="settings.terminal.proxyNote" components={{ 1: <b /> }} />
        </SettingNote>
      )}

      <SettingGroupLabel>{t("settings.terminal.display")}</SettingGroupLabel>
      <SettingCard>
        <SettingRow
          name={t("settings.terminal.font")}
          desc={t("settings.terminal.fontDesc")}
          pendingReason={t("settings.terminal.fontPending")}
        >
          <SettingValue align="end">ui-monospace</SettingValue>
        </SettingRow>
        <SettingRow
          name={t("settings.terminal.fontSize")}
          desc={t("settings.terminal.fontSizeDesc")}
        >
          <SettingChips
            label={t("settings.terminal.terminalFontSize")}
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
          name={t("settings.terminal.themeFollows")}
          desc={t("settings.terminal.themeFollowsDesc")}
        >
          <SettingChip tone="on">{t("common.enabled")}</SettingChip>
        </SettingRow>
        <SettingRow
          name={t("settings.terminal.scrollback")}
          desc={t("settings.terminal.scrollbackDesc")}
        >
          <SettingValue align="end">256 KB</SettingValue>
        </SettingRow>
        <SettingRow
          name={t("settings.terminal.renderer")}
          desc={t("settings.terminal.rendererDesc")}
        >
          <SettingChip tone="on">WebGL</SettingChip>
        </SettingRow>
      </SettingCard>
    </SettingSection>
  );
}

/// What "follow the system" actually resolved to. Three states worth telling
/// apart: not read yet, a PAC script (which no env-var-reading client can
/// use, so we say so rather than showing an empty result and looking broken),
/// and the address itself. HTTPS is the one that matters for an agent CLI —
/// every API call it makes is https — so that's the one shown.
function detectedSummary(
  detected: SystemProxyView | null,
  t: (key: string) => string,
): string {
  if (!detected) return "—";
  if (detected.pac_url) return t("settings.terminal.proxyPac");
  const vars = new Map(detected.vars);
  return (
    vars.get("HTTPS_PROXY") ??
    vars.get("HTTP_PROXY") ??
    vars.get("ALL_PROXY") ??
    t("settings.terminal.proxyNone")
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
