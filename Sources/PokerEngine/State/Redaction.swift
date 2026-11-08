// Redaction: the hand as it may be given to someone who must not learn the cards the table never saw.

/// Why `HandState.redactingHiddenCards(keeping:)` gave no hand.
public enum RedactionError: Error, Sendable, Hashable {
    /// The redacted operations do not replay. The engine takes an unknown card wherever it takes a known one, so
    /// this would be an engine bug.
    case replayFailed(ReplayError)
    /// The redacted hand does not stand where the full one does: other chips, statuses, boards, shown cards or next
    /// operation.
    case outcomeChanged
}

extension HandState {
    /// The hand with every card the table never saw turned into `.unknown`: each hole card never shown, except the
    /// cards of the players in `keeping`, and every burned card. Board cards and shown cards stay. The hand is
    /// rebuilt by replaying the redacted operations, so its log, results and stored document name no hidden card
    /// either.
    ///
    /// Only shown cards decide the chips: pots are awarded on shown cards, and the last river forgets the cards kept
    /// face down before any hand is killed. A redacted hand therefore stands where the full one does. That is
    /// checked rather than assumed, and a hand that differs is never returned.
    public func redactingHiddenCards(keeping players: Set<Int> = []) throws(RedactionError) -> HandState {
        let shown = Set(dealtHoleCards.joined().filter(\.isFaceUp).map(\.card))
        let redactedOperations = operations.map { operation -> HandOperation in
            switch operation {
            case let .dealHole(player, card) where !players.contains(player) && !shown.contains(card):
                .dealHole(player: player, card: .unknown)
            case .burnCard:
                .burnCard(.unknown)
            default:
                operation
            }
        }
        let redacted: HandState
        do {
            redacted = try Self.replay(config: config, operations: redactedOperations)
        } catch {
            throw .replayFailed(error)
        }
        guard redacted.publicOutcome == publicOutcome else { throw .outcomeChanged }
        return redacted
    }

    private var publicOutcome: PublicOutcome {
        PublicOutcome(
            stacks: stacks, bets: bets, statuses: statuses, boards: boards,
            shownCards: dealtHoleCards.map { $0.filter(\.isFaceUp).map(\.card) },
            street: street, actor: actor, pendingOperation: pendingOperation,
            results: results?.map { PublicOutcome.Result(net: $0.net, won: $0.won, status: $0.status, shown: $0.shown) }
        )
    }
}

/// What everyone at the table saw of a hand, which a redacted copy must keep.
private struct PublicOutcome: Equatable {
    /// A player's result without the hole cards, which redaction hides.
    struct Result: Equatable {
        let net: Int
        let won: Int
        let status: PlayerStatus
        let shown: Bool
    }

    let stacks: [Int]
    let bets: [Int]
    let statuses: [PlayerStatus]
    let boards: [[Card]]
    let shownCards: [[Card]]
    let street: Street?
    let actor: Int?
    let pendingOperation: PendingOperation?
    let results: [Result]?
}
