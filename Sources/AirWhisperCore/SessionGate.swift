import Foundation

/// An invalidated run must never publish an old transcript into a newer session.
public struct SessionGate: Sendable {
    public private(set) var current: UUID?
    public init() {}

    @discardableResult public mutating func begin() -> UUID? {
        guard current == nil else { return nil }
        let id = UUID()
        current = id
        return id
    }

    public func contains(_ id: UUID) -> Bool { current == id }

    @discardableResult public mutating func finish(_ id: UUID) -> Bool {
        guard contains(id) else { return false }
        current = nil
        return true
    }

    public mutating func invalidate() { current = nil }
}
