import AppKit
import Testing
@testable import TandockApp

@Suite("Terminal scroll indicator")
@MainActor
struct TerminalScrollIndicatorTests {
    private let bounds = CGRect(x: 0, y: 0, width: 15, height: 406)

    @Test func liveBottomPinsKnobToBottomEdge() {
        let knob = TandockTerminalScrollIndicator.knobFrame(in: bounds, position: 1, proportion: 0.25)
        #expect(knob.minY == 3)
        #expect(knob.height == 100)
        #expect(knob.maxX == bounds.maxX - 3)
        #expect(knob.width == TandockTerminalScrollIndicator.knobWidth)
    }

    @Test func oldestScrollbackPinsKnobToTopEdge() {
        let knob = TandockTerminalScrollIndicator.knobFrame(in: bounds, position: 0, proportion: 0.25)
        #expect(knob.maxY == bounds.maxY - 3)
    }

    @Test func longScrollbackKeepsKnobGrabbable() {
        let knob = TandockTerminalScrollIndicator.knobFrame(in: bounds, position: 0.5, proportion: 0.001)
        #expect(knob.height == TandockTerminalScrollIndicator.minimumKnobHeight)
        #expect(abs(knob.midY - bounds.midY) < 0.5)
    }
}
