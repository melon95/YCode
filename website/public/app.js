// English copy lives in the HTML; Chinese overrides are keyed by data-i.
const zh = {
  skip: '跳至正文', navTour: '演示', navPanels: '面板', navStart: '开始使用', navFaq: '常见问题',
  heroTitle: '编程 Agent，<br>并排工作。',
  heroBody: 'Tandock 是 Mac 原生工作台，支持 Claude Code、Codex、Pi 或任意 CLI。每个 Agent 都有自己的真实终端，文件、Git 变更和待办一个快捷键就能打开。',
  download: '下载 macOS 版', viewSource: '查看源码',
  compat: '需要 macOS 14 或更高版本，支持 Apple Silicon 和 Intel。MIT 协议免费开源。',
  layoutGrid: '四宫格', layoutColumns: '多栏', layoutMain: '主 + 侧', demoSearch: '搜索会话',
  s1: '调整欢迎页间距', s2: '更新 plan.md', s3: '跑测试', s4: '审阅变更',
  workspaceShot: '原生工作台，项目内容为演示数据。',
  stageCaption: '四个独立会话，各自运行在独立 PTY 中。切换布局，看看 Tandock 如何排列它们。',
  agentsTitle: '带上你正在用的 CLI', customCli: '在设置中添加任意命令',
  agentsNote: 'Tandock 不附带模型或订阅。按平常的方式安装并登录各个 CLI 即可。',
  filmTitle: '53 秒看完整个工作台',
  filmMeta: '启动 Agent、排列会话、查看代码、审阅变更、共享待办，以及把这一切串起来的快捷键。',
  filmFallback: '下载视频',
  panelsTitle: '不离开终端，也能看清上下文', panelsIntro: '在会话旁打开面板，用完再关掉。App 里也是同样的快捷键。',
  tabFiles: '文件', tabChanges: '变更', tabTodos: '待办',
  startTitle: '从文件夹到第一个会话',
  s1Title: '打开项目', s1Body: '选择任意本地文件夹。选 Git 仓库就能审阅和提交变更。',
  s2Title: '新建会话', s2Body: '选择 Claude Code、Codex、Pi 或自定义 CLI。Pi 等工具可在「设置 → Agent」中添加。',
  s3Title: '随处搜索', s3Body: '在一个面板里搜索会话、待办、历史和可用动作。',
  faqTitle: '下载前你可能想知道',
  q1: '支持哪些 Mac？', a1: 'Tandock 支持 macOS 14 及以上系统，发布包兼容 Apple Silicon 和 Intel。下载 ZIP，解压后将 Tandock 拖入「应用程序」即可。',
  q2: '包含 AI 服务或订阅吗？', a2: '不包含。Tandock 免费开源，采用 MIT 许可证。你需要安装并登录自己的 Agent CLI，模型服务和费用由对应工具的提供方处理。',
  q3: '这是一个完整的代码编辑器吗？', a3: '编辑器用于文件查看、基础语法高亮和小幅手动修改，支持 Markdown、SVG 与图片预览。不提供 LSP、语义诊断或定义跳转。',
  q4: '能用 worktree 隔离会话吗？', a4: '原生版目前尚未接入 worktree 隔离，虽然新建会话时能看到入口。当前请使用普通项目会话。',
  q5: '支持深色模式和中文吗？', a5: '支持。应用有中英文界面，以及浅色、深色和跟随系统外观。本页截图来自更名前的 0.7.0，使用英文界面与示例项目数据。',
  q6: '可以自己编译吗？', a6: '可以。需要带 Swift 6 工具链的 Xcode、macOS 14 或更高版本和 Git。克隆仓库后执行：',
  copy: '复制',
  closingTitle: '给你的 Agent 一个像样的工作台。', closingMeta: '需要 macOS 14 或更高版本。免费开源。',
  footer: '属于你的原生 Agent 工作台。', license: 'MIT 许可证',
};
const english = Object.fromEntries([...document.querySelectorAll('[data-i]')].map(el => [el.dataset.i, el.innerHTML]));

