import AppKit
import SwiftUI
import TandockCore

/// 设计稿 §06 屏 05：新建会话没有弹窗。
/// 选择器就地摆进画布，选完 agent 立刻变成终端；同一个组件也用作「项目无会话」与「空窗格」。
struct NewSessionPickerView: View {
    @ObservedObject var model: WorkspaceModel
    @Environment(\.tandockL10n) private var l10n
    @State private var useWorktree = false
    @State private var branch: String = ""
    /// 新会话落在哪个项目。默认值的来历见 `defaultProjectID()`。
    @State private var projectID: String?
    @State private var projectBranches = TandockProjectBranches.none
    @State private var branchesLoaded = false
    /// 已经点下去的 agent。只用来先把反馈画出来——真正的启动下一个 runloop 才跑。
    @State private var startingProfileID: String?

    var body: some View {
        GeometryReader { proxy in
            let compact = proxy.size.width < 470 || proxy.size.height < 300
            ScrollView(.vertical) {
                card(compact: compact)
                    .frame(maxWidth: compact ? .infinity : 520)
                    .padding(compact ? 8 : 16)
                    .frame(width: proxy.size.width)
                    .frame(minHeight: proxy.size.height)
            }
            .scrollBounceBehavior(.basedOnSize)
        }
        .onAppear {
            model.reloadAgentProfiles()
            applyProjectRequest()
        }
        .onChange(of: model.newSessionProjectRequest) { _, _ in applyProjectRequest() }
        // 项目变了，分支列表和当前分支都要重读，不能把 A 项目的分支名带进 B 项目。
        .task(id: projectID) { await reloadBranches() }
    }

    private func card(compact: Bool) -> some View {
        VStack(spacing: 0) {
            tandockLogo(size: compact ? 32 : 44)
                .shadow(color: Color.tandockShadow, radius: 6, y: 3)
                .padding(.bottom, compact ? 9 : 14)
            Text(l10n.text("newSessionTitle"))
                .font(compact ? .headline : .title2.weight(.semibold))
                .tracking(-0.2)
                .padding(.bottom, compact ? 10 : 16)

            agents(compact: compact)

            Rectangle().fill(Color.tandockHairline).frame(height: 1)
                .padding(.top, compact ? 10 : 18).padding(.bottom, compact ? 8 : 14)
            foot(compact: compact)
                .disabled(startingProfileID != nil)
        }
        // 选择器本身就放在一张浮卡（画布窗格）里，不再套第二层卡片。
        .padding(compact ? 13 : 22)
    }

    /// agent 横排一行 —— 选一个是一次横向扫视，不是一列待读的清单。
    private func agents(compact: Bool) -> some View {
        HStack(spacing: compact ? 5 : 9) {
            ForEach(model.availableAgentProfiles) { profile in
                let starting = startingProfileID == profile.id
                Button { start(profile) } label: {
                    VStack(spacing: compact ? 4 : 7) {
                        ZStack {
                            TandockAgentIconView(profile: profile, size: compact ? 18 : 24)
                                .opacity(starting ? 0 : 1)
                            if starting { ProgressView().controlSize(.small) }
                        }
                        .frame(height: compact ? 20 : 28)
                        Text(profile.resolvedDisplayName)
                            .font(compact ? .caption2.weight(.semibold) : .subheadline.weight(.semibold))
                            .lineLimit(1)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, compact ? 9 : 14)
                }
                .buttonStyle(TandockAgentTileStyle(active: starting, cornerRadius: compact ? 8 : TandockMetrics.radiusCard))
                .disabled(startingProfileID != nil)
            }
            if model.availableAgentProfiles.isEmpty {
                Text(l10n.text("addAgentFirst"))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
            }
        }
    }

