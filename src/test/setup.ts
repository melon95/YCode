import "@testing-library/jest-dom/vitest";

if (!globalThis.requestAnimationFrame) {
  globalThis.requestAnimationFrame = (callback) =>
    window.setTimeout(() => callback(performance.now()), 0);
}

if (!globalThis.cancelAnimationFrame) {
  globalThis.cancelAnimationFrame = (handle) => window.clearTimeout(handle);
}