const copy = {
  en: {
    title: 'Tandock — Run your coding agents side by side', lang: '切换到中文', toggle: '中文', film: 'Tandock product overview film',
    layoutGroup: 'Layout', copied: 'Copied to clipboard.', copyFailed: 'Select the commands above to copy them.',
    panels: {
      files: ['Read the code your agent is touching.', 'Browse the file tree, preview Markdown, SVG, and images, and save small edits with ⌘S.', "Built for reading and light edits. There's no LSP or go-to-definition.", 'Tandock file tree and a Swift file with syntax highlighting'],
      changes: ['Review every change before it lands.', 'Read inline diffs file by file, stage a single hunk, and commit. Switch branches, fetch, pull, and push from the same panel.', 'Session checkpoints let you see what changed during a conversation.', 'Tandock Changes panel showing Swift and Markdown diffs'],
      overview: ['Keep one list of what comes next.', 'Queue, doing, and done. Agents read and update the same list through the built-in MCP tools, so progress shows up while they work.', 'Todos are stored per project on your Mac.', 'Tandock Todos panel next to a Swift file'],
    },
    chapters: [[0, 'Opening'], [5, 'Launch an agent'], [10, 'Parallel sessions'], [17, 'Layouts'], [24, 'Files'], [30, 'Git review'], [36, 'Todos and MCP'], [42, 'Shortcuts'], [48, 'Closing']],
    scripts: {
      claude: [['p', '› tighten spacing on the welcome screen'], ['', '● Read Sources/WelcomeView.swift'], ['', '● Edit spacing: 16 → 20'], ['ok', 'Updated 1 file  +3 −3']],
      codex: [['p', '› note this update in plan.md'], ['', '• Open docs/plan.md'], ['', '• Append "This update"'], ['ok', 'Done  +4']],
      pi: [['p', '› run the test suite'], ['cmd', '$ swift test'], ['dim', 'Executed 42 tests, 0 failures'], ['ok', 'All tests passed']],
      review: [['p', '› review this branch'], ['', '● git diff main...HEAD'], ['', '● 2 files  +7 −3'], ['ok', 'No blocking issues']],
    },
  },
  zh: {
    title: 'Tandock — 让多个编程 Agent 并排工作', lang: 'Switch to English', toggle: 'EN', film: 'Tandock 产品介绍视频',
    layoutGroup: '布局', copied: '已复制到剪贴板。', copyFailed: '请选中上方命令手动复制。',
    panels: {
      files: ['看清 Agent 正在改的代码。', '浏览文件树，预览 Markdown、SVG 和图片，小改动用 ⌘S 直接保存。', '定位是查看和轻量编辑，不提供 LSP 或定义跳转。', 'Tandock 文件树与带语法高亮的 Swift 文件'],
      changes: ['每处变更，落地前先过目。', '逐文件查看内联 diff，按块暂存再提交。切换分支、Fetch、Pull、Push 都在同一个面板里。', '会话检查点能看到一次对话里改了什么。', 'Tandock 变更面板中的 Swift 和 Markdown 差异'],
      overview: ['接下来要做什么，只留一份清单。', '队列、进行中、已完成。Agent 通过内置 MCP 工具读写同一份待办，工作进度随时可见。', '待办按项目保存在你的 Mac 上。', 'Tandock 待办面板与 Swift 文件'],
    },
    chapters: [[0, '开场'], [5, '启动 Agent'], [10, '多会话并行'], [17, '布局切换'], [24, '文件'], [30, 'Git 审阅'], [36, '待办与 MCP'], [42, '快捷键'], [48, '结尾']],
    scripts: {
      claude: [['p', '› 调整欢迎页的间距'], ['', '● 读取 Sources/WelcomeView.swift'], ['', '● 编辑 spacing: 16 → 20'], ['ok', '已更新 1 个文件  +3 −3']],
      codex: [['p', '› 在 plan.md 里记录这次更新'], ['', '• 打开 docs/plan.md'], ['', '• 追加「This update」'], ['ok', '完成  +4']],
      pi: [['p', '› 跑一遍测试'], ['cmd', '$ swift test'], ['dim', 'Executed 42 tests, 0 failures'], ['ok', '全部通过']],
      review: [['p', '› 审阅当前分支'], ['', '● git diff main...HEAD'], ['', '● 2 个文件  +7 −3'], ['ok', '没有阻塞问题']],
    },
  },
};

