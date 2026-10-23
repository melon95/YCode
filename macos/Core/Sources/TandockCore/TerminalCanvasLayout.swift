import Foundation

public enum TandockTerminalLayout: String, CaseIterable, Codable, Identifiable, Sendable {
    case single
    case stack
    case columns
    case grid2x2
    case mainSide
    case tabs

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .single: "单栏"
        case .stack: "上下堆叠"
        case .columns: "并排多栏"
        case .grid2x2: "网格 2×2"
        case .mainSide: "主 + 侧"
        case .tabs: "标签页"
        }
    }

    public static func validModes(for count: Int) -> [Self] {
        switch count {
        case ...1: [.single, .tabs]
        case 2: [.stack, .columns, .tabs]
        case 3: [.stack, .columns, .mainSide, .tabs]
        default: [.stack, .columns, .grid2x2, .mainSide, .tabs]
        }
    }

    public static func defaultLayout(for count: Int) -> Self {
        switch count {
        case ...1: .single
        case 2: .columns
        case 3: .mainSide
        default: .grid2x2
        }
    }

    public static func reflow(_ current: Self, for count: Int) -> Self {
        validModes(for: count).contains(current) ? current : defaultLayout(for: count)
    }

    public static func reflow(_ current: Self, from previousCount: Int, to count: Int) -> Self {
        if count > previousCount, current == defaultLayout(for: previousCount) {
            return defaultLayout(for: count)
        }
        return reflow(current, for: count)
    }
}

public enum TandockTerminalCanvasOpenMode: Sendable {
    case newPane
    case replaceFocused
}

public struct TandockTerminalCanvasOpenResult: Equatable, Sendable {
    public let sessionIDs: [String]
    public let focusedSlot: Int
    public let layout: TandockTerminalLayout
}

public enum TandockTerminalCanvasRouting {
    public static let maximumVisibleSessions = 4

    public static func open(
        sessionID: String,
        visibleSessionIDs: [String],
        focusedSlot: Int,
        layout: TandockTerminalLayout,
        mode: TandockTerminalCanvasOpenMode
    ) -> TandockTerminalCanvasOpenResult {
        var sessionIDs = layout == .tabs ? visibleSessionIDs : Array(visibleSessionIDs.prefix(maximumVisibleSessions))
        let previousCount = sessionIDs.count
        var resolvedFocus = sessionIDs.isEmpty ? 0 : min(max(focusedSlot, 0), sessionIDs.count - 1)

        if let existing = sessionIDs.firstIndex(of: sessionID) {
            resolvedFocus = existing
        } else if layout == .tabs || (mode == .newPane && sessionIDs.count < maximumVisibleSessions) {
            sessionIDs.append(sessionID)
            resolvedFocus = sessionIDs.count - 1
        } else if sessionIDs.isEmpty {
            sessionIDs = [sessionID]
            resolvedFocus = 0
        } else {
            sessionIDs[resolvedFocus] = sessionID
        }

        return .init(
            sessionIDs: sessionIDs,
            focusedSlot: resolvedFocus,
            layout: TandockTerminalLayout.reflow(layout, from: previousCount, to: sessionIDs.count)
        )
    }
}
