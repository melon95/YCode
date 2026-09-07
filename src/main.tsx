import { StrictMode } from "react";
import { createRoot } from "react-dom/client";
// 在渲染任何组件之前初始化 i18next。晚一步的话第一帧就会漏出词条 key,
// 等 `getConfig` 回来才被替换成真正的文案 —— 那一闪对用户是坏掉的界面。
// 这里先按系统语言起,配置里存的选择由 App 读到后再覆盖。
import { applyLocale, SYSTEM_LOCALE_ID } from "./lib/i18n";
import { App } from "./App";
import { Toaster } from "./components/ui/Toaster";
import "./tailwind.css";
import "./styles.css";
import "./design-system.css";
import "./redesign.css";

applyLocale(SYSTEM_LOCALE_ID);

const root = document.getElementById("root");
if (!root) throw new Error("root element missing");
createRoot(root).render(
  <StrictMode>
    <App />
    <Toaster />
  </StrictMode>,
);
