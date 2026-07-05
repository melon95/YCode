// Settings dialog. v1 has a single section (Agents); the section-nav rail
// is rendered ahead of time so adding Theme / Hotkeys later is a one-line
// change in SECTIONS.
//
// Edit lifecycle is all-or-nothing: opening the modal snapshots the
// backend's config into `staged`; every form edit mutates `staged` locally;
// "Save" pushes via `save_config` and refreshes the agents store; "Cancel"
// drops the staged copy. Closing with unsaved changes prompts a confirm.

import { useEffect, useRef, useState } from "react";
import {
  Button,
  Modal,
  ModalBackdrop,
  ModalBody,
  ModalContainer,
  ModalDialog,
  ModalFooter,
  ModalHeader,
  ModalHeading,
  toast,
} from "@heroui/react";
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
const SECTIONS: Array<{ id: SectionId; label: string }> = [
  { id: "agents", label: "Agents" },
  { id: "appearance", label: "Appearance" },
  { id: "languages", label: "Languages" },
  { id: "notifications", label: "Notifications" },
  { id: "usage", label: "Usage" },
  { id: "updates", label: "Updates" },
];

interface Props {
  open: boolean;
  onClose: () => void;
}

export function SettingsModal({ open, onClose }: Props) {
  const setAgents = useStore((s) => s.setAgents);
  const setFontSizes = useStore((s) => s.setFontSizes);
  const setTheme = useStore((s) => s.setTheme);
  const [staged, setStaged] = useState<ConfigView | null>(null);
  const [original, setOriginal] = useState<ConfigView | null>(null);
  const [section, setSection] = useState<SectionId>("agents");
  const [loading, setLoading] = useState(false);
  const [saving, setSaving] = useState(false);

  // Snapshot the backend config on open. Re-fetched every open so we never
  // edit a stale copy after another part of the app refreshed agents.
  //
  // `onClose` is read through a ref instead of being a useEffect dep — the
  // parent (TopBar) re-renders whenever the global theme changes (App.tsx
  // re-renders the whole tree), which mints a fresh `() => setSettingsOpen(false)`
  // each time. If `onClose` were a real dep, this effect would re-fire on
  // every theme swap, fetch the backend config again, and clobber the user's
  // unsaved live-preview pick — making the theme card's selection appear
  // to "snap back" to the on-disk value mid-edit.
  const onCloseRef = useRef(onClose);
  useEffect(() => {
    onCloseRef.current = onClose;
  }, [onClose]);
  useEffect(() => {
    if (!open) return;
    let cancelled = false;
    setLoading(true);
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
  }, [open]);

  const dirty =
    staged !== null && original !== null && !sameConfig(staged, original);

  // Escape closes Settings through the same guarded path as the ✕/backdrop
  // (unsaved-changes confirm included), without also dropping out of fullscreen.
  useEscapeGuard(() => void handleClose(), open);

  async function handleClose() {
    if (dirty) {
      const ok = await confirmDialog({
        title: "Discard unsaved changes?",
        message: "You have unsaved edits in Settings.",
        confirmLabel: "Discard",
        destructive: true,
      });
      if (!ok) return;
      // Theme is live-previewed (AppearanceSettings calls `setTheme` straight
      // through the store so the chrome updates the instant the user picks a
      // card). Discard has to undo that side effect explicitly — the rest of
      // the staged copy never escapes this component.
      if (original && original.theme !== useStore.getState().theme) {
        setTheme(original.theme);
      }
    }
    setStaged(null);
    setOriginal(null);
    onClose();
  }

  async function handleSave() {
    if (!staged || saving) return;
    setSaving(true);
    try {
      const refreshed = await saveConfig(staged);
      setAgents(refreshed);
      // `save_config` only returns the agent list; mirror the staged font
      // sizes and theme into the store so the rest of the UI picks them up
      // without a second round-trip.
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
      // Re-fetch so staged matches what's now on disk.
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

  // HeroUI Modal renders ModalBackdrop (a full-screen overlay) regardless
  // of `isOpen`, so an always-mounted instance blacks out the whole app.
  // Mount-on-open mirrors the confirmDialog / NewSessionDialog pattern.
  if (!open) return null;

  return (
    <Modal isOpen onOpenChange={(o) => !o && handleClose()}>
      <ModalBackdrop>
        <ModalContainer placement="center" size="lg">
          <ModalDialog className="settings-dialog">
            <ModalHeader>
              <ModalHeading>Settings</ModalHeading>
            </ModalHeader>
            <ModalBody className="settings-body">
              {loading || !staged ? (
                <div className="settings-loading">Loading…</div>
              ) : (
                <div className="settings-layout">
                  <nav className="settings-nav" aria-label="Settings sections">
                    {SECTIONS.map((s) => (
                      <button
                        key={s.id}
                        type="button"
                        className={
                          "settings-nav-item" +
                          (section === s.id ? " active" : "")
                        }
                        onClick={() => setSection(s.id)}
                      >
                        {s.label}
                      </button>
                    ))}
                  </nav>
                  <div className="settings-content">
                    {section === "agents" && (
                      <AgentsSettings
                        config={staged}
                        onChange={setStaged}
                      />
                    )}
                    {section === "appearance" && (
                      <AppearanceSettings
                        config={staged}
                        onChange={setStaged}
                      />
                    )}
                    {section === "languages" && <LanguagesSettings />}
                    {section === "usage" && <UsageSettings />}
                    {section === "notifications" && (
                      <NotificationsSettings
                        config={staged}
                        onChange={setStaged}
                      />
                    )}
                    {section === "updates" && <UpdatesSettings />}
                  </div>
                </div>
              )}
            </ModalBody>
            <ModalFooter className="settings-footer">
              <Button variant="ghost" onPress={handleReset} isDisabled={saving}>
                Reset to defaults
              </Button>
              <div className="flex-1" />
              <Button variant="ghost" onPress={handleClose} isDisabled={saving}>
                Cancel
              </Button>
              <Button
                variant="primary"
                onPress={handleSave}
                isDisabled={!dirty || saving}
              >
                {saving ? "Saving…" : "Save"}
              </Button>
            </ModalFooter>
          </ModalDialog>
        </ModalContainer>
      </ModalBackdrop>
    </Modal>
  );
}

// Cheap structural equality — agents list is short (~10 entries) and field
// types are primitives + small arrays/maps, so JSON.stringify is fine here.
function sameConfig(a: ConfigView, b: ConfigView): boolean {
  return JSON.stringify(a) === JSON.stringify(b);
}
