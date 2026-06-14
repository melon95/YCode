// Markdown → sanitized HTML for the editor's Preview tab. Opened repos are
// untrusted, so a README could embed `<img onerror>` or <script>; everything
// goes through DOMPurify before it touches the DOM.

import { marked } from "marked";
import DOMPurify from "dompurify";

marked.setOptions({
  gfm: true,
  breaks: false,
});

export function renderMarkdown(src: string): string {
  // `async: false` keeps parse synchronous so callers get a string, not a
  // Promise — we don't use any async marked extensions.
  const html = marked.parse(src, { async: false }) as string;
  return DOMPurify.sanitize(html, { USE_PROFILES: { html: true } });
}
