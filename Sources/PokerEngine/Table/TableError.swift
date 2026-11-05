/// Why `TableState` refused a change. The synthesized `Codable` form is not part of the stored hand format.
public enum TableError: Error, Sendable, Hashable, Codable {
    /// Seats, stacks and the button change only between hands, and a hand is dealt only once the last one is finished.
    case handInPlay
    /// Seats are numbered from 0 to `TableState.seatCount - 1`.
    case noSuchSeat(Int)
    case seatTaken(Int)
    case seatEmpty(Int)
    /// A stack is from 0 to `HandConfig.maximumChips`, the most a hand may hold, and a player sits down with chips.
    case invalidStack(Int)
    /// A hand needs two players with chips; this many have them.
    case notEnoughPlayers(Int)
    /// A blind is never below 0. Below 0 a `HandConfig` reads it as a live post, which the table does not deal.
    case negativeBlind(Int)
    /// The stakes make no valid hand; the reason is the config's.
    case handConfigRefused(ConfigError)
    /// No hand has been dealt yet.
    case noHandDealt
    /// The hand given is not the last one dealt, or has another number of players. Once the next hand is dealt, the
    /// last one's result stands.
    case notThisHand
    case handNotComplete
    /// A player of the finished hand stood up or changed seats before its correction, which goes by seat, so the
    /// seat's chips may no longer be theirs.
    case seatChanged(Int)
    /// The correction takes more chips from this seat than it now has.
    case stackBelowZero(seat: Int)
}
