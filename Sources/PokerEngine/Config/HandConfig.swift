/// The rules for one hand: the game, its mode, starting stacks, forced bets, and which bookkeeping steps the engine
/// performs by itself.
///
/// Player indices follow PokerKit. Player 0 is the first seat left of the button and the last player is the
/// button; `playerOrder(occupiedSeats:buttonSeat:)` maps physical seats to indices. Heads-up, player 0 is the big
/// blind and player 1 is the button, which posts the small blind. `antes` and `blindsOrStraddles` are written by
/// position, small blind first, and heads-up they are read in reverse, as PokerKit reads them.
///
/// `Codable` is part of the stored hand format. Decoding runs the same validation as `init`. `variant` is written only
/// for a game other than Texas Hold'em, and read as Texas Hold'em when it is missing.
public struct HandConfig: Sendable, Hashable {
    /// The game, as PokerKit names it.
    public enum Variant: String, Sendable, Hashable, CaseIterable, Codable {
        /// Two hole cards, and any bet up to the whole stack.
        case noLimitTexasHoldem
        /// Four hole cards, of which a hand uses exactly two, with exactly three from the board, and no bet or raise
        /// above the pot.
        case potLimitOmahaHoldem
    }

    public enum Mode: String, Sendable, Hashable, Codable {
        /// Free folds are allowed, all-in players may run it more than once, and hands may be partly shown.
        case cashGame
        /// Folding when checking is free is an error, the board runs once, and shown hands are shown in full.
        case tournament
    }

    /// Bookkeeping steps the engine can perform by itself. Dealing, betting and showing are never automated.
    public enum Automation: String, Sendable, Hashable, CaseIterable, Codable {
        case antePosting, betCollection, blindOrStraddlePosting
        /// Every runout selector abstains, so the board runs once. Off in `.bookkeeping`; turn it on for a game
        /// that never runs it twice.
        case runoutCountSelection
        case handKilling, chipsPushing, chipsPulling
    }

    public let variant: Variant
    public let mode: Mode
    /// Chips each player starts with, by player index. The count is the player count (2…10).
    public let startingStacks: [Int]
    /// Antes by position, padded with 0 to the player count. `[0, 2]` is a 2-chip big-blind ante.
    public let antes: [Int]
    /// PokerKit's `ante_trimming_status`: `true` for uniform antes, `false` for big-blind or button antes, which
    /// go into the pot as dead money.
    public let anteTrimming: Bool
    /// Blinds and straddles by position, padded with 0 to the player count: `[1, 2]` blinds, `[1, 2, 4]` an UTG
    /// straddle, `[1, 2, 0, 0, 0, 4]` a button straddle. A negative value is a live post of that size by a player
    /// who just sat down.
    public let blindsOrStraddles: [Int]
    /// The minimum bet, and the smallest raise increment on every street.
    public let minBet: Int
    public let automations: Set<Automation>

    public var playerCount: Int { startingStacks.count }

    /// The most chips a hand may involve: all starting stacks together, and any one forced bet or the minimum
    /// bet. Far beyond any real game; it keeps every sum the engine computes within `Int`.
    public static let maximumChips = 1 << 50

    public init(
        variant: Variant = .noLimitTexasHoldem,
        mode: Mode,
        startingStacks: [Int],
        antes: [Int] = [],
        anteTrimming: Bool = false,
        blindsOrStraddles: [Int],
        minBet: Int,
        automations: Set<Automation> = .bookkeeping
    ) throws(ConfigError) {
        let playerCount = startingStacks.count
        guard (2...10).contains(playerCount) else { throw .playerCountOutOfRange(playerCount) }
        guard antes.count <= playerCount else { throw .tooManyAntes(antes.count) }
        guard blindsOrStraddles.count <= playerCount else { throw .tooManyBlindsOrStraddles(blindsOrStraddles.count) }
        if let player = startingStacks.firstIndex(where: { $0 <= 0 }) { throw .nonPositiveStartingStack(player: player) }
        if let position = antes.firstIndex(where: { $0 < 0 }) { throw .negativeAnte(position: position) }
        // Each stack is checked before summing, so the sum itself cannot overflow.
        let limit = Self.maximumChips
        guard startingStacks.allSatisfy({ $0 <= limit }), startingStacks.reduce(0, +) <= limit,
              antes.allSatisfy({ $0 <= limit }), blindsOrStraddles.allSatisfy({ (-limit...limit).contains($0) }),
              minBet <= limit
        else { throw .amountsTooLarge }

        let paddedAntes = antes + Array(repeating: 0, count: playerCount - antes.count)
        let paddedBlinds = blindsOrStraddles + Array(repeating: 0, count: playerCount - blindsOrStraddles.count)
        guard paddedAntes.contains(where: { $0 != 0 }) || paddedBlinds.contains(where: { $0 != 0 }) else {
            throw .noForcedBets
        }
        guard minBet > 0 else { throw .nonPositiveMinBet(minBet) }
        // Trimming cuts the largest ante down to the second largest, which would refund a big-blind ante in full.
        guard !anteTrimming || Set(paddedAntes).count == 1 else { throw .anteTrimmingRequiresUniformAntes }

        self.variant = variant
        self.mode = mode
        self.startingStacks = startingStacks
        self.antes = paddedAntes
        self.anteTrimming = anteTrimming
        self.blindsOrStraddles = paddedBlinds
        self.minBet = minBet
        self.automations = automations
    }

