import Foundation
import Testing
@testable import TandockCore

@Test func developmentDataNeverAliasesLegacyData() {
    let locations = TandockDataLocations(homeDirectory: URL(fileURLWithPath: "/Users/tester", isDirectory: true))
    #expect(locations.developmentRoot.path == "/Users/tester/Library/Application Support/dev.ycode.native.dev")
    #expect(locations.legacyRoot.path == "/Users/tester/Library/Application Support/dev.ycode.ycode")
    #expect(locations.defaultRoot(bundleIdentifier: TandockBuildInfo.developmentBundleIdentifier) == locations.developmentRoot)
    #expect(locations.defaultRoot(bundleIdentifier: TandockBuildInfo.releaseBundleIdentifier) == locations.releaseRoot)
    #expect(locations.legacyDatabaseURL.lastPathComponent == "ycode.db")
    #expect(locations.legacyConfigurationURL.lastPathComponent == "config.json")
    #expect(locations.isIsolatedFromLegacyData)
}

@Test func allRequiredExecutableTargetsHaveStableNames() {
    #expect(Set(TandockExecutableRole.allCases.map(\.rawValue)) == ["TandockApp", "tandock", "tandock-mcp", "tandock-notify"])
}

@Test func releaseArchitectureContractIsUniversal2() {
    #expect(TandockBuildInfo.releaseArchitectures == ["arm64", "x86_64"])
}
