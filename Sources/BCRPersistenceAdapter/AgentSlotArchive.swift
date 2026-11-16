import BCRConfigurationAdapter
import BCRFoundation
import Foundation
import enum AgentPlugin.AgentRunState

/// Exact old required-key archive, separate from live state-machine authority.
public enum AgentSlotArchive {
    private struct Record: Codable {
        let id: AgentSlotID
        let name: String
        let state: AgentRunState
        let progress: Double
        let statusText: String
        let lastUpdated: Date
        init(_ value: AgentSlotPresentation) {
            id = value.id; name = value.name; state = value.state; progress = value.progress
            statusText = value.statusText; lastUpdated = value.lastUpdated
        }

        var presentation: AgentSlotPresentation {
            .init(
                id: id,
                name: name,
                state: state,
                progress: progress,
                statusText: statusText,
                lastUpdated: lastUpdated
            )
        }
    }

    public static func decode(_ data: Data) throws -> AgentSlotPresentation { try JSONDecoder().decode(
        Record.self,
        from: data
    ).presentation }
    public static func encode(_ value: AgentSlotPresentation) throws -> Data { try JSONEncoder().encode(Record(value)) }
    public static func json(_ values: [AgentSlotPresentation]) throws -> JSONValue {
        try .encoded(values.map(Record.init))
    }
}
