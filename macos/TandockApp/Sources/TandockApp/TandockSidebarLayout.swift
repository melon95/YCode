import AppKit
import SwiftUI

@MainActor
final class TandockSidebarPresentation: ObservableObject {
    @Published var isExpanded = true {
        didSet { dismissPreview() }
    }
    @Published private(set) var isPreviewing = false
    private var dismissal: Task<Void, Never>?
    private var pointerInside = false
    private var menuTrackingDepth = 0

    var isVisible: Bool { isExpanded || isPreviewing }

    func hover(at location: CGPoint?, sidebarWidth: CGFloat) {
        guard !isExpanded else { return }
        let activationWidth = isPreviewing ? sidebarWidth : 6
        pointerInside = location.map { $0.x >= 0 && $0.x <= activationWidth } ?? false
        if pointerInside {
            dismissal?.cancel()
            dismissal = nil
            isPreviewing = true
        } else if isPreviewing, menuTrackingDepth == 0, dismissal == nil {
            dismissal = Task { @MainActor [weak self] in
                do { try await Task.sleep(for: .milliseconds(220)) } catch { return }
                self?.isPreviewing = false
                self?.dismissal = nil
            }
        }
    }

    func beginMenuTracking() {
        menuTrackingDepth += 1
        dismissal?.cancel()
        dismissal = nil
    }

    func endMenuTracking() {
        menuTrackingDepth = max(0, menuTrackingDepth - 1)
        if menuTrackingDepth == 0, !pointerInside { dismissPreview() }
    }

    func dismissPreview() {
        dismissal?.cancel()
        dismissal = nil
        isPreviewing = false
    }
}

/// 只有固定展开才给侧栏留宽度；悬停预览始终在画布上方，画布与终端宿主保持原位。
struct TandockSidebarLayout<Sidebar: View, Detail: View>: View {
    @ObservedObject var presentation: TandockSidebarPresentation
    @ViewBuilder var sidebar: Sidebar
    @ViewBuilder var detail: Detail
    @State private var requestedWidth = TandockMetrics.sidebarWidth
    @State private var dragStartWidth: CGFloat?

    var body: some View {
        GeometryReader { proxy in
            let width = min(requestedWidth, max(TandockMetrics.sidebarMinWidth,
                                               proxy.size.width - TandockMetrics.canvasMinWidth))
            ZStack(alignment: .leading) {
                HStack(spacing: 0) {
                    Color.clear.frame(width: presentation.isExpanded ? width + 1 : 0)
                    detail.frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                sidebar
                    .frame(width: width, height: proxy.size.height)
                    .background(Color.tandockChrome)
                    .shadow(color: .black.opacity(presentation.isPreviewing ? 0.16 : 0), radius: 12, x: 4)
                    .offset(x: presentation.isVisible ? 0 : -width - 20)
                    .animation(TandockMotion.panelArea, value: presentation.isVisible)
                    .allowsHitTesting(presentation.isVisible)
                    .accessibilityHidden(!presentation.isVisible)
                if presentation.isExpanded {
                    resizeHandle(width: width, availableWidth: proxy.size.width)
                        .offset(x: width - 3)
                }
            }
            .frame(width: proxy.size.width, height: proxy.size.height)
            .clipped()
            .contentShape(Rectangle())
            .onContinuousHover { phase in
                switch phase {
                case .active(let location): presentation.hover(at: location, sidebarWidth: width)
                case .ended: presentation.hover(at: nil, sidebarWidth: width)
                }
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSMenu.didBeginTrackingNotification)) { _ in
            presentation.beginMenuTracking()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSMenu.didEndTrackingNotification)) { _ in
            presentation.endMenuTracking()
        }
        .onDisappear { presentation.dismissPreview() }
    }

    private func resizeHandle(width: CGFloat, availableWidth: CGFloat) -> some View {
        Color.clear
            .frame(width: 7)
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 1)
                .onChanged { value in
                    if dragStartWidth == nil { dragStartWidth = width }
                    requestedWidth = min(max(TandockMetrics.sidebarMinWidth,
                                             (dragStartWidth ?? width) + value.translation.width),
                                         max(TandockMetrics.sidebarMinWidth, availableWidth - TandockMetrics.canvasMinWidth))
                }
                .onEnded { _ in dragStartWidth = nil })
            .onHover { inside in
                if inside { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() }
            }
    }
}
