import SwiftUI
import YCodeCore

/// 设计稿 §06 屏 05：新建会话没有弹窗。
/// 选择器就地摆进画布，选完 agent 立刻变成终端；同一个组件也用作「项目无会话」与「空窗格」。
struct NewSessionPickerView: View {
    @ObservedObject var model: WorkspaceModel
    @Environment(\.ycodeL10n) private var l10n
    @State private var useWorktree = false
    @State private var branch: String = ""
    /// 已经点下去的 agent。只用来先把反馈画出来——真正的启动下一个 runloop 才跑。
    @State private var startingProfileID: String?

    var body: some View {
        GeometryReader { proxy in
            let compact = proxy.size.width < 470
            VStack(spacing: 0) {
                Spacer(minLength: 0)
                card(compact: compact)
                    .frame(maxWidth: compact ? .infinity : 520)
                    .padding(compact ? 8 : 16)
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .onAppear {
            model.reloadAgentProfiles()
            if model.gitBranches.isEmpty { model.refreshGitStatus() }
            if branch.isEmpty { branch = model.gitStatus?.branch.current ?? "" }
        }
        .onChange(of: model.gitStatus?.branch.current) { _, current in
            if branch.isEmpty, let current { branch = current }
        }
    }

    private func card(compact: Bool) -> some View {
        VStack(spacing: 0) {
            ycodeLogo(size: compact ? 28 : 36)
                .padding(.bottom, compact ? 7 : 10)
            Text(l10n.text("newSessionTitle"))
                .font(compact ? .headline : .title3.weight(.semibold))
            Text(model.selectedProject.map { l10n.text("newSessionSubtitleFormat", $0.name) } ?? l10n.text("newSessionSubtitleNoProject"))
                .font(compact ? .caption : .subheadline)
                .foregroundStyle(.secondary)
                .padding(.top, 2)
                .padding(.bottom, compact ? 10 : 16)

            agents(compact: compact)

            Divider().padding(.top, compact ? 9 : 17).padding(.bottom, compact ? 8 : 15)
            foot(compact: compact)
        }
        .padding(compact ? 13 : 22)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: compact ? 10 : 14))
        .overlay {
            RoundedRectangle(cornerRadius: compact ? 10 : 14)
                .stroke(Color.secondary.opacity(0.18))
        }
    }

    /// agent 横排一行 —— 选一个是一次横向扫视，不是一列待读的清单。
    private func agents(compact: Bool) -> some View {
        HStack(spacing: compact ? 5 : 9) {
            ForEach(model.availableAgentProfiles) { profile in
                let starting = startingProfileID == profile.id
                Button { start(profile) } label: {
                    VStack(spacing: compact ? 4 : 6) {
                        ZStack {
                            YCodeAgentIconView(profile: profile, size: compact ? 18 : 24)
                                .opacity(starting ? 0 : 1)
                            if starting { ProgressView().controlSize(.small) }
                        }
                        .frame(height: compact ? 20 : 28)
                        Text(profile.resolvedDisplayName)
                            .font(compact ? .caption2.weight(.semibold) : .subheadline.weight(.semibold))
                            .lineLimit(1)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, compact ? 8 : 12)
                    .background(
                        Color.secondary.opacity(starting ? 0.16 : 0.08),
                        in: RoundedRectangle(cornerRadius: compact ? 8 : 10)
                    )
                }
                .buttonStyle(.plain)
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

    /// 只有两件事必须在起会话前决定：要不要隔离、基于哪个分支。起来之后就改不了了。
    private func foot(compact: Bool) -> some View {
        HStack(spacing: compact ? 7 : 9) {
            Toggle(isOn: $useWorktree) {
                Text("worktree").font(compact ? .caption : .subheadline)
            }
            .toggleStyle(.checkbox)
            .fixedSize()
            Spacer(minLength: 4)
            Menu {
                ForEach(model.gitBranches) { item in
                    Button {
                        branch = item.name
                    } label: {
                        if item.name == branch { Label(item.name, systemImage: "checkmark") } else { Text(item.name) }
                    }
                }
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: "arrow.triangle.branch").font(.system(size: 10))
                    Text(branch.isEmpty ? l10n.text("currentBranch") : branch)
                        .font(.system(size: 11, design: .monospaced))
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .frame(height: compact ? 22 : 24)
        }
    }

    @ViewBuilder
    private func ycodeLogo(size: CGFloat) -> some View {
        if let logo = YCodeAgentIconRenderer.ycodeLogo {
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

    /// 乐观反馈：先把选中的 agent 置为「启动中」让 SwiftUI 画一帧，下一个 runloop 再做
    /// 真正的启动。`model.createSession` 是主线程同步的（建行、makePlan、拉起 PTY），
    /// 直接在点击里跑的话这段时间界面是死的——点下去没反应，然后突然跳终端。
    private func start(_ profile: YCodeAgentProfile) {
        guard startingProfileID == nil else { return }
        startingProfileID = profile.id
        DispatchQueue.main.async {
            // title 传空串：名字来自 CLI，侧栏先显示斜体的「新会话」。
            model.createSession(
                agentProfileID: profile.id,
                title: "",
                branch: branch.isEmpty ? nil : branch,
                useWorktree: useWorktree
            )
            // 成功的话这个视图已经被终端替掉了；失败时要把按钮放回可点状态。
            startingProfileID = nil
        }
    }
}
