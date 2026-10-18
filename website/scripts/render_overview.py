"""Render the YCode product overview film in English or Chinese, fully procedurally.

Usage: python3 scripts/render_overview.py [--lang en|zh] [contact-sheet.jpg]
Requires Pillow, NumPy, FFmpeg, rsvg-convert (librsvg) and macOS system fonts (PingFang SC or Hiragino Sans GB, Menlo).
No screen recordings or screenshots are used: every frame of the YCode window,
terminals, panels and motion graphics is drawn here as an illustrative animation.
Outputs ycode-overview.<lang>.mp4, ycode-overview-poster.<lang>.jpg and zh/en captions into public/assets.
"""
from pathlib import Path
from functools import lru_cache
import glob
import math
import subprocess
import sys
import tempfile
import wave
import numpy as np
from PIL import Image, ImageDraw, ImageFont, ImageFilter

ROOT = Path(__file__).resolve().parents[1]
A = ROOT / 'public/assets'
W, H, FPS = 1920, 1080, 24
# The app window is drawn at 2x logical size, then downsampled for crisp text.
LW, LH, K = 1390, 796, 2
BOX = (265, 211, LW, LH)
INK = '#23251f'
MUTED = '#6c7163'
ACCENT = '#b64b2c'
GREEN = '#407568'
UI_MUTED = '#7c7f75'
UI_LINE = '#dedcd5'
SELECT = '#e3e9f8'
SELECT_INK = '#3552c4'

# name, seconds, title, subtitle
SCENES = [
 ('intro', 5, 'Agents, code, changes.', 'One workspace.'),
 ('launch', 5, 'Start with the CLI you know', 'Claude Code, Codex, Pi, or your own CLI. Every session runs in its own PTY.'),
 ('four', 7, 'Four sessions, side by side', 'Each agent keeps its own terminal process. No context switching.'),
 ('layout', 7, 'Layouts that follow your flow', 'Main and side, columns, or a grid. Refocus and rearrange in one step.'),
 ('files', 6, 'Read code next to the terminal', 'File tree, syntax highlighting, Markdown and image preview. Save quick edits in place.'),
 ('changes', 6, 'Review every change an agent makes', 'Inline diffs, hunk staging, commits, and Fetch / Pull / Push.'),
 ('todos', 6, 'Todos, shared with your agents', 'Queue, doing, done. Agents read and write the same list through MCP tools.'),
 ('palette', 6, 'Drive the workspace from the keyboard', '⌘K finds sessions, todos, and actions. Every panel has a shortcut.'),
 ('outro', 5, 'YCode', 'A native multi-agent workspace for macOS'),
]
TOTAL = sum(s[1] for s in SCENES)

args = [a for a in sys.argv[1:]]
LANG = 'en'
if '--lang' in args:
    i = args.index('--lang'); LANG = args[i+1]; del args[i:i+2]
if LANG not in ('en', 'zh'):
    raise SystemExit('--lang must be en or zh')

# Every on-screen English string maps to its Chinese counterpart for --lang zh.
ZH_UI = {
 'Agents, code, changes.': '把 Agent、代码和变更', 'One workspace.': '放在同一个工作台。',
 'Start with the CLI you know': '从你熟悉的 CLI 开始',
 'Claude Code, Codex, Pi, or your own CLI. Every session runs in its own PTY.': 'Claude Code、Codex、Pi 或自定义 CLI，每个会话运行在独立 PTY 中。',
 'Four sessions, side by side': '最多四个会话，同屏并行',
 'Each agent keeps its own terminal process. No context switching.': '每个 Agent 保留自己的终端进程，互不打扰。',
 'Layouts that follow your flow': '布局随工作切换',
 'Main and side, columns, or a grid. Refocus and rearrange in one step.': '主侧、多栏、四宫格，一键调整焦点与排列。',
 'Read code next to the terminal': '在终端旁直接看代码',
 'File tree, syntax highlighting, Markdown and image preview. Save quick edits in place.': '文件树、语法高亮、Markdown 与图片预览，小改动当场保存。',
 'Review every change an agent makes': '审阅 Agent 的每一处变更',
 'Inline diffs, hunk staging, commits, and Fetch / Pull / Push.': '内联 diff、逐块暂存、提交，以及 Fetch / Pull / Push。',
 'Todos, shared with your agents': '待办，与 Agent 共享',
 'Queue, doing, done. Agents read and write the same list through MCP tools.': '队列、进行中、已完成；Agent 通过 MCP 工具读写同一份待办。',
 'Drive the workspace from the keyboard': '键盘驱动整个工作台',
 '⌘K finds sessions, todos, and actions. Every panel has a shortcut.': '⌘K 搜索会话、待办与动作，常用面板都有快捷键。',
 'A native multi-agent workspace for macOS': 'macOS 原生多 Agent 工作台',
 '› tighten spacing and copy on the welcome screen': '› 调整欢迎页的间距和文案', '● Read Sources/WelcomeView.swift': '● 读取 Sources/WelcomeView.swift',
 '● Edit spacing: 16 → 20': '● 编辑 spacing: 16 → 20', '● Edit padding: 24 → 32': '● 编辑 padding: 24 → 32',
 '✓ Updated 1 file  +3 −3': '✓ 已更新 1 个文件  +3 −3', '› note this update in plan.md': '› 在 plan.md 里记录这次更新',
 '• Open docs/plan.md': '• 打开 docs/plan.md', '• Append a "This update" section': '• 追加「This update」小节',
 '✓ Done  +4': '✓ 完成  +4', '› run the test suite': '› 跑一遍测试', '✓ All tests passed': '✓ 全部通过',
 '› review the changes on this branch': '› 审阅当前分支的变更', '● 2 files  +7 −3': '● 2 个文件  +7 −3', '✓ No blocking issues': '✓ 没有阻塞问题',
 'Files': '文件', 'Changes': '变更', 'Changes  2': '变更  2', 'Todos': '待办', 'Terminal': '终端', 'Search sessions': '搜索会话',
 'Running': '运行中', 'Idle': '空闲', '+  New Session': '+  新建会话', 'Saved  ⌘S': '已保存  ⌘S',
 '✓ Staged': '✓ 已暂存', 'Stage hunk': '暂存块', 'Commit message': '提交说明', 'Committed': '已提交', 'Commit': '提交',
 'Check contrast in dark mode': '检查深色模式下的对比度', '+  Add Todo': '+  添加待办',
 'Doing': '进行中', 'Queue': '队列', 'Done': '已完成',
 'Polish the welcome screen': '打磨欢迎页', 'Check light and dark appearance': '检查浅色和深色外观',
 'Review changes and commit': '审阅变更并提交', 'Tidy up the project README': '整理项目 README',
 'Claude Code updated your todos': 'Claude Code 更新了待办', 'MCP · todo_update  →  1 marked done': 'MCP · todo_update  →  已完成 1 项',
 'NATIVE AGENT WORKSPACE · macOS': '原生多 Agent 工作台 · macOS',
 'ILLUSTRATIVE ANIMATION · MODELED ON THE NATIVE YCODE UI': '示意动画 · 按 YCode 原生界面绘制',
 'Welcome spacing': '调整欢迎页间距', 'Update plan.md': '更新 plan.md', 'Run tests': '跑测试', 'Review changes': '审阅变更',
 'Terminals, files, Git, and todos in one native window.': '终端、文件、Git 和待办，一个窗口全部就位。',
 'NATIVE macOS · FREE & OPEN SOURCE': 'macOS 原生 · 免费开源',
 'Your agents, code, and changes in one workspace.': '把 Agent、代码和变更放在同一个工作台',
 'New Session': '新建会话', 'Pick an agent to start in Welcome.': '选择一个 Agent，在 Welcome 中开始',
 'CLAUDE CODE · OWN PTY': 'Claude Code · 独立 PTY', 'CHOOSE YOUR AGENT': '选择 Agent',
 'GRID': '四宫格', 'MAIN + SIDE': '主 + 侧', 'COLUMNS': '多栏', '⇧⌘3 FOCUS': '⇧⌘3 聚焦',
 'FILE TREE': '文件树', 'SYNTAX HIGHLIGHTING': '语法高亮', 'EDIT · ⌘S TO SAVE': '手动编辑 · ⌘S 保存',
 'INLINE DIFF': '内联 diff', 'STAGE BY HUNK': '逐块暂存', 'COMMIT · PUSH': '提交 · Push',
 'ADD A TODO': '添加待办', 'AGENTS WRITE VIA MCP': 'Agent 经 MCP 读写', 'QUEUE → DOING → DONE': '队列 → 进行中 → 已完成',
 'Search sessions, todos, history, actions': '搜索会话、待办、历史与动作',
 'Sessions': '会话', 'Session': '会话', 'Actions': '动作', 'Open Changes panel': '打开变更面板',
 'Claude Code · Welcome spacing': 'Claude Code · 调整欢迎页间距', 'Codex · Update plan.md': 'Codex · 更新 plan.md',
 'Command palette': '命令面板', 'New session': '新建会话', 'Toggle panels': '切换面板', 'Focus a pane': '聚焦窗格',
}

def tr(value):
    return ZH_UI.get(value, value) if LANG == 'zh' else value

# ---------- fonts and easing ----------

def cjk_font_path():
    found = glob.glob('/System/Library/AssetsV2/com_apple_MobileAsset_Font*/*/AssetData/PingFang.ttc')
    if found:
        return found[0], {'regular': 3, 'medium': 7, 'bold': 11}
    return '/System/Library/Fonts/Hiragino Sans GB.ttc', {'regular': 0, 'medium': 0, 'bold': 1}

