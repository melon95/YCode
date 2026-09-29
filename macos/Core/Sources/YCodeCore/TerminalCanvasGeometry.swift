import Foundation

/// Flat pane frames keep terminal view identity independent of the split hierarchy.
public struct YCodeTerminalCanvasGeometry {
    public struct Divider: Identifiable {
        public let group: String
        public let index: Int
        public let isVertical: Bool
        public let frame: CGRect
        public let lengths: [CGFloat]
        public let availableLength: CGFloat
        public var id: String { "\(group)-\(index)" }

        /// Resize only the two neighbours; small canvases relax the minimum equally.
        public func resizedWeights(translation: CGFloat) -> [CGFloat] {
            guard availableLength > 0 else { return lengths }
            var result = lengths
            let pair = lengths[index] + lengths[index + 1]
            let minimum = min(isVertical ? 220 : 150, pair / 2)
            result[index] = min(max(lengths[index] + translation, minimum), pair - minimum)
            result[index + 1] = pair - result[index]
            return result.map { $0 / availableLength }
        }
    }

    public private(set) var frames: [CGRect] = []
    public private(set) var dividers: [Divider] = []

    /// `gap` 是窗格之间的缝，也是分隔条的命中宽度；浮卡布局传 8，贴合布局用默认的 5。
    public init(layout: YCodeTerminalLayout, count: Int, size: CGSize, weights: [String: [CGFloat]] = [:],
                gap preferredGap: CGFloat = 5) {
        guard count > 0 else { return }
        let count = min(count, YCodeTerminalCanvasRouting.maximumVisibleSessions)
        let layout = YCodeTerminalLayout.reflow(layout, for: count)
        let bounds = CGRect(origin: .zero, size: CGSize(width: max(0, size.width), height: max(0, size.height)))
        func split(_ rect: CGRect, count: Int, vertical: Bool, group: String, defaults: [CGFloat]? = nil) -> [CGRect] {
            guard count > 1 else { return [rect] }
            let total = vertical ? rect.width : rect.height
            let gap = min(preferredGap, total / CGFloat(count - 1))
            let available = max(0, total - gap * CGFloat(count - 1))
            let proposed = weights[group] ?? defaults ?? Array(repeating: 1, count: count)
            let valid = proposed.count == count && proposed.allSatisfy { $0.isFinite && $0 > 0 }
            let values = valid ? proposed : Array(repeating: CGFloat(1), count: count)
            let sum = values.reduce(0, +)
            let lengths = values.map { available * $0 / sum }
            var offset: CGFloat = 0
            var result: [CGRect] = []
            for index in 0..<count {
                let frame = vertical
                    ? CGRect(x: rect.minX + offset, y: rect.minY, width: lengths[index], height: rect.height)
                    : CGRect(x: rect.minX, y: rect.minY + offset, width: rect.width, height: lengths[index])
                result.append(frame)
                offset += lengths[index]
                if index < count - 1 {
                    let dividerFrame = vertical
                        ? CGRect(x: rect.minX + offset, y: rect.minY, width: gap, height: rect.height)
                        : CGRect(x: rect.minX, y: rect.minY + offset, width: rect.width, height: gap)
                    dividers.append(Divider(group: group, index: index, isVertical: vertical,
                                            frame: dividerFrame, lengths: lengths, availableLength: available))
                    offset += gap
                }
            }
            return result
        }
        switch layout {
        case .single:
            frames = [bounds]
        case .stack, .columns:
            frames = split(bounds, count: count, vertical: layout == .columns, group: "linear")
        case .grid2x2:
            let rows = split(bounds, count: 2, vertical: false, group: "rows")
            frames = split(rows[0], count: 2, vertical: true, group: "top")
                + split(rows[1], count: 2, vertical: true, group: "bottom")
        case .mainSide:
            let columns = split(bounds, count: 2, vertical: true, group: "columns", defaults: [0.6, 0.4])
            frames = [columns[0]] + split(columns[1], count: count - 1, vertical: false, group: "side")
        }
    }
}
