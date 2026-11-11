import Foundation

public enum ProviderContractSchema {
    public static let version = "1.0"
    public static var data: Data {
        guard let url = ProviderResources.bundle.url(forResource: "provider.schema", withExtension: "json"),
              let data = try? Data(contentsOf: url)
        else {
            preconditionFailure("The published provider schema resource is missing")
        }
        return data
    }

    public static var document: JSONValue { try! JSONDecoder().decode(JSONValue.self, from: data) }
    public static func definition(_ name: String) -> JSONValue {
        guard let result = document.objectValue?["$defs"]?.objectValue?[name]
        else { preconditionFailure("Unknown built-in provider schema") }
        return result
    }
}
