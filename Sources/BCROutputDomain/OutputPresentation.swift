import BCRFoundation
import Foundation

public func withLegacyOutputErrors<T>(_ operation: () throws -> T) throws -> T {
    do { return try operation() }
    catch let error as SharedMotionSafetyError { throw MotionSafetyError(legacyOutputReason(error.reason)) }
}

public func legacyOutputReason(_ key: String, parameterID: ParameterID? = nil) -> String {
    switch key {
    case "output.reason.001": return L10n.text(.init(stringLiteral: "限位、单周期变化量和速度必须是有效的有限数值"))
    case "output.reason.002": return L10n.text(.init(stringLiteral: "安全门需要非空、唯一的限位与不超过 450 ms 的心跳期限"))
    case "output.reason.003": return L10n.text(.init(stringLiteral: "实际状态含非有限数值"))
    case "output.reason.004": return L10n.text(.init(stringLiteral: "时钟倒退，需重新连接安全门"))
    case "output.reason.005": return L10n.text(.init(stringLiteral: "适配器未连接，禁止输出"))
    case "output.reason.006": return L10n.text(.init(stringLiteral: "心跳时间异常，禁止输出"))
    case "output.reason.007": return L10n.text(.init(stringLiteral: "心跳超时，已停止输出"))
    case "output.reason.008": return L10n.text(.init(stringLiteral: "未收到对端心跳，已停止输出"))
    case "output.reason.009": return L10n.text(.init(stringLiteral: "等待对端心跳"))
    case "output.reason.010": return L10n.text(.init(stringLiteral: "使能关闭，禁止运动输出"))
    case "output.reason.011":
        guard let parameterID else { return key }
        return L10n.text("等待新鲜实际状态：\(parameterID)")
    case "output.reason.012":
        guard let parameterID else { return key }
        return L10n.text("实际状态超出软限位：\(parameterID)")
    case "output.reason.013":
        guard let parameterID else { return key }
        return L10n.text("目标缺失或不是有限数值：\(parameterID)")
    case "output.reason.014": return L10n.text(.init(stringLiteral: "请先关闭再开启使能，禁止自动恢复运动"))
    case "output.reason.015": return L10n.text(.init(stringLiteral: "限位 / 限速中"))
    case "output.reason.016": return L10n.text(.init(stringLiteral: "输出已就绪"))
    case "output.reason.017": return L10n.text(.init(stringLiteral: "OSC bundle 嵌套过深"))
    case "output.reason.018": return L10n.text(.init(stringLiteral: "OSC 地址必须以 / 开始"))
    case "output.reason.019": return L10n.text(.init(stringLiteral: "OSC 不接受非有限浮点数"))
    case "output.reason.020": return L10n.text(.init(stringLiteral: "OSC bundle 元素过大"))
    case "output.reason.021": return L10n.text(.init(stringLiteral: "OSC UDP 数据包过大"))
    case "output.reason.022": return L10n.text(.init(stringLiteral: "本适配器只接受立即执行的 OSC bundle"))
    case "output.reason.023": return L10n.text(.init(stringLiteral: "实际状态 OSC 地址无效"))
    case "output.reason.024": return L10n.text(.init(stringLiteral: "OSC 数据包长度或嵌套无效"))
    case "output.reason.025": return L10n.text(.init(stringLiteral: "OSC bundle 长度无效"))
    case "output.reason.026": return L10n.text(.init(stringLiteral: "OSC 地址无效"))
    case "output.reason.027": return L10n.text(.init(stringLiteral: "OSC 缺少类型标签"))
    case "output.reason.028": return L10n.text(.init(stringLiteral: "OSC 实际值不是有限数值"))
    case "output.reason.029": return L10n.text(.init(stringLiteral: "不支持 OSC 类型标签"))
    case "output.reason.030": return L10n.text(.init(stringLiteral: "OSC 消息有多余字节"))
    case "output.reason.031": return L10n.text(.init(stringLiteral: "OSC 字符串必须是非空字符编码的 ASCII"))
    case "output.reason.032": return L10n.text(.init(stringLiteral: "OSC 数值不完整"))
    case "output.reason.033": return L10n.text(.init(stringLiteral: "OSC 字符串缺少结束符"))
    case "output.reason.034": return L10n.text(.init(stringLiteral: "OSC 字符串不是 ASCII"))
    case "output.reason.035": return L10n.text(.init(stringLiteral: "OSC 字符串填充无效"))
    case "output.reason.036": return L10n.text(.init(stringLiteral: "尚未确认对端标识"))
    case "output.reason.037": return L10n.text(.init(stringLiteral: "禁止在停止帧中发送运动值"))
    case "output.reason.038": return L10n.text(.init(stringLiteral: "参数值必须是有限数值"))
    case "output.reason.039": return L10n.text(.init(stringLiteral: "实际回传包含未知参数或非法数值"))
    case "output.clock.nonfinite": return L10n.text("时间不是有限数值，需重新连接安全门")
    case "output.clock.regressed": return L10n.text("心跳时间倒退，需重新连接安全门")
    default: return key
    }
}

public func legacyMotionStatus(_ status: SharedMotionGateStatus) -> MotionGateStatus {
    switch status {
    case .disconnected: .disconnected
    case .disabled: .disabled
    case .waitingHeartbeat: .waitingHeartbeat
    case .heartbeatExpired: .heartbeatExpired
    case .waitingActual: .waitingActual
    case .actualOutOfLimits: .actualOutOfLimits
    case .invalidTarget: .invalidTarget
    case .invalidActual: .invalidActual
    case .clockError: .clockError
    case .waitingRearm: .waitingRearm
    case .ready: .ready
    }
}
