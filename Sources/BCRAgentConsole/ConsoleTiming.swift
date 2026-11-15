import BCRFoundation
import Foundation

/// Work delays can complete immediately without spinning periodic presentation tasks. Tests that
/// assert duration semantics inject the same manual clock into both lanes instead.
@MainActor
struct ConsoleTiming {
    var work: HostTime = .live
    var presentation: HostTime = .live
    static var immediate: Self { .init(work: .immediate) }

    static let frame: Duration = .milliseconds(16)
    static let activity: Duration = .milliseconds(120)
    static let connection: Duration = .milliseconds(300)
    static let notice: Duration = .seconds(6)
    static let minimumPressSeconds = 0.08
    static let pulse: Duration = .milliseconds(180)
    static let blink: Duration = .milliseconds(50)
    static let outputTick: Duration = .milliseconds(20)
    static let webSocketPoll: Duration = .milliseconds(200)
}
