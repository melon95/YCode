import SwiftUI
import YCodeCore

@MainActor
final class LanguageSettingsModel: ObservableObject {
    @Published private(set) var statuses: [YCodeLSPManifestStatus] = []
    @Published private(set) var progress: [String: YCodeLSPInstallProgress] = [:]
    @Published var errorMessage: String?

    private let service: YCodeLanguageServerService?

    init(dataRoot: URL) {
        do {
            service = try YCodeLanguageServiceRegistry.shared.service(dataRoot: dataRoot)
        } catch {
            service = nil
            errorMessage = error.localizedDescription
        }
    }

    func reload() {
        guard let service else { return }
        Task {
            do { statuses = try await service.manifestStatuses() }
            catch { errorMessage = error.localizedDescription }
        }
    }

    func install(_ serverID: String) {
        guard let service, progress[serverID] == nil else { return }
        progress[serverID] = .init(serverID: serverID, stage: .resolving, percent: nil, message: "正在开始安装")
        Task {
            do {
                _ = try await service.install(serverID: serverID) { [weak self] update in
                    await MainActor.run { self?.progress[serverID] = update }
                }
                progress.removeValue(forKey: serverID)
                statuses = try await service.manifestStatuses()
            } catch {
                progress.removeValue(forKey: serverID)
                errorMessage = error.localizedDescription
                reload()
            }
        }
    }

    func uninstall(_ serverID: String) {
        guard let service, progress[serverID] == nil else { return }
        Task {
            do {
                try await service.uninstall(serverID: serverID)
                statuses = try await service.manifestStatuses()
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }
}

struct LanguageSettingsView: View {
    @StateObject private var model: LanguageSettingsModel
    @State private var pendingUninstall: YCodeLSPManifestStatus?
    @Environment(\.ycodeL10n) private var l10n

    init(dataRoot: URL) {
        _model = StateObject(wrappedValue: LanguageSettingsModel(dataRoot: dataRoot))
    }

    var body: some View {
        Form {
            Section {
                Text(l10n.text("languageServerHelp"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            ForEach(model.statuses) { status in
                Section {
                    VStack(alignment: .leading, spacing: 10) {
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(status.manifest.displayName).font(.headline)
                                Text(status.manifest.id)
                                    .font(.system(.caption, design: .monospaced))
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            statusBadge(status)
                        }
                        Text(status.manifest.description).font(.callout)
                        HStack(spacing: 5) {
                            Text(l10n.text("fileLabel")).font(.caption).foregroundStyle(.secondary)
                            ForEach(status.manifest.fileExtensions, id: \.self) { ext in
                                Text(ext)
                                    .font(.system(.caption2, design: .monospaced))
                                    .padding(.horizontal, 5).padding(.vertical, 2)
                                    .background(.quaternary, in: RoundedRectangle(cornerRadius: 4))
                            }
                        }
                        if !status.missingRequirements.isEmpty, !status.isInstalled {
                            Label(l10n.text("missingCommandsFormat", status.missingRequirements.joined(separator: ", ")), systemImage: "exclamationmark.triangle")
                                .font(.caption).foregroundStyle(.orange)
                        }
                        if let update = model.progress[status.id] {
                            if let percent = update.percent {
                                ProgressView(value: Double(percent), total: 100)
                            } else {
                                ProgressView()
                            }
                            Text(update.message).font(.caption).foregroundStyle(.secondary)
                        }
                        HStack {
                            if let url = URL(string: status.manifest.homepage) {
                                Link(l10n.text("learnMore"), destination: url).font(.caption)
                            }
                            Spacer()
                            if status.isInstalled {
                                Button(l10n.text("uninstall"), role: .destructive) { pendingUninstall = status }
                                    .disabled(model.progress[status.id] != nil)
                            } else {
                                Button(model.progress[status.id] == nil ? l10n.text("install") : l10n.text("installingEllipsis")) {
                                    model.install(status.id)
                                }
                                .buttonStyle(.borderedProminent)
                                .disabled(!status.missingRequirements.isEmpty || model.progress[status.id] != nil)
                            }
                        }
                    }
                    .padding(.vertical, 4)
                }
            }
        }
        .formStyle(.grouped)
        .task { model.reload() }
        .confirmationDialog(
            pendingUninstall.map { l10n.text("uninstallLanguageServerTitleFormat", $0.manifest.displayName) } ?? l10n.text("uninstallLanguageServer"),
            isPresented: Binding(
                get: { pendingUninstall != nil },
                set: { if !$0 { pendingUninstall = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button(l10n.text("uninstall"), role: .destructive) {
                if let id = pendingUninstall?.id { model.uninstall(id) }
                pendingUninstall = nil
            }
            Button(l10n.text("cancel"), role: .cancel) { pendingUninstall = nil }
        } message: {
            Text(l10n.text("uninstallLanguageServerMessage"))
        }
        .alert(l10n.text("languageServiceFailed"), isPresented: Binding(
            get: { model.errorMessage != nil },
            set: { if !$0 { model.errorMessage = nil } }
        )) {
            Button(l10n.text("ok")) { model.errorMessage = nil }
        } message: {
            Text(model.errorMessage ?? l10n.text("unknownError"))
        }
    }

    @ViewBuilder
    private func statusBadge(_ status: YCodeLSPManifestStatus) -> some View {
        if model.progress[status.id] != nil {
            Label(l10n.text("installing"), systemImage: "arrow.down.circle").foregroundStyle(.orange)
        } else if let installation = status.installation {
            Label(installation.version, systemImage: "checkmark.circle.fill").foregroundStyle(.green)
        } else {
            Text(l10n.text("notInstalled")).foregroundStyle(.secondary)
        }
    }
}
