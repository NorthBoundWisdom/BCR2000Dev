import BCRSurfaceDomain
import BCRFoundation
import Foundation

/// Validates the JSON Schema vocabulary used by this server's advertised tool inputs.
enum MCPInputValidation {
    static func validate(_ value: JSONValue, schema: JSONValue, depth: Int = 0) throws {
        guard depth < 32,
              let schema = schema.objectValue else { throw MCPToolFailure(L10n.text("工具参数嵌套过深或 Schema 无效")) }
        if let constant = schema["const"], constant != value { throw MCPToolFailure(L10n.text("参数枚举值无效")) }
        if let values = schema["enum"]?.arrayValue,
           !values.contains(value) { throw MCPToolFailure(L10n.text("参数枚举值无效")) }
        if let alternatives = schema["oneOf"]?.arrayValue {
            var matches = 0
            for alternative in alternatives {
                do { try validate(value, schema: alternative, depth: depth + 1); matches += 1 }
                catch { continue }
            }
            guard matches == 1 else { throw MCPToolFailure(L10n.text("参数结构不符合工具 Schema")) }
        }
        switch schema["type"]?.stringValue {
        case "object":
            guard let object = value.objectValue else { throw MCPToolFailure(L10n.text("参数必须是对象")) }
            let properties = schema["properties"]?.objectValue ?? [:]
            if schema["additionalProperties"] == .bool(false),
               !Set(object.keys).isSubset(of: Set(properties.keys)) { throw MCPToolFailure(L10n.text("包含未知工具参数")) }
            for required in schema["required"]?.arrayValue?.compactMap(\.stringValue) ?? []
                where object[required] == nil
            {
                throw MCPToolFailure(L10n.text("缺少参数：\(required)"))
            }
            for (key, value) in object {
                if let schema = properties[key] { try validate(value, schema: schema, depth: depth + 1) }
            }
        case "array":
            guard let array = value.arrayValue else { throw MCPToolFailure(L10n.text("参数必须是数组")) }
            if let minimum = schema["minItems"]?.exactIntValue,
               array.count < minimum { throw MCPToolFailure(L10n.text("数组成员过少")) }
            if let maximum = schema["maxItems"]?.exactIntValue,
               array.count > maximum { throw MCPToolFailure(L10n.text("数组成员过多")) }
            if let items = schema["items"] {
                for value in array { try validate(value, schema: items, depth: depth + 1) }
            }
        case "number", "integer":
            guard let number = value.finiteNumber else { throw MCPToolFailure(L10n.text("参数必须是有限数值")) }
            if schema["type"] == .string("integer"),
               number.rounded() != number { throw MCPToolFailure(L10n.text("参数必须是整数")) }
            if let minimum = schema["minimum"]?.finiteNumber,
               number < minimum { throw MCPToolFailure(L10n.text("数值小于允许范围")) }
            if let maximum = schema["maximum"]?.finiteNumber,
               number > maximum { throw MCPToolFailure(L10n.text("数值超过允许范围")) }
            if let minimum = schema["exclusiveMinimum"]?.finiteNumber,
               number <= minimum { throw MCPToolFailure(L10n.text("数值必须大于最小边界")) }
        case "string":
            guard value.stringValue != nil else { throw MCPToolFailure(L10n.text("参数必须是字符串")) }
        case "null":
            guard value == .null else { throw MCPToolFailure(L10n.text("参数必须为空值")) }
        case "boolean":
            guard value.boolValue != nil else { throw MCPToolFailure(L10n.text("参数必须是布尔值")) }
        case nil: break
        default: throw MCPToolFailure(L10n.text("工具参数 Schema 类型不受支持"))
        }
    }
}
