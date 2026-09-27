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

    /// `CFBundleVersion`。发布包是递增的整数（87、88…），开发包由
    /// `build_and_run.sh` 戳成 `dev-<短 sha>` —— 「关于」页要能一眼区分
    /// 「装的是哪个发布版」和「我刚从哪个 commit 跑起来的」。
    public static var installedBuild: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "0"
    }

    /// 「关于」页显示的版本串：`0.2.3 (88)`。版本号单独看不出是哪次构建，
    /// 报 bug 时真正有用的是后面那个 build。
    public static var versionDescription: String {
        "\(installedVersion) (\(installedBuild))"
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
