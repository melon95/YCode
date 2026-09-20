import Foundation
import YCodeCore

guard CommandLine.arguments.count == 4 else {
    FileHandle.standardError.write(Data("usage: YCodeMigrationProbe <source-db> <source-config> <destination-root>\n".utf8))
    exit(64)
}

do {
    let outcome = try LegacyMigrationService().importLegacyData(
        database: URL(fileURLWithPath: CommandLine.arguments[1]),
        configuration: URL(fileURLWithPath: CommandLine.arguments[2]),
        to: URL(fileURLWithPath: CommandLine.arguments[3], isDirectory: true)
    )
    let summary = outcome.summary
    print("status=\(outcome.status.rawValue) schema=\(summary.schema.rawValue) migration=\(summary.migrationVersion)")
    print("projects=\(summary.projects) sessions=\(summary.sessions) archived=\(summary.archivedSessions) worktrees=\(summary.worktreeSessions)")
    print("todos=\(summary.todos) lsp=\(summary.lspInstallations) checkpoints=\(summary.checkpoints)")
    print("destination=\(outcome.destinationRoot.path)")
} catch {
    FileHandle.standardError.write(Data("migration failed: \(error)\n".utf8))
    exit(1)
}