CJK, FACES = cjk_font_path()

@lru_cache(None)
def font(size, kind='regular'):
    if kind in ('mono', 'monobold'):
        return ImageFont.truetype('/System/Library/Fonts/Menlo.ttc', size, index=1 if kind == 'monobold' else 0)
    if kind == 'sym':
        return ImageFont.truetype('/System/Library/Fonts/Apple Symbols.ttf', size)
    return ImageFont.truetype(CJK, size, index=FACES[kind])

# PingFang lacks these glyphs; Menlo covers most, Apple Symbols the rest.
MENLO_SYM = set('⌘⌕☐▸▾✓')

def face_for(ch, kind):
    if ch == '⑂':
        return 'sym'
    if ch in MENLO_SYM and kind not in ('mono', 'monobold'):
        return 'monobold' if kind == 'bold' else 'mono'
    return kind

def runs_of(value, choose):
    runs = []
    for ch in value:
        k = choose(ch)
        if runs and runs[-1][1] == k:
            runs[-1][0] += ch
        else:
            runs.append([ch, k])
    return runs

def text_width(value, size, kind='regular'):
    value = tr(value)
    return sum(font(size, k).getlength(r) for r, k in runs_of(value, lambda ch: face_for(ch, kind)))

def draw_text(d, x, y, value, size, fill, kind='regular', anchor='la'):
    """Draw with per-glyph font fallback; anchor semantics match PIL."""
    value = tr(value)
    runs = runs_of(value, lambda ch: face_for(ch, kind))
    x -= {'l': 0, 'm': .5, 'r': 1}[anchor[0]]*text_width(value, size, kind)
    for run, k in runs:
        f = font(size, k)
        d.text((x, y), run, font=f, fill=fill, anchor='l'+anchor[1])
        x += f.getlength(run)

def clamp(t):
    return max(0, min(1, t))

def ease(t):
    return 1-(1-clamp(t))**3

def inout(t):
    t = clamp(t)
    return t*t*(3-2*t)

def lerp(a, b, q):
    return a+(b-a)*q

def lerp_rect(a, b, q):
    return tuple(lerp(a[i], b[i], q) for i in range(len(a)))

def fade(img, alpha):
    if alpha < .999:
        img.putalpha(img.getchannel('A').point(lambda v: int(v*alpha)))
    return img

# ---------- 2x canvas in logical coordinates ----------

class Canvas:
    def __init__(self, w, h, bg=(0,0,0,0)):
        self.w, self.h = w, h
        self.im = Image.new('RGBA', (int(w*K), int(h*K)), bg)
        self.d = ImageDraw.Draw(self.im)

    def rect(self, x, y, w, h, r=0, fill=None, outline=None, width=1):
        box = [x*K, y*K, (x+w)*K-1, (y+h)*K-1]
        if box[2] <= box[0] or box[3] <= box[1]:
            return
        self.d.rounded_rectangle(box, int(r*K), fill=fill, outline=outline, width=int(width*K))

    def blend(self, x, y, w, h, r, rgba):
        layer = Image.new('RGBA', self.im.size)
        ImageDraw.Draw(layer).rounded_rectangle([x*K, y*K, (x+w)*K-1, (y+h)*K-1], int(r*K), fill=rgba)
        self.im.alpha_composite(layer)

    def text(self, x, y, v, size, fill=INK, kind='regular', anchor='la'):
        draw_text(self.d, x*K, y*K, v, int(size*K), fill, kind, anchor)

    def tw(self, v, size, kind='regular'):
        return text_width(v, int(size*K), kind)/K

    def mixed(self, x, y, v, size, fill, bold=False):
        """Monospace for ASCII runs, CJK font for the rest; y is the baseline."""
        v = tr(v)
        mono = 'monobold' if bold else 'mono'
        cjk = 'bold' if bold else 'regular'
        for run, kind in runs_of(v, lambda ch: mono if ord(ch) < 128 else face_for(ch, cjk)):
            f = font(int(size*K), kind)
            self.d.text((x*K, y*K), run, font=f, fill=fill, anchor='ls')
            x += f.getlength(run)/K
        return x

    def circle(self, cx, cy, r, fill):
        self.d.ellipse([(cx-r)*K, (cy-r)*K, (cx+r)*K, (cy+r)*K], fill=fill)

    def paste(self, img, x, y):
        self.im.alpha_composite(img, (int(x*K), int(y*K)))

# ---------- agents and terminal content (illustrative) ----------

CLAUDE = [('head','Claude Code  ·  ~/Welcome'),('p','› tighten spacing and copy on the welcome screen'),('i','● Read Sources/WelcomeView.swift'),
          ('i','● Edit spacing: 16 → 20'),('i','● Edit padding: 24 → 32'),('ok','✓ Updated 1 file  +3 −3')]
CODEX = [('head','Codex  ·  workspace-write'),('p','› note this update in plan.md'),('i','• Open docs/plan.md'),
         ('i','• Append a "This update" section'),('ok','✓ Done  +4')]
PI = [('head','Pi  ·  ~/Welcome'),('p','› run the test suite'),('cmd','$ swift test'),('i','Building for debugging...'),
      ('i','Executed 42 tests, with 0 failures'),('ok','✓ All tests passed')]
REVIEW = [('head','Claude Code  ·  review'),('p','› review the changes on this branch'),('i','● git diff main...HEAD'),
          ('i','● 2 files  +7 −3'),('ok','✓ No blocking issues')]
AGENTS = {
 'claude': ('Claude Code', '#d97757', CLAUDE, 'C'),
 'codex': ('Codex', '#7b6cf6', CODEX, 'X'),
 'pi': ('Pi', '#2f6fed', PI, 'P'),
 'review': ('Claude Code', '#d97757', REVIEW, 'C'),
}
LINE_COLOR = {'head': '#f1efe6', 'p': '#f0a57f', 'i': '#bdbab0', 'cmd': '#9dbaf0', 'ok': '#8fcf9c'}

def terminal(w, h, agent, t, focus=False):
    """One PTY pane as its own canvas so content clips naturally."""
    name, color, script, _ = AGENTS[agent]
    c = Canvas(w, h)
    c.rect(0, 0, w, h, 9, fill='#1d1f1a')
    c.rect(0, 0, w, 28, 9, fill='#26281f')
    c.rect(0, 18, w, 10, 0, fill='#26281f')
    c.circle(16, 14, 4.5, color)
    c.text(28, 14, name, 12.5, '#e9e6dc', 'medium', 'lm')
    if w > 260:
        c.text(w-12, 14, 'PTY · zsh', 11, '#8d8a80', 'mono', 'rm')
    lines, y, step = [], 54, 21
    for i, (kind, value) in enumerate(script):
        at = i*.42
        if t < at:
            break
        if kind == 'p':
            value = tr(value)[:max(1, int((t-at)*26))]
        lines.append((kind, value))
    visible = max(1, int((h-44)/step))
    for kind, value in lines[-visible:]:
        c.mixed(14, y, value, 13, LINE_COLOR[kind], bold=kind == 'head')
        y += step
    if int(t*2.2) % 2 == 0:
        c.rect(14 + (0 if not lines else 0), y-13, 8, 15, 0, fill='#d8d5ca')
    if focus:
        c.rect(0, 0, w, h, 9, outline=ACCENT, width=2.5)
    return c.im

# ---------- app window chrome ----------

TABS = [('Files','⌘1'), ('Changes','⌘2'), ('Todos','⌘3'), ('Terminal','⌘4')]
SIDEBAR = 206
TOP = 46

def window(sessions, tool=None, panel_w=0):
    c = Canvas(LW, LH, (255,255,255,255))
    # Toolbar
    c.rect(0, 0, LW, TOP, 0, fill='#fbfaf8')
    c.rect(0, TOP-1, LW, 1, 0, fill=UI_LINE)
    for i, col in enumerate(['#ff5f57', '#febc2e', '#28c840']):
        c.circle(20+i*19, 23, 6, col)
    c.text(SIDEBAR+18, 23, 'Welcome', 15, INK, 'bold', 'lm')
    c.text(SIDEBAR+100, 23, '⑂ feature/welcome', 12, UI_MUTED, 'regular', 'lm')
    x = LW-14
    for label, key in reversed(TABS):
        tw = c.tw(label, 13, 'medium')+c.tw(key, 11)+30
        x -= tw
        active = tool == label
        if active:
            c.rect(x, 9, tw, 28, 7, fill=SELECT)
        c.text(x+12, 23, label, 13, SELECT_INK if active else INK, 'medium', 'lm')
        c.text(x+tw-10, 23, key, 11, SELECT_INK if active else UI_MUTED, 'regular', 'rm')
        x -= 6
    # Sidebar
    c.rect(0, TOP, SIDEBAR, LH-TOP, 0, fill='#f5f4f0')
    c.rect(SIDEBAR-1, TOP, 1, LH-TOP, 0, fill=UI_LINE)
    c.rect(12, TOP+12, SIDEBAR-24, 30, 8, fill='#ebeae5')
    c.text(24, TOP+27, 'Search sessions', 12.5, UI_MUTED, 'regular', 'lm')
    c.text(SIDEBAR-22, TOP+27, '⌘K', 11, UI_MUTED, 'regular', 'rm')
    c.text(16, TOP+66, 'Welcome', 12.5, UI_MUTED, 'bold', 'lm')
    for i, (agent, title, running, alpha) in enumerate(sessions):
        if alpha <= 0:
            continue
        y = TOP+84+i*48
        row = Canvas(SIDEBAR, 48)
        if i == 0:
            row.rect(8, 2, SIDEBAR-16, 44, 8, fill='#e9e8e2')
        name, color, _, letter = AGENTS[agent]
        row.rect(18, 12, 22, 22, 6, fill=color)
        row.text(29, 23, letter, 12, 'white', 'bold', 'mm')
        row.text(50, 17, title, 12.5, INK, 'medium', 'lm')
        row.text(50, 34, f"{name} · {tr('Running' if running else 'Idle')}", 10.5, UI_MUTED, 'regular', 'lm')
        if running:
            row.circle(SIDEBAR-24, 24, 3.5, '#3fae63')
        c.paste(fade(row.im, alpha), 0, y)
    c.text(18, LH-24, '+  New Session', 12.5, INK, 'medium', 'lm')
    # Canvas area and optional right panel
    right = LW-panel_w
    c.rect(SIDEBAR, TOP, right-SIDEBAR, LH-TOP, 0, fill='#ebeae5')
    if panel_w > 0:
        c.rect(right-1, TOP, 1, LH-TOP, 0, fill=UI_LINE)
    return c, (SIDEBAR+8, TOP+8, right-8, LH-8), (right, TOP, panel_w, LH-TOP)

