// Brand-icon wrapper for AI CLI agents.
//
// Each backend `AgentProfileView` carries an `icon` string — the key the
// user (or the shipped default config) put in `~/.config/ycode/config.toml`.
// We look that key up in the whitelist below; misses render a generic
// fallback so unknown agents still get a placeholder instead of blank space.
//
// To add a new icon: import it from `@lobehub/icons/es/<Name>` and add it
// to REGISTRY. Tree-shaking keeps the bundle limited to entries we list
// here even though @lobehub/icons exposes 300+ brands.

import ClaudeCode from "@lobehub/icons/es/ClaudeCode";
import Claude from "@lobehub/icons/es/Claude";
import Anthropic from "@lobehub/icons/es/Anthropic";
import Codex from "@lobehub/icons/es/Codex";
import OpenAI from "@lobehub/icons/es/OpenAI";
import GeminiCLI from "@lobehub/icons/es/GeminiCLI";
import Gemini from "@lobehub/icons/es/Gemini";
import Google from "@lobehub/icons/es/Google";
import Cline from "@lobehub/icons/es/Cline";
import Cursor from "@lobehub/icons/es/Cursor";
import Copilot from "@lobehub/icons/es/Copilot";
import GithubCopilot from "@lobehub/icons/es/GithubCopilot";
import KiloCode from "@lobehub/icons/es/KiloCode";
import Trae from "@lobehub/icons/es/Trae";
import Amp from "@lobehub/icons/es/Amp";
import Phind from "@lobehub/icons/es/Phind";
import Ollama from "@lobehub/icons/es/Ollama";
import Mistral from "@lobehub/icons/es/Mistral";
import DeepSeek from "@lobehub/icons/es/DeepSeek";
import Qwen from "@lobehub/icons/es/Qwen";
import Doubao from "@lobehub/icons/es/Doubao";
import Kimi from "@lobehub/icons/es/Kimi";
import Moonshot from "@lobehub/icons/es/Moonshot";
import Grok from "@lobehub/icons/es/Grok";
import XAI from "@lobehub/icons/es/XAI";
import Meta from "@lobehub/icons/es/Meta";
import MetaAI from "@lobehub/icons/es/MetaAI";
import Cohere from "@lobehub/icons/es/Cohere";
import Perplexity from "@lobehub/icons/es/Perplexity";
import Replit from "@lobehub/icons/es/Replit";

// Each lobehub icon is the Mono variant plus `.Color`, `.Avatar`, etc. as
// properties. The per-brand `CompoundedIcon` types are technically distinct
// (some carry extra fields like `colorGradient`) and not mutually
// assignable, so the registry uses a permissive shape and we narrow on
// access via the typed local alias below.
// eslint-disable-next-line @typescript-eslint/no-explicit-any
export const REGISTRY: Record<string, any> = {
  ClaudeCode,
  Claude,
  Anthropic,
  Codex,
  OpenAI,
  GeminiCLI,
  Gemini,
  Google,
  Cline,
  Cursor,
  Copilot,
  GithubCopilot,
  KiloCode,
  Trae,
  Amp,
  Phind,
  Ollama,
  Mistral,
  DeepSeek,
  Qwen,
  Doubao,
  Kimi,
  Moonshot,
  Grok,
  XAI,
  Meta,
  MetaAI,
  Cohere,
  Perplexity,
  Replit,
};

interface Props {
  /// Whitelist key from the agent config (e.g. "ClaudeCode"). Unknown or
  /// missing values render the generic placeholder.
  icon: string | null | undefined;
  /// Backend hint — "mono" picks the monochrome variant (currentColor),
  /// anything else picks the colored brand variant. Default: colored.
  variant?: string | null;
  /// Letter to draw in the placeholder when `icon` doesn't match. Usually
  /// the first character of the agent's display name.
  fallbackChar?: string;
  size?: number;
  className?: string;
}

export function AgentIcon({
  icon,
  variant,
  fallbackChar,
  size = 14,
  className,
}: Props) {
  if (icon && icon in REGISTRY) {
    const Icon = REGISTRY[icon];
    // Not every lobehub brand ships a `.Color` variant (Anthropic, OpenAI,
    // Cline, Cursor, GithubCopilot, KiloCode, Phind, Ollama, Moonshot,
    // Grok, XAI are mono-only as of v2.x). Fall back to the Mono component
    // (which `Icon` itself is) so we don't render `undefined` and crash.
    const Variant =
      variant === "mono" ? Icon : (Icon.Color ?? Icon);
    if (!Variant) {
      return <PlaceholderIcon size={size} char={fallbackChar} className={className} />;
    }
    return <Variant size={size} className={className} />;
  }
  return <PlaceholderIcon size={size} char={fallbackChar} className={className} />;
}

// Generic fallback so unknown/custom agents still have something to render.
// A dim circle with the first letter of the agent name — matches the
// proportions of the lobehub icons so layouts don't shift.
function PlaceholderIcon({
  size,
  char,
  className,
}: {
  size: number;
  char?: string;
  className?: string;
}) {
  const letter = (char ?? "?").slice(0, 1).toUpperCase();
  return (
    <svg
      width={size}
      height={size}
      viewBox="0 0 24 24"
      className={className}
      aria-hidden
    >
      <circle cx="12" cy="12" r="11" fill="currentColor" opacity="0.18" />
      <text
        x="12"
        y="12"
        textAnchor="middle"
        dominantBaseline="central"
        fontSize="13"
        fontFamily="ui-sans-serif, system-ui, sans-serif"
        fontWeight="600"
        fill="currentColor"
      >
        {letter}
      </text>
    </svg>
  );
}
