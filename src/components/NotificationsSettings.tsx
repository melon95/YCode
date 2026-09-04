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
  type ChipOption,
} from "./ui/SettingControls";

interface Props {
  config: ConfigView;
  onChange: (next: ConfigView) => void;
}

/// The delivery switch is two booleans on the wire but one decision to the
/// user, so it reads as one three-way picker.
type Delivery = "always" | "unfocused" | "off";

const DELIVERY_OPTIONS: ReadonlyArray<ChipOption<Delivery>> = [
  { value: "always", label: "总是" },
  { value: "unfocused", label: "仅窗口失焦时" },
  { value: "off", label: "关" },
];

export function NotificationsSettings({ config, onChange }: Props) {
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
      title="通知"
      lede={
        <>
  agent 回合结束时发一条系统通知,这样你不用一直盯着终端。事件来自
          「集成」页配置的 hook。
        </>
      }
    >
      <SettingGroupLabel>送达方式</SettingGroupLabel>
      <SettingCard>
        <SettingRow
          name="系统通知"
          desc="「仅窗口失焦时」= ycode 在前台时不打扰,因为终端里已经看得见"
        >
          <SettingChips
            label="系统通知"
            options={DELIVERY_OPTIONS}
            value={delivery}
            onChange={setDelivery}
          />
        </SettingRow>
        <SettingRow
          name="发一条测试通知"
          desc="macOS 上首次会弹出系统通知权限申请"
        >
          <SettingAction
            label="发送测试通知"
            disabled={!enabled}
            onClick={() => {
              testNotification()
                .then(() => toast.success("测试通知已发送"))
                .catch((err) => toast.danger(`发送失败:${err}`));
            }}
          >
            <SendIcon />
          </SettingAction>
        </SettingRow>
        <SettingRow
          name="提示音"
          desc="通知送达时播放的声音"
          pendingReason="提示音播放未实现"
        >
          <SettingChips
            label="提示音"
            options={[
              { value: "none", label: "无" },
              { value: "soft", label: "轻柔" },
              { value: "loud", label: "明显" },
            ]}
            value="none"
            disabled
          />
        </SettingRow>
        <SettingRow
          name="Dock 角标显示待处理数"
          desc="等待授权的会话数显示在应用图标上"
          pendingReason="Dock 角标需要接入 macOS badge API,未实现"
        >
          <SettingToggle
            label="Dock 角标显示待处理数"
            checked={false}
            disabled
          />
        </SettingRow>
      </SettingCard>

      <SettingGroupLabel>触发时机</SettingGroupLabel>
      <SettingCard>
        <SettingRow
          name={<><StatusDot status="done" /> 回合完成</>}
          desc="agent 结束一轮并把控制权交回给你"
        >
          <SettingToggle label="回合完成" checked={enabled} disabled />
        </SettingRow>
        <SettingRow
          name={<><StatusDot status="blocked" /> 需要你授权</>}
          desc="agent 停下来等确认 —— 最值得立刻知道"
          pendingReason="需要 PreToolUse hook 才能区分「等授权」和「回合结束」,见 docs/agent-hook-integration-spec.md"
        >
          <SettingToggle label="需要你授权" checked={false} disabled />
        </SettingRow>
        <SettingRow
          name={<><StatusDot status="error" /> 运行出错</>}
          desc="agent 进程非正常退出"
          pendingReason="退出码目前只反映在会话状态点上,还没有接到通知里"
        >
          <SettingToggle label="运行出错" checked={false} disabled />
        </SettingRow>
      </SettingCard>
      <SettingNote>
        目前只有「回合完成」有事件来源 —— 它就是 hook 报告的那一个事件,
        所以它跟着上面的总开关走,没有单独的开关。
      </SettingNote>

      <SettingGroupLabel>免打扰</SettingGroupLabel>
      <SettingCard>
        <SettingRow
          name="跟随系统专注模式"
          desc="开启专注模式时不发通知"
          pendingReason="macOS 没有公开的专注模式查询接口,需要另找办法"
        >
          <SettingToggle label="跟随系统专注模式" checked={false} disabled />
        </SettingRow>
        <SettingRow
          name="同一会话最短间隔"
          desc="避免连续回合刷屏"
          pendingReason="需要按会话做节流,尚未实现"
        >
          <SettingChips
            label="同一会话最短间隔"
            options={[
              { value: "off", label: "关" },
              { value: "30s", label: "30 秒" },
              { value: "2m", label: "2 分钟" },
            ]}
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
