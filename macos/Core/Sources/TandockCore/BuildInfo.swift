import Foundation

public enum TandockBuildInfo {
    public static let displayName = "Tandock"
    public static let version = "0.1.0-native-dev"
    public static let minimumSystemVersion = "14.0"
    public static let developmentBundleIdentifier = "dev.ycode.native.dev"
    public static let releaseBundleIdentifier = "dev.ycode.app"
    public static let releaseArchitectures = ["arm64", "x86_64"]

    public static var installedVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? version
    }

    public static var installedBuild: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "0"
    }

    public static var versionDescription: String {
        "\(installedVersion) (\(installedBuild))"
    }

    public static var bundleIdentifier: String {
        Bundle.main.bundleIdentifier ?? developmentBundleIdentifier
    }
}

public enum TandockExecutableRole: String, CaseIterable, Sendable {
    case app = "TandockApp"
    case cli = "tandock"
    case mcp = "tandock-mcp"
    case notify = "tandock-notify"
}
