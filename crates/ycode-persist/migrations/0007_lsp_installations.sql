-- LSP installation tracking. One row per language server the user has
-- successfully installed. The row is what the Settings UI consults to know
-- whether to show "Install" vs "Uninstall", and what version label to render.

CREATE TABLE lsp_installations (
    id              TEXT PRIMARY KEY,           -- matches ServerManifest.id
    version         TEXT NOT NULL,              -- e.g. "2024-08-01" / "v4.2.0"
    binary_path     TEXT NOT NULL,              -- absolute path on disk
    installed_at    INTEGER NOT NULL            -- unix ms
);
