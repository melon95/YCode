// M0.3 原生终端验证程序。
//
// 两种模式:
//   headless  —— 不开窗口,跑固定脚本,输出机器可读的结果。CI / 复现用。
//   gui       —— 开窗口跑真实 CLI,人工确认中文、Emoji、ANSI、全屏 TUI。
//
// 验收点(计划 M0.3):
//   真实 Claude/Codex 可输入、执行、中断
//   中文、Emoji、ANSI、全屏界面、复制粘贴可用
//   隐藏后进程继续运行;隐藏/恢复 20 次进程标识不变、标记输出可找回
//   连续输出 10 分钟不崩、无重复进程、无输入错位

import AppKit
import Foundation
import SwiftTerm

let args = CommandLine.arguments
let mode = args.count > 1 ? args[1] : "gui"

switch mode {
case "headless":
    let soakIndex = args.firstIndex(of: "--soak-seconds")
    let soakSeconds = soakIndex.flatMap { index in
        args.indices.contains(index + 1) ? TimeInterval(args[index + 1]) : nil
    } ?? 0
    runHeadless(soakSeconds: soakSeconds)
case "gui":
    runGUI()
default:
    print("usage: TerminalSpike [headless|gui]")
    exit(2)
}
