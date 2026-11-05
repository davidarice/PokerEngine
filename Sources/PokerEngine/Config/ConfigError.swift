/// Why `HandConfig.init` rejected its arguments. The synthesized `Codable` form is not part of the stored hand
/// format.
public enum ConfigError: Error, Sendable, Hashable, Codable {
    /// The player count must be 2…10.
    case playerCountOutOfRange(Int)
    case nonPositiveStartingStack(player: Int)
    case negativeAnte(position: Int)
    /// More antes than players. PokerKit silently drops the extra entries.
    case tooManyAntes(Int)
    /// More blinds or straddles than players. PokerKit silently drops the extra entries.
    case tooManyBlindsOrStraddles(Int)
    /// Every ante and blind is 0.
    case noForcedBets
    case nonPositiveMinBet(Int)
    /// The starting stacks add up to more than `HandConfig.maximumChips`, or a forced bet or the minimum bet is
    /// larger than that. PokerKit's Python integers have no limit.
    case amountsTooLarge
    /// `anteTrimming` is for uniform antes only; it would refund a big-blind or button ante.
    case anteTrimmingRequiresUniformAntes
}
