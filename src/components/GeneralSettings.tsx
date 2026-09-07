// Settings → 通用:启动行为与窗口。
//
// The window-position row is here rather than in 外观 for the same reason
// 自动隐藏顶栏 moved out of it: both are about how the window behaves, not
// how it looks. 外观 is themes and type sizes.

import { useTranslation } from "react-i18next";
import type { ConfigView, StartupModeView } from "../lib/types";
import { LOCALE_CHOICES, LOCALE_LABEL } from "../lib/i18n";
import { useStore } from "../lib/store";
import {
  SettingSection,
  SettingCard,
  SettingChip,
  SettingChips,
  SettingRow,
  type ChipOption,
} from "./ui/SettingControls";

interface Props {
  config: ConfigView;
  onChange: (next: ConfigView) => void;
}

function startupOptions(
  t: (k: string) => string,
): ReadonlyArray<ChipOption<StartupModeView>> {
  return [
    { value: "resume", label: t("settings.general.startupResume") },
    { value: "overview", label: t("settings.general.startupOverview") },
    { value: "blank", label: t("settings.general.startupBlank") },
  ];
}

/// 语言名不翻译 —— 每一项都用它自己那门语言的写法(见 LOCALE_LABEL)。
/// 唯一的例外是「跟随系统」,那不是一门语言而是一句说明,得跟着当前
/// 界面语言走。
function localeOptions(t: (k: string) => string): ReadonlyArray<ChipOption<string>> {
  return LOCALE_CHOICES.map((v) => ({
    value: v,
    label:
      v === "system" ? t("settings.general.matchSystem") : LOCALE_LABEL[v],
  }));
}

export function GeneralSettings({ config, onChange }: Props) {
  const { t } = useTranslation();
  const setLocale = useStore((s) => s.setLocale);
  return (
    <SettingSection
      title={t("settings.general.title")}
      lede={<>{t("settings.general.lede")}</>}
    >
      <SettingCard>
        <SettingRow
          name={t("settings.general.startup")}
          desc={t("settings.general.startupDesc")}
        >
          <SettingChips
            label={t("settings.general.startup")}
            options={startupOptions(t)}
            value={config.startup}
            onChange={(startup) => onChange({ ...config, startup })}
          />
        </SettingRow>

        <SettingRow
          name={t("settings.general.windowState")}
          desc={t("settings.general.windowStateDesc")}
        >
          {/* Handled by tauri-plugin-window-state at the process level, with
              no runtime switch to expose. Stating that it's on beats an
              always-checked toggle that does nothing when you click it. */}
          <SettingChip tone="on" title={t("settings.general.windowStateBy")}>
            {t("common.enabled")}
          </SettingChip>
        </SettingRow>

        {/* 「自动隐藏顶栏」已随顶栏一起移除:全局入口迁到了侧边栏头部
            与画布工具条,没有可隐藏的横条了。config 字段保留兼容老配置。 */}

        <SettingRow
          name={t("settings.general.locale")}
          desc={t("settings.general.localeDesc")}
        >
          <SettingChips
            label={t("settings.general.locale")}
            options={localeOptions(t)}
            value={config.locale}
            onChange={(locale) => {
              // 立刻切给 i18next,不等保存 —— 语言是所见即所得的选择,
              // 先看到界面变了才知道自己选对没有。真正落盘仍走
              // `onChange` 那条 staged-config 的常规路径。
              setLocale(locale);
              onChange({ ...config, locale });
            }}
          />
        </SettingRow>
      </SettingCard>
    </SettingSection>
  );
}
