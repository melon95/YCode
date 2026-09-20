import Foundation
import Testing
@testable import YCodeCore

@Test func developmentDataNeverAliasesLegacyData() {
    let locations = YCodeDataLocations(homeDirectory: URL(fileURLWithPath: "/Users/tester", isDirectory: true))
    #expect(locations.developmentRoot.path == "/Users/tester/Library/Application Support/dev.ycode.native.dev")
    #expect(locations.legacyRoot.path == "/Users/tester/Library/Application Support/dev.ycode.ycode")
    #expect(locations.defaultRoot(bundleIdentifier: YCodeBuildInfo.developmentBundleIdentifier) == locations.developmentRoot)
    #expect(locations.defaultRoot(bundleIdentifier: YCodeBuildInfo.releaseBundleIdentifier) == locations.releaseRoot)
    #expect(locations.legacyDatabaseURL.lastPathComponent == "ycode.db")
    #expect(locations.legacyConfigurationURL.lastPathComponent == "config.json")
    #expect(locations.isIsolatedFromLegacyData)
}

@Test func allRequiredExecutableTargetsHaveStableNames() {
    #expect(Set(YCodeExecutableRole.allCases.map(\.rawValue)) == ["YCodeApp", "ycode", "ycode-mcp", "ycode-notify"])
}

@Test func releaseArchitectureContractIsUniversal2() {
    #expect(YCodeBuildInfo.releaseArchitectures == ["arm64", "x86_64"])
}
