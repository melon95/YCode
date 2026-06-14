import fs from "node:fs";
import path from "node:path";

const fixtureProjectPath = process.env.E2E_FIXTURE_PROJECT_PATH;
const fixtureFilePath = fixtureProjectPath
  ? path.join(fixtureProjectPath, "docs", "fixture.md")
  : null;

describe("YCode fixture project editor", () => {
  it("opens and saves a real project file through the desktop UI", async () => {
    if (!fixtureProjectPath || !fixtureFilePath) {
      throw new Error("E2E_FIXTURE_PROJECT_PATH was not prepared");
    }

    await $("body").waitForExist({ timeout: 30000 });
    await browser.keys("Escape");

    const marker = `Saved by WebDriver e2e ${Date.now()}`;
    const project = await invokeTauri("create_project", {
      request: {
        name: "e2e-fixture",
        repo_path: fixtureProjectPath,
      },
    });

    try {
      await expect($("span=e2e-fixture")).toBeExisting();

      await clickSelector('button[aria-label="Search across sessions (⌘K)"]');
      const input = await $('input[aria-label="Search files"]');
      await input.waitForExist({ timeout: 30000 });
      await input.setValue("fixture");
      await browser.waitUntil(
        async () => (await $$('button[role="option"]')).length > 0,
        {
          timeout: 30000,
          timeoutMsg: "fixture file did not appear in the command palette",
        },
      );
      await browser.keys("Enter");

      const tab = await $("span=fixture.md");
      await tab.waitForExist({ timeout: 30000 });

      const editor = await $(".cm-content");
      await editor.waitForExist({ timeout: 30000 });
      await browser.waitUntil(
        async () => (await editor.getText()).includes("Fixture doc"),
        {
          timeout: 30000,
          timeoutMsg: "fixture contents did not load in CodeMirror",
        },
      );

      await focusEditorAtEnd();
      await browser.keys(`\n${marker}`);

      await expect($('span[aria-label="unsaved"]')).toBeExisting();
      await browser.keys(["\uE009", "s", "\uE000"]);

      await browser.waitUntil(
        () => fs.readFileSync(fixtureFilePath, "utf8").includes(marker),
        { timeout: 30000, timeoutMsg: "fixture file was not saved to disk" },
      );
      await expect($('span[aria-label="unsaved"]')).not.toBeExisting();
    } finally {
      await invokeTauri("delete_project", { projectId: project.id });
    }
  });
});

async function invokeTauri(command, args = {}) {
  return browser.execute(async (cmd, cmdArgs) => {
    const tauriWindow = window;
    if (tauriWindow.__TAURI_INTERNALS__?.invoke) {
      return tauriWindow.__TAURI_INTERNALS__.invoke(cmd, cmdArgs);
    }
    if (tauriWindow.__TAURI__?.core?.invoke) {
      return tauriWindow.__TAURI__.core.invoke(cmd, cmdArgs);
    }
    throw new Error("Tauri invoke API is not available in this WebView");
  }, command, args);
}

async function clickSelector(selector) {
  await $(selector).waitForExist({ timeout: 30000 });
  await browser.execute((targetSelector) => {
    const element = document.querySelector(targetSelector);
    if (!(element instanceof HTMLElement)) {
      throw new Error(`Element is not clickable: ${targetSelector}`);
    }
    element.click();
  }, selector);
}

async function focusEditorAtEnd() {
  await browser.execute(() => {
    const editor = document.querySelector(".cm-editor");
    const content = document.querySelector(".cm-content");
    if (!(content instanceof HTMLElement)) {
      throw new Error("CodeMirror content is not focusable");
    }

    const view = editor?.cmView?.view;
    if (view) {
      const end = view.state.doc.length;
      view.dispatch({ selection: { anchor: end } });
      view.focus();
      return;
    }

    content.focus();
  });
}
