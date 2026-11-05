/// What the player to act may do. The synthesized `Codable` form is not part of the stored hand format.
public struct LegalActions: Sendable, Hashable, Codable {
    public let player: Int
    /// `false` in a tournament when checking is free, or if the fold would abandon a pot (DECISIONS.md B2).
    public let canFold: Bool
    /// 0 means the player may check. Less than the bet faced means calling puts the player all in.
    public let toCall: Int
    public let betOrRaise: BetOrRaise
}

/// The street totals a player may bet or raise to, both ends included. The synthesized `Codable` form is not
/// part of the stored hand format.
public enum BetOrRaise: Sendable, Hashable, Codable {
    /// Nobody has bet on this street yet. Antes do not count; blinds and straddles do.
    case bet(ClosedRange<Int>)
    case raise(ClosedRange<Int>)
    case unavailable(RaiseUnavailableReason)
}

/// Why the player may not bet or raise. When several apply, the first listed here is given. The synthesized
/// `Codable` form is not part of the stored hand format.
public enum RaiseUnavailableReason: String, Sendable, Hashable, Codable {
    /// The player cannot put in more than calling costs.
    case playerIsCovered
    /// The player already acted, and the all-ins since then do not reopen the action: one that is not a full
    /// raise does not, and several reopen it only as PokerKit's rule in DECISIONS.md A3 says.
    case actionNotReopened
    /// No other player could call a raise: each has folded, is all in, or can at most call the current bet.
    case noOpponentCanRespond
}
