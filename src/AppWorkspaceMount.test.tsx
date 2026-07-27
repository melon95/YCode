// Guards one invariant of App's render shape: opening Settings must HIDE the
// workspace, never unmount it.
//
// ManualTerminal kills its PTY on cleanup — it has no session row keeping it
// alive backend-side — and the right pane's split layout is component state.
// So unmounting the workspace would kill a long-running `npm run dev` and drop
// the terminal layout just because the user opened Settings.
//
// Rendering the real App would need the whole Tauri surface mocked, so this
// models the exact render structure from App.tsx instead and asserts on the
// mount/unmount lifecycle that matters.

import { describe, expect, it } from "vitest";
import { useEffect, useRef, useState } from "react";
import { act, render, screen } from "@testing-library/react";

let ptyKills = 0;
let mountSeq = 0;

/** Stands in for ManualTerminal: kills its PTY when unmounted. */
function FakeManualTerminal() {
  useEffect(() => {
    return () => {
      ptyKills += 1;
    };
  }, []);
  return <div data-testid="manual-terminal" />;
}

/** Stands in for RightPane: holds split layout in component state. */
function FakeWorkspace() {
  const mountId = useRef(0);
  if (!mountId.current) mountId.current = ++mountSeq;
  return (
    <div data-testid="workspace" data-mount={String(mountId.current)}>
      <FakeManualTerminal />
    </div>
  );
}

/** Mirrors the render shape of App.tsx. */
function Harness() {
  const [settingsOpen, setSettingsOpen] = useState(false);
  return (
    <>
      <button type="button" onClick={() => setSettingsOpen((v) => !v)}>
        Toggle settings
      </button>
      <div className="app-workspace" hidden={settingsOpen}>
        <FakeWorkspace />
      </div>
      {settingsOpen && <div data-testid="settings-screen" />}
    </>
  );
}

describe("App workspace mounting", () => {
  it("hides the workspace behind Settings without unmounting it", () => {
    ptyKills = 0;
    mountSeq = 0;
    render(<Harness />);

    const workspace = screen.getByTestId("workspace");
    const mountId = workspace.getAttribute("data-mount");
    expect(screen.getByTestId("manual-terminal")).toBeTruthy();

    act(() => {
      screen.getByText("Toggle settings").click();
    });

    expect(screen.getByTestId("settings-screen")).toBeTruthy();
    // Still in the tree, just hidden — so no PTY was killed.
    expect(ptyKills).toBe(0);
    const hiddenWorkspace = screen.getByTestId("workspace");
    expect(hiddenWorkspace.getAttribute("data-mount")).toBe(mountId);
    expect(hiddenWorkspace.closest(".app-workspace")?.hasAttribute("hidden")).toBe(
      true,
    );

    act(() => {
      screen.getByText("Toggle settings").click();
    });

    // Same instance came back: terminals and split layout are intact.
    expect(screen.getByTestId("workspace").getAttribute("data-mount")).toBe(
      mountId,
    );
    expect(ptyKills).toBe(0);
    expect(
      screen.getByTestId("workspace").closest(".app-workspace")?.hasAttribute("hidden"),
    ).toBe(false);
  });
});
