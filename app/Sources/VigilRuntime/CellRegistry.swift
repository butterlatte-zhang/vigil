import Foundation
import VigilCore

/// nodeID → live cell, plus its terminal backend (so the app can show the focused
/// cell's view). Pure bookkeeping; the orchestrator drives lifecycle. (DOCTRINE §4 L3.)
@MainActor
public final class CellRegistry {
    private var cells: [NodeID: CellHandle] = [:]
    private var backends: [NodeID: TerminalBackend] = [:]

    public init() {}

    public func add(_ cell: CellHandle, backend: TerminalBackend) {
        cells[cell.nodeID] = cell; backends[cell.nodeID] = backend
    }
    public func cell(_ id: NodeID) -> CellHandle? { cells[id] }
    public func backend(_ id: NodeID) -> TerminalBackend? { backends[id] }
    public var nodeIDs: [NodeID] { Array(cells.keys) }

    @discardableResult
    public func remove(_ id: NodeID) -> CellHandle? {
        backends[id] = nil
        let c = cells[id]; cells[id] = nil; return c
    }
}
