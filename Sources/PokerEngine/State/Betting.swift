// Betting rounds: the actor queue, folding, checking or calling, and betting or raising (no-limit).

extension HandState {
    mutating func beginBetting() throws(EngineError) {
        // The opener sits left of the largest blind or straddle posted (a tie goes to the later seat); a live post
        // never counts. After the flop every bet is 0, so the opener is player 0.
        let blinds = config.playerCount == 2 ? Array(config.blindsOrStraddles.reversed()) : config.blindsOrStraddles
        let largest = players.max { (bets[$0] * blinds[$0].signum(), $0) < (bets[$1] * blinds[$1].signum(), $1) }!
        openerIndex = (largest + 1) % config.playerCount
        actorIndices = rotated(from: openerIndex!).filter {
            statuses[$0] == .active && stacks[$0] > 0 && effectiveStack($0) > 0
        }
        completionBettingOrRaisingAmount = 0
        actedPlayerIndices = []
        consecutiveShortAllInAmounts = []
        // PokerKit also ends the round here for a lone actor who already matches the largest bet. The filter above
        // rules that out: such an actor has chips at stake only if another player does too.
        try updateBetting()
    }

    mutating func updateBetting() throws(EngineError) {
        if actorIndices.isEmpty || activeCount <= 1 {
            try endBetting()
        }
    }

    mutating func endBetting() throws(EngineError) {
        actorIndices = []
        if activeCount > 1, players.count(where: { statuses[$0] == .active && stacks[$0] > 0 }) <= 1 {
            allInStatus = true
        }
        // Only deviation B13 reads this case: on the river it changes nothing else.
        if isLastStreet && stacks.contains(0) {
            allInStatus = true
        }
        try beginBetCollection()
    }

    /// What an active player can still lose: no more than the second-largest stack among active players allows.
    func effectiveStack(_ player: Int) -> Int {
        let totals = players.filter { statuses[$0] == .active }.map { bets[$0] + stacks[$0] }.sorted()
        // Deviation B3: PokerKit asserts that a second active player exists.
        guard totals.count > 1 else { return 0 }
        return min(stacks[player], max(0, totals[totals.count - 2] - bets[player]))
    }

    private mutating func popActor() {
        actedPlayerIndices.insert(actorIndices.removeFirst())
    }

    /// The checks every betting action shares: someone is to act, and it is this player's turn.
    private func verifyActor(_ player: Int) throws(EngineError) {
        guard let actor else { throw .noActionExpected }
        guard player == actor else { throw .notYourTurn(player: player, actor: actor) }
    }

    // MARK: Folding

    func verifyFolding(_ player: Int) throws(EngineError) {
        try verifyActor(player)
        // A free fold only warns in PokerKit's cash games.
        if bets[player] >= maxBet && config.mode == .tournament {
            throw .cannotFoldWhenCheckIsFree(player: player)
        }
        if let pot = potAbandoned(byRemoving: player) {
            throw .wouldAbandonPot(player: player, pot: pot)
        }
    }

    mutating func fold(_ player: Int) throws(EngineError) {
        popActor()
        muckHand(player, as: .folded)
        record(.folded(player: player))
        try updateBetting()
    }

    // MARK: Checking or calling

    /// What checking or calling costs the actor, capped at the actor's stack.
    var checkingOrCallingAmount: Int? {
        actor.map { min(stacks[$0], maxBet - bets[$0]) }
    }

    func verifyCheckingOrCalling(_ player: Int) throws(EngineError) {
        try verifyActor(player)
    }

    mutating func checkOrCall(_ player: Int) throws(EngineError) {
        let amount = checkingOrCallingAmount!
        popActor()
        bets[player] += amount
        stacks[player] -= amount
        payoffs[player] -= amount
        record(.checkedOrCalled(player: player, amount: amount))
        try updateBetting()
    }

    // MARK: Betting or raising

    /// Nil when the actor may bet or raise. PokerKit refuses for any of four reasons, in its own order; the
    /// result names the first that applies by meaning: covered, then not reopened, then nobody to respond.
    func raiseUnavailableReason(for actor: Int) -> RaiseUnavailableReason? {
        let toCall = maxBet - bets[actor]
        let facesShortAllIn = min(stacks[actor], toCall) < completionBettingOrRaisingAmount
        let shortAllIns = consecutiveShortAllInAmounts.reduce(0, +)
        let alreadyActed = !consecutiveShortAllInAmounts.isEmpty
            && shortAllIns < completionBettingOrRaisingAmount
            && actedPlayerIndices.contains(actor)
        let opponentCanRespond = players.contains {
            $0 != actor && statuses[$0] == .active && stacks[$0] + bets[$0] > maxBet
        }
        if stacks[actor] <= toCall {
            return .playerIsCovered
        } else if facesShortAllIn || alreadyActed {
            return .actionNotReopened
        } else if !opponentCanRespond {
            return .noOpponentCanRespond
        }
        return nil
    }

    func minCompletionBettingOrRaisingToAmount(_ actor: Int) -> Int {
        min(stacks[actor] + bets[actor], max(completionBettingOrRaisingAmount, config.minBet) + maxBet)
    }

    /// No-limit: everything the actor has. Any excess over what opponents can match is returned at collection.
    /// Pot-limit: a call, then a raise the size of the pot after it, but never less than the minimum: PokerKit's
    /// `pot_completion_betting_or_raising_to_amount`.
    func maxCompletionBettingOrRaisingToAmount(_ actor: Int) -> Int {
        let allIn = stacks[actor] + bets[actor]
        switch config.variant {
        case .noLimitTexasHoldem:
            return allIn
        case .potLimitOmahaHoldem:
            let potSized = 2 * maxBet - bets[actor] + totalPot
            return min(allIn, max(minCompletionBettingOrRaisingToAmount(actor), potSized))
        }
    }

    func verifyCompletionBettingOrRaisingTo(_ player: Int, _ amount: Int) throws(EngineError) {
        try verifyActor(player)
        if let reason = raiseUnavailableReason(for: player) {
            throw .raiseNotAllowed(player: player, reason: reason)
        }
        let minimum = minCompletionBettingOrRaisingToAmount(player)
        let maximum = maxCompletionBettingOrRaisingToAmount(player)
        guard amount >= minimum else { throw .betBelowMinimum(amount: amount, minimum: minimum) }
        guard amount <= maximum else { throw .betAboveMaximum(amount: amount, maximum: maximum) }
    }

    mutating func completeBetOrRaiseTo(_ player: Int, _ amount: Int) throws(EngineError) {
        popActor()
        let increment = amount - maxBet
        stacks[player] -= amount - bets[player]
        payoffs[player] -= amount - bets[player]
        bets[player] = amount
        actorIndices = rotated(from: player).dropFirst().filter { statuses[$0] == .active && stacks[$0] > 0 }
        openerIndex = player
        // A full raise (at least the largest increment so far) reopens the action for everyone else.
        if increment >= completionBettingOrRaisingAmount {
            actedPlayerIndices = [player]
        }
        completionBettingOrRaisingAmount = max(completionBettingOrRaisingAmount, increment)
        if stacks[player] > 0 {
            consecutiveShortAllInAmounts = []
        } else {
            consecutiveShortAllInAmounts.append(increment)
        }
        if consecutiveShortAllInAmounts.reduce(0, +) >= completionBettingOrRaisingAmount {
            consecutiveShortAllInAmounts = []
        }
        record(.betOrRaised(player: player, to: amount))
        try updateBetting()
    }
}