    /// 起会话前要决定三件事：项目、分支、是否隔离。起来之后就改不了了。
    /// 项目和分支挨在一起（分支是项目的下一级，换项目分支就跟着重读），worktree 单独靠右。
    private func foot(compact: Bool) -> some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: compact ? 7 : 9) {
                projectMenu(compact: compact)
                branchMenu(compact: compact)
                Spacer(minLength: 4)
                worktreeToggle(compact: compact)
            }
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 7) {
                    projectMenu(compact: compact)
                    Spacer(minLength: 4)
                    worktreeToggle(compact: compact)
                }
                branchMenu(compact: compact)
            }
        }
    }

    private func worktreeToggle(compact: Bool) -> some View {
        Toggle(isOn: $useWorktree) {
            Text("worktree").font(compact ? .caption : .subheadline)
        }
        .toggleStyle(.checkbox)
        .fixedSize()
        .disabled(!projectBranches.isGitRepository)
    }

    private func projectMenu(compact: Bool) -> some View {
        Menu {
            ForEach(model.projects) { project in
                Button {
                    projectID = project.id
                } label: {
                    if project.id == projectID { Label(project.name, systemImage: "checkmark") } else { Text(project.name) }
                }
            }
            Divider()
            Button(l10n.text("addProjectEllipsis")) { addProject() }
        } label: {
            HStack(spacing: 5) {
                if let project = chosenProject {
                    Image(nsImage: TandockProjectPalette.dotImage(for: project.id))
                    Text(project.name)
                        .font(.system(size: 11, weight: .semibold))
                        .lineLimit(1)
                        .truncationMode(.tail)
                } else {
                    Text(l10n.text("newSessionProject")).font(.system(size: 11, weight: .semibold))
                }
            }
        }
        .menuStyle(.borderlessButton)
        .frame(height: compact ? 22 : 24)
        .help(l10n.text("newSessionProjectHelp"))
        .accessibilityLabel("\(l10n.text("newSessionProject")): \(chosenProject?.name ?? "")")
    }

    private func branchMenu(compact: Bool) -> some View {
        Menu {
            ForEach(projectBranches.branches) { item in
                Button {
                    branch = item.name
                } label: {
                    if item.name == branch { Label(item.name, systemImage: "checkmark") } else { Text(item.name) }
                }
            }
        } label: {
            HStack(spacing: 5) {
                Image(systemName: "arrow.triangle.branch").font(.system(size: 10))
                Text(branchLabel)
                    .font(.system(size: 11, design: .monospaced))
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        }
        .menuStyle(.borderlessButton)
        .frame(height: compact ? 22 : 24)
        .disabled(!projectBranches.isGitRepository)
    }

    private var branchLabel: String {
        if branchesLoaded, !projectBranches.isGitRepository { return l10n.text("notGitRepository") }
        return branch.isEmpty ? l10n.text("currentBranch") : branch
    }

    private var chosenProject: ProjectRecord? {
        projectID.flatMap { model.project(id: $0) }
    }

    /// 默认项目：侧栏「+」点名的 > 焦点窗格所属项目（⌘N 再开一个同项目的最常见）
    /// > 最近建会话用过的 > 当前项目 > 侧栏第一个。
    private func defaultProjectID() -> String? {
        let candidates = [
            model.newSessionProjectRequest,
            model.focusedCanvasProjectID,
            model.lastNewSessionProjectID,
            model.selectedProjectID,
            model.projects.first?.id
        ]
        return candidates.compactMap { $0 }.first { model.project(id: $0) != nil }
    }

    /// 「+」点名的项目只用一次；选择器读走就清掉，免得下一次 ⌘N 还被它钉住。
    private func applyProjectRequest() {
        if let request = model.newSessionProjectRequest, model.project(id: request) != nil {
            projectID = request
            model.newSessionProjectRequest = nil
        } else if projectID == nil || chosenProject == nil {
            projectID = defaultProjectID()
        }
    }

    private func reloadBranches() async {
        guard let projectID else { return }
        branchesLoaded = false
        branch = ""
        let result = await model.loadBranches(projectID: projectID)
        // 读的过程中又换了项目：这份结果已经过期。
        guard !Task.isCancelled, self.projectID == projectID else { return }
        projectBranches = result
        branch = result.current
        if !result.isGitRepository { useWorktree = false }
        branchesLoaded = true
    }

    private func addProject() {
        let panel = NSOpenPanel()
        panel.prompt = l10n.text("add")
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        model.addProject(directory: url)
        projectID = model.selectedProjectID
    }

    @ViewBuilder
    private func tandockLogo(size: CGFloat) -> some View {
        if let logo = TandockAgentIconRenderer.tandockLogo {
            Image(nsImage: logo)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: size, height: size)
                .clipShape(RoundedRectangle(cornerRadius: size * 0.22))
        } else {
            Image(systemName: "terminal.fill")
                .font(.system(size: size * 0.7))
                .foregroundStyle(.tint)
        }
    }

    /// Keep the selection busy while command preflight runs off the main actor.
    private func start(_ profile: TandockAgentProfile) {
        guard startingProfileID == nil else { return }
        startingProfileID = profile.id
        Task { @MainActor in
            // title 传空串：名字来自 CLI，侧栏先显示斜体的「新会话」。
            await model.createSession(
                agentProfileID: profile.id,
                title: "",
                branch: branch.isEmpty ? nil : branch,
                useWorktree: useWorktree,
                projectID: projectID
            )
            // 成功的话这个视图已经被终端替掉了；失败时要把按钮放回可点状态。
            startingProfileID = nil
        }
    }
}

/// 新会话里的 agent 按钮：白色小卡片，悬停时一圈强调色描边加淡光晕，按下时略微压低。
/// 之前是四块没有任何反馈的灰色色块，看不出哪个能点、指针在哪一个上。
private struct TandockAgentTileStyle: ButtonStyle {
    var active: Bool
    var cornerRadius: CGFloat

    func makeBody(configuration: Configuration) -> some View {
        Tile(configuration: configuration, active: active, cornerRadius: cornerRadius)
    }

    private struct Tile: View {
        let configuration: ButtonStyleConfiguration
        let active: Bool
        let cornerRadius: CGFloat
        @State private var hovering = false
        @Environment(\.isEnabled) private var isEnabled

        var body: some View {
            let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            let lit = active || (hovering && isEnabled)
            configuration.label
                .background {
                    shape.fill(active ? Color.tandockAccent.opacity(0.10) : Color.tandockSelection)
                        .shadow(color: Color.tandockShadow, radius: configuration.isPressed ? 0.5 : 1.5,
                                y: configuration.isPressed ? 0 : 1)
                }
                .overlay { shape.strokeBorder(lit ? Color.tandockAccent : Color.tandockHairline, lineWidth: 1) }
                .background {
                    // 光晕画在卡片外侧，不占布局。
                    shape.stroke(Color.tandockAccent.opacity(lit ? 0.16 : 0), lineWidth: 6)
                }
                .scaleEffect(configuration.isPressed ? 0.98 : 1)
                .contentShape(shape)
                .onHover { hovering = $0 }
                .animation(TandockMotion.hover, value: hovering)
                .animation(TandockMotion.hover, value: configuration.isPressed)
        }
    }
}
