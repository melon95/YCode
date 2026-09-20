import AppKit

let mode = CommandLine.arguments.dropFirst().first ?? "gui"
switch mode {
case "gui":
    runEditorGUI()
case "headless":
    exit(runEditorHeadless())
default:
    print("usage: EditorSpike [gui|headless]")
    exit(2)
}
