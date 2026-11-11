import BCRFoundation
import Foundation

public struct MCPStreamSource: Sendable {
    public let notification: String
    public let journal: ProviderEventJournal
    public init(notification: String, journal: ProviderEventJournal) {
        self.notification = notification; self.journal = journal
    }
}