const motion = matchMedia('(prefers-reduced-motion: reduce)');
let language = 'en';
let view = 'files';
try { language = localStorage.getItem('ycode-language') === 'zh' ? 'zh' : 'en'; } catch {}

function applyLanguage() {
  const t = copy[language];
  document.documentElement.lang = language === 'zh' ? 'zh-CN' : 'en';
  document.querySelectorAll('[data-i]').forEach(el => { el.innerHTML = (language === 'zh' && zh[el.dataset.i]) || english[el.dataset.i]; });
  document.querySelectorAll('[data-i-aria]').forEach(el => el.setAttribute('aria-label', t[el.dataset.iAria]));
  const toggle = document.querySelector('#language');
  toggle.textContent = t.toggle; toggle.setAttribute('aria-label', t.lang);
  document.title = t.title;
  document.querySelectorAll('.layouts button').forEach(button => {
    button.setAttribute('aria-label', button.querySelector('span').textContent);
  });
  document.querySelector('#copy-status').textContent = '';
  updateFilm(); renderChapters(); renderPanel(); typeDemo();
}

document.querySelector('#language').addEventListener('click', () => {
  language = language === 'en' ? 'zh' : 'en';
  try { localStorage.setItem('ycode-language', language); } catch {}
  applyLanguage();
});

// ---------- Film: one rendered file per language, plus chapter links ----------
const video = document.querySelector('#intro-video');
function updateFilm() {
  const src = `assets/tandock-overview.${language}.mp4`;
  const source = video.querySelector('source');
  video.setAttribute('aria-label', copy[language].film);
  if (source.getAttribute('src') === src) return;
  video.pause();
  source.setAttribute('src', src);
  video.poster = `assets/tandock-overview-poster.${language}.jpg`;
  document.querySelector('#film-download').href = src;
  video.load();
}
const fmt = s => `${Math.floor(s / 60)}:${String(s % 60).padStart(2, '0')}`;
function renderChapters() {
  const list = document.querySelector('#chapters');
  list.setAttribute('aria-label', language === 'zh' ? '视频章节' : 'Chapters');
  list.replaceChildren(...copy[language].chapters.map(([at, label]) => {
    const li = document.createElement('li');
    const button = document.createElement('button');
    button.type = 'button'; button.dataset.at = at;
    button.innerHTML = `<time>${fmt(at)}</time><span></span>`;
    button.querySelector('span').textContent = label;
    button.addEventListener('click', () => { video.currentTime = at; video.play().catch(() => {}); });
    li.append(button);
    return li;
  }));
  markChapter();
}
function markChapter() {
  const buttons = [...document.querySelectorAll('#chapters button')];
  let active = -1;
  buttons.forEach((b, i) => { if (video.currentTime >= Number(b.dataset.at) && video.currentTime > 0) active = i; });
  buttons.forEach((b, i) => b.setAttribute('aria-current', String(i === active)));
}
video.addEventListener('timeupdate', markChapter);

// ---------- Panels dock: tabs mirror the app's panel shortcuts ----------
const tabs = [...document.querySelectorAll('.dock-tabs [role=tab]')];
function renderPanel() {
  const [title, body, limit, alt] = copy[language].panels[view];
  document.querySelector('#panel-title').textContent = title;
  document.querySelector('#panel-body').textContent = body;
  document.querySelector('#panel-limit').textContent = limit;
  const img = document.querySelector('#panel-shot');
  img.alt = alt;
  if (!img.src.endsWith(`/${view}.png`)) img.src = `assets/${view}.png`;
}
function selectTab(tab) {
  view = tab.dataset.view;
  tabs.forEach(t => { const on = t === tab; t.setAttribute('aria-selected', String(on)); t.tabIndex = on ? 0 : -1; });
  document.querySelector('#panel-view').setAttribute('aria-labelledby', tab.id);
  renderPanel();
}
tabs.forEach((tab, i) => {
  tab.addEventListener('click', () => selectTab(tab));
  tab.addEventListener('keydown', e => {
    const next = { ArrowRight: (i + 1) % tabs.length, ArrowLeft: (i + tabs.length - 1) % tabs.length, Home: 0, End: tabs.length - 1 }[e.key];
    if (next === undefined) return;
    e.preventDefault(); tabs[next].focus(); selectTab(tabs[next]);
  });
});

