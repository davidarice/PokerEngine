// Values that `HandState` reports.

/// Its `Codable` form is part of the stored hand format, in `results`.
public enum PlayerStatus: String, Sendable, Hashable, Codable {
    /// Still in the hand.
    case active
    case folded
    /// Gave up the hand at the showdown.
    case mucked
    /// Ruled unable to win any pot during settlement.
    case killed
}

/// Its `Codable` form is part of the stored hand format, in `results`.
public struct HoleCard: Sendable, Hashable, Codable {
    public let card: Card
    public let isFaceUp: Bool
}

/// A main or side pot of collected chips. Once chips pushing begins, `HandState.pots` is frozen: amounts drop as
/// chips are pushed and a fully pushed pot stays listed with amount 0, so pot indices stay stable. The synthesized
/// `Codable` form is not part of the stored hand format.
public struct Pot: Sendable, Hashable, Codable {
    public let amount: Int
    /// Active players who have put in enough to win this pot, in player-index order.
    public let eligiblePlayers: [Int]
}

/// One player's outcome, once the hand is complete. A post-hand show after completion can change `holeCards` and
/// `shown`, so `HandState.results` is not fixed at completion. Its `Codable` form is part of the stored hand format,
/// as `results`.
public struct PlayerResult: Sendable, Hashable, Codable {
    public let player: Int
    /// Final stack minus starting stack.
    public let net: Int
    /// Chips pushed to this player from pots (PHH `winnings`). A bet returned to the player is not counted.
    public let won: Int
    public let status: PlayerStatus
    /// As dealt, with cards dealt as `.unknown` filled in where the player revealed them. `isFaceUp` is whether
    /// the card was shown at any point, even if a later re-ask turned it back down: a hand shown and then killed
    /// has no live cards at the end, so "at the end" could not work.
    public let holeCards: [HoleCard]
    /// Every hole card was shown at some point.
    public let shown: Bool
}
