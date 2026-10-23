import Foundation
import TandockCore

do {
    switch try TandockCLIArguments.parse(Array(CommandLine.arguments.dropFirst())) {
    case .help:
        print(TandockCLIArguments.help)
    case .version:
        print("tandock \(TandockBuildInfo.version)")
    case let .open(rawPath):
        let request = try TandockCLIArguments.request(
            rawPath: rawPath,
            currentDirectory: URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
        )
        let socketURL = TandockCLISocket.defaultURL()
        do {
            _ = try TandockCLITransport.send(request, to: socketURL)
        } catch TandockCLITransportError.notRunning {
            try launchTandock()
            let deadline = ContinuousClock.now.advanced(by: .seconds(30))
            while true {
                do {
                    _ = try TandockCLITransport.send(request, to: socketURL)
                    break
                } catch TandockCLITransportError.notRunning where ContinuousClock.now < deadline {
                    Thread.sleep(forTimeInterval: 0.05)
                }
            }
        }
    }
} catch {
    FileHandle.standardError.write(Data("tandock: \(error.localizedDescription)\n".utf8))
    exit(1)
}

private func launchTandock() throws {
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
    candidates.append(["-g", "-b", TandockBuildInfo.developmentBundleIdentifier])
    candidates.append(["-g", "-a", "/Applications/Tandock.app"])

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
    throw TandockCLIInstallationError.operationFailed(
        "Tandock 未运行且无法启动；请确认应用仍在原位置或已安装到 /Applications。"
    )
}
