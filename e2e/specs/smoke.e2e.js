describe("YCode desktop shell", () => {
  it("starts the real Tauri app and shows the main chrome", async () => {
    await $("body").waitForExist({ timeout: 30000 });

    await expect($('button[aria-label="Settings"]')).toBeExisting();
    await expect($('button[aria-label="Search across sessions (⌘K)"]')).toBeExisting();
  });

  it("opens settings from the real desktop window", async () => {
    await clickSelector('button[aria-label="Settings"]');

    await expect($("h2=Settings")).toBeExisting();
    await expect($('nav[aria-label="Settings sections"]')).toBeExisting();
  });

  it("opens the command palette from the real desktop window", async () => {
    await browser.keys("Escape");
    await clickSelector('button[aria-label="Search across sessions (⌘K)"]');

    await expect($('input[aria-label="Search files"]')).toBeExisting();
  });
});

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