def arrangement(name, area):
    x0, y0, x1, y1 = area
    g = 8; w = x1-x0; h = y1-y0
    hw, hh = (w-g)/2, (h-g)/2
    hidden = (x1, y1, 0, 0)
    if name == 'one':
        return [(x0,y0,w,h)] + [hidden]*3
    if name == 'two':
        return [(x0,y0,hw,h), (x0+hw+g,y0,hw,h), hidden, hidden]
    if name == 'three':
        return [(x0,y0,hw,h), (x0+hw+g,y0,hw,hh), (x0+hw+g,y0+hh+g,hw,hh), hidden]
    if name == 'grid':
        return [(x0,y0,hw,hh), (x0+hw+g,y0,hw,hh), (x0,y0+hh+g,hw,hh), (x0+hw+g,y0+hh+g,hw,hh)]
    if name == 'mainside':
        mw = w*.6; sw = w-mw-g; sh = (h-2*g)/3
        return [(x0,y0,mw,h)] + [(x0+mw+g, y0+i*(sh+g), sw, sh) for i in range(3)]
    if name == 'columns':
        cw = (w-3*g)/4
        return [(x0+i*(cw+g), y0, cw, h) for i in range(4)]

def keyframes(frames, t):
    """frames: [(time, arrangement)]; returns (from, to, q)."""
    for (t0, a), (t1, b) in zip(frames, frames[1:]):
        if t < t1:
            return a, b, inout((t-t0-(t1-t0-.7))/.7)
    return frames[-1][1], frames[-1][1], 1

def draw_panes(c, area, agents, frames, t, starts, focus=None):
    a, b, q = keyframes(frames, t)
    ra, rb = arrangement(a, area), arrangement(b, area)
    for i, agent in enumerate(agents):
        x, y, w, h = lerp_rect(ra[i], rb[i], q)
        if w < 40 or h < 40:
            continue
        pane = terminal(int(w), int(h), agent, t-starts[i], focus == i)
        c.paste(fade(pane, clamp(min(w, h)/160)), x, y)
    return [lerp_rect(ra[i], rb[i], q) for i in range(len(agents))]

def cursor(c, x, y):
    pts = [(0,0),(0,19),(5,15),(9,23),(12,22),(8,14),(14,14)]
    c.d.polygon([((x+px)*K, (y+py)*K) for px, py in pts], fill='white', outline='#1d1f1a', width=K*1)

def click_ring(c, x, y, t):
    if 0 <= t < .6:
        r = 8+24*ease(t/.6); a = int(200*(1-t/.6))
        layer = Image.new('RGBA', c.im.size)
        ImageDraw.Draw(layer).ellipse([(x-r)*K, (y-r)*K, (x+r)*K, (y+r)*K], outline=(182,75,44,a), width=3*K)
        c.im.alpha_composite(layer)

# ---------- right-side panels ----------

KW, STR, NUM = '#a846b9', '#c8412f', '#2f6fed'
CODE = [
 [('import', KW), (' SwiftUI', INK)],
 [],
 [('struct', KW), (' WelcomeView: View {', INK)],
 [('    let', KW), (' projectName: String', INK)],
 [],
 [('    var', KW), (' body: ', INK), ('some', KW), (' View {', INK)],
 [('        VStack(alignment: .leading, spacing: ', INK), ('SPACING', NUM), (') {', INK)],
 [('            Text(', INK), ('"Welcome to \\(projectName)"', STR), (')', INK)],
 [('                .font(.largeTitle.bold())', INK)],
 [('            Text(', INK), ('"Build something you care about."', STR), (')', INK)],
 [('                .foregroundStyle(.secondary)', INK)],
 [('        }', INK)],
 [('        .padding(', INK), ('32', NUM), (')', INK)],
 [('    }', INK)],
 [('}', INK)],
]

def panel_header(c, x, y, w, title, extra=''):
    c.rect(x, y, w, 40, 0, fill='#fbfaf8')
    c.rect(x, y+39, w, 1, 0, fill=UI_LINE)
    c.text(x+16, y+20, title, 13.5, INK, 'bold', 'lm')
    if extra:
        c.text(x+22+c.tw(title, 13.5, 'bold'), y+20, extra, 12, SELECT_INK, 'regular', 'lm')

def files_panel(c, rect, t):
    x, y, w, h = rect
    c.rect(x, y, w, 40, 0, fill='#fbfaf8')
    c.rect(x+12, y+7, 190, 26, 6, fill=SELECT)
    c.text(x+24, y+20, 'WelcomeView.swift', 12.5, SELECT_INK, 'medium', 'lm')
    c.text(x+190, y+20, '×', 13, SELECT_INK, 'regular', 'mm')
    if t > 4.3:
        c.text(x+w-16, y+20, 'Saved  ⌘S', 12, '#3f8f5a', 'medium', 'rm')
    c.rect(x, y+39, w, 1, 0, fill=UI_LINE)
    tree_w = 200
    c.rect(x+tree_w, y+40, 1, h-40, 0, fill=UI_LINE)
    expanded = t > 1.0
    rows = [('▸  docs', 0, '#3a6fd8'), ('▾  Sources' if expanded else '▸  Sources', 0, '#3a6fd8')]
    if expanded:
        rows.append(('WelcomeView.swift', 1, '#e8653d'))
    rows += [('.gitignore', 0, '#d0562f'), ('README.md', 0, '#3a6fd8')]
    for i, (label, depth, col) in enumerate(rows):
        ry = y+52+i*30
        if label == 'WelcomeView.swift' and t > 1.5:
            c.rect(x+4, ry-2, tree_w-8, 28, 6, fill=SELECT)
        c.circle(x+20+depth*16, ry+12, 4, col)
        c.text(x+32+depth*16, ry+12, label, 12.5, INK, 'regular', 'lm')
    if t < 1.5:
        return
    reveal = ease((t-1.5)/.6)
    spacing = '16' if t < 3.4 else ('1' if t < 3.6 else '20')
    cx = x+tree_w+18
    for i, tokens in enumerate(CODE):
        ly = y+70+i*22
        c.text(cx, ly, str(i+1), 11.5, '#b2b3aa', 'mono', 'rs')
        px = cx+18
        for value, col in tokens:
            value = value.replace('SPACING', spacing)
            layer_col = col
            px = c.mixed(px, ly, value, 13, layer_col)
        if i == 6 and 3.0 < t:
            c.blend(cx+14, ly-16, w-tree_w-40, 22, 4, (182,75,44,int(26*clamp((t-3)/.3))))
    if reveal < 1:
        c.blend(x+tree_w+1, y+41, w-tree_w-1, h-41, 0, (255,255,255,int(255*(1-reveal))))

DIFF = [
 (4, ' ', '    let projectName: String'), (6, ' ', '    var body: some View {'),
 (7, '-', '        VStack(alignment: .leading, spacing: 16) {'),
 (7, '+', '        VStack(alignment: .leading, spacing: 20) {'),
 (8, ' ', '            Text("Welcome to \\(projectName)")'),
 (11, '-', '            Text("Your next idea starts here.")'),
 (11, '+', '            Text("Build something you care about.")'),
 (14, '-', '        .padding(24)'), (14, '+', '        .padding(32)'), (15, ' ', '    }'),
]
PLAN = [(11, ' ', 'Small steps. One focused change per commit.'), (12, '+', ''),
        (13, '+', '## This update'), (14, '+', ''), (15, '+', 'Refine spacing and copy on the welcome screen.')]

