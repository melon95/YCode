// Standalone settings workspace. The component keeps the existing staged
// config lifecycle, but presents it as a first-class screen instead of a
// modal layered over the coding workspace.

import { useEffect, useRef, useState } from "react";
import {
  ArrowLeft,
  Bell,
  Bot,
  ChartPie,
  CircleArrowDown,
  Code2,
  Monitor,
  type LucideIcon,
} from "lucide-react";
import { toast } from "@heroui/react";
import { getConfig, resetConfig, saveConfig } from "../lib/ipc";
import { useStore } from "../lib/store";
import type { ConfigView } from "../lib/types";
import { confirmDialog } from "../lib/confirm";
import { useEscapeGuard } from "../lib/useEscapeGuard";
import { AgentsSettings } from "./AgentsSettings";
import { AppearanceSettings } from "./AppearanceSettings";
import { LanguagesSettings } from "./LanguagesSettings";
import { NotificationsSettings } from "./NotificationsSettings";
import { UpdatesSettings } from "./UpdatesSettings";
import { UsageSettings } from "./UsageSettings";

type SectionId =
  | "agents"
  | "appearance"
  | "languages"
  | "notifications"
  | "usage"
  | "updates";

const SECTIONS: Array<{ id: SectionId; label: string; icon: LucideIcon }> = [
  { id: "agents", label: "Agents", icon: Bot },
  { id: "appearance", label: "Appearance", icon: Monitor },
  { id: "languages", label: "Languages", icon: Code2 },
  { id: "notifications", label: "Notifications", icon: Bell },
  { id: "usage", label: "Usage", icon: ChartPie },
  { id: "updates", label: "Updates", icon: CircleArrowDown },
];

interface Props {
  onClose: () => void;
}

export function SettingsScreen({ onClose }: Props) {
  const setAgents = useStore((s) => s.setAgents);
  const setFontSizes = useStore((s) => s.setFontSizes);
  const setTheme = useStore((s) => s.setTheme);
  const [staged, setStaged] = useState<ConfigView | null>(null);
  const [original, setOriginal] = useState<ConfigView | null>(null);
  const [section, setSection] = useState<SectionId>("agents");
  const [loading, setLoading] = useState(true);
  const [saving, setSaving] = useState(false);

  const onCloseRef = useRef(onClose);
  useEffect(() => {
    onCloseRef.current = onClose;
  }, [onClose]);

  useEffect(() => {
    let cancelled = false;
    getConfig()
      .then((cfg) => {
        if (cancelled) return;
        setStaged(cfg);
        setOriginal(cfg);
      })
      .catch((err) => {
        if (cancelled) return;
        toast.danger(`Failed to load config: ${err}`);
        onCloseRef.current();
      })
      .finally(() => {
        if (!cancelled) setLoading(false);
      });
    return () => {
      cancelled = true;
    };
  }, []);

  const dirty =
    staged !== null && original !== null && !sameConfig(staged, original);

  useEscapeGuard(() => void handleClose());

  async function handleClose() {
    if (dirty) {
      const ok = await confirmDialog({
        title: "Discard unsaved changes?",
        message: "You have unsaved edits in Settings.",
        confirmLabel: "Discard",
        destructive: true,
      });
      if (!ok) return;
      if (original && original.theme !== useStore.getState().theme) {
        setTheme(original.theme);
      }
    }
    onClose();
  }

  async function handleSave() {
    if (!staged || saving) return;
    setSaving(true);
    try {
      const refreshed = await saveConfig(staged);
      setAgents(refreshed);
      setFontSizes(staged.font_sizes);
      setTheme(staged.theme);
      setOriginal(staged);
      toast.success("Settings saved");
      onClose();
    } catch (err) {
      toast.danger(`Save failed: ${err}`);
    } finally {
      setSaving(false);
    }
  }

  async function handleReset() {
    const ok = await confirmDialog({
      title: "Reset to defaults?",
      message:
        "This overwrites your config file with the shipped defaults. Your customizations will be lost.",
      confirmLabel: "Reset",
      destructive: true,
    });
    if (!ok) return;
    try {
      const refreshed = await resetConfig();
      setAgents(refreshed);
      const cfg = await getConfig();
      setStaged(cfg);
      setOriginal(cfg);
      setFontSizes(cfg.font_sizes);
      setTheme(cfg.theme);
      toast.success("Reset to defaults");
    } catch (err) {
      toast.danger(`Reset failed: ${err}`);
    }
  }

  return (
    <section className="settings-screen" aria-label="Settings">
      <aside className="settings-sidebar">
        <button
          type="button"
          className="settings-back"
          onClick={() => void handleClose()}
        >
          <ArrowLeft aria-hidden size={17} />
          <span>Back to workspace</span>
        </button>

        <div className="settings-intro">
          <h1>Settings</h1>
          <p>Configure agents, appearance, languages, and app behavior.</p>
        </div>

        <nav className="settings-nav" aria-label="Settings sections">
          {SECTIONS.map((item) => {
            const Icon = item.icon;
            return (
              <button
                key={item.id}
                type="button"
                className={`settings-nav-item${section === item.id ? " active" : ""}`}
                aria-current={section === item.id ? "page" : undefined}
                onClick={() => setSection(item.id)}
              >
                <Icon aria-hidden size={18} />
                <span>{item.label}</span>
              </button>
            );
          })}
        </nav>
      </aside>

      <main className="settings-main">
        {loading || !staged ? (
          <div className="settings-loading">Loading settings…</div>
        ) : (
          <div className="settings-content">
            {section === "agents" && (
              <AgentsSettings config={staged} onChange={setStaged} />
            )}
            {section === "appearance" && (
              <AppearanceSettings config={staged} onChange={setStaged} />
            )}
            {section === "languages" && <LanguagesSettings />}
            {section === "usage" && <UsageSettings />}
            {section === "notifications" && (
              <NotificationsSettings config={staged} onChange={setStaged} />
            )}
            {section === "updates" && (
              <UpdatesSettings onClose={handleClose} />
            )}
          </div>
        )}
      </main>

      <footer className="settings-footer">
        <button
          type="button"
          className="settings-reset"
          onClick={() => void handleReset()}
          disabled={saving || loading}
        >
          Reset to defaults
        </button>
        <span className={`settings-save-state${dirty ? " dirty" : ""}`}>
          {dirty ? "Unsaved changes" : "No unsaved changes"}
        </span>
        <button
          type="button"
          className="settings-action"
          onClick={() => void handleClose()}
          disabled={saving}
        >
          Cancel
        </button>
        <button
          type="button"
          className="settings-action primary"
          onClick={() => void handleSave()}
          disabled={!dirty || saving}
        >
          {saving ? "Saving…" : "Save"}
        </button>
      </footer>
    </section>
  );
}

function sameConfig(a: ConfigView, b: ConfigView): boolean {
  return JSON.stringify(a) === JSON.stringify(b);
}
