import AppKit
import SwiftUI

/// Captures scroll-wheel and vertical drag on a knob and reports whole detents.
/// Hold Shift while dragging for fine steps.
@MainActor
struct KnobValueInput: NSViewRepresentable {
    let onTouch: () -> Void
    let onDelta: (Int) -> Void

    func makeNSView(context: Context) -> KnobValueInputView {
        KnobValueInputView(onTouch: onTouch, onDelta: onDelta)
    }

    func updateNSView(_ nsView: KnobValueInputView, context: Context) {
        nsView.onTouch = onTouch
        nsView.onDelta = onDelta
    }
}

@MainActor
final class KnobValueInputView: NSView {
    var onTouch: () -> Void
    var onDelta: (Int) -> Void

    private var scrollRemainder: CGFloat = 0
    private var mouseRemainder: CGFloat = 0
    private var lastMouseLocation: CGFloat?

    init(onTouch: @escaping () -> Void, onDelta: @escaping (Int) -> Void) {
        self.onTouch = onTouch
        self.onDelta = onDelta
        super.init(frame: .zero)
        toolTip = "上下拖动或滚轮调整（按住 Shift 精调）"
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        bounds.contains(convert(point, from: superview)) ? self : nil
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .openHand)
    }

    override func scrollWheel(with event: NSEvent) {
        if event.phase == .began || (event.phase == [] && event.momentumPhase == []) {
            onTouch()
        }
        emitSteps(from: event.scrollingDeltaY * (event.hasPreciseScrollingDeltas ? 0.25 : 1), accumulator: &scrollRemainder)
    }

    override func mouseDown(with event: NSEvent) {
        onTouch()
        lastMouseLocation = convert(event.locationInWindow, from: nil).y
        mouseRemainder = 0
        NSCursor.closedHand.set()
    }

    override func mouseDragged(with event: NSEvent) {
        let location = convert(event.locationInWindow, from: nil).y
        defer { lastMouseLocation = location }
        guard let lastMouseLocation else { return }
        let divisor: CGFloat = event.modifierFlags.contains(.shift) ? 8 : 2
        emitSteps(from: (location - lastMouseLocation) / divisor, accumulator: &mouseRemainder)
    }

    override func mouseUp(with event: NSEvent) {
        lastMouseLocation = nil
        mouseRemainder = 0
        NSCursor.openHand.set()
    }

    private func emitSteps(from delta: CGFloat, accumulator: inout CGFloat) {
        accumulator += delta
        let steps = accumulator.rounded(.towardZero)
        guard steps != 0 else { return }
        accumulator -= steps
        onDelta(Int(steps))
    }
}
