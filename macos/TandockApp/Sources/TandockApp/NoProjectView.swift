import AppKit
import SwiftUI

/// 与 docs/design-preview/index.html#empty 对齐的首次打开项目界面。
struct NoProjectView: View {
    @Binding var isDropTargeted: Bool
    let dropRejection: String?
    let onOpenProject: () -> Void
    let onDropFolders: ([NSItemProvider]) -> Void

    @Environment(\.tandockL10n) private var l10n
    @State private var dropHovered = false

    var body: some View {
        GeometryReader { proxy in
            let compact = proxy.size.height < 576
            ScrollView {
                content(compact: compact)
                    .frame(maxWidth: 390)
                    .padding(.horizontal, 24)
                    .padding(.vertical, compact ? 22 : 40)
                    .frame(maxWidth: .infinity)
                    .frame(minHeight: proxy.size.height)
            }
            .scrollBounceBehavior(.basedOnSize)
        }
        .tandockCard(cornerRadius: TandockMetrics.radiusCard)
        .contentShape(Rectangle())
        .onDrop(of: [.fileURL], isTargeted: $isDropTargeted) { providers in
            onDropFolders(providers)
            return true
        }
    }

    private func content(compact: Bool) -> some View {
        VStack(spacing: 0) {
            logo(size: compact ? 39 : 48)
                .shadow(color: .tandockShadow, radius: 6, y: 3)
                .padding(.bottom, compact ? 18 : 23)
            Text(l10n.text("addFirstProjectTitle"))
                .font(.system(size: 23, weight: .semibold))
                .tracking(-0.55)
            Text(l10n.text("addFirstProjectBody"))
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
                .lineSpacing(5)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 10)

            Button(action: onOpenProject) {
                HStack(spacing: 9) {
                    Image(systemName: "folder").font(.system(size: 14))
                    Text(l10n.text("chooseFolderEllipsis"))
                        .font(.system(size: 13, weight: .semibold))
                    Text("⌘O")
                        .font(.system(size: 11, design: .monospaced))
                        .padding(.leading, 5)
                        .accessibilityHidden(true)
                }
                .padding(.horizontal, 17)
                .frame(height: 40)
            }
            .buttonStyle(NoProjectOpenButtonStyle())
            .padding(.top, compact ? 18 : 27)

            dropTarget
                .padding(.top, compact ? 18 : 24)

            if let dropRejection {
                Text(dropRejection)
                    .font(.caption)
                    .foregroundStyle(Color.tandockWarn)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 10)
                    .accessibilityLabel(dropRejection)
            }

            Text(l10n.text("addFirstProjectNext"))
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .lineSpacing(5)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, compact ? 17 : 24)
        }
    }

    private var dropTarget: some View {
        let highlighted = isDropTargeted || dropHovered
        return Button(action: onOpenProject) {
            VStack(spacing: 6) {
                Image(systemName: "folder")
                    .font(.system(size: 23, weight: .light))
                    .foregroundStyle(isDropTargeted ? Color.tandockAccentText : Color.secondary)
                    .padding(.bottom, 3)
                Text(l10n.text("dropFolderHere"))
                    .font(.system(size: 12))
                Text(l10n.text("dropFolderHint"))
                    .font(.system(size: 11))
            }
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity)
            .frame(height: 108)
            .background(highlighted ? Color.tandockAccent.opacity(0.04) : .clear)
            .clipShape(RoundedRectangle(cornerRadius: TandockMetrics.radiusCard))
            .overlay {
                RoundedRectangle(cornerRadius: TandockMetrics.radiusCard)
                    .strokeBorder(
                        highlighted ? Color.tandockAccent.opacity(0.5) : Color.tandockHairline,
                        style: StrokeStyle(lineWidth: 1, dash: isDropTargeted ? [] : [3, 3])
                    )
            }
            .contentShape(RoundedRectangle(cornerRadius: TandockMetrics.radiusCard))
        }
        .buttonStyle(.plain)
        .onHover { dropHovered = $0 }
        .animation(TandockMotion.hover, value: highlighted)
        .help(l10n.text("chooseFolderEllipsis"))
    }

    @ViewBuilder
    private func logo(size: CGFloat) -> some View {
        if let logo = TandockAgentIconRenderer.tandockLogo {
            Image(nsImage: logo)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: size, height: size)
                .accessibilityHidden(true)
        } else {
            Image(systemName: "terminal.fill")
                .font(.system(size: size * 0.7))
                .foregroundStyle(Color.tandockAccent)
                .frame(width: size, height: size)
                .accessibilityHidden(true)
        }
    }
}

private struct NoProjectOpenButtonStyle: ButtonStyle {
    @State private var hovering = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            // 深色文字与珊瑚底保持可读对比度，浅深主题共用。
            .foregroundStyle(Color(red: 36 / 255, green: 23 / 255, blue: 21 / 255))
            .background(Color.tandockAccent.opacity(configuration.isPressed ? 0.72 : hovering ? 0.88 : 1))
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .shadow(color: Color.tandockAccent.opacity(0.09), radius: 2, y: 2)
            .onHover { hovering = $0 }
            .animation(TandockMotion.hover, value: hovering)
    }
}