    /// The same config with another game, which needs no validation of its own.
    init(_ config: HandConfig, variant: Variant) {
        self.variant = variant
        mode = config.mode
        startingStacks = config.startingStacks
        antes = config.antes
        anteTrimming = config.anteTrimming
        blindsOrStraddles = config.blindsOrStraddles
        minBet = config.minBet
        automations = config.automations
    }

    /// Physical seats in player-index order: `order[i]` is the seat of player `i`. Seats are numbered clockwise;
    /// player 0 is the first occupied seat after `buttonSeat`. The button seat may be empty (a dead button), in
    /// which case the occupied seat before it acts last. `occupiedSeats` must not repeat a seat.
    public static func playerOrder(occupiedSeats: [Int], buttonSeat: Int) -> [Int] {
        precondition(Set(occupiedSeats).count == occupiedSeats.count, "Occupied seats must be distinct")
        let seats = occupiedSeats.sorted()
        return seats.filter { $0 > buttonSeat } + seats.filter { $0 <= buttonSeat }
    }
}

extension Set<HandConfig.Automation> {
    /// Every automation except `.runoutCountSelection`, so all-in players still choose how many times to run it.
    public static var bookkeeping: Self {
        [.antePosting, .betCollection, .blindOrStraddlePosting, .handKilling, .chipsPushing, .chipsPulling]
    }
}

extension HandConfig: Codable {
    private enum CodingKeys: String, CodingKey {
        case variant, mode, startingStacks, antes, anteTrimming, blindsOrStraddles, minBet, automations
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let automations = try container.decode([Automation].self, forKey: .automations)
        guard Set(automations).count == automations.count else {
            throw DecodingError.dataCorruptedError(
                forKey: .automations, in: container, debugDescription: "Duplicate automations: \(automations)"
            )
        }
        do {
            try self.init(
                variant: container.decodeIfPresent(Variant.self, forKey: .variant) ?? .noLimitTexasHoldem,
                mode: container.decode(Mode.self, forKey: .mode),
                startingStacks: container.decode([Int].self, forKey: .startingStacks),
                antes: container.decode([Int].self, forKey: .antes),
                anteTrimming: container.decode(Bool.self, forKey: .anteTrimming),
                blindsOrStraddles: container.decode([Int].self, forKey: .blindsOrStraddles),
                minBet: container.decode(Int.self, forKey: .minBet),
                automations: Set(automations)
            )
        } catch let error as ConfigError {
            throw DecodingError.dataCorrupted(DecodingError.Context(
                codingPath: decoder.codingPath, debugDescription: "Invalid hand config: \(error)", underlyingError: error
            ))
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        // Texas Hold'em documents stay as every earlier version of the engine wrote them.
        if variant != .noLimitTexasHoldem {
            try container.encode(variant, forKey: .variant)
        }
        try container.encode(mode, forKey: .mode)
        try container.encode(startingStacks, forKey: .startingStacks)
        try container.encode(antes, forKey: .antes)
        try container.encode(anteTrimming, forKey: .anteTrimming)
        try container.encode(blindsOrStraddles, forKey: .blindsOrStraddles)
        try container.encode(minBet, forKey: .minBet)
        try container.encode(Automation.allCases.filter(automations.contains), forKey: .automations)
    }
}
