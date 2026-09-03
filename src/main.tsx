import { StrictMode } from "react";
import { createRoot } from "react-dom/client";
import { App } from "./App";
import { Toaster } from "./components/ui/Toaster";
import "./tailwind.css";
import "./styles.css";
import "./design-system.css";
import "./redesign.css";

const root = document.getElementById("root");
if (!root) throw new Error("root element missing");
createRoot(root).render(
  <StrictMode>
    <App />
    <Toaster />
  </StrictMode>,
);