def diff_block(c, x, y, w, name, folder, stat, rows, staged, stage_t):
    c.rect(x, y, w, 34, 0, fill='#fbfaf8')
    c.rect(x+12, y+9, 16, 16, 4, fill='#ecebe5')
    c.text(x+20, y+17, 'M', 10, UI_MUTED, 'bold', 'mm')
    c.text(x+38, y+17, name, 13.5, INK, 'bold', 'lm')
    c.text(x+46+c.tw(name, 13.5, 'bold'), y+17, folder, 12, UI_MUTED, 'regular', 'lm')
    c.text(x+w-14, y+17, stat, 12, '#3f8f5a', 'medium', 'rm')
    y += 34
    c.rect(x, y, w, 26, 0, fill='#f4f3ef')
    c.text(x+14, y+13, '@@ -4,13 +4,13 @@' if name.endswith('swift') else '@@ -9,3 +9,7 @@', 11.5, UI_MUTED, 'mono', 'lm')
    if staged:
        c.rect(x+w-104, y+3, 92, 20, 5, fill='#e3f3e6')
        c.text(x+w-58, y+13, '✓ Staged', 11.5, '#2f7d4a', 'medium', 'mm')
    else:
        c.rect(x+w-86, y+3, 74, 20, 5, fill='white', outline=UI_LINE)
        c.text(x+w-49, y+13, 'Stage hunk', 11.5, INK, 'medium', 'mm')
    y += 26
    for n, sign, value in rows:
        bg = {'-': '#fbe6e2', '+': '#e3f3e6'}.get(sign)
        if bg:
            c.rect(x, y, w, 21, 0, fill=bg)
        if staged and sign != ' ':
            c.rect(x, y, 3, 21, 0, fill='#3fae63')
        c.text(x+34, y+15, str(n), 11, '#a8a9a0', 'mono', 'rs')
        col = {'-': '#b43a2a', '+': '#2c7a45'}.get(sign, INK)
        c.mixed(x+46, y+15, (sign if sign != ' ' else ' ')+value, 12, col)
        y += 21
    return y

def changes_panel(c, rect, t):
    x, y, w, h = rect
    panel_header(c, x, y, w, 'Changes  2', 'main → feature/welcome')
    staged = t > 2.8
    yy = diff_block(c, x, y+40, w, 'WelcomeView.swift', 'Sources', '+3 −3', DIFF, staged, 2.8)
    diff_block(c, x, yy+8, w, 'plan.md', 'docs', '+4', PLAN, t > 3.3, 3.3)
    # Commit bar
    by = y+h-56
    c.rect(x, by, w, 56, 0, fill='#fbfaf8')
    c.rect(x, by, w, 1, 0, fill=UI_LINE)
    c.rect(x+12, by+12, w-120, 32, 7, fill='white', outline=UI_LINE)
    msg = 'Refine welcome spacing and copy'
    typed = msg[:int(clamp((t-3.5)/1.0)*len(msg))]
    c.mixed(x+24, by+33, typed if typed else 'Commit message', 12.5, INK if typed else UI_MUTED)
    pressed = t > 4.7
    c.rect(x+w-98, by+12, 86, 32, 7, fill='#2f7d4a' if pressed else INK)
    c.text(x+w-55, by+28, 'Committed' if pressed else 'Commit', 13, 'white', 'medium', 'mm')
    return (x+w-55, by+28), (x+w-49, y+40+34+13)

def todos_panel(c, rect, t):
    x, y, w, h = rect
    moved = inout((t-3.3)/.6)
    added = t > 2.1
    panel_header(c, x, y, w, f"{tr('Todos')}  {3+int(added)}")
    c.rect(x+12, y+52, w-24, 34, 8, fill='white', outline=UI_LINE)
    draft = tr('Check contrast in dark mode')
    typed = draft[:int(clamp((t-.7)/1.1)*len(draft))] if t < 2.1 else ''
    c.text(x+28, y+69, typed if typed else '+  Add Todo', 13, INK if typed else UI_MUTED, 'regular', 'lm')
    # Item slots: section headers and rows are laid out from state, then interpolated.
    def layout(after):
        doing = ['review'] if after else ['polish']
        queue = ['dark', 'check'] if added else ['check', 'review']
        if not after and added:
            queue = ['check', 'review', 'dark']
        if after:
            queue = ['check', 'dark']
        done = ['old', 'polish'] if after else ['old']
        pos, yy, heads = {}, y+110, []
        for label, items in [('Doing', doing), ('Queue', queue), ('Done', done)]:
            heads.append((label, yy, len(items))); yy += 30
            for it in items:
                pos[it] = yy; yy += 38
            yy += 10
        return pos, heads
    before, heads_b = layout(False)
    after, heads_a = layout(True)
    labels = {'polish': 'Polish the welcome screen', 'check': 'Check light and dark appearance', 'review': 'Review changes and commit',
              'dark': 'Check contrast in dark mode', 'old': 'Tidy up the project README'}
    for (label, yb, nb), (_, ya, na) in zip(heads_b, heads_a):
        hy = lerp(yb, ya, moved)
        c.text(x+16, hy+12, label, 12, UI_MUTED, 'bold', 'lm')
        c.text(x+w-16, hy+12, str(na if moved > .5 else nb), 11.5, UI_MUTED, 'regular', 'rm')
    for key, label in labels.items():
        if key not in before and key not in after:
            continue
        yb = before.get(key, after.get(key)); ya = after.get(key, yb)
        iy = lerp(yb, ya, moved)
        alpha = 1 if key != 'dark' else clamp((t-2.1)/.3)
        if alpha <= 0:
            continue
        done = key == 'old' or (key == 'polish' and moved > .5)
        doing = (key == 'polish' and moved <= .5) or (key == 'review' and moved > .5)
        row = Canvas(w, 38)
        if key in ('polish', 'review') and 0 < moved < 1:
            row.rect(8, 1, w-16, 36, 7, fill='#f6efe9')
        if done:
            row.rect(16, 10, 18, 18, 5, fill='#3fae63')
            row.text(25, 19, '✓', 12, 'white', 'bold', 'mm')
        elif doing:
            row.rect(16, 10, 18, 18, 5, fill='#c98a2c')
            row.circle(25, 19, 3.5, 'white')
        else:
            row.rect(16, 10, 18, 18, 5, fill='white', outline='#b9bab0', width=1.5)
        row.text(44, 19, label, 13.5, UI_MUTED if done else INK, 'regular', 'lm')
        c.paste(fade(row.im, alpha), x, iy)
    # MCP toast from the agent that updated the list.
    q = ease((t-3.1)/.4) * (1-ease((t-5.4)/.4))
    if q > 0:
        tw = 360
        toast = Canvas(tw, 58)
        toast.rect(0, 0, tw, 58, 12, fill='#23251f')
        toast.rect(14, 16, 26, 26, 7, fill='#d97757')
        toast.text(27, 29, 'C', 13, 'white', 'bold', 'mm')
        toast.text(52, 20, 'Claude Code updated your todos', 13, 'white', 'medium', 'lm')
        toast.text(52, 40, 'MCP · todo_update  →  1 marked done', 11.5, '#bdbab0', 'regular', 'lm')
        c.paste(fade(toast.im, q), x+w-tw-16, y+470+int(16*(1-q)))

# ---------- scene composition ----------

def rounded_panel(im, shot, box, radius=15, alpha=1):
    x, y, w, h = map(int, box); w = max(1, w); h = max(1, h)
    panel = shot.resize((w, h), Image.Resampling.LANCZOS).convert('RGBA')
    mask = Image.new('L', (w, h)); ImageDraw.Draw(mask).rounded_rectangle((0,0,w-1,h-1), radius, fill=int(255*alpha))
    panel.putalpha(mask)
    shadow = Image.new('RGBA', (w+70, h+70))
    ImageDraw.Draw(shadow).rounded_rectangle((25,18,w+45,h+38), radius+7, fill=(32,40,29,int(38*alpha)))
    shadow = shadow.filter(ImageFilter.GaussianBlur(13))
    im.alpha_composite(shadow, (x-35, y-25))
    im.alpha_composite(panel, (x, y))
    ImageDraw.Draw(im).rounded_rectangle((x,y,x+w,y+h), radius, outline=(168,174,159,int(110*alpha)), width=1)

def text(im, xy, value, size=40, fill=INK, kind='regular', alpha=1, anchor='la'):
    if alpha <= 0:
        return
    layer = Image.new('RGBA', im.size)
    draw_text(ImageDraw.Draw(layer), xy[0], xy[1], value, size, fill, kind, anchor)
    im.alpha_composite(fade(layer, alpha))

def pill(im, x, y, label, color=INK, alpha=1):
    if alpha <= 0:
        return 0
    width = int(text_width(label, 20, 'medium'))+44
    layer = Image.new('RGBA', im.size); d = ImageDraw.Draw(layer)
    d.rounded_rectangle((x, y, x+width, y+40), 20, fill=color)
    draw_text(d, x+22, y+20, label, 20, 'white', 'medium', 'lm')
    im.alpha_composite(fade(layer, alpha))
    return width

yy, xx = np.mgrid[0:H, 0:W]
# Diagonal coordinate: 0 at the top-left corner, 2 at the bottom-right corner.
DIAG = (xx/W + yy/H).astype(np.float32)
TRANSITION = .6
ACCENT_RGB = np.array([182, 75, 44], dtype=np.float32)
# Each scene enters with its own transition.
TRANSITIONS = {'launch': 'iris', 'four': 'push', 'layout': 'tiles', 'files': 'sweep',
               'changes': 'split', 'todos': 'zoom', 'palette': 'push_up', 'outro': 'blur'}
