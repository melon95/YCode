import { beforeEach, describe, expect, it, vi } from "vitest";
import { invoke } from "@tauri-apps/api/core";
import { listen } from "@tauri-apps/api/event";
import {
  createSession,
  listenSessionEvents,
  openInExternalEditor,
  readFile,
  resolveTerminalPath,
  saveConfig,
  writeFile,
} from "./ipc";
import type { ConfigView, UiEvent } from "./types";

vi.mock("@tauri-apps/api/core", () => ({
  invoke: vi.fn(),
}));

vi.mock("@tauri-apps/api/event", () => ({
  listen: vi.fn(),
}));

const invokeMock = vi.mocked(invoke);
const listenMock = vi.mocked(listen);

describe("ipc wrappers", () => {
  beforeEach(() => {
    vi.clearAllMocks();
  });

  it("normalizes omitted createSession resume to null", async () => {
    invokeMock.mockResolvedValueOnce({ id: "s1" });

    await createSession({
      agent_profile_id: "shell-test",
      project_id: "p1",
      title: "new",
    });

    expect(invokeMock).toHaveBeenCalledWith("create_session", {
      request: {
        agent_profile_id: "shell-test",
        project_id: "p1",
        title: "new",
        resume: null,
      },
    });
  });

  it("passes command payloads through the names expected by Tauri", async () => {
    const config = { agents: [] } as unknown as ConfigView;

    await saveConfig(config);
    await readFile("p1", "src/main.tsx");
    await writeFile({ project_id: "p1", file_path: "a.txt", contents: "hi" });
    await openInExternalEditor({ path: "/tmp/a.txt", editor: null });
    await resolveTerminalPath("p1", "./src/main.tsx");

    expect(invokeMock).toHaveBeenNthCalledWith(1, "save_config", { config });
    expect(invokeMock).toHaveBeenNthCalledWith(2, "read_file", {
      projectId: "p1",
      filePath: "src/main.tsx",
    });
    expect(invokeMock).toHaveBeenNthCalledWith(3, "write_file", {
      request: { project_id: "p1", file_path: "a.txt", contents: "hi" },
    });
    expect(invokeMock).toHaveBeenNthCalledWith(4, "fs_open_in_external_editor", {
      request: { path: "/tmp/a.txt", editor: null },
    });
    expect(invokeMock).toHaveBeenNthCalledWith(5, "resolve_terminal_path", {
      projectId: "p1",
      candidate: "./src/main.tsx",
    });
  });

  it("subscribes to the ycode session event channel", async () => {
    const unlisten = vi.fn();
    listenMock.mockResolvedValueOnce(unlisten);
    const handler = vi.fn();

    await listenSessionEvents(handler);
    const callback = listenMock.mock.calls[0][1];
    const payload = {
      session_id: "s1",
      kind: { type: "SessionTouched" },
    } as UiEvent;
    callback({ payload } as Parameters<typeof callback>[0]);

    expect(listenMock).toHaveBeenCalledWith("ycode://session", expect.any(Function));
    expect(handler).toHaveBeenCalledWith(payload);
  });
});
