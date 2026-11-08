/// One hand of No-Limit Texas Hold'em or Pot-Limit Omaha, as an immutable value. `apply(_:)` returns the next state.
///
/// This is a port of PokerKit 0.7.7's `State`. PokerKit has no phase variable: whichever pending structure is
/// non-empty is the phase. Each phase has a begin, an update and an end step. An operation's update records its
/// event and then either ends the phase, which begins the next one, or fires the phase's automation. One
/// `apply(_:)` therefore records the dealer's event followed by every automated event it set off, in PokerKit's
/// order. A step deep in that cascade can still refuse the operation (an unknown board card blocks settlement), so
/// `apply(_:)` works on a copy. The internal stored properties keep PokerKit's names.
///
/// `Codable` is the stored hand format (JSON v1, or v2 for Omaha): `json()` writes it at any point in the hand and
/// `init(json:)` reads it back by replaying the operations. A plain decode, which includes a `Decodable` row with a
/// `HandState` field, has none of the checks in DECISIONS.md C10, so a row should hold the document as text for
/// `init(json:)` to read.
/// `phh()` exports the hand as PokerKit's hand-history text.
public struct HandState: Sendable, Equatable {
    /// The largest runout count a player may choose. Every run needs a card of its own, so no hand can use more
    /// than a deck holds (deviation B5).
    public static let maximumRunoutCount = 52

    public let config: HandConfig
    /// The dealer's operations so far: the input to `replay(config:operations:)`.
    public internal(set) var operations: [HandOperation] = []
    /// Every event so far, automated ones included, in order.
    public internal(set) var log: [LogEntry] = []

    public internal(set) var stacks: [Int]
    /// Chips in front of each player. From chips pushing on (`street` is nil) these are winnings, plus a fold-out
    /// winner's uncollected bet, waiting to be pulled.
    public internal(set) var bets: [Int]
    public internal(set) var statuses: [PlayerStatus]
    /// Each player's cards as they stand now. Emptied when the player folds, mucks or is killed. A listed show puts
    /// the shown cards first. On the last run's river, cards kept face down become `.unknown` (forgotten, as in
    /// PokerKit); `results` keeps the scanned cards.
    public internal(set) var holeCards: [[HoleCard]]
    /// Each player's hole cards as dealt, with cards dealt as `.unknown` replaced once revealed. `isFaceUp` is whether
    /// the card has been shown at any point. Unlike `holeCards`, never emptied, reordered or forgotten.
    var dealtHoleCards: [[HoleCard]]

    /// Chips won minus chips put in, per player; negated, the contributions that pots are built from.
    var payoffs: [Int]

    var antePostingStatuses: [Bool]
    var betCollectionStatus = false
    var blindOrStraddlePostingStatuses: [Bool]

    var streetIndex: Int?
    var cardBurningStatus = false
    /// Hole cards still owed per player on this street (all face down in both games).
    var holeDealingCounts: [Int]
    var boardDealingCount = 0
    /// One list per board position; a position re-dealt for another runout holds one card per runout.
    var boardCards: [[Card]] = []
    var burnCards: [Card] = []
    var muckedCards: [Card] = []

    var openerIndex: Int?
    var actorIndices: [Int] = []
    /// The largest raise increment so far on this street. Blinds and straddles never set it.
    var completionBettingOrRaisingAmount = 0
    var actedPlayerIndices: Set<Int> = []
    /// Increments of all-in raises since the last full one, to tell when together they reopen the action.
    var consecutiveShortAllInAmounts: [Int] = []
    /// At most one active player can still bet, so the rest of the board is dealt without betting; or, as PokerKit's
    /// `all_in_status` also counts, the river's betting ended with a stack at 0.
    var allInStatus = false
    var foldedStatus = false

    var runoutCountSelectorStatuses: [Bool]
    /// What the selections so far add up to (PokerKit's `runout_count`): nil while nobody has named a count.
    var selectedRunoutCount: Int?
    /// The choice is offered once per hand.
    var runoutCountSelectionFlag = false
    /// The first street each run repeats, set when the first showdown ends if anyone named a count.
    var streetReturnIndex: Int?
    /// Runs still to start.
    var streetReturnCount = 0
    var showdownIndices: [Int] = []
    var handKillingStatuses: [Bool]
    /// The pots frozen when chips pushing begins (PokerKit's `_pots`); their amounts drop as they are pushed.
    var frozenPots: [Pot]?
    var subPots: [SubPot] = []
    var chipsPullingStatuses: [Bool]
    /// `false` once the hand is over.
    var status = true