IRIS_C = (W/2, H*.55)
DIST = np.hypot(xx-IRIS_C[0], yy-IRIS_C[1]).astype(np.float32)
TILE = 120
TCOLS, TROWS = W//TILE, math.ceil(H/TILE)
_col, _row = xx//TILE, yy//TILE
# Tiles flip in along the diagonal from the top-left.
TILE_DELAY = ((_col+_row)/(TCOLS+TROWS-2)*.55).astype(np.float32)
TILE_LX = np.abs(xx-(_col*TILE+TILE/2)).astype(np.float32)
TILE_LY = np.abs(yy-(_row*TILE+TILE/2)).astype(np.float32)
glow = np.exp(-(((xx-1560)/760)**2+((yy-830)/580)**2))
base = np.zeros((H, W, 3), dtype=np.float32)+np.array([246,245,241])
base -= glow[:, :, None]*np.array([19,12,23])
BG = Image.fromarray(np.uint8(base)).convert('RGBA')

def background(t):
    im = BG.copy(); d = ImageDraw.Draw(im)
    for i in range(3):
        x = 1550+int(math.sin(t*.19+i)*38); r = 300+i*75
        d.ellipse((x-r, 620-r, x+r, 620+r), outline=(205,210,198,100), width=1)
    d.text((68, 39), 'YCode', font=font(28, 'bold'), fill=INK)
    d.ellipse((164, 52, 172, 60), fill=ACCENT)
    d.text((W-68, 46), tr('NATIVE AGENT WORKSPACE · macOS'), font=font(17), fill=(110,114,102), anchor='ra')
    d.line((68, 1019, W-68, 1019), fill=(215,217,207), width=2)
    d.line((68, 1019, 68+(W-136)*t/TOTAL, 1019), fill=ACCENT, width=3)
    d.text((68, 1036), tr('ILLUSTRATIVE ANIMATION · MODELED ON THE NATIVE YCODE UI'), font=font(15), fill=(116,120,108))
    return im

def header(im, title, sub, local):
    q = ease(local/.75)
    text(im, (70, 100+int(22*(1-q))), title, 50, kind='bold', alpha=q)
    text(im, (73, 168), sub, 24, fill=MUTED, alpha=ease((local-.15)/.7))

def keycap(im, x, y, key, label, alpha, scale=1):
    if alpha <= 0:
        return
    layer = Image.new('RGBA', im.size); d = ImageDraw.Draw(layer)
    y += int(24*(1-alpha)); w, h = 230*scale, 116*scale
    d.rounded_rectangle((x+4, y+8, x+w+4, y+h+8), 18, fill=(35,37,31,40))
    d.rounded_rectangle((x, y, x+w, y+h), 18, fill=(255,255,255), outline=(210,212,202), width=2)
    draw_text(d, x+w/2, y+h*.42, key, int(40*scale), INK, 'bold', 'mm')
    draw_text(d, x+w/2, y+h*.8, label, int(18*scale), MUTED, 'regular', 'mm')
    im.alpha_composite(fade(layer, alpha))

# Camera: logical crop rects (x, y, width) inside the window.
def camera(local, target, start=.5, dur=1.6):
    q = inout((local-start)/dur)
    x, y, w = (lerp(a, b, q) for a, b in zip((0, 0, LW), target))
    return x, y, w

def show_window(im, c, cam=None, alpha=1):
    if cam is None:
        rounded_panel(im, c.im, BOX, 14, alpha); return
    x, y, w = cam; h = w*LH/LW
    rounded_panel(im, c.im.crop((int(x*K), int(y*K), int((x+w)*K), int((y+h)*K))), BOX, 14, alpha)

def to_screen(cam, px, py):
    x, y, w = cam; s = BOX[2]/w
    return BOX[0]+(px-x)*s, BOX[1]+(py-y)*s

def highlight(im, cam, rect, q):
    if q <= 0:
        return
    x0, y0 = to_screen(cam, rect[0], rect[1]); x1, y1 = to_screen(cam, rect[0]+rect[2], rect[1]+rect[3])
    layer = Image.new('RGBA', im.size); d = ImageDraw.Draw(layer)
    d.rounded_rectangle((x0-5, y0-5, x1+5, y1+5), 10, fill=(182,75,44,int(20*q)), outline=(182,75,44,int(255*q)), width=3)
    im.alpha_composite(layer)

def tags(im, items):
    """Right-aligned pills on the title row: [(label, color, alpha)], first is leftmost."""
    widths = [int(text_width(label, 20, 'medium'))+44 for label, _, a in items if a > 0]
    x = W-70-sum(widths)-12*max(0, len(widths)-1)
    for label, color, a in items:
        if a > 0:
            x += pill(im, x, 122-int(10*(1-a)), label, color, a)+12

def chips(im, items, local):
    tags(im, [(label, ACCENT, ease((local-at)/.4)) for label, at in items])

ICON = None
S4 = ['claude', 'codex', 'pi', 'review']
SESS = [('claude', 'Welcome spacing'), ('codex', 'Update plan.md'), ('pi', 'Run tests'), ('review', 'Review changes')]

def sessions(n, t=99, appear=()):
    out = []
    for i, (agent, title) in enumerate(SESS[:n]):
        a = clamp((t-appear[i])/.4) if i < len(appear) else 1
        out.append((agent, title, True, a))
    return out

