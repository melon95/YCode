import Foundation

public struct TandockDataLocations: Equatable, Sendable {
    public let developmentRoot: URL
    public let legacyRoot: URL
    public let releaseRoot: URL

    public init(homeDirectory: URL) {
        developmentRoot = homeDirectory
            .appendingPathComponent("Library/Application Support", isDirectory: true)
            .appendingPathComponent(TandockBuildInfo.developmentBundleIdentifier, isDirectory: true)
        legacyRoot = homeDirectory
            .appendingPathComponent("Library/Application Support", isDirectory: true)
            .appendingPathComponent("dev.ycode.ycode", isDirectory: true)
        releaseRoot = legacyRoot
    }

    public static var current: TandockDataLocations {
        TandockDataLocations(homeDirectory: FileManager.default.homeDirectoryForCurrentUser)
    }

    public var isIsolatedFromLegacyData: Bool {
        developmentRoot.standardizedFileURL != legacyRoot.standardizedFileURL
    }

    public func defaultRoot(bundleIdentifier: String?) -> URL {
        bundleIdentifier == TandockBuildInfo.releaseBundleIdentifier ? releaseRoot : developmentRoot
    }

    public var legacyDatabaseURL: URL { legacyRoot.appendingPathComponent("ycode.db") }
    public var legacyConfigurationURL: URL { legacyRoot.appendingPathComponent("config.json") }
}
