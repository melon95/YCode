# YCode website

Bilingual product website for YCode. Static HTML, CSS, and JavaScript; no framework dependencies.

## Local preview

```sh
python3 -m http.server 4173 --bind 127.0.0.1 --directory public
```

Open http://127.0.0.1:4173. Source content is based on the repository's Chinese and English README files. Images are the original native-app screenshots with sample data. The screenshot interface and sample content are English; website copy supports English and Chinese.

Design: pale lavender surfaces and ink-purple terminals, with the icon's coral accent and yellow sparkle, Schibsted Grotesk for text and JetBrains Mono for terminal content, light and dark modes. The hero is an interactive YCode window: four terminals type in on load and the Grid / Columns / Main and side buttons rearrange them with a FLIP animation. Other sections: supported CLIs, the overview film with chapter links, a panels dock (Files / Changes / Todos with the app's shortcuts), a three-step start, FAQ with copyable build commands. Language choice persists in localStorage and swaps the film. Motion respects the system's reduced-motion preference.

## Cloudflare deployment

The deployment target is https://ycode.agentscience.com.cn. `wrangler.jsonc` configures the `ycode-website` Worker to serve static assets and bind the custom domain. Source assets live in `public/`; only the generated `dist/` directory is uploaded.

From this directory, with the domain's Cloudflare account authenticated (set `CLOUDFLARE_ACCOUNT_ID` in your local environment if you have multiple accounts):

```sh
python3 build.py
npx wrangler@4.132.0 deploy
```

The overview film follows the interactive hero and supported-CLI section. It plays the language-matched overview film (`ycode-overview.en.mp4` or `ycode-overview.zh.mp4`), switching source, poster, and download link with the page language. The panels dock and getting-started section follow it. Video playback starts on user interaction.

Local environment files and hosting account bindings are excluded from source control.

Run the video response regression checks with `node --test tests/worker.test.mjs`. They cover byte ranges, HEAD metadata and If-Range validators.

## Overview film

The homepage and `public/intro.html` use a 53-second, 1920×1080 product overview rendered in two languages: `ycode-overview.en.mp4` and `ycode-overview.zh.mp4`, with matching posters (`ycode-overview-poster.<lang>.jpg`) and shared en/zh captions. It covers launching an agent, four parallel sessions, layouts, files, Git review, todos over MCP, and ⌘K. `intro.html` is the English standalone page with chapter buttons and a transcript.

The film uses no screen recordings or screenshots. `scripts/render_overview.py` draws every frame procedurally (window chrome, terminal panes, panels, camera moves, captions, synthesized audio) as an illustrative animation with sample content. All on-screen text lives in English in the script, with a Chinese mapping (`ZH_UI`) applied for `--lang zh`. Rebuild with Python, Pillow, NumPy, and FFmpeg on macOS (uses PingFang / Menlo / Apple Symbols system fonts):

```sh
python3 scripts/render_overview.py --lang en
python3 scripts/render_overview.py --lang zh
```

Chrome needs HTTP Range support to seek video; `python3 -m http.server` lacks it, so use `npx http-server public` when testing chapter jumps locally.

Product scope and historical design references are indexed in [docs/README.md](../docs/README.md). Website mock terminal content and the rendered overview film are illustrative examples, not runtime acceptance evidence.
