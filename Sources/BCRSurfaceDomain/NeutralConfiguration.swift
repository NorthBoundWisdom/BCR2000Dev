import BCRFoundation
import Foundation

public extension SurfaceConfiguration {
    static func neutral() -> SurfaceConfiguration {
        let parameters = (1 ... 8).map { ParameterDefinition(
            id: ParameterID("general.\($0)"),
            name: L10n.text("参数 \($0)"),
            group: L10n.text("通用"),
            minimum: 0,
            maximum: 100
        ) }
        let assignments = parameters.enumerated().map { ControlAssignment(
            control: .pushEncoder(group: 1, $0.offset + 1),
            target: .parameter($0.element.id)
        ) }
        return SurfaceConfiguration(name: L10n.text("默认配置"), parameters: parameters, assignments: assignments)
    }
}
