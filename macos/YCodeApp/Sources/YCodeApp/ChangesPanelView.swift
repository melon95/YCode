import SwiftUI
import YCodeCore

struct ChangesPanelView: View {
    @ObservedObject var model: WorkspaceModel
    @Environment(\.ycodeL10n) private var l10n
    @State private var mode: Mode = .changes

    private enum Mode: Hashable {
        case changes
        case checkpoints
    }

    var body: some View {
        VStack(spacing: 0) {
            Picker("", selection: $mode) {
                Text(l10n.text("changes")).tag(Mode.changes)
                Text(l10n.text("checkpoints")).tag(Mode.checkpoints)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(10)
            Divider()
            switch mode {
            case .changes:
                header
                Divider()
                if model.gitStatus == nil, !model.gitStatusMessage.isEmpty {
                    ContentUnavailableView(l10n.text("gitUnavailable"), systemImage: "exclamationmark.triangle", description: Text(model.gitStatusMessage))
                } else {
                    HSplitView {
                        changeList.frame(minWidth: 210, idealWidth: 260)
                        diffPane.frame(minWidth: 260)
                    }
                }
            case .checkpoints:
                checkpointHeader
                Divider()
                HSplitView {
                    checkpointList.frame(minWidth: 210, idealWidth: 260)
                    checkpointDiffPane.frame(minWidth: 260)
                }
            }
        }
        .onAppear {
            model.refreshGitStatus()
            model.refreshCheckpoints()
        }
        .onChange(of: mode) { _, value in
            if value == .checkpoints { model.refreshCheckpoints() }
        }
        .onChange(of: model.selectedSessionID) { _, _ in
            if mode == .checkpoints { model.refreshCheckpoints() }
        }
    }

    private var checkpointHeader: some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Label(l10n.text("checkpoints"), systemImage: "clock.arrow.circlepath")
                    .font(.caption.weight(.semibold))
                if let session = model.selectedSession {
                    Text(session.title)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer()
            Text(model.checkpointStatus)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Button { model.refreshCheckpoints() } label: { Image(systemName: "arrow.clockwise") }
                .buttonStyle(.borderless)
                .disabled(model.checkpointIsLoading)
                .help(l10n.text("refreshCheckpoints"))
        }
        .padding(10)
    }

