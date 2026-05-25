// Map filenames and folder names to material-icon-theme SVG asset URLs.
//
// material-icon-theme ships its mapping in `dist/material-icons.json` and the
// SVGs in `icons/<name>.svg`. We:
//   1. eagerly resolve every SVG to a hashed URL via Vite's `import.meta.glob`
//      (only the URL strings end up in the JS bundle — the SVGs themselves
//      are fetched lazily by the browser when an icon actually renders)
//   2. look up `fileExtensions` / `fileNames` / `folderNames` keys against the
//      shipped mapping to choose which icon to render
//
// If a name has no specific mapping, we fall back to the theme's `file` /
// `folder` defaults.

import manifest from "material-icon-theme/dist/material-icons.json";

// Build the URL table. The path string is what Vite expects — leading slash
// makes it project-root-relative so node_modules works.
const iconUrls = import.meta.glob<string>(
  "/node_modules/material-icon-theme/icons/*.svg",
  { eager: true, query: "?url", import: "default" },
);

// Strip the directory prefix so we can index by icon name only.
const URL_BY_NAME: Record<string, string> = {};
for (const [path, url] of Object.entries(iconUrls)) {
  const base = path.split("/").pop();
  if (!base) continue;
  const name = base.replace(/\.svg$/, "");
  URL_BY_NAME[name] = url;
}

const m = manifest as unknown as MaterialIconsManifest;
const DEFAULT_FILE = m.file;
const DEFAULT_FOLDER = m.folder;
const DEFAULT_FOLDER_OPEN = m.folderExpanded;

interface MaterialIconsManifest {
  file: string;
  folder: string;
  folderExpanded: string;
  fileExtensions: Record<string, string>;
  fileNames: Record<string, string>;
  folderNames: Record<string, string>;
  folderNamesExpanded: Record<string, string>;
}

/// Resolve the icon URL for a file. `name` is the basename (e.g. `index.ts`).
export function iconForFile(name: string): string | null {
  const lower = name.toLowerCase();
  const byName = m.fileNames[lower];
  if (byName) return URL_BY_NAME[byName] ?? null;

  // Try progressively shorter extensions: `index.test.tsx` → tries `test.tsx`
  // then `tsx`. material-icon-theme registers compound extensions for some
  // file types (e.g. test files, story files).
  const parts = lower.split(".");
  for (let i = 1; i < parts.length; i++) {
    const ext = parts.slice(i).join(".");
    const byExt = m.fileExtensions[ext];
    if (byExt) return URL_BY_NAME[byExt] ?? null;
  }
  return URL_BY_NAME[DEFAULT_FILE] ?? null;
}

/// Resolve the icon URL for a folder. Uses the expanded variant when `open`
/// is true so opened folders show the lighter "open" glyph.
export function iconForFolder(name: string, open: boolean): string | null {
  const lower = name.toLowerCase();
  const table = open ? m.folderNamesExpanded : m.folderNames;
  const byName = table[lower];
  if (byName) return URL_BY_NAME[byName] ?? null;
  const fallback = open ? DEFAULT_FOLDER_OPEN : DEFAULT_FOLDER;
  return URL_BY_NAME[fallback] ?? null;
}
