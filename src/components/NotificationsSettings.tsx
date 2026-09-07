// Settings → 通知:哪些事值得打断你。
//
// This page used to also own the hook installers and MCP registration.
// Those moved to 集成, where they belong: a hook is how ycode learns what an
// agent is doing, and that drives the sidebar status lights whether or not
// you ever want a toast. What's left here is purely "should this interrupt
// me", which is the question the page's name asks.
//
// Both switches live in the staged `ConfigView` and apply on Save.

import { toast } from "../lib/toast";
import { useTranslation } from "react-i18next";
import { testNotification } from "../lib/ipc";
import type { ConfigView } from "../lib/types";
import { StatusDot } from "./ui/StatusDot";
import {
  SettingSection,
  SettingAction,
  SettingCard,
  SettingChips,
  SettingGroupLabel,
  SettingNote,
  SettingRow,
  SettingToggle,
  chips,
  type Choice,
} from "./ui/SettingControls";

interface Props {
  config: ConfigView;
  onChange: (next: ConfigView) => void;
}

/// The delivery switch is two booleans on the wire but one decision to the
/// user, so it reads as one three-way picker.
type Delivery = "always" | "unfocused" | "off";

const DELIVERY_CHOICES: ReadonlyArray<Choice<Delivery>> = [
  ["always", "common.always"],
  ["unfocused", "settings.notifications.unfocusedOnly"],
  ["off", "common.off"],
];

export function NotificationsSettings({ config, onChange }: Props) {
  const { t } = useTranslation();
  const { enabled, only_when_unfocused } = config.notifications;
  const delivery: Delivery = !enabled
    ? "off"
    : only_when_unfocused
      ? "unfocused"
      : "always";

  function setDelivery(next: Delivery) {
    onChange({
      ...config,
      notifications: {
        enabled: next !== "off",
        // Keep the gate's stored value when switching off, so turning
        // notifications back on restores the choice rather than resetting it.
        only_when_unfocused: next === "off" ? only_when_unfocused : next === "unfocused",
      },
    });
  }

  return (
    <SettingSection
      title={t("settings.notifications.title")}
      lede={
        <>
          {t("settings.notifications.lede")}
        </>
      }
    >
      <SettingGroupLabel>{t("settings.notifications.delivery")}</SettingGroupLabel>
      <SettingCard>
        <SettingRow
          name={t("settings.notifications.systemNotification")}
          desc={t("settings.notifications.systemNotificationDesc")}
        >
          <SettingChips
            label={t("settings.notifications.systemNotification")}
            options={chips(DELIVERY_CHOICES, t)}
            value={delivery}
            onChange={setDelivery}
          />
        </SettingRow>
        <SettingRow
          name={t("settings.notifications.testTitle")}
          desc={t("settings.notifications.testDesc")}
        >
          <SettingAction
            label={t("settings.notifications.testSend")}
            disabled={!enabled}
            onClick={() => {
              testNotification()
                .then(() => toast.success(t("settings.notifications.testSent")))
                .catch((err) =>
                  toast.danger(t("settings.notifications.testFailed", { error: err })),
                );
            }}
          >
            <SendIcon />
          </SettingAction>
        </SettingRow>
        <SettingRow
          name={t("settings.notifications.sound")}
          desc={t("settings.notifications.soundDesc")}
          pendingReason={t("settings.notifications.soundPending")}
        >
          <SettingChips
            label={t("settings.notifications.sound")}
            options={chips(
              [
                ["none", "common.none"],
                ["soft", "settings.notifications.soundSoft"],
                ["loud", "settings.notifications.soundLoud"],
              ],
              t,
            )}
            value="none"
            disabled
          />
        </SettingRow>
        <SettingRow
          name={t("settings.notifications.dockBadge")}
          desc={t("settings.notifications.dockBadgeDesc")}
          pendingReason={t("settings.notifications.dockBadgePending")}
        >
          <SettingToggle
            label={t("settings.notifications.dockBadge")}
            checked={false}
            disabled
          />
        </SettingRow>
      </SettingCard>

      <SettingGroupLabel>{t("settings.notifications.triggers")}</SettingGroupLabel>
      <SettingCard>
        <SettingRow
          name={<><StatusDot status="done" /> {t("settings.notifications.turnDone")}</>}
          desc={t("settings.notifications.turnDoneDesc")}
        >
          <SettingToggle label={t("settings.notifications.turnDone")} checked={enabled} disabled />
        </SettingRow>
        <SettingRow
          name={<><StatusDot status="blocked" /> {t("settings.notifications.needsApproval")}</>}
          desc={t("settings.notifications.needsApprovalDesc")}
          pendingReason={t("settings.notifications.needsApprovalPending")}
        >
          <SettingToggle label={t("settings.notifications.needsApproval")} checked={false} disabled />
        </SettingRow>
        <SettingRow
          name={<><StatusDot status="error" /> {t("settings.notifications.runError")}</>}
          desc={t("settings.notifications.runErrorDesc")}
          pendingReason={t("settings.notifications.runErrorPending")}
        >
          <SettingToggle label={t("settings.notifications.runError")} checked={false} disabled />
        </SettingRow>
      </SettingCard>
      <SettingNote>
        {t("settings.notifications.onlyTurnDoneNote")}
      </SettingNote>

      <SettingGroupLabel>{t("settings.notifications.dnd")}</SettingGroupLabel>
      <SettingCard>
        <SettingRow
          name={t("settings.notifications.followFocus")}
          desc={t("settings.notifications.followFocusDesc")}
          pendingReason={t("settings.notifications.followFocusPending")}
        >
          <SettingToggle label={t("settings.notifications.followFocus")} checked={false} disabled />
        </SettingRow>
        <SettingRow
          name={t("settings.notifications.minInterval")}
          desc={t("settings.notifications.minIntervalDesc")}
          pendingReason={t("settings.notifications.minIntervalPending")}
        >
          <SettingChips
            label={t("settings.notifications.minInterval")}
            options={chips(
              [
                ["off", "common.off"],
                ["30s", "settings.notifications.interval30s"],
                ["2m", "settings.notifications.interval2m"],
              ],
              t,
            )}
            value="off"
            disabled
          />
        </SettingRow>
      </SettingCard>
    </SettingSection>
  );
}

function SendIcon() {
  return (
    <svg width="15" height="15" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="1.9" strokeLinecap="round" strokeLinejoin="round" aria-hidden>
      <path d="M22 2 11 13" />
      <path d="M22 2l-7 20-4-9-9-4z" />
    </svg>
  );
}
