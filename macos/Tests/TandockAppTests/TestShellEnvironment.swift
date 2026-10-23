import Foundation
@testable import TandockCore

extension TandockShellEnvironmentStore {
    /// Hermetic stand-in for the login-shell resolver: the test process environment is the "rc" result,
    /// so tests never depend on the machine's shell configuration or wait on a real rc.
    static let testHost = TandockShellEnvironmentStore { _, _, host, _ in .success(.init(variables: host)) }
}