def render_frame(scene, local, global_t, index, prev=None):
    name, duration, title, sub = scene
    im = background(global_t)
    q = ease(local/.75)
    if name == 'intro':
        for k, agent in enumerate(S4):
            amt = ease((local-k*.13)/.85)
            x = 930+(k%2)*452+int(math.sin(local*.7+k)*7)
            y = 215+(k//2)*307+int(64*(1-amt)+math.sin(local*.6+k)*6)
            pane = terminal(414, 237, agent, local*1.1+.4-k*.25)
            rounded_panel(im, pane, (x, y, 414, 237), 13, amt)
        text(im, (70, 300+int(38*(1-q))), title, 70, kind='bold', alpha=q)
        text(im, (70, 400+int(40*(1-q))), sub, 70, kind='bold', fill=ACCENT, alpha=ease((local-.3)/.7))
        text(im, (74, 540), 'Terminals, files, Git, and todos in one native window.', 28, fill=MUTED, alpha=ease((local-.7)/.7))
        pill(im, 74, 610, 'NATIVE macOS · FREE & OPEN SOURCE', INK, ease((local-1)/.6))
    elif name == 'outro':
        a = ease(local/.9); size = 190
        icon = fade(ICON.resize((size, size), Image.Resampling.LANCZOS), a)
        im.alpha_composite(icon, (W//2-size//2, 200+int(30*(1-a))))
        text(im, (W//2, 470), title, 110, kind='bold', alpha=a, anchor='mm')
        text(im, (W//2, 570), sub, 40, fill=ACCENT, kind='medium', alpha=ease((local-.3)/.7), anchor='mm')
        text(im, (W//2, 650), 'Your agents, code, and changes in one workspace.', 28, fill=MUTED, alpha=ease((local-.6)/.7), anchor='mm')
        text(im, (W//2, 760), 'github.com/melon95/YCode', 30, fill=INK, kind='mono', alpha=ease((local-1)/.7), anchor='mm')
        text(im, (W//2, 815), 'macOS 14+ · Apple Silicon / Intel · MIT License', 22, fill=MUTED, alpha=ease((local-1.2)/.7), anchor='mm')
        if local > duration-.6:
            im.alpha_composite(Image.new('RGBA', im.size, (246,245,241,int(255*(local-(duration-.6))/.6))))
    elif name == 'launch':
        header(im, title, sub, local)
        c, area, _ = window(sessions(1, local, (2.0,)))
        ax0, ay0, ax1, ay1 = area
        cw, ch = 560, 300
        cx, cy = (ax0+ax1)/2-cw/2, (ay0+ay1)/2-ch/2
        tiles = [((cx+24+i*176), cy+150, 160, 96) for i in range(3)]
        card_a = 1-clamp((local-2.0)/.35)
        if card_a > 0:
            card = Canvas(cw, ch)
            card.rect(0, 0, cw, ch, 16, fill='white', outline=UI_LINE)
            card.paste(ICON.resize((40*K, 40*K), Image.Resampling.LANCZOS), cw/2-20, 24)
            card.text(cw/2, 88, 'New Session', 18, INK, 'bold', 'mm')
            card.text(cw/2, 114, 'Pick an agent to start in Welcome.', 12.5, UI_MUTED, 'regular', 'mm')
            for i, agent in enumerate(['claude', 'codex', 'pi']):
                nm, col, _, letter = AGENTS[agent]
                tx = 24+i*176
                hot = i == 0 and local > 1.2
                card.rect(tx, 150, 160, 96, 12, fill=SELECT if hot else '#f4f3ef', outline=SELECT_INK if hot and local > 1.6 else None, width=2)
                card.rect(tx+64, 166, 32, 32, 9, fill=col)
                card.text(tx+80, 182, letter, 16, 'white', 'bold', 'mm')
                card.text(tx+80, 224, nm, 13.5, INK, 'medium', 'mm')
            card.text(24, 276, '☐  worktree', 12, UI_MUTED, 'regular', 'lm')
            card.text(cw-24, 276, '⑂ feature/welcome', 12, SELECT_INK, 'regular', 'rm')
            c.paste(fade(card.im, card_a), cx, cy)
        # The chosen tile grows into the live terminal pane.
        g = inout((local-2.0)/.6)
        if g > 0:
            tile = tiles[0]
            rect = lerp_rect(tile, (ax0, ay0, ax1-ax0, ay1-ay0), g)
            pane = terminal(int(rect[2]), int(rect[3]), 'claude', local-2.5)
            c.paste(fade(pane, clamp(g*1.5)), rect[0], rect[1])
        if local < 2.1:
            p = inout((local-.4)/1.0)
            mx, my = lerp(ax1-160, tiles[0][0]+90, p), lerp(ay1-120, tiles[0][1]+56, p)
            cursor(c, mx, my)
            click_ring(c, tiles[0][0]+90, tiles[0][1]+56, local-1.6)
        show_window(im, c, alpha=q if index else 1)
        tags(im, [('CLAUDE CODE · OWN PTY' if local > 2.2 else 'CHOOSE YOUR AGENT', ACCENT, q)])
    elif name == 'four':
        header(im, title, sub, local)
        n = 1 if local < 1.2 else 2 if local < 2.9 else 3 if local < 4.1 else 4
        c, area, _ = window(sessions(4, local, (-1, 1.2, 2.9, 4.1)))
        frames = [(0, 'one'), (1.9, 'two'), (3.6, 'three'), (4.8, 'grid')]
        draw_panes(c, area, S4, frames, local, [-3, 1.4, 3.1, 4.3])
        show_window(im, c)
        tags(im, [((f'{n} 个独立会话' if LANG == 'zh' else f'{n} INDEPENDENT SESSION' + ('S' if n > 1 else '')), GREEN, q)])
        if local > 5.4:
            p = inout((local-5.4)/.5)
            ImageDraw.Draw(im).rounded_rectangle((BOX[0]+SIDEBAR+4, BOX[1]+TOP+4, BOX[0]+LW-4, BOX[1]+LH-4), 12, outline=GREEN, width=max(1, int(4*p)))
    elif name == 'layout':
        header(im, title, sub, local)
        c, area, _ = window(sessions(4))
        frames = [(0, 'grid'), (1.6, 'mainside'), (3.9, 'columns'), (6.2, 'grid')]
        focus = 0 if local < 3.2 else 2
        draw_panes(c, area, S4, frames, local, [-6, -5, -4, -3], focus)
        show_window(im, c)
        label = 'GRID' if local < .9 else 'MAIN + SIDE' if local < 3.2 else 'COLUMNS' if local < 5.5 else 'GRID'
        focus_a = ease((local-2.4)/.3)*(1-ease((local-3.3)/.3)) if 2.4 < local < 3.6 else 0
        tags(im, [('⇧⌘3 FOCUS', ACCENT, focus_a), (label, GREEN, q)])
    elif name == 'files':
        header(im, title, sub, local)
        pw = int(lerp(0, 700, inout((local-.2)/.7)))
        c, area, prect = window(sessions(4), 'Files', pw)
        ax0, ay0, ax1, ay1 = area
        c.paste(terminal(int(ax1-ax0), int(ay1-ay0), 'claude', 9), ax0, ay0)
        if pw > 20:
            files_panel(c, prect, local)
        cam = camera(local, (LW-760, TOP-6, 760), 1.3, 1.4)
        show_window(im, c, cam)
        highlight(im, cam, (prect[0]+4, prect[1]+48, 194, 160), inout((local-2.2)/.4))
        highlight(im, cam, (prect[0]+212, prect[1]+184, 480, 24), inout((local-3.2)/.4))
        chips(im, [('FILE TREE', 2.2), ('SYNTAX HIGHLIGHTING', 2.8), ('EDIT · ⌘S TO SAVE', 3.6)], local)
    elif name == 'changes':
        header(im, title, sub, local)
        pw = 700
        c, area, prect = window(sessions(4), 'Changes', pw)
        ax0, ay0, ax1, ay1 = area
        c.paste(terminal(int(ax1-ax0), int(ay1-ay0), 'review', 9), ax0, ay0)
        commit_at, stage_at = changes_panel(c, prect, local)
        if 2.1 < local < 3.0:
            cursor(c, lerp(prect[0]+300, stage_at[0], inout((local-2.1)/.5)), lerp(prect[1]+300, stage_at[1], inout((local-2.1)/.5)))
            click_ring(c, stage_at[0], stage_at[1], local-2.7)
        if 4.1 < local < 5.3:
            cursor(c, lerp(prect[0]+400, commit_at[0], inout((local-4.1)/.5)), lerp(prect[1]+500, commit_at[1], inout((local-4.1)/.5)))
            click_ring(c, commit_at[0], commit_at[1], local-4.7)
        cam = camera(local, (LW-760, TOP-6, 760), .4, 1.2)
        p = inout((local-3.3)/.8)
        cam = (cam[0], lerp(cam[1], LH-760*LH/LW, p), cam[2])
        show_window(im, c, cam)
        highlight(im, cam, (prect[0], prect[1]+100+21*2, pw, 42), inout((local-1.6)/.4)*(1-inout((local-2.6)/.3)))
        chips(im, [('INLINE DIFF', 1.6), ('STAGE BY HUNK', 2.8), ('COMMIT · PUSH', 4.7)], local)
    elif name == 'todos':
        header(im, title, sub, local)
        pw = 620
        c, area, prect = window(sessions(4), 'Todos', pw)
        ax0, ay0, ax1, ay1 = area
        c.paste(terminal(int(ax1-ax0), int(ay1-ay0), 'claude', 9), ax0, ay0)
        todos_panel(c, prect, local)
        cam = camera(local, (LW-940, TOP-6, 940), .3, 1.2)
        show_window(im, c, cam)
        chips(im, [('ADD A TODO', 1.0), ('AGENTS WRITE VIA MCP', 3.2), ('QUEUE → DOING → DONE', 3.8)], local)
    elif name == 'palette':
        header(im, title, sub, local)
        c, area, _ = window(sessions(4))
        draw_panes(c, area, S4, [(0, 'grid')], 9, [0, 0, 0, 0])
        o = ease((local-.4)/.3)
        if o > 0:
            c.blend(0, 0, LW, LH, 0, (30,32,27,int(90*o)))
            pw, ph = 640, 400
            px, py = (LW-pw)/2, 120-int(16*(1-o))
            p = Canvas(pw, ph)
            p.rect(0, 0, pw, ph, 16, fill='white', outline=UI_LINE)
            query = 'welcome'[:int(clamp((local-.8)/.7)*7)]
            p.text(20, 30, '⌕', 16, UI_MUTED, 'regular', 'lm')
            p.mixed(46, 36, query if query else 'Search sessions, todos, history, actions', 15, INK if query else UI_MUTED)
            p.rect(0, 58, pw, 1, 0, fill=UI_LINE)
            groups = [('Sessions', [('C', '#d97757', 'Claude Code · Welcome spacing', 'Session'), ('X', '#7b6cf6', 'Codex · Update plan.md', 'Session')]),
                      ('Todos', [('✓', '#c98a2c', 'Polish the welcome screen', 'Doing')]),
                      ('Actions', [('⌘', '#6c7163', 'Open Changes panel', '⌘2'), ('⌘', '#6c7163', 'New Session', '⌘N')])]
            sel = 0 if local < 2.4 else 2 if local < 3.2 else 3
            yy, row = 72, 0
            for gname, items in groups:
                p.text(20, yy+8, gname, 11.5, UI_MUTED, 'bold', 'lm'); yy += 22
                for letter, col, label, hint in items:
                    if query or local > 1.6:
                        if row == sel:
                            p.rect(8, yy, pw-16, 38, 8, fill=SELECT)
                        p.rect(20, yy+8, 22, 22, 6, fill=col)
                        p.text(31, yy+19, letter, 11, 'white', 'bold', 'mm')
                        p.text(54, yy+19, label, 13.5, SELECT_INK if row == sel else INK, 'regular', 'lm')
                        p.text(pw-22, yy+19, hint, 11.5, UI_MUTED, 'regular', 'rm')
                    yy += 40; row += 1
                yy += 4
            c.paste(fade(p.im, o), px, py)
        show_window(im, c, camera(local, ((LW-860)/2, 80, 860), .5, .9))
        keys = [('⌘K', 'Command palette'), ('⌘N', 'New session'), ('⌘1–4', 'Toggle panels'), ('⇧⌘1–4', 'Focus a pane')]
        for k, (key, label) in enumerate(keys):
            keycap(im, 330+k*320, 835, key, label, ease((local-3.4-k*.18)/.45), .9)
    frame = im.convert('RGB')
    if prev is not None and index > 0 and local < TRANSITION:
        frame = transition(TRANSITIONS[name], prev, frame, local/TRANSITION)
    return frame

def arr(img):
    return np.asarray(img, dtype=np.float32)

def to_img(a):
    return Image.fromarray(np.uint8(np.clip(a, 0, 255)))

def paint(out, mask, strength=1.):
    """Blend the accent color into out where mask (H, W) is set."""
    m = (mask*strength)[..., None]
    return out*(1-m) + ACCENT_RGB*m

def transition(kind, old, new, t):
    p = inout(t)
    if kind == 'sweep':
        return line_sweep(old, new, p)
    if kind == 'iris':
        r = p*math.hypot(W, H)*.62
        a = arr(old)*(1-.2*p); b = arr(new)
        m = np.clip((r-DIST)/3+.5, 0, 1)[..., None]
        out = a*(1-m) + b*m
        ring = np.clip(1-np.abs(DIST-r)/3.5, 0, 1)
        halo = np.exp(-((DIST-r)/40)**2)*.18
        return to_img(paint(paint(out, halo), ring))
    if kind in ('push', 'push_up'):
        horizontal = kind == 'push'
        span = W if horizontal else H
        off = int(span*p)
        canvas = Image.new('RGB', (W, H))
        dim = Image.eval(old, lambda v: int(v*(1-.25*p)))
        if horizontal:
            canvas.paste(dim, (-off, 0)); canvas.paste(new, (W-off, 0))
            ImageDraw.Draw(canvas).rectangle((W-off-3, 0, W-off+3, H), fill=tuple(int(c) for c in ACCENT_RGB))
        else:
            canvas.paste(dim, (0, -off)); canvas.paste(new, (0, H-off))
            ImageDraw.Draw(canvas).rectangle((0, H-off-3, W, H-off+3), fill=tuple(int(c) for c in ACCENT_RGB))
        return canvas
    if kind == 'tiles':
        q = np.clip((t-TILE_DELAY)/.45, 0, 1)
        q = q*q*(3-2*q)
        half = q*TILE/2
        m = ((TILE_LX < half) & (TILE_LY < half)).astype(np.float32)
        out = arr(old)*(1-m[..., None]) + arr(new)*m[..., None]
        # Fresh tiles start in the accent color and settle to the new frame.
        return to_img(paint(out, m*(1-q), .85))
    if kind == 'split':
        off = int(H/2*p)
        b = new.resize((int(W*(1.06-.06*p)), int(H*(1.06-.06*p))), Image.Resampling.BILINEAR)
        canvas = Image.new('RGB', (W, H))
        canvas.paste(b, ((W-b.width)//2, (H-b.height)//2))
        top = old.crop((0, 0, W, H//2)); bottom = old.crop((0, H//2, W, H))
        canvas.paste(top, (0, -off)); canvas.paste(bottom, (0, H//2+off))
        d = ImageDraw.Draw(canvas); col = tuple(int(c) for c in ACCENT_RGB)
        if 0 < off < H//2:
            d.rectangle((0, H//2-off-3, W, H//2-off), fill=col)
            d.rectangle((0, H//2+off, W, H//2+off+3), fill=col)
        return canvas
    if kind == 'zoom':
        def scaled(img, z):
            w, h = int(W*z), int(H*z)
            img = img.resize((w, h), Image.Resampling.BILINEAR)
            if z >= 1:
                return img.crop(((w-W)//2, (h-H)//2, (w-W)//2+W, (h-H)//2+H))
            canvas = Image.new('RGB', (W, H), (246, 245, 241)); canvas.paste(img, ((W-w)//2, (H-h)//2))
            return canvas
        a = arr(scaled(old, 1+.3*p)); b = arr(scaled(new, .9+.1*p))
        return to_img(a*(1-p) + b*p)
    if kind == 'blur':
        a = old.filter(ImageFilter.GaussianBlur(16*p)); b = new.filter(ImageFilter.GaussianBlur(16*(1-p)))
        return Image.blend(a, b, p)
    raise ValueError(kind)

def line_sweep(old, new, p):
    """A thin accent line travels from the bottom-right corner to the top-left.
    Behind it (toward the bottom-right) the new scene is revealed; ahead of it
    the previous scene stays, dimming slightly as the line approaches."""
    pos = 2.08 - 2.16*p
    a = np.asarray(old, dtype=np.float32); b = np.asarray(new, dtype=np.float32)
    reveal = np.clip((DIAG-pos)/.004 + .5, 0, 1)[..., None]
    ahead = np.clip(1-(pos-DIAG)/.22, 0, 1)[..., None]*(1-reveal)
    a = a*(1-.18*ahead)
    out = a*(1-reveal) + b*reveal
    glow = np.exp(-((DIAG-pos)/.035)**2)[..., None]*.22
    line = np.clip(1-np.abs(DIAG-pos)/.0032, 0, 1)[..., None]
    out = out*(1-glow) + ACCENT_RGB*glow
    out = out*(1-line) + ACCENT_RGB*line
    return Image.fromarray(np.uint8(np.clip(out, 0, 255)))

# ---------- sound: original synthesized score and UI effects ----------

SR = 48000
STARTS = dict(zip([s[0] for s in SCENES], np.cumsum([0]+[s[1] for s in SCENES])[:-1].tolist()))
# One chord per scene (I–vi–IV–V), so harmony changes land on the line sweep.
CHORDS = {'intro': [48,55,59,62,64], 'launch': [45,52,55,59,60], 'four': [41,48,52,55,57], 'layout': [43,50,55,57,62],
          'files': [48,55,59,62,64], 'changes': [45,52,55,59,60], 'todos': [41,48,52,55,57], 'palette': [43,50,55,57,62],
          'outro': [48,55,59,62,64,67]}

def hz(m):
    return 440*2**((m-69)/12)

def lowpass(x, k):
    """Cheap FIR lowpass: repeated moving averages."""
    for _ in range(2):
        x = np.convolve(x, np.ones(k)/k, mode='same')
    return x

class Mix:
    def __init__(self, n):
        self.l = np.zeros(n); self.r = np.zeros(n); self.n = n

    def add(self, sig, at, pan=0., gain=1.):
        i = int(at*SR)
        if i >= self.n or i < 0:
            return
        seg = sig[:self.n-i]
        if np.ndim(pan) == 0:
            pan = np.full(len(seg), pan)
        else:
            pan = pan[:len(seg)]
        self.l[i:i+len(seg)] += seg*gain*np.sqrt((1-pan)/2)
        self.r[i:i+len(seg)] += seg*gain*np.sqrt((1+pan)/2)

def env_adsr(n, a, r):
    e = np.ones(n); ai = max(1, int(a*SR)); ri = max(1, int(r*SR))
    e[:ai] = np.linspace(0, 1, ai)
    e[-ri:] *= np.linspace(1, 0, ri)
    return e

def pad_note(f, dur, rng):
    t = np.arange(int(dur*SR))/SR
    sig = np.zeros_like(t)
    for cents in (-6, 0, 5):
        fd = f*2**(cents/1200); ph = rng.uniform(0, 2*np.pi)
        for k in range(1, 7):
            sig += np.sin(2*np.pi*fd*k*t+ph*k)/k**1.7
    sig *= 1+.12*np.sin(2*np.pi*.23*t+rng.uniform(0, 6))
    return sig*env_adsr(len(t), .9, 1.2)/3

def pluck(f, dur=.9):
    t = np.arange(int(dur*SR))/SR
    sig = np.sin(2*np.pi*f*t) + .35*np.sin(2*np.pi*2*f*t)*np.exp(-t*6) + .12*np.sin(2*np.pi*3*f*t)*np.exp(-t*9)
    return sig*np.exp(-t*5.5)*np.minimum(1, t/.004)

def bass_note(f, dur):
    t = np.arange(int(dur*SR))/SR
    sig = np.sin(2*np.pi*f*t) + .25*np.sin(2*np.pi*2*f*t)
    return sig*np.minimum(1, t/.02)*np.exp(-t*1.6)*env_adsr(len(t), .01, .15)

def kick():
    t = np.arange(int(.35*SR))/SR
    f = 44+70*np.exp(-t*28)
    return np.sin(2*np.pi*np.cumsum(f)/SR)*np.exp(-t*11)

def hat(rng):
    x = rng.normal(0, 1, int(.06*SR))
    x = x - lowpass(x, 6)
    return x*np.exp(-np.arange(len(x))/SR*70)

def whoosh(rng, dur=.62):
    # Band-limited noise with a rising-then-falling brightness, swept right to left.
    n = int(dur*SR); u = np.arange(n)/n
    x = rng.normal(0, 1, n)
    bright = lowpass(x, 5) - lowpass(x, 90)
    dark = lowpass(x, 40)
    shape = np.sin(np.pi*np.clip(u/.8, 0, 1))**2
    tone = u**.6
    sig = (bright*tone + dark*(1-tone)*1.6)*shape
    return sig/np.max(np.abs(sig)), np.linspace(.75, -.75, n)

def click():
    t = np.arange(int(.05*SR))/SR
    rng = np.random.default_rng(3)
    return np.sin(2*np.pi*2300*t)*np.exp(-t*140)*.6 + rng.normal(0, 1, len(t))*np.exp(-t*420)*.5

def tick(rng):
    x = rng.normal(0, 1, int(.018*SR)); x = x - lowpass(x, 4)
    t = np.arange(len(x))/SR
    return x*np.exp(-t*380) + np.sin(2*np.pi*rng.uniform(3200, 4200)*t)*np.exp(-t*500)*.4

def pop(f0=620, f1=980):
    t = np.arange(int(.12*SR))/SR
    f = f0+(f1-f0)*np.minimum(1, t/.05)
    return np.sin(2*np.pi*np.cumsum(f)/SR)*np.exp(-t*34)*np.minimum(1, t/.002)

def chime(f):
    t = np.arange(int(1.6*SR))/SR
    sig = sum(a*np.sin(2*np.pi*f*r*t)*np.exp(-t*d) for r, a, d in [(1, 1, 3.2), (2.76, .35, 6), (5.4, .15, 11), (2, .25, 4.5)])
    return sig*np.minimum(1, t/.003)

def reverb(x, rng, seconds=2.2, decay=.55):
    t = np.arange(int(seconds*SR))/SR
    ir = rng.normal(0, 1, len(t))*np.exp(-t/decay)
    ir = lowpass(ir, 3); ir /= np.sqrt(np.sum(ir**2))
    size = 1 << int(np.ceil(np.log2(len(x)+len(ir))))
    y = np.fft.irfft(np.fft.rfft(x, size)*np.fft.rfft(ir, size), size)
    return y[:len(x)]

def soundtrack(path):
    n = int(TOTAL*SR); rng = np.random.default_rng(21)
    # Pad and arpeggio go to the hall; rhythm stays dry so low end never smears.
    music = Mix(n); rhythm = Mix(n); sfx = Mix(n)
    beat = 60/96
    # Pad and bass follow the per-scene chords.
    for name, dur, *_ in SCENES:
        at = STARTS[name]; chord = CHORDS[name]
        hold = dur+(3.5 if name == 'outro' else 1.2)
        # The bass carries the root, so the pad voices only the upper chord tones.
        for k, m in enumerate(chord[1:]):
            music.add(pad_note(hz(m), hold, rng), at-.35, pan=(k-len(chord)/2)*.18, gain=.03)
        if name not in ('intro', 'outro'):
            for b in np.arange(0, dur, beat*2):
                rhythm.add(bass_note(hz(chord[0]-12), beat*2), at+b, gain=.05)
    # Plucked arpeggio on eighth notes, sparse in the intro, resolving on the outro.
    pattern = [0, 2, 4, 3, 1, 3, 4, 2]
    step = beat/2
    for i, at in enumerate(np.arange(0, TOTAL-4.2, step)):
        name = next(nm for nm, _, *_ in reversed(SCENES) if STARTS[nm] <= at+1e-6)
        chord = CHORDS[name]
        if name == 'intro' and i % 2:
            continue
        m = chord[pattern[i % 8] % len(chord)]+24
        music.add(pluck(hz(m)), at, pan=.35 if i % 2 else -.35, gain=.1 if i % 4 == 0 else .07)
    # Light rhythm from the second scene until the outro.
    for at in np.arange(STARTS['launch'], STARTS['outro'], beat):
        k = int(round((at-STARTS['launch'])/beat))
        if k % 2 == 0:
            rhythm.add(kick(), at, gain=.09)
        if at >= STARTS['four']:
            rhythm.add(hat(rng), at+beat/2, pan=.25, gain=.035)
    music.add(chime(hz(84)), STARTS['outro']+.15, gain=.12)
    music.add(chime(hz(91)), STARTS['outro']+.55, pan=.2, gain=.08)
    # UI effects timed to on-screen actions.
    for name in list(STARTS)[1:]:
        sig, pan = whoosh(rng)
        if TRANSITIONS[name] not in ('push', 'sweep'):
            pan = pan*.15
        sfx.add(sig, STARTS[name]-.04, pan=pan, gain=.13)
    S = STARTS
    for at in [S['launch']+1.6, S['changes']+2.7, S['changes']+4.7, S['layout']+.9, S['layout']+3.2, S['layout']+5.5]:
        sfx.add(click(), at, gain=.22)
    for at in [S['four']+1.2, S['four']+2.9, S['four']+4.1, S['launch']+2.05, S['todos']+2.1]:
        sfx.add(pop(520, 820), at, gain=.14)
    chips_at = {'files': [2.2, 2.8, 3.6], 'changes': [1.6, 2.8, 4.7], 'todos': [1.0, 3.2, 3.8]}
    for name, times in chips_at.items():
        for k, at in enumerate(times):
            sfx.add(pop(700+k*120, 1100+k*120), S[name]+at, pan=.5, gain=.09)
    for k in range(4):
        sfx.add(pop(560+k*90, 900+k*90), S['palette']+3.4+k*.18, pan=-.45+k*.3, gain=.12)
    typing = [(S['todos']+.7, S['todos']+1.8, .075), (S['changes']+3.5, S['changes']+4.5, .065), (S['palette']+.8, S['palette']+1.5, .1)]
    for a, b, gap in typing:
        for at in np.arange(a, b, gap):
            sfx.add(tick(rng), at+rng.uniform(-.012, .012), pan=rng.uniform(-.2, .2), gain=.07)
    for at in [S['palette']+2.4, S['palette']+3.2]:
        sfx.add(tick(rng), at, gain=.1)
    sfx.add(chime(hz(88)), S['todos']+3.1, pan=.3, gain=.07)
    sfx.add(chime(hz(84)), S['files']+4.3, pan=.3, gain=.045)
    sfx.add(pop(400, 700), S['palette']+.4, gain=.1)
    # Master: music gets a hall, effects a short room; soft-limit and fade.
    wet_l = reverb(music.l, rng); wet_r = reverb(music.r, rng)
    room_l = reverb(sfx.l, rng, .6, .12); room_r = reverb(sfx.r, rng, .6, .12)
    left = music.l*.8 + wet_l*.35 + rhythm.l + sfx.l + room_l*.18
    right = music.r*.8 + wet_r*.35 + rhythm.r + sfx.r + room_r*.18
    # Gentle high-pass (~40 Hz) removes sub rumble.
    left = left - lowpass(left, 1200); right = right - lowpass(right, 1200)
    t = np.arange(n)/SR
    fade = np.minimum(1, t/.8)*np.minimum(1, (TOTAL-t)/2.2)
    stereo = np.column_stack([left*fade, right*fade])
    stereo /= np.max(np.abs(stereo))/.9
    stereo = np.tanh(stereo*1.1)/np.tanh(1.1)*.95
    with wave.open(str(path), 'wb') as f:
        f.setnchannels(2); f.setsampwidth(2); f.setframerate(SR)
        f.writeframes((np.clip(stereo, -1, 1)*32767).astype('<i2').tobytes())

ZH = ['把 Agent、代码和变更放在同一个工作台。',
      '从你熟悉的 CLI 开始：Claude Code、Codex、Pi 或自定义 CLI，每个会话运行在独立 PTY 中。',
      '最多四个会话同屏并行，每个 Agent 保留自己的终端进程。',
      '布局随工作切换：主侧、多栏、四宫格，一键调整焦点与排列。',
      '在终端旁直接看代码：文件树、语法高亮、Markdown 与图片预览，小改动当场保存。',
      '审阅 Agent 的每一处变更：内联 diff、逐块暂存、提交，以及 Fetch / Pull / Push。',
      '待办与 Agent 共享：队列、进行中、已完成，Agent 通过 MCP 工具读写同一份待办。',
      '键盘驱动整个工作台：⌘K 搜索会话、待办与动作，常用面板都有快捷键。',
      'YCode，macOS 原生多 Agent 工作台。']

def ts(s):
    return f'00:{s//60:02}:{s%60:02}.000'

def write_captions():
    for lang in ['zh', 'en']:
        cues = ['WEBVTT', '']; start = 0
        for i, s in enumerate(SCENES):
            if lang == 'zh':
                line = ZH[i]
            elif s[0] == 'intro':
                line = 'Your agents, code, and changes. One workspace.'
            else:
                line = s[2]+'. '+s[3]
            cues.extend([f'{ts(start)} --> {ts(start+s[1])}', line, '']); start += s[1]
        (A/f'ycode-overview.{lang}.vtt').write_text('\n'.join(cues), encoding='utf-8')

if __name__ == '__main__':
    contact = Path(args[0]) if args else None
    with tempfile.TemporaryDirectory(prefix='ycode-overview-') as td:
        temp = Path(td); silent = temp/'silent.mp4'; audio = temp/'sound.wav'
        # rsvg-convert keeps the transparent corners (Quick Look renders onto white).
        subprocess.run(['rsvg-convert', '-w', '512', '-h', '512', str(A/'icon.svg'), '-o', str(temp/'icon.png')], check=True)
        ICON = Image.open(temp/'icon.png').convert('RGBA')
        encoder = subprocess.Popen(['ffmpeg', '-v', 'error', '-y', '-f', 'rawvideo', '-pix_fmt', 'rgb24', '-s', f'{W}x{H}',
            '-r', str(FPS), '-i', 'pipe:0', '-an', '-c:v', 'libx264', '-preset', 'fast', '-crf', '20', '-pix_fmt', 'yuv420p', str(silent)],
            stdin=subprocess.PIPE)
        elapsed = 0; prev = None
        try:
            for index, scene in enumerate(SCENES):
                print(f'Rendering {scene[0]} ({elapsed}/{TOTAL}s)', flush=True)
                for n in range(scene[1]*FPS):
                    frame = render_frame(scene, n/FPS, elapsed+n/FPS, index, prev)
                    encoder.stdin.write(frame.tobytes())
                    if n == int(scene[1]*FPS*.75):
                        frame.save(temp/f'{scene[0]}.jpg', quality=88)
                    if scene[0] == 'intro' and n == 96:
                        frame.save(A/f'ycode-overview-poster.{LANG}.jpg', quality=92)
                prev = frame
                elapsed += scene[1]
        finally:
            encoder.stdin.close()
        if encoder.wait() != 0:
            raise RuntimeError('Video encoder failed')
        soundtrack(audio)
        subprocess.run(['ffmpeg', '-v', 'error', '-y', '-i', str(silent), '-i', str(audio), '-c:v', 'copy', '-c:a', 'aac', '-b:a', '128k',
                        '-movflags', '+faststart', '-shortest', str(A/f'ycode-overview.{LANG}.mp4')], check=True)
        if contact:
            sheet = Image.new('RGB', (640*3, 360*3), '#f6f5f1')
            for i, s in enumerate(SCENES):
                sheet.paste(Image.open(temp/f'{s[0]}.jpg').resize((640, 360)), ((i%3)*640, (i//3)*360))
            sheet.save(contact)
    write_captions()
    print(f'Created {TOTAL}s {LANG} overview film.', flush=True)
