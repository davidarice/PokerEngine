/// A betting round, with the dealing that comes before it. The synthesized `Codable` form is not part of the
/// stored hand format.
public enum Street: String, Sendable, Hashable, CaseIterable, Codable {
    case preflop, flop, turn, river
}

/// What happened at the table, with the amounts the engine worked out. One event per PokerKit operation record,
/// automated ones included. The synthesized `Codable` form is not part of the stored hand format: `HandState.json()`
/// stores the operations, which rebuild the log.
public enum HandEvent: Sendable, Hashable, Codable {
    case antePosted(player: Int, amount: Int)
    case blindOrStraddlePosted(player: Int, amount: Int)
    /// Bets moved into the pot, by player. `returned` is the uncalled part of a bet, given back to the bettor.
    /// After everyone else folds, the winner's bet is neither collected nor returned here: it comes back through
    /// `chipsPulled` alone, because `chipsPushed` carries pot chips only.
    case betsCollected(collected: [Int], returned: [Int])
    case cardBurned(Card, street: Street, runout: Int)
    case holeCardDealt(player: Int, card: Card)
    case boardCardDealt(Card, street: Street, runout: Int)
    case folded(player: Int)
    case checkedOrCalled(player: Int, amount: Int)
    /// `to` is the player's total bet on the street.
    case betOrRaised(player: Int, to: Int)
    case runoutCountSelected(player: Int, count: Int?)
    /// `cards` is the listed cards padded with `.unknown` for those kept face down, or every hole card for a show of
    /// all.
    case holeCardsShown(player: Int, cards: [Card])
    case holeCardsMucked(player: Int)
    case handKilled(player: Int)
    /// Chips from one pot, by player. `runout` is the board this push compared hands on, or nil when only one player
    /// is left, after folds, mucks or kills. Nil does not mean nobody showed down: a showdown with one winner gets
    /// nil too, because hand killing has already compared the hands and taken out the beaten ones.
    case chipsPushed(pot: Int, runout: Int?, amounts: [Int])
    case chipsPulled(player: Int, amount: Int)
    /// The blinds took their chips back, by player: their blinds, and any ante of theirs.
    case blindsChopped(returned: [Int])
    /// Every stack went back to where it started. `returned` is each player's starting stack minus the stack before
    /// the void, so a player who had already pulled winnings hands them back as a negative amount.
    case handVoided(returned: [Int])
}

/// One row of `HandState.log`. The synthesized `Codable` form is not part of the stored hand format.
public struct LogEntry: Sendable, Hashable, Codable {
    public let event: HandEvent
    /// `true` for a step the engine performed by itself (see `HandConfig.Automation`).
    public let isAutomated: Bool
    /// The index in `HandState.operations` of the dealer operation that produced this event, or nil for the
    /// start-of-hand automation that `HandState.init` runs. Pass it to `replacingOperation(at:with:)` to fix a
    /// misread, unless a listed show repeats the card (see there).
    public let operationIndex: Int?
}
