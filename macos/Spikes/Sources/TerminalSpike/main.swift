
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
