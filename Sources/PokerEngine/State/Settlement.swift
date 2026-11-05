// What follows the showdown: killing hands that cannot win, pushing each pot to its winners, and pulling the chips.

/// One push: a pot's chips on one runout (PokerKit's `_sub_pots`, whose hand-type index is always 0 in hold'em).
struct SubPot: Sendable, Hashable {
    let amount: Int
    let pot: Int
    /// Nil when only one player is left at pushing, after folds, mucks or kills. The push compares no hands, though
    /// hand killing may already have.
    let runout: Int?
}

extension HandState {
    // MARK: Hand killing

    mutating func beginHandKilling() throws(EngineError) {
        // Deviation B4: a lone survivor is paid without evaluating hands. PokerKit evaluates here, stopping at the
        // first board that hand can win: a known first board never kills it, and a `??` on it raises `KeyError`.
        if activeCount > 1 {
            try verifyBoardsKnown()
            for player in players where statuses[player] == .active {
                handKillingStatuses[player] = !canWinNow(player)
            }
        }
        try updateHandKilling()
    }

    /// Deviation B4. Settlement cannot evaluate hands on a board with an unknown card.
    private func verifyBoardsKnown() throws(EngineError) {
        for (runout, board) in boards.enumerated() {
            if let position = board.firstIndex(of: .unknown) {
                throw .unknownBoardCard(runout: runout, position: position)
            }
        }
    }

    /// Whether the player's hand, face-down cards included, can still take a share of a pot from the hands shown.
    func canWinNow(_ player: Int) -> Bool {
        for board in boards.indices {
            let upHands = players.map { hand(of: $0, board: board, faceUpOnly: true) }
            guard let own = hand(of: player, board: board) else { continue }
            for pot in pots where pot.eligiblePlayers.contains(player) {
                let best = pot.eligiblePlayers.compactMap { upHands[$0] }.max()
                if best.map({ $0 <= own }) ?? true {
                    return true
                }
            }
        }
        return false
    }

    mutating func updateHandKilling() throws(EngineError) {
        if !handKillingStatuses.contains(true) {
            try endHandKilling()
        } else if config.automations.contains(.handKilling), let player = handKillingStatuses.firstIndex(of: true) {
            try killHand(player)
        }
    }

    mutating func endHandKilling() throws(EngineError) {
        try beginChipsPushing()
    }

    func verifyHandKilling(_ player: Int) throws(EngineError) {
        guard handKillingStatuses[player] else { throw .noHandToKill(player: player) }
    }

    /// Kills never abandon a pot: the best hand shown among a pot's eligible players can always win it.
    mutating func killHand(_ player: Int) throws(EngineError) {
        handKillingStatuses[player] = false
        muckHand(player, as: .killed)
        record(.handKilled(player: player))
        try updateHandKilling()
    }

    // MARK: Chips pushing

    mutating func beginChipsPushing() throws(EngineError) {
        streetIndex = nil
        let pots = pots
        frozenPots = pots
        if activeCount == 1 {
            subPots = pots.enumerated().map { SubPot(amount: $1.amount, pot: $0, runout: nil) }
        } else if activeCount > 1 {
            for (index, pot) in pots.enumerated() {
                let (quotient, remainder) = pot.amount.quotientAndRemainder(dividingBy: boards.count)
                for board in boards.indices {
                    let amount = quotient + (board == 0 ? remainder : 0)
                    if amount > 0 {
                        subPots.append(SubPot(amount: amount, pot: index, runout: board))
                    }
                }
            }
        }
        try updateChipsPushing()
    }

    /// A loop, unlike every other update: enough runouts make hundreds of pushes, too deep for a thread's stack.
    mutating func updateChipsPushing() throws(EngineError) {
        while config.automations.contains(.chipsPushing), !subPots.isEmpty {
            pushNextSubPot()
        }
        if subPots.isEmpty {
            try beginChipsPulling()
        }
    }

    func verifyChipsPushing() throws(EngineError) {
        guard !subPots.isEmpty else { throw .noChipsToPush }
    }

    mutating func pushChips() throws(EngineError) {
        pushNextSubPot()
        try updateChipsPushing()
    }

    /// Hands are evaluated here, not when pushing begins, so a post-hand show can change who wins the next push.
    private mutating func pushNextSubPot() {
        let subPot = subPots.removeFirst()
        let pot = frozenPots![subPot.pot]
        frozenPots![subPot.pot] = Pot(amount: pot.amount - subPot.amount, eligiblePlayers: pot.eligiblePlayers)
        var amounts = Array(repeating: 0, count: config.playerCount)
        if activeCount == 1 {
            // Deviation B2 keeps the survivor eligible for every pot, so nobody else can be.
            amounts[pot.eligiblePlayers[0]] = subPot.amount
        } else {
            let upHands = players.map { hand(of: $0, board: subPot.runout!, faceUpOnly: true) }
            let best = pot.eligiblePlayers.compactMap { upHands[$0] }.max()
            let winners = pot.eligiblePlayers.filter { upHands[$0] == best }
            // Only an abandoned pot has no winner, and deviation B2 prevents one.
            precondition(!winners.isEmpty, "Pot \(subPot.pot) has no eligible player")
            let (quotient, remainder) = subPot.amount.quotientAndRemainder(dividingBy: winners.count)
            for winner in winners {
                amounts[winner] = quotient
            }
            amounts[winners[0]] += remainder
        }
        for player in players {
            bets[player] += amounts[player]
        }
        record(.chipsPushed(pot: subPot.pot, runout: subPot.runout, amounts: amounts))
    }

    // MARK: Chips pulling

    mutating func beginChipsPulling() throws(EngineError) {
        chipsPullingStatuses = bets.map { $0 > 0 }
        try updateChipsPulling()
    }

    mutating func updateChipsPulling() throws(EngineError) {
        if !chipsPullingStatuses.contains(true) {
            endChipsPulling()
        } else if config.automations.contains(.chipsPulling), let player = chipsPullingStatuses.firstIndex(of: true) {
            try pullChips(player)
        }
    }

    mutating func endChipsPulling() {
        status = false
    }

    func verifyChipsPulling(_ player: Int) throws(EngineError) {
        guard chipsPullingStatuses[player] else { throw .noChipsToPull(player: player) }
    }

    mutating func pullChips(_ player: Int) throws(EngineError) {
        let amount = bets[player]
        stacks[player] += amount
        payoffs[player] += amount
        bets[player] = 0
        chipsPullingStatuses[player] = false
        record(.chipsPulled(player: player, amount: amount))
        try updateChipsPulling()
    }
}
