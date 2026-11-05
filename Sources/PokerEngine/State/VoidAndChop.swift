// Two ways to end a hand that PokerKit does not have (deviation B12): the blinds chopping, and a void for a misdeal
// or a fouled deck. Either gives every stack back its starting chips, and nothing is accepted after it.

extension HandState {
    /// Whether a chop or a void ended the hand. Nothing can follow either, so the last event says.
    var isVoidedOrChopped: Bool {
        switch log.last?.event {
        case .blindsChopped, .handVoided: true
        default: false
        }
    }

    /// Robert's Rules of Poker allows a chop in a non-tournament button game once everyone else has folded: the
    /// blinds take their blinds back. Nobody else may have put in a chip, and neither blind more than the blind, so
    /// each blind gets back exactly what they put in, an ante of their own included.
    func verifyChoppingBlinds() throws(EngineError) {
        // Positions 0 and 1 post the blinds; heads-up the button, player 1, posts the small blind.
        let blinds = config.playerCount == 2 ? [1, 0] : [0, 1]
        guard config.mode == .cashGame, currentStreet == .preflop, actor != nil,
              players.allSatisfy({ (statuses[$0] == .active) == blinds.contains($0) }),
              players.allSatisfy({ blinds.contains($0) || payoffs[$0] == 0 }),
              blinds.allSatisfy({ bets[$0] > 0 && bets[$0] == effectiveBlindOrStraddle($0) })
        else { throw .cannotChopBlinds }
    }

    /// Gives every player back their starting stack, ends the hand and records `event` with what each got back.
    /// The cards stay as dealt, for the record.
    mutating func returnEveryChip(recording event: ([Int]) -> HandEvent) {
        let none = Array(repeating: false, count: config.playerCount)
        let zeros = Array(repeating: 0, count: config.playerCount)
        let returned = players.map { config.startingStacks[$0] - stacks[$0] }
        stacks = config.startingStacks
        bets = zeros
        payoffs = zeros
        antePostingStatuses = none
        betCollectionStatus = false
        blindOrStraddlePostingStatuses = none
        cardBurningStatus = false
        holeDealingCounts = zeros
        boardDealingCount = 0
        actorIndices = []
        runoutCountSelectorStatuses = none
        showdownIndices = []
        handKillingStatuses = none
        frozenPots = nil
        subPots = []
        chipsPullingStatuses = none
        streetIndex = nil
        status = false
        record(event(returned))
    }
}