// ---------- Interactive demo: typing terminals and animated layouts ----------
const canvas = document.querySelector('#canvas');
const panes = [...canvas.querySelectorAll('.pane')];
let typingRun = 0;

function typeDemo() {
  const run = ++typingRun;
  const scripts = copy[language].scripts;
  panes.forEach((pane, index) => {
    const pre = pane.querySelector('pre');
    const lines = scripts[pane.dataset.agent];
    if (motion.matches) {
      pre.replaceChildren(...lines.map(([kind, text]) => line(kind, text)));
      pre.append(cursor());
      return;
    }
    pre.replaceChildren(cursor());
    let delay = 300 + index * 380;
    lines.forEach(([kind, text]) => {
      const el = line(kind, '');
      if (kind === 'p') {
        [...text].forEach((ch, c) => setTimeout(() => { if (run !== typingRun) return; if (c === 0) pre.insertBefore(el, pre.lastChild); el.textContent += ch; }, delay + c * 38));
        delay += text.length * 38 + 260;
      } else {
        setTimeout(() => { if (run !== typingRun) return; el.textContent = text; pre.insertBefore(el, pre.lastChild); }, delay);
        delay += 420;
      }
    });
  });
}
function line(kind, text) {
  const el = document.createElement('span');
  if (kind) el.className = kind;
  el.textContent = text;
  el.style.display = 'block';
  return el;
}
function cursor() {
  const el = document.createElement('span'); el.className = 'cursor'; el.setAttribute('aria-hidden', 'true');
  return el;
}

// FLIP: measure, switch the grid, then animate each pane from its old box.
document.querySelectorAll('.layouts button').forEach(button => button.addEventListener('click', () => {
  const layout = button.dataset.layout;
  if (canvas.classList.contains(`layout-${layout}`)) return;
  const before = panes.map(p => p.getBoundingClientRect());
  canvas.className = `canvas layout-${layout}`;
  document.querySelectorAll('.layouts button').forEach(b => b.setAttribute('aria-pressed', String(b === button)));
  panes.forEach(p => p.classList.toggle('focus', layout === 'main' && p === panes[0]));
  if (motion.matches) return;
  panes.forEach((pane, i) => {
    const after = pane.getBoundingClientRect();
    if (!after.width || !before[i].width) return;
    const dx = before[i].left - after.left, dy = before[i].top - after.top;
    const sx = before[i].width / after.width, sy = before[i].height / after.height;
    pane.animate([
      { transformOrigin: 'top left', transform: `translate(${dx}px, ${dy}px) scale(${sx}, ${sy})` },
      { transformOrigin: 'top left', transform: 'none' },
    ], { duration: 420, easing: 'cubic-bezier(.2,.8,.2,1)' });
  });
}));
panes.forEach(pane => pane.addEventListener('click', () => panes.forEach(p => p.classList.toggle('focus', p === pane))));

// ---------- Copy build commands ----------
document.querySelector('#copy').addEventListener('click', async () => {
  const status = document.querySelector('#copy-status');
  try {
    await navigator.clipboard.writeText('git clone https://github.com/melon95/YCode.git Tandock\ncd Tandock/macos\nswift test\nscripts/build_and_run.sh run');
    status.textContent = copy[language].copied;
  } catch {
    status.textContent = copy[language].copyFailed;
  }
});

applyLanguage();

// Keep content visible without scripts or motion support; animate each real
// section's content once when it enters the viewport.
if (!motion.matches && 'IntersectionObserver' in window) {
  const entrances = new IntersectionObserver(entries => {
    for (const entry of entries) {
      if (!entry.isIntersecting) continue;
      entry.target.classList.add('is-entering');
      entrances.unobserve(entry.target);
    }
  }, { threshold: 0.1 });
  document.querySelectorAll('.agents > *, .tour-head > *, .tour-body, .panels-head > *, .dock, .workspace-shot, .start > *, .faq > *, .closing > *').forEach(el => entrances.observe(el));
}
