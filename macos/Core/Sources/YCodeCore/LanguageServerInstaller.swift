import Foundation

public struct YCodeLSPInstaller: Sendable {
    public let dataRoot: URL

    public init(dataRoot: URL) {
        self.dataRoot = dataRoot.standardizedFileURL
    }

    public func install(
        manifest: YCodeLSPServerManifest,
        progress: @escaping @Sendable (YCodeLSPInstallProgress) async -> Void
    ) async throws -> YCodeLSPInstallation {
        let missing = manifest.requiredCommands.filter { Self.resolveCommand($0) == nil }
        guard missing.isEmpty else { throw YCodeLSPError.requirementsMissing(missing) }

        await progress(.init(serverID: manifest.id, stage: .resolving, percent: nil, message: "正在解析安装方案"))
        let fileManager = FileManager.default
        let lspRoot = dataRoot.appendingPathComponent("lsp", isDirectory: true)
        try fileManager.createDirectory(at: lspRoot, withIntermediateDirectories: true)
        let staging = lspRoot.appendingPathComponent(".\(manifest.id).install-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: staging, withIntermediateDirectories: true)

        do {
            let result = try await installIntoStaging(manifest, staging: staging, progress: progress)
            await progress(.init(serverID: manifest.id, stage: .finalizing, percent: 100, message: "正在完成安装"))
            let destination = lspRoot.appendingPathComponent(manifest.id, isDirectory: true)
            let backup = lspRoot.appendingPathComponent(".\(manifest.id).backup-\(UUID().uuidString)", isDirectory: true)
            if fileManager.fileExists(atPath: destination.path) {
                try fileManager.moveItem(at: destination, to: backup)
            }
            do {
                try fileManager.moveItem(at: staging, to: destination)
                if fileManager.fileExists(atPath: backup.path) { try? fileManager.removeItem(at: backup) }
            } catch {
                if fileManager.fileExists(atPath: backup.path) { try? fileManager.moveItem(at: backup, to: destination) }
                throw error
            }
            let binaryURL = destination.appendingPathComponent(result.binaryRelativePath)
            guard Self.isRunnableExecutable(at: binaryURL) else {
                throw YCodeLSPError.installFailed("安装结果缺少可执行文件：\(binaryURL.path)")
            }
            return .init(
                serverID: manifest.id,
                version: result.version,
                binaryURL: binaryURL,
                installedAtMilliseconds: Int64(Date().timeIntervalSince1970 * 1_000)
            )
        } catch {
            try? fileManager.removeItem(at: staging)
            throw error
        }
    }

    public func uninstall(serverID: String) throws {
        let url = dataRoot.appendingPathComponent("lsp/\(serverID)", isDirectory: true)
        if FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }
    }

    public static func missingRequirements(for manifest: YCodeLSPServerManifest) -> [String] {
        manifest.requiredCommands.filter { resolveCommand($0) == nil }
    }

