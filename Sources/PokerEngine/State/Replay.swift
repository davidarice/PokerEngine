extension HandState {
    /// The state after applying `operations` in order to a new hand. Throws at the first operation that is not
    /// allowed, naming it.
    public static func replay(config: HandConfig, operations: [HandOperation]) throws(ReplayError) -> HandState {
        var state = HandState(config: config)
        for (index, operation) in operations.enumerated() {
            do {
                try state.applyInPlace(operation)
            } catch {
                throw ReplayError(operationIndex: index, operation: operation, error: error)
            }
        }
        return state
    }

    /// The hand replayed with one operation changed, for correcting a misread card or a mis-entered action.
    /// `index` must be an index of `operations`.
    ///
    /// Shown cards must match the dealt cards, so a misread that a listed show repeats sits in several operations.
    /// Changing only one fails with `.shownCardNotDealt`, or, if the player still has an unrevealed `.unknown` card,
    /// is accepted with the misread card left in the hand. Change all of them in a copy of `operations` and pass
    /// that to `replay(config:operations:)`.
    public func replacingOperation(at index: Int, with operation: HandOperation) throws(ReplayError) -> HandState {
        precondition(operations.indices.contains(index), "Invalid operation index \(index)")
        var operations = operations
        operations[index] = operation
        return try Self.replay(config: config, operations: operations)
    }
}
