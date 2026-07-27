import { StrictMode } from "react";
import { createRoot } from "react-dom/client";
import { ToastProvider } from "@heroui/react";
import { App } from "./App";
import "./styles.css";
import "./design-system.css";

const root = document.getElementById("root");
if (!root) throw new Error("root element missing");
createRoot(root).render(
  <StrictMode>
    <App />
    <ToastProvider placement="bottom end" />
  </StrictMode>,
);
