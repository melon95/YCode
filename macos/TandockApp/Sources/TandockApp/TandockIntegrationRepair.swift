import Foundation
import TandockCore

enum TandockBundledHelpers {
    static func url(named name: String) -> URL {
        let resource = Bundle.main.resourceURL?.appendingPathComponent(name)
        let adjacent = Bundle.main.executableURL?.deletingLastPathComponent().appendingPathComponent(name)
        return [resource, adjacent]
            .compactMap { $0 }
            .first { FileManager.default.isExecutableFile(atPath: $0.path) }
            ?? resource
            ?? adjacent
            ?? URL(fileURLWithPath: name)
    }

    static func isInstalledLocation(_ bundleURL: URL, home: URL) -> Bool {
        let path = bundleURL.resolvingSymlinksInPath().path
        guard !path.contains("/AppTranslocation/") else { return false }
        let applications = ["/Applications/", home.resolvingSymlinksInPath().path + "/Applications/"]
        return applications.contains { path.hasPrefix($0) }
    }

    static func repairStaleIntegrations() async {
        let home = FileManager.default.homeDirectoryForCurrentUser
        guard isInstalledLocation(Bundle.main.bundleURL, home: home) else { return }
        let mcp = TandockMCPRegistrationService(homeDirectory: home, helperURL: url(named: "tandock-mcp"))
        let hooks = TandockHookRegistrationService(homeDirectory: home, helperURL: url(named: "tandock-notify"))
        for agent in TandockMCPAgent.allCases {
            do { try await mcp.repairStaleHelperPath(for: agent) } catch {
                NSLog("Tandock could not repair \(agent.rawValue) MCP helper path: \(error.localizedDescription)")
            }
            do { try await hooks.repairStaleHelperPath(for: agent) } catch {
                NSLog("Tandock could not repair \(agent.rawValue) hook helper path: \(error.localizedDescription)")
            }
        }
    }
}
