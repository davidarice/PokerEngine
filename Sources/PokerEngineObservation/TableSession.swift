import Observation
import PokerEngine

/// One hand at the table, for a SwiftUI view to observe: the current `HandState`, with undo and corrections.
///
/// Undo replays the operations without the last one rather than keeping earlier states, so a session restored with
/// `init(state:)` can undo as far as one that played the whole hand. Only a correction keeps the state it replaced, so
/// that undo can reverse it.
@MainActor
@Observable
public final class TableSession {
    public private(set) var state: HandState
    /// The state before each correction made here, with the operation count just after it, newest last. While the hand
    /// is back at that count, the correction is the last change.
    private var corrections: [(before: HandState, operationCount: Int)] = []

    /// Whether there is a dealer operation or a correction to take back.
    public var canUndo: Bool { !state.operations.isEmpty || !corrections.isEmpty }

    public init(config: HandConfig) {
        state = HandState(config: config)
    }

    /// Picks up a hand already under way, for example one read back with `HandState(json:)` after a crash.
    public init(state: HandState) {
        self.state = state
    }

    /// Applies `operation` and every automated step it sets off. Throws, changing nothing, if it is not allowed now.
    public func apply(_ operation: HandOperation) throws(EngineError) {
        state = try state.apply(operation)
    }

    /// Takes back the last change: a correction made in this session, or else the last dealer operation and every
    /// automated step it set off. Does nothing if there is neither.
    public func undo() {
        if let last = corrections.last, last.operationCount == state.operations.count {
            corrections.removeLast()
            state = last.before
        } else if !state.operations.isEmpty {
            do {
                state = try HandState.replay(config: state.config, operations: Array(state.operations.dropLast()))
            } catch {
                preconditionFailure("Operations already applied must replay: \(error)")
            }
        }
    }

    /// Corrects one operation, for a misread card or a mis-entered action. Throws, changing nothing, if the hand no
    /// longer fits; see `HandState.replacingOperation(at:with:)`.
    public func replaceOperation(at index: Int, with operation: HandOperation) throws(ReplayError) {
        correct(to: try state.replacingOperation(at: index, with: operation))
    }

    /// Replaces the whole hand's operations, for a correction that touches several. Throws, changing nothing, if
    /// they do not replay.
    public func replaceOperations(with operations: [HandOperation]) throws(ReplayError) {
        correct(to: try HandState.replay(config: state.config, operations: operations))
    }

    /// Corrects the hand's config, for a stack or forced bet entered wrong, and replays `operations` on it: by
    /// default the hand's own. A bet's `to:` stays the number entered, so a player who went all in at the old stack
    /// needs a corrected list too. Operations name players by index, so keep the player count. Throws, changing
    /// nothing, if they do not replay.
    public func replaceConfig(with config: HandConfig, operations: [HandOperation]? = nil) throws(ReplayError) {
        correct(to: try HandState.replay(config: config, operations: operations ?? state.operations))
    }

    private func correct(to corrected: HandState) {
        corrections.append((state, corrected.operations.count))
        state = corrected
    }
}
