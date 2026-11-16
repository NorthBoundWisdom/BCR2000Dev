import BCRFoundation
import Foundation
import struct ParameterOutputPlugin.ParameterOutputPlugin
import struct ParameterOutputPlugin.MotionLimit
import struct ParameterOutputPlugin.MotionSafetyDecision
import enum ParameterOutputPlugin.MotionOutputPrecision

func startedOutputFixture(limits: [MotionLimit], heartbeatTimeout: TimeInterval = 0.3,
                          precision: MotionOutputPrecision = .double) throws -> ParameterOutputPlugin
{
    var plugin = try ParameterOutputPlugin(limits: limits, heartbeatTimeout: heartbeatTimeout, precision: precision)
    _ = try plugin.handle(.start, at: 0)
    return plugin
}

func evaluateFixture(_ plugin: inout ParameterOutputPlugin, targets: [ParameterID: Double],
                     enabled: Bool, at time: Date) throws -> MotionSafetyDecision
{
    try plugin.setEnabled(enabled)
    return plugin.evaluate(targets: targets, at: time.timeIntervalSinceReferenceDate)
}
