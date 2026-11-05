/// A forced bet still owed, with the amount the player will actually post (less than the full amount when the
/// stack is short). The synthesized `Codable` form is not part of the stored hand format.
public struct ForcedBet: Sendable, Hashable, Codable {
    public let player: Int
    public let amount: Int
}

/// What the hand is waiting for. `HandState.pendingOperation` is nil exactly when the hand is complete.
/// The synthesized `Codable` form is not part of the stored hand format.
public enum PendingOperation: Sendable, Hashable, Codable {
    /// Antes still owed. They may be posted in any order.
    case postAnte([ForcedBet])
    case collectBets
    /// Blinds and straddles still owed. They may be posted in any order.
    case postBlindOrStraddle([ForcedBet])
    case burnCard(street: Street, runout: Int)
    /// The suggested next hole card: one card to each player in turn, starting from player 0. Any player still
    /// owed a card may be dealt instead.
    case dealHoleCard(player: Int, cardIndex: Int)
    /// For example, the second flop card is `(.flop, runout: 0, cardIndex: 1, cardCount: 3)`.
    case dealBoardCard(street: Street, runout: Int, cardIndex: Int, cardCount: Int)
    /// See `HandState.legalActions`.
    case act(player: Int)
    /// Players who still choose a runout count, and the order in which players still show or muck. Both may be
    /// entered in any order, interleaved.
    case showdown(runoutSelectors: [Int], showOrder: [Int])
    case killHand(players: [Int])
    case pushChips(pot: Int, runout: Int?)
    case pullChips(players: [Int])
}
