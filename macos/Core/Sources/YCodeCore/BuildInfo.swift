import Foundation

public enum YCodeBuildInfo {
    public static let displayName = "YCode"
    public static let version = "0.1.0-native-dev"
    public static let minimumSystemVersion = "14.0"
    public static let developmentBundleIdentifier = "dev.ycode.native.dev"
    public static let releaseBundleIdentifier = "dev.ycode.app"
    public static let releaseArchitectures = ["arm64", "x86_64"]

    public static var installedVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? version
    }

    public static var bundleIdentifier: String {
        Bundle.main.bundleIdentifier ?? developmentBundleIdentifier
    }
}

public enum YCodeExecutableRole: String, CaseIterable, Sendable {
    case app = "YCodeApp"
    case cli = "ycode"
    case mcp = "ycode-mcp"
    case notify = "ycode-notify"
}
