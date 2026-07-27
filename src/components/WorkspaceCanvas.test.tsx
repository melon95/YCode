import { cleanup, render, screen } from "@testing-library/react";
import type { ReactNode } from "react";
import { afterEach, describe, expect, it, vi } from "vitest";
import { WorkspaceCanvas } from "./WorkspaceCanvas";

vi.mock("react-resizable-panels", () => ({
  Group: ({ children }: { children: ReactNode }) => <div>{children}</div>,
  Panel: ({ children }: { children: ReactNode }) => <div>{children}</div>,
  Separator: () => <div role="separator" />,
}));
vi.mock("./Sidebar", () => ({ Sidebar: () => <div>Agent sessions</div> }));
vi.mock("./RightPane", () => ({ RightPane: () => <div>Project tools</div> }));
vi.mock("./TerminalPane", () => ({
  TerminalPane: () => <div>Persistent agent terminal</div>,
}));

const baseProps = {
  defaultLayout: undefined,
  onLayoutChanged: vi.fn(),
  sidebarRef: { current: null },
  rightPaneRef: { current: null },
};

describe("WorkspaceCanvas", () => {
  afterEach(() => {
    cleanup();
    vi.clearAllMocks();
  });

  it("keeps agent sessions, terminal, and project tools visible together", () => {
    render(<WorkspaceCanvas {...baseProps} />);

    expect(screen.getByText("Agent sessions")).toBeInTheDocument();
    expect(screen.getByText("Persistent agent terminal")).toBeInTheDocument();
    expect(screen.getByText("Project tools")).toBeInTheDocument();
  });
});