    /// `FileManager.isExecutableFile` also returns true for a searchable
    /// directory. Installation records must point to an executable file (or a
    /// symlink resolving to one), otherwise the UI can report an installed
    /// server that immediately fails to spawn.
    public static func isRunnableExecutable(at url: URL) -> Bool {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory),
              !isDirectory.boolValue else { return false }
        return FileManager.default.isExecutableFile(atPath: url.path)
    }

    public static func resolveCommand(_ command: String) -> URL? {
        let shell = ProcessInfo.processInfo.environment["SHELL"].flatMap { $0.isEmpty ? nil : $0 } ?? "/bin/zsh"
        let process = Process()
        process.executableURL = URL(fileURLWithPath: shell)
        process.arguments = ["-l", "-c", "command -v -- \(YCodeAgentLauncher.shellQuote(command))"]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else { return nil }
            let path = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard path.hasPrefix("/"), FileManager.default.isExecutableFile(atPath: path) else { return nil }
            return URL(fileURLWithPath: path)
        } catch {
            return nil
        }
    }

    private struct StagedResult: Sendable {
        let version: String
        let binaryRelativePath: String
    }

    private func installIntoStaging(
        _ manifest: YCodeLSPServerManifest,
        staging: URL,
        progress: @escaping @Sendable (YCodeLSPInstallProgress) async -> Void
    ) async throws -> StagedResult {
        if let command = manifest.adoptSystemCommand, let existing = Self.resolveCommand(command) {
            let relative = binaryPath(for: manifest.installPlan)
            let destination = staging.appendingPathComponent(relative)
            try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
            try FileManager.default.copyItem(at: existing, to: destination)
            try makeExecutable(destination)
            let version = (try? await commandVersion(destination)) ?? "system"
            return .init(version: version, binaryRelativePath: relative)
        }

        switch manifest.installPlan {
        case let .githubGzip(repo, arm64Asset, x86Asset, binaryName):
            let asset = try platformAsset(arm64: arm64Asset, x86: x86Asset)
            let release = try await githubRelease(repo: repo, assetName: asset)
            await progress(.init(serverID: manifest.id, stage: .downloading, percent: nil, message: "正在下载 \(release.version)"))
            let archive = staging.appendingPathComponent("\(binaryName).gz.part")
            try await download(release.url, to: archive)
            await progress(.init(serverID: manifest.id, stage: .extracting, percent: nil, message: "正在解压"))
            let binary = staging.appendingPathComponent(binaryName)
            try await runProcess(
                executable: URL(fileURLWithPath: "/usr/bin/gzip"),
                arguments: ["-dc", archive.path],
                workingDirectory: staging,
                outputFile: binary
            )
            try? FileManager.default.removeItem(at: archive)
            try makeExecutable(binary)
            return .init(version: release.version, binaryRelativePath: binaryName)

        case let .npm(packages, binaryName):
            await progress(.init(serverID: manifest.id, stage: .runningCommand, percent: nil, message: "正在运行 npm install"))
            let packageJSON = staging.appendingPathComponent("package.json")
            let packageBody = "{\"name\":\"ycode-lsp-\(manifest.id)\",\"private\":true,\"version\":\"0.0.0\"}\n"
            try Data(packageBody.utf8).write(to: packageJSON, options: .atomic)
            try await runShell(
                command: (["npm", "install", "--no-audit", "--no-fund", "--loglevel=error"] + packages)
                    .map(YCodeAgentLauncher.shellQuote).joined(separator: " "),
                workingDirectory: staging
            )
            let relative = "node_modules/.bin/\(binaryName)"
            let versionURL = staging.appendingPathComponent("node_modules/\(packages[0])/package.json")
            let version = (try? npmVersion(at: versionURL)) ?? "installed"
            guard FileManager.default.fileExists(atPath: staging.appendingPathComponent(relative).path) else {
                throw YCodeLSPError.installFailed("npm 未生成 \(relative)")
            }
            return .init(version: version, binaryRelativePath: relative)

        case let .go(package, binaryName):
            await progress(.init(serverID: manifest.id, stage: .runningCommand, percent: nil, message: "正在运行 go install"))
            try await runShell(
                command: "GOBIN=\(YCodeAgentLauncher.shellQuote(staging.path)) go install \(YCodeAgentLauncher.shellQuote(package))",
                workingDirectory: staging
            )
            let binary = staging.appendingPathComponent(binaryName)
            try makeExecutable(binary)
            let version = (try? await commandVersion(binary)) ?? "installed"
            return .init(version: version, binaryRelativePath: binaryName)

        case let .archive(url, binaryPath):
            await progress(.init(serverID: manifest.id, stage: .downloading, percent: nil, message: "正在下载安装包"))
            let archive = staging.appendingPathComponent("server.tar.gz.part")
            guard let source = URL(string: url) else { throw YCodeLSPError.installFailed("下载地址无效") }
            try await download(source, to: archive)
            await progress(.init(serverID: manifest.id, stage: .extracting, percent: nil, message: "正在解压"))
            try await extractTarGzip(archive, into: staging)
            try? FileManager.default.removeItem(at: archive)
            let binary = staging.appendingPathComponent(binaryPath)
            try makeExecutable(binary)
            return .init(version: "latest", binaryRelativePath: binaryPath)

        case let .githubArchive(repo, arm64Asset, x86Asset, binaryPath):
            let asset = try platformAsset(arm64: arm64Asset, x86: x86Asset)
            let release = try await githubRelease(repo: repo, assetName: asset)
            await progress(.init(serverID: manifest.id, stage: .downloading, percent: nil, message: "正在下载 \(release.version)"))
            let archive = staging.appendingPathComponent("server.tar.gz.part")
            try await download(release.url, to: archive)
            await progress(.init(serverID: manifest.id, stage: .extracting, percent: nil, message: "正在解压"))
            try await extractTarGzip(archive, into: staging)
            try? FileManager.default.removeItem(at: archive)
            let binary = staging.appendingPathComponent(binaryPath)
            try makeExecutable(binary)
            return .init(version: release.version, binaryRelativePath: binaryPath)
        }
    }

    private func binaryPath(for plan: YCodeLSPInstallPlan) -> String {
        switch plan {
        case let .githubGzip(_, _, _, binaryName): binaryName
        case let .npm(_, binaryName): "node_modules/.bin/\(binaryName)"
        case let .go(_, binaryName): binaryName
        case let .archive(_, binaryPath): binaryPath
        case let .githubArchive(_, _, _, binaryPath): binaryPath
        }
    }

    private func platformAsset(arm64: String, x86: String) throws -> String {
        #if arch(arm64)
        return arm64
        #elseif arch(x86_64)
        return x86
        #else
        throw YCodeLSPError.installFailed("当前 Mac 架构不受支持")
        #endif
    }

    private func githubRelease(repo: String, assetName: String) async throws -> (version: String, url: URL) {
        guard let url = URL(string: "https://api.github.com/repos/\(repo)/releases/latest") else {
            throw YCodeLSPError.installFailed("GitHub 地址无效")
        }
        var request = URLRequest(url: url)
        request.setValue("YCodeNative/\(YCodeBuildInfo.version)", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, 200..<300 ~= http.statusCode else {
            throw YCodeLSPError.installFailed("GitHub release 查询失败")
        }
        struct Release: Decodable { struct Asset: Decodable { let name: String; let browser_download_url: String }; let tag_name: String; let assets: [Asset] }
        let release = try JSONDecoder().decode(Release.self, from: data)
        guard let raw = release.assets.first(where: { $0.name == assetName })?.browser_download_url,
              let downloadURL = URL(string: raw) else {
            throw YCodeLSPError.installFailed("release 中缺少 \(assetName)")
        }
        return (release.tag_name, downloadURL)
    }

    private func download(_ source: URL, to destination: URL) async throws {
        var request = URLRequest(url: source)
        request.setValue("YCodeNative/\(YCodeBuildInfo.version)", forHTTPHeaderField: "User-Agent")
        let (temporary, response) = try await URLSession.shared.download(for: request)
        guard let http = response as? HTTPURLResponse, 200..<300 ~= http.statusCode else {
            throw YCodeLSPError.installFailed("下载失败")
        }
        try? FileManager.default.removeItem(at: destination)
        try FileManager.default.moveItem(at: temporary, to: destination)
    }

    private func extractTarGzip(_ archive: URL, into destination: URL) async throws {
        try await runProcess(
            executable: URL(fileURLWithPath: "/usr/bin/tar"),
            arguments: ["-xzf", archive.path, "-C", destination.path],
            workingDirectory: destination
        )
    }

    private func makeExecutable(_ url: URL) throws {
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw YCodeLSPError.installFailed("缺少可执行文件：\(url.path)")
        }
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        let existing = (attributes[.posixPermissions] as? NSNumber)?.intValue ?? 0o644
        try FileManager.default.setAttributes([.posixPermissions: existing | 0o111], ofItemAtPath: url.path)
    }

    private func npmVersion(at url: URL) throws -> String {
        let value = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any]
        return "v\(value?["version"] as? String ?? "installed")"
    }

    private func commandVersion(_ executable: URL) async throws -> String {
        let result = try await captureProcess(executable: executable, arguments: ["--version"], workingDirectory: executable.deletingLastPathComponent())
        return result.split(separator: "\n").first.map(String.init) ?? "installed"
    }

    private func runShell(command: String, workingDirectory: URL) async throws {
        let shell = ProcessInfo.processInfo.environment["SHELL"].flatMap { $0.isEmpty ? nil : $0 } ?? "/bin/zsh"
        try await runProcess(
            executable: URL(fileURLWithPath: shell),
            arguments: ["-l", "-c", command],
            workingDirectory: workingDirectory
        )
    }

    private func captureProcess(executable: URL, arguments: [String], workingDirectory: URL) async throws -> String {
        try await Task.detached(priority: .utility) {
            let process = Process()
            process.executableURL = executable
            process.arguments = arguments
            process.currentDirectoryURL = workingDirectory
            let output = Pipe()
            process.standardOutput = output
            process.standardError = output
            try process.run()
            process.waitUntilExit()
            let data = output.fileHandleForReading.readDataToEndOfFile()
            guard process.terminationStatus == 0 else {
                throw YCodeLSPError.installFailed(String(decoding: data, as: UTF8.self))
            }
            return String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        }.value
    }

    private func runProcess(
        executable: URL,
        arguments: [String],
        workingDirectory: URL,
        outputFile: URL? = nil
    ) async throws {
        try await Task.detached(priority: .utility) {
            let process = Process()
            process.executableURL = executable
            process.arguments = arguments
            process.currentDirectoryURL = workingDirectory
            let logURL = workingDirectory.appendingPathComponent(".install-command.log")
            FileManager.default.createFile(atPath: logURL.path, contents: nil)
            let log = try FileHandle(forWritingTo: logURL)
            defer { try? log.close() }
            if let outputFile {
                FileManager.default.createFile(atPath: outputFile.path, contents: nil)
                process.standardOutput = try FileHandle(forWritingTo: outputFile)
                process.standardError = log
            } else {
                process.standardOutput = log
                process.standardError = log
            }
            try process.run()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else {
                let message = (try? String(contentsOf: logURL, encoding: .utf8)) ?? "退出码 \(process.terminationStatus)"
                throw YCodeLSPError.installFailed(message)
            }
            try? FileManager.default.removeItem(at: logURL)
        }.value
    }
}
