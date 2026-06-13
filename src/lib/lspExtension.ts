// CodeMirror 6 ↔ ycode-lsp glue.
//
// Provides two extensions:
//
// 1. **semantic-tokens** — a `StateField<DecorationSet>` driven by an
//    `applyLspTokens(view, data)` helper. The backend hands back the raw LSP
//    `data` array (5 numbers per token, delta-encoded relative to the
//    previous one); we walk it into mark decorations whose class names line
//    up with the legend in `crates/ycode-lsp/src/client.rs:TOKEN_TYPES`.
//
// 2. **goto-def** — a mousedown handler that fires `onGotoDef(line, ch)` on
//    ⌘/Ctrl + left-click and `preventDefault`s the native text selection.
//
// Token legend must stay 1:1 with the Rust side. If you reorder/add an entry
// there, mirror it here or the colours will silently drift.

import { Decoration, EditorView, type DecorationSet } from "@codemirror/view";
import { RangeSetBuilder, StateEffect, StateField } from "@codemirror/state";

/// Must match `crates/ycode-lsp/src/client.rs:TOKEN_TYPES` exactly — the
/// indices in the LSP `data` array are positions into this list.
export const LSP_TOKEN_TYPES = [
  "namespace",
  "type",
  "class",
  "enum",
  "interface",
  "struct",
  "typeParameter",
  "parameter",
  "variable",
  "property",
  "enumMember",
  "event",
  "function",
  "method",
  "macro",
  "keyword",
  "modifier",
  "comment",
  "string",
  "number",
  "regexp",
  "operator",
  "decorator",
] as const;

/// Server response payload — only the shape we actually need.
export interface SemanticTokensResponse {
  data: number[];
}

const setLspTokens = StateEffect.define<DecorationSet>();

// ── cmd/ctrl-hover goto-def affordance ──────────────────────────────────────
//
// While the modifier is held, the word under the cursor gets a "this is a
// clickable link" underline — same gesture VS Code uses to telegraph that a
// ⌘-click will jump to definition. The field stores the word range (not a
// DecorationSet) so position-mapping through edits is a one-liner.

const setGotoHover = StateEffect.define<{ from: number; to: number } | null>();

const gotoHoverField = StateField.define<{ from: number; to: number } | null>({
  create: () => null,
  update(value, tr) {
    for (const eff of tr.effects) {
      if (eff.is(setGotoHover)) value = eff.value;
    }
    // Keep the highlight pinned to its text as the doc changes underneath it.
    if (value && !tr.changes.empty) {
      const from = tr.changes.mapPos(value.from);
      const to = tr.changes.mapPos(value.to);
      value = to > from ? { from, to } : null;
    }
    return value;
  },
  provide: (f) =>
    EditorView.decorations.compute([f], (state) => {
      const range = state.field(f);
      if (!range || range.to <= range.from) return Decoration.none;
      return Decoration.set([
        Decoration.mark({ class: "cm-lsp-goto-link" }).range(
          range.from,
          range.to,
        ),
      ]);
    }),
});

function clearGotoHover(view: EditorView) {
  if (view.state.field(gotoHoverField, false)) {
    view.dispatch({ effects: setGotoHover.of(null) });
  }
}

const lspTokensField = StateField.define<DecorationSet>({
  create: () => Decoration.none,
  update(value, tr) {
    let next = value.map(tr.changes);
    for (const eff of tr.effects) {
      if (eff.is(setLspTokens)) next = eff.value;
    }
    return next;
  },
  provide: (f) => EditorView.decorations.from(f),
});

/**
 * Decode an LSP semantic-tokens response into a CM6 decoration set and
 * dispatch it onto `view`. Silently no-ops when the response is empty or
 * the document already moved past the snapshot the server sent for.
 */
export function applyLspTokens(
  view: EditorView,
  response: SemanticTokensResponse | null | undefined,
) {
  if (!response || !Array.isArray(response.data)) {
    view.dispatch({ effects: setLspTokens.of(Decoration.none) });
    return;
  }
  const decorations = buildDecorations(view, response.data);
  view.dispatch({ effects: setLspTokens.of(decorations) });
}

function buildDecorations(view: EditorView, data: number[]): DecorationSet {
  const doc = view.state.doc;
  const builder = new RangeSetBuilder<Decoration>();
  let line = 0;
  let col = 0;
  for (let i = 0; i + 4 < data.length; i += 5) {
    const dLine = data[i];
    const dCol = data[i + 1];
    const len = data[i + 2];
    const typeIdx = data[i + 3];
    // tokenModifiers (data[i+4]) is ignored — none of our defaults map to
    // a distinct CSS class yet.
    if (dLine > 0) {
      line += dLine;
      col = dCol;
    } else {
      col += dCol;
    }
    if (line + 1 > doc.lines) break;
    const lineInfo = doc.line(line + 1);
    // Defensive clamp: rust-analyzer occasionally reports a token whose end
    // sticks past the line terminator on partial edits — clipping to
    // `lineInfo.to` keeps RangeSet from rejecting the range.
    const from = lineInfo.from + Math.min(col, lineInfo.length);
    const to = Math.min(from + len, lineInfo.to);
    if (to <= from) continue;
    const type = LSP_TOKEN_TYPES[typeIdx];
    if (!type) continue;
    builder.add(from, to, Decoration.mark({ class: `lsp-token-${type}` }));
  }
  return builder.finish();
}

/**
 * Build the LSP CM6 extension bundle. `onGotoDef(line, character)` is fired
 * with zero-indexed coordinates (LSP convention); the caller dispatches an
 * IPC `lsp_definition` call. Return value is ignored — the handler always
 * eats the click via `preventDefault`.
 */
export function createLspExtension(opts: {
  onGotoDef: (line: number, character: number) => void;
}) {
  return [
    lspTokensField,
    gotoHoverField,
    EditorView.domEventHandlers({
      mousedown(event, view) {
        if (event.button !== 0) return false;
        if (!(event.metaKey || event.ctrlKey)) return false;
        const pos = view.posAtCoords({ x: event.clientX, y: event.clientY });
        if (pos == null) return false;
        const lineInfo = view.state.doc.lineAt(pos);
        const lineNum = lineInfo.number - 1;
        const ch = pos - lineInfo.from;
        opts.onGotoDef(lineNum, ch);
        clearGotoHover(view);
        event.preventDefault();
        return true;
      },
      mousemove(event, view) {
        // Only telegraph the link while the modifier is held. We key off the
        // event's own `metaKey`/`ctrlKey` so we don't need to track keyboard
        // state separately — the user has to move the mouse a hair after
        // pressing ⌘, which matches VS Code's feel.
        if (!(event.metaKey || event.ctrlKey)) {
          clearGotoHover(view);
          return false;
        }
        const pos = view.posAtCoords({ x: event.clientX, y: event.clientY });
        if (pos == null) {
          clearGotoHover(view);
          return false;
        }
        const word = view.state.wordAt(pos);
        if (!word) {
          clearGotoHover(view);
          return false;
        }
        const cur = view.state.field(gotoHoverField, false);
        if (cur && cur.from === word.from && cur.to === word.to) return false;
        view.dispatch({
          effects: setGotoHover.of({ from: word.from, to: word.to }),
        });
        return false;
      },
      mouseleave(_event, view) {
        clearGotoHover(view);
        return false;
      },
      keyup(event, view) {
        // Releasing the modifier should drop the underline even if the mouse
        // hasn't moved since.
        if (!event.metaKey && !event.ctrlKey) clearGotoHover(view);
        return false;
      },
    }),
  ];
}