    private var checkpointList: some View {
        List(selection: Binding(
            get: { model.selectedCheckpointID },
            set: { model.selectCheckpoint($0) }
        )) {
            ForEach(model.checkpoints) { checkpoint in
                VStack(alignment: .leading, spacing: 3) {
                    HStack {
                        Text("#\(checkpoint.sequence)")
                            .font(.system(.caption2, design: .monospaced).weight(.semibold))
                        Text(checkpoint.kind == "initial" ? l10n.text("initialCheckpoint") : l10n.text("turnCheckpoint"))
                            .font(.caption)
                        Spacer()
                        Text(Self.checkpointDate(checkpoint.createdAtMilliseconds))
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    if let preview = checkpoint.bodyPreview, !preview.isEmpty {
                        Text(preview)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    } else if let eventKind = checkpoint.eventKind, !eventKind.isEmpty {
                        Text(eventKind)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    Text(String(checkpoint.commitSHA.prefix(12)))
                        .font(.system(.caption2, design: .monospaced))
                        .foregroundStyle(.tertiary)
                }
                .tag(Optional(checkpoint.id))
            }
        }
        .overlay {
            if model.checkpoints.isEmpty, !model.checkpointIsLoading {
                ContentUnavailableView(l10n.text("noCheckpoints"), systemImage: "clock.badge.questionmark")
            }
        }
    }

    private var checkpointDiffPane: some View {
        ScrollView([.vertical, .horizontal]) {
            Text(model.checkpointDiff.isEmpty ? l10n.text("selectCheckpointForDiff") : model.checkpointDiff)
                .font(.system(.caption, design: .monospaced))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(10)
        }
        .background(Color(nsColor: .textBackgroundColor))
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                if let branch = model.gitStatus?.branch {
                    Label(branch.current ?? "detached", systemImage: "arrow.triangle.branch")
                        .font(.caption.weight(.semibold))
                    if let upstream = branch.upstream {
                        Text("\(upstream) ↑\(branch.ahead) ↓\(branch.behind)")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                } else {
                    Label("Git", systemImage: "arrow.triangle.branch")
                        .font(.caption.weight(.semibold))
                }
                Spacer()
                Button { model.refreshGitStatus() } label: { Image(systemName: "arrow.clockwise") }
                    .buttonStyle(.borderless)
                    .disabled(model.gitIsLoading)
                    .help(l10n.text("refreshGitStatus"))
            }
            HStack(spacing: 6) {
                Menu {
                    ForEach(model.gitBranches) { branch in
                        Button {
                            model.checkoutGitBranch(branch)
                        } label: {
                            if branch.current {
                                Label(branch.name, systemImage: "checkmark")
                            } else {
                                Text(branch.name)
                            }
                        }
                    }
                } label: {
                    Label(l10n.text("branch"), systemImage: "rectangle.stack")
                }
                .disabled(model.gitBranches.isEmpty || model.gitIsLoading)
                Button("Fetch") { model.fetchGitRemote() }.disabled(model.gitIsLoading)
                Button("Pull") { model.pullGitRemote() }.disabled(model.gitIsLoading)
                Button("Push") { model.pushGitRemote() }.disabled(model.gitIsLoading)
            }
            Text(model.gitStatusMessage)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .padding(10)
    }

    private var changeList: some View {
        VStack(spacing: 0) {
            List(selection: Binding(
                get: { model.selectedGitPath },
                set: { model.selectGitChange($0) }
            )) {
                ForEach(model.gitStatus?.changes ?? []) { change in
                    HStack(spacing: 8) {
                        Text(statusLabel(change))
                            .font(.system(.caption2, design: .monospaced).weight(.semibold))
                            .foregroundStyle(statusColor(change))
                            .frame(width: 24, alignment: .leading)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(change.path).lineLimit(1)
                            if let original = change.originalPath {
                                Text(l10n.text("fromPathFormat", original))
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                        }
                    }
                    .tag(Optional(change.path))
                }
            }
            .overlay {
                if model.gitStatus?.changes.isEmpty == true {
                    ContentUnavailableView(l10n.text("noChanges"), systemImage: "checkmark.circle")
                }
            }
            Divider()
            VStack(spacing: 8) {
                TextField(l10n.text("commitMessage"), text: $model.gitCommitMessage)
                    .textFieldStyle(.roundedBorder)
                HStack {
                    Button(l10n.text("stage")) { model.stageSelectedGitChange() }
                        .disabled(model.selectedGitPath == nil || model.gitIsLoading)
                    Button(l10n.text("unstage")) { model.unstageSelectedGitChange() }
                        .disabled(model.selectedGitPath == nil || model.gitIsLoading)
                    Button(l10n.text("discard"), role: .destructive) { model.discardSelectedGitChange() }
                        .disabled(model.selectedGitPath == nil || model.gitIsLoading)
                }
                Button(l10n.text("commitStagedChanges")) { model.commitGitChanges() }
                    .disabled(model.gitCommitMessage.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || model.gitIsLoading)
            }
            .padding(10)
        }
    }

    private var diffPane: some View {
        ScrollView([.vertical, .horizontal]) {
            Text(model.gitDiff.isEmpty ? l10n.text("selectFileForDiff") : model.gitDiff)
                .font(.system(.caption, design: .monospaced))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(10)
        }
        .background(Color(nsColor: .textBackgroundColor))
    }

    private func statusLabel(_ change: YCodeGitFileChange) -> String {
        if change.indexStatus == "?" || change.worktreeStatus == "?" { return "??" }
        return "\(change.indexStatus)\(change.worktreeStatus)"
    }

    private func statusColor(_ change: YCodeGitFileChange) -> Color {
        switch change.kind {
        case .added, .untracked: .green
        case .deleted: .red
        case .renamed, .copied: .blue
        case .conflicted: .orange
        default: .secondary
        }
    }

    private static func checkpointDate(_ milliseconds: Int64) -> String {
        let date = Date(timeIntervalSince1970: Double(milliseconds) / 1_000)
        return date.formatted(date: .omitted, time: .shortened)
    }
}
