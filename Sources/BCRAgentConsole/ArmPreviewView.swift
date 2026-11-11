import BCRAgentCore
import SwiftUI

/// Simple kinematic sketch of the demo arm, driven only by software parameter values.
/// It demonstrates that hardware and software edits land in the same parameter state.
struct ArmPreviewView: View {
    @ObservedObject var model: ConsoleViewModel

    private func value(_ id: String) -> Double? {
        model.engine.value(of: ParameterID(id))
    }

    var body: some View {
        if let j1 = value("arm.j1"), let j2 = value("arm.j2"), let j3 = value("arm.j3"), let j4 = value("arm.j4") {
            let pose = ArmPose(
                base: j1,
                shoulder: j2,
                elbow: j3,
                wristPitch: j4,
                wristRoll: value("arm.j5") ?? 0,
                toolRoll: value("arm.j6") ?? 0,
                gripper: value("arm.gripper") ?? 0,
                speed: value("arm.speed") ?? 0,
                enabled: (value("arm.enabled") ?? 1) >= 0.5
            )
            // Side by side when wide enough, otherwise the side view stacks above the readouts.
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .top, spacing: 16) {
                    sideView(pose).frame(minWidth: 260)
                    details(pose)
                }
                VStack(spacing: 12) {
                    sideView(pose)
                    HStack(alignment: .top, spacing: 12) {
                        details(pose)
                        Spacer(minLength: 0)
                    }
                }
            }
        } else {
            Text(L10n.text("当前配置不含 arm.j1–arm.j4 参数。可在“参数”页“载入预置…”中选择“机械臂示例”。"))
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, minHeight: 120)
        }
    }

    private func sideView(_ pose: ArmPose) -> some View {
        SideView(pose: pose)
            .frame(height: 240)
            .frame(maxWidth: .infinity)
            .background(Color.black.opacity(0.22), in: RoundedRectangle(cornerRadius: 10))
    }

    private func details(_ pose: ArmPose) -> some View {
        VStack(spacing: 12) {
            TopView(pose: pose)
                .frame(width: 150, height: 150)
                .background(Color.black.opacity(0.22), in: RoundedRectangle(cornerRadius: 10))
            VStack(alignment: .leading, spacing: 4) {
                readout(L10n.text("J5 腕旋"), pose.wristRoll, "°")
                readout(L10n.text("J6 末端"), pose.toolRoll, "°")
                readout(L10n.text("夹爪"), pose.gripper, "%")
                readout(L10n.text("速度"), pose.speed, "%")
                Text(pose.enabled ? L10n.text("● 已使能") : L10n.text("○ 未使能（B2-1 切换）"))
                    .font(.caption.bold())
                    .foregroundStyle(pose.enabled ? .green : .orange)
            }
            .frame(width: 150, alignment: .leading)
        }
    }

    private func readout(_ title: String, _ value: Double, _ unit: String) -> some View {
        HStack {
            Text(title).foregroundStyle(.secondary)
            Spacer()
            Text("\(ArmPreviewNumbers.text(value.rounded()))\(unit)").monospacedDigit()
        }
        .font(.caption)
    }
}

private struct ArmPose {
    let base, shoulder, elbow, wristPitch, wristRoll, toolRoll, gripper, speed: Double
    let enabled: Bool
}

private struct SideView: View {
    let pose: ArmPose

