import Foundation
import YCodeCore

do {
    switch try YCodeCLIArguments.parse(Array(CommandLine.arguments.dropFirst())) {
    case .help:
        print(YCodeCLIArguments.help)
    case .version:
        print("ycode \(YCodeBuildInfo.version)")
    case let .open(rawPath):
        let request = try YCodeCLIArguments.request(
            rawPath: rawPath,
            currentDirectory: URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
        )
        let socketURL = YCodeCLISocket.defaultURL()
        do {
            _ = try YCodeCLITransport.send(request, to: socketURL)
        } catch YCodeCLITransportError.notRunning {
            try launchYCode()
            let deadline = ContinuousClock.now.advanced(by: .seconds(30))
            while true {
                do {
                    _ = try YCodeCLITransport.send(request, to: socketURL)
                    break
                } catch YCodeCLITransportError.notRunning where ContinuousClock.now < deadline {
                    Thread.sleep(forTimeInterval: 0.05)
                }
            }
        }
    }
} catch {
    FileHandle.standardError.write(Data("ycode: \(error.localizedDescription)\n".utf8))
    exit(1)
}

private func launchYCode() throws {
    var candidates: [[String]] = []
    let executable = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath()
    let bundle = executable
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
    if bundle.pathExtension == "app",
       FileManager.default.fileExists(atPath: bundle.appendingPathComponent("Contents/Info.plist").path) {
        candidates.append(["-g", bundle.path])
    }
    candidates.append(["-g", "-b", "dev.ycode.app"])
    candidates.append(["-g", "-b", YCodeBuildInfo.developmentBundleIdentifier])
    candidates.append(["-g", "-a", "/Applications/YCode.app"])

    for arguments in candidates {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        process.arguments = arguments
        process.standardOutput = Pipe()
        process.standardError = Pipe()
        do {
            try process.run()
            process.waitUntilExit()
            if process.terminationStatus == 0 { return }
        } catch {
            continue
        }
    }
    throw YCodeCLIInstallationError.operationFailed(
        "YCode 未运行且无法启动；请确认应用仍在原位置或已安装到 /Applications。"
    )
}