    /// Starts the hand and runs every automated step up to the first dealer operation.
    public init(config: HandConfig) {
        let none = Array(repeating: false, count: config.playerCount)
        let zeros = Array(repeating: 0, count: config.playerCount)
        self.config = config
        stacks = config.startingStacks
        bets = zeros
        statuses = Array(repeating: .active, count: config.playerCount)
        holeCards = Array(repeating: [], count: config.playerCount)
        dealtHoleCards = Array(repeating: [], count: config.playerCount)
        payoffs = zeros
        antePostingStatuses = none
        blindOrStraddlePostingStatuses = none
        holeDealingCounts = zeros
        runoutCountSelectorStatuses = none
        handKillingStatuses = none
        chipsPullingStatuses = none
        do {
            try beginAntePosting()
        } catch {
            preconditionFailure("The start of a hand stops at the first hole card, before settlement: \(error)")
        }
        assert(brokenInvariant == nil, brokenInvariant ?? "")
    }

    /// The state after `operation` and every automated step it sets off. Throws, leaving this state as it was,
    /// if the operation is not allowed now.
    public func apply(_ operation: HandOperation) throws(EngineError) -> HandState {
        var next = self
        try next.applyInPlace(operation)
        return next
    }

    /// `apply(_:)` without the copy, for a caller that discards the state when this throws, as replay does. A copy
    /// would share the history arrays with the caller's state, so every append would copy all of them. A throw
    /// may leave the state partly changed.
    mutating func applyInPlace(_ operation: HandOperation) throws(EngineError) {
        try perform(operation)
        assert(brokenInvariant == nil, brokenInvariant ?? "")
    }

    /// Whether `apply(_:)` would accept `operation`.
    public func canApply(_ operation: HandOperation) -> Bool {
        (try? apply(operation)) != nil
    }

    public var playerCount: Int { config.playerCount }

    var players: Range<Int> { 0..<config.playerCount }
    var activeCount: Int { statuses.count { $0 == .active } }
    var maxBet: Int { bets.max() ?? 0 }
    var currentStreet: Street? { streetIndex.map { Street.allCases[$0] } }
    var isLastStreet: Bool { streetIndex == Street.allCases.count - 1 }

    /// Player indices starting at `player` and wrapping around.
    func rotated(from player: Int) -> [Int] {
        Array(player..<config.playerCount) + Array(0..<player)
    }

    /// Appends `event` to the log. The first event of an operation is the dealer's own; the rest are automated.
    mutating func record(_ event: HandEvent) {
        let operationIndex = operations.indices.last
        let isAutomated = operationIndex == nil || log.last?.operationIndex == operationIndex
        log.append(LogEntry(event: event, isAutomated: isAutomated, operationIndex: operationIndex))
    }

    func verifyPlayer(_ player: Int) throws(EngineError) {
        guard players.contains(player) else { throw .invalidPlayer(player) }
    }