    var body: some View {
        Canvas { context, size in
            let scale = min(size.width, size.height) / 3.0
            let ground = CGPoint(x: size.width / 2, y: size.height - 24)
            let color = pose.enabled ? Theme.parameter : Color.gray

            var groundLine = Path()
            groundLine.move(to: CGPoint(x: 20, y: ground.y))
            groundLine.addLine(to: CGPoint(x: size.width - 20, y: ground.y))
            context.stroke(groundLine, with: .color(.white.opacity(0.15)), lineWidth: 1)

            let baseRect = CGRect(x: ground.x - 26, y: ground.y - 18, width: 52, height: 18)
            context.fill(Path(roundedRect: baseRect, cornerRadius: 4), with: .color(.white.opacity(0.18)))

            // Angles from vertical; J2 tilts the upper arm, J3 and J4 are relative.
            let shoulderPoint = CGPoint(x: ground.x, y: ground.y - 30)
            let a1 = ArmPreviewNumbers.radians(pose.shoulder)
            let a2 = a1 + ArmPreviewNumbers.radians(pose.elbow)
            let a3 = a2 + ArmPreviewNumbers.radians(pose.wristPitch)
            func advance(_ p: CGPoint, _ angle: Double, _ length: Double) -> CGPoint {
                CGPoint(x: p.x + sin(angle) * length * scale, y: p.y - cos(angle) * length * scale)
            }
            let elbowPoint = advance(shoulderPoint, a1, 1.0)
            let wristPoint = advance(elbowPoint, a2, 0.85)
            let toolPoint = advance(wristPoint, a3, 0.35)

            var links = Path()
            links.move(to: shoulderPoint)
            links.addLine(to: elbowPoint)
            links.addLine(to: wristPoint)
            links.addLine(to: toolPoint)
            context.stroke(
                links,
                with: .color(color),
                style: StrokeStyle(lineWidth: 9, lineCap: .round, lineJoin: .round)
            )

            for point in [shoulderPoint, elbowPoint, wristPoint] {
                let joint = CGRect(x: point.x - 7, y: point.y - 7, width: 14, height: 14)
                context.fill(Path(ellipseIn: joint), with: .color(Color(white: 0.12)))
                context.stroke(Path(ellipseIn: joint), with: .color(color), lineWidth: 2)
            }

            // Gripper jaws open perpendicular to the last link.
            let opening = 4 + min(max(pose.gripper, 0), 100) / 100 * 12
            let normal = CGVector(dx: cos(a3), dy: sin(a3))
            for side in [-1.0, 1.0] {
                let start = CGPoint(
                    x: toolPoint.x + normal.dx * opening * side,
                    y: toolPoint.y + normal.dy * opening * side
                )
                var jaw = Path()
                jaw.move(to: start)
                jaw.addLine(to: advance(start, a3, 0.12))
                context.stroke(jaw, with: .color(.orange), style: StrokeStyle(lineWidth: 3.5, lineCap: .round))
            }

            context.draw(
                Text(
                    L10n
                        .text(
                            "侧视 · J2 \(ArmPreviewNumbers.text(pose.shoulder))°  J3 \(ArmPreviewNumbers.text(pose.elbow))°  J4 \(ArmPreviewNumbers.text(pose.wristPitch))°"
                        )
                )
                .font(.caption2.monospaced())
                .foregroundColor(.secondary),
                at: CGPoint(x: 12, y: 14),
                anchor: .leading
            )
        }
    }
}

private struct TopView: View {
    let pose: ArmPose

    var body: some View {
        Canvas { context, size in
            let center = CGPoint(x: size.width / 2, y: size.height / 2 + 6)
            let radius = min(size.width, size.height) / 2 - 22
            let ring = CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2)
            context.stroke(Path(ellipseIn: ring), with: .color(.white.opacity(0.15)), lineWidth: 1)

            let angle = ArmPreviewNumbers.radians(pose.base)
            var arm = Path()
            arm.move(to: center)
            arm.addLine(to: CGPoint(x: center.x + sin(angle) * radius, y: center.y - cos(angle) * radius))
            context.stroke(
                arm,
                with: .color(pose.enabled ? Theme.parameter : .gray),
                style: StrokeStyle(lineWidth: 6, lineCap: .round)
            )
            context.fill(
                Path(ellipseIn: CGRect(x: center.x - 6, y: center.y - 6, width: 12, height: 12)),
                with: .color(.white.opacity(0.6))
            )
            context.draw(
                Text(L10n.text("俯视 · J1 \(ArmPreviewNumbers.text(pose.base))°")).font(.caption2.monospaced())
                    .foregroundColor(.secondary),
                at: CGPoint(x: size.width / 2, y: 12)
            )
        }
    }
}

/// Presentation uses floating-point formatting; no narrowing conversion to a machine integer.
enum ArmPreviewNumbers {
    static func text(_ value: Double) -> String {
        guard value.isFinite else { return L10n.text("无效值") }
        if abs(value) >= 1e9 {
            return value.formatted(.number.notation(.scientific).precision(.significantDigits(4)))
        }
        return value.formatted(.number.grouping(.never).precision(.fractionLength(0)))
    }

    static func radians(_ degrees: Double) -> Double {
        degrees.truncatingRemainder(dividingBy: 360) / 180 * .pi
    }
}
