import AppKit
import SwiftUI

@MainActor
struct KnobValueInput: NSViewRepresentable {
    let onDelta: (Int) -> Void

    func makeNSView(context: Context) -> KnobValueInputView {
        KnobValueInputView(onDelta: onDelta)
    }

    func updateNSView(_ nsView: KnobValueInputView, context: Context) {
        nsView.onDelta = onDelta
    }
}

@MainActor
final class KnobValueInputView: NSView {
    var onDelta: (Int) -> Void

    private var scrollRemainder: CGFloat = 0
    private var mouseRemainder: CGFloat = 0
    private var lastMouseLocation: CGFloat?

    init(onDelta: @escaping (Int) -> Void) {
        self.onDelta = onDelta
        super.init(frame: .zero)
        toolTip = "滚轮或三指上下拖动可调整数值"
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func scrollWheel(with event: NSEvent) {
        emitSteps(from: event.scrollingDeltaY, accumulator: &scrollRemainder)
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        bounds.contains(point) ? self : nil
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .openHand)
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        lastMouseLocation = convert(event.locationInWindow, from: nil).y
        mouseRemainder = 0
        NSCursor.closedHand.set()
    }

    override func mouseDragged(with event: NSEvent) {
        let location = convert(event.locationInWindow, from: nil).y
        guard let lastMouseLocation else {
            self.lastMouseLocation = location
            return
        }
        self.lastMouseLocation = location
        emitSteps(from: (location - lastMouseLocation) / 4, accumulator: &mouseRemainder)
    }

    override func mouseUp(with event: NSEvent) {
        lastMouseLocation = nil
        mouseRemainder = 0
        NSCursor.openHand.set()
    }

    private func emitSteps(from delta: CGFloat, accumulator: inout CGFloat) {
        accumulator += delta
        let steps = accumulator.rounded(.towardZero)
        guard steps != 0 else {
            return
        }
        accumulator -= steps
        onDelta(Int(steps))
    }
}