    /// Validates `operation` (see `EngineError` for the order of checks), then records it and performs it with its
    /// cascade. The validators below may assume a valid player index.
    private mutating func perform(_ operation: HandOperation) throws(EngineError) {
        // Nothing follows a chop or a void (deviation B12).
        guard !isVoidedOrChopped else { throw .handComplete }
        switch operation {
        // PokerKit still accepts a show after the hand, so these answer for themselves (deviation B9), and a fouled
        // deck found once the hand is over still voids it (B12).
        case .showHoleCards, .muckHoleCards, .voidHand:
            break
        default:
            guard status else { throw .handComplete }
        }
        if let player = operation.player {
            try verifyPlayer(player)
        }
        switch operation {
        case let .postAnte(player):
            try verifyAntePosting(player)
            operations.append(operation)
            try postAnte(player)
        case .collectBets:
            try verifyBetCollection()
            operations.append(operation)
            try collectBets()
        case let .postBlindOrStraddle(player):
            try verifyBlindOrStraddlePosting(player)
            operations.append(operation)
            try postBlindOrStraddle(player)
        case let .burnCard(card):
            try verifyCardBurning(card)
            operations.append(operation)
            try burnCard(card)
        case let .dealHole(player, card):
            try verifyHoleDealing(player, card)
            operations.append(operation)
            try dealHole(player, card)
        case let .dealBoard(card):
            try verifyBoardDealing(card)
            operations.append(operation)
            try dealBoard(card)
        case let .fold(player):
            try verifyFolding(player)
            operations.append(operation)
            try fold(player)
        case let .checkOrCall(player):
            try verifyCheckingOrCalling(player)
            operations.append(operation)
            try checkOrCall(player)
        case let .betOrRaise(player, amount):
            try verifyCompletionBettingOrRaisingTo(player, amount)
            operations.append(operation)
            try completeBetOrRaiseTo(player, amount)
        case let .selectRunoutCount(player, count):
            try verifyRunoutCountSelection(player, count)
            operations.append(operation)
            try selectRunoutCount(player, count)
        case let .showHoleCards(player, cards):
            let show = try verifyHoleCardsShowing(player, cards)
            operations.append(operation)
            try showHoleCards(player, show)
        case let .muckHoleCards(player):
            try verifyHoleCardsMucking(player)
            operations.append(operation)
            try muckHoleCards(player)
        case let .killHand(player):
            try verifyHandKilling(player)
            operations.append(operation)
            try killHand(player)
        case .pushChips:
            try verifyChipsPushing()
            operations.append(operation)
            try pushChips()
        case let .pullChips(player):
            try verifyChipsPulling(player)
            operations.append(operation)
            try pullChips(player)
        case .chopBlinds:
            try verifyChoppingBlinds()
            operations.append(operation)
            returnEveryChip(recording: HandEvent.blindsChopped(returned:))
        case .voidHand:
            operations.append(operation)
            returnEveryChip(recording: HandEvent.handVoided(returned:))
        }
    }

    /// The first internal rule this state breaks, if any. Chips are conserved, frozen pots included. Known cards are
    /// unique across active players' dealt cards, the board, the burns and the muck, and each active player's live
    /// cards come from their dealt cards, slot for slot; other players hold nothing. The actor can bet. At most one
    /// phase is pending, and none exactly when the hand is complete. Checked after every operation in debug builds
    /// only.
    var brokenInvariant: String? {
        let active = players.filter { statuses[$0] == .active }
        let known = (active.flatMap { dealtHoleCards[$0].map(\.card) } + Array(boardCards.joined()) + burnCards + muckedCards)
            .filter { $0 != .unknown }
        let pendingPhases = [
            antePostingStatuses.contains(true),
            betCollectionStatus,
            blindOrStraddlePostingStatuses.contains(true),
            cardBurningStatus || holeDealingCounts.contains { $0 > 0 } || boardDealingCount > 0,
            !actorIndices.isEmpty,
            runoutCountSelectorStatuses.contains(true) || !showdownIndices.isEmpty,
            handKillingStatuses.contains(true),
            !subPots.isEmpty,
            chipsPullingStatuses.contains(true),
        ]
        if stacks.contains(where: { $0 < 0 }) || bets.contains(where: { $0 < 0 }) {
            return "Negative chips"
        } else if stacks.reduce(0, +) + totalPot != config.startingStacks.reduce(0, +) {
            return "Chips not conserved"
        } else if players.contains(where: { stacks[$0] != config.startingStacks[$0] + payoffs[$0] }) {
            return "Stack and payoff disagree"
        } else if Set(known).count != known.count {
            return "Duplicate card"
        } else if active.contains(where: { !liveCardsMatchDealtCards($0) }) {
            return "Live cards disagree with dealt cards"
        } else if players.contains(where: { statuses[$0] != .active && !holeCards[$0].isEmpty }) {
            return "Player out of the hand holds cards"
        } else if actorIndices.contains(where: { statuses[$0] != .active || stacks[$0] == 0 }) {
            return "Actor cannot bet"
        } else if pendingPhases.count(where: { $0 }) > 1 {
            return "More than one phase pending"
        } else if (pendingOperation == nil) != isHandComplete {
            return "Pending operation disagrees with completion"
        }
        return nil
    }

    private func liveCardsMatchDealtCards(_ player: Int) -> Bool {
        let live = holeCards[player].map(\.card).filter { $0 != .unknown }
        let dealt = dealtHoleCards[player].map(\.card)
        return holeCards[player].count == dealt.count
            && Set(live).count == live.count
            && live.allSatisfy(dealt.contains)
    }
}
