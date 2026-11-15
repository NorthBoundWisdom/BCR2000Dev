import Foundation

public enum ProviderContractSchema {
    public static let version = "1.0"
    // The bundled Provider 1.0 contract is immutable for this process. Decode once,
    // rather than reading and parsing the complete document for each tool definition.
    public static let data: Data = {
        guard let url = ProviderResources.bundle.url(forResource: "provider.schema", withExtension: "json"),
              let data = try? Data(contentsOf: url)
        else {
            preconditionFailure("The published provider schema resource is missing")
        }
        return data
    }()

    public static let document: JSONValue = try! JSONDecoder().decode(JSONValue.self, from: data)
    public static func definition(_ name: String) -> JSONValue {
        guard let result = document.objectValue?["$defs"]?.objectValue?[name]
        else { preconditionFailure("Unknown built-in provider schema") }
        return result
    }
}
