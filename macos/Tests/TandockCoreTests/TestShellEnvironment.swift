import Foundation
@testable import TandockCore

extension TandockShellEnvironmentStore {
    static let testHost = TandockShellEnvironmentStore { _, _, host, _ in .success(.init(variables: host)) }
}
