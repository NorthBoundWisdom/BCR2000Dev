import BCRFoundation
import Foundation

/// Bounded value-only history. Keys identify one input source/control, never a definition edit.
/// The caller injects time and commits only the outermost synchronous value transaction.
public struct ParameterValueHistory: Sendable {
    public struct Entry: Equatable, Sendable {
        public var before: [ParameterID: Double]
        public var after: [ParameterID: Double]
    }

    public static let limit = 50
    public static let coalescingWindow: TimeInterval = 0.4
    private var undoEntries: [Entry] = []
    private var redoEntries: [Entry] = []
    private var coalescingKey: String?
    private var lastTime: TimeInterval?
    public var canUndo: Bool { !undoEntries.isEmpty }
    public var canRedo: Bool { !redoEntries.isEmpty }
    public var undoEntry: Entry? { undoEntries.last }
    public var redoEntry: Entry? { redoEntries.last }
    public init() {}

    public mutating func endGroup() { coalescingKey = nil; lastTime = nil }
    public mutating func clear() { self = Self() }

    public mutating func record(before: [ParameterID: Double], after: [ParameterID: Double],
                                key: String?, at time: TimeInterval)
    {
        let changed = before.keys.filter { after[$0] != nil && before[$0] != after[$0] }
        guard !changed.isEmpty else { return }
        let entry = Entry(before: before.filter { changed.contains($0.key) },
                          after: after.filter { changed.contains($0.key) })
        let merge = key != nil && key == coalescingKey && time.isFinite && lastTime.map {
            time >= $0 && time - $0 <= Self.coalescingWindow
        } == true && !undoEntries.isEmpty && redoEntries.isEmpty
        redoEntries.removeAll()
        if merge {
            let index = undoEntries.count - 1
            for (id, value) in entry.before where undoEntries[index].before[id] == nil {
                undoEntries[index].before[id] = value
            }
            undoEntries[index].after.merge(entry.after) { _, latest in latest }
        } else {
            undoEntries.append(entry)
            if undoEntries.count > Self.limit { undoEntries.removeFirst(undoEntries.count - Self.limit) }
        }
        coalescingKey = key
        lastTime = time.isFinite ? time : nil
    }

    /// Called only after the host validates and applies the normal writes successfully.
    public mutating func didUndo(actualBefore: [ParameterID: Double], actualAfter: [ParameterID: Double]) {
        guard let entry = undoEntries.popLast() else { return }
        redoEntries.append(Entry(before: actualAfter.filter { entry.before[$0.key] != nil },
                                 after: actualBefore.filter { entry.before[$0.key] != nil }))
        endGroup()
    }

    public mutating func didRedo(actualBefore: [ParameterID: Double], actualAfter: [ParameterID: Double]) {
        guard let entry = redoEntries.popLast() else { return }
        undoEntries.append(Entry(before: actualBefore.filter { entry.after[$0.key] != nil },
                                 after: actualAfter.filter { entry.after[$0.key] != nil }))
        endGroup()
    }
}

public struct ParameterHistoryError: LocalizedMessageError, Sendable {
    public let parameter: ParameterID
    public var localizedMessage: LocalizedMessage { "参数当前受保护，无法撤销或重做：\(parameter)" }
    public init(parameter: ParameterID) { self.parameter = parameter }
}
