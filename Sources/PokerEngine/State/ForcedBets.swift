// Ante posting, bet collection, and blind or straddle posting.

extension HandState {
    // MARK: Ante posting

    /// The ante the player actually posts: heads-up the ante array is read in reverse, and a short stack posts
    /// what it has.
    func effectiveAnte(_ player: Int) -> Int {
        let ante = config.playerCount == 2 ? config.antes[1 - player] : config.antes[player]
        return min(ante, config.startingStacks[player])
    }

    mutating func beginAntePosting() throws(EngineError) {
        antePostingStatuses = players.map { effectiveAnte($0) > 0 }
        try updateAntePosting()
    }

    mutating func updateAntePosting() throws(EngineError) {
        if !antePostingStatuses.contains(true) {
            try beginBetCollection()
        } else if config.automations.contains(.antePosting), let player = antePostingStatuses.firstIndex(of: true) {
            try postAnte(player)
        }
    }

    func verifyAntePosting(_ player: Int) throws(EngineError) {
        guard antePostingStatuses[player] else { throw .noAnteExpected(player: player) }
    }

    mutating func postAnte(_ player: Int) throws(EngineError) {
        let amount = effectiveAnte(player)
        antePostingStatuses[player] = false
        bets[player] = amount
        stacks[player] -= amount
        payoffs[player] -= amount
        record(.antePosted(player: player, amount: amount))
        try updateAntePosting()
    }

    // MARK: Bet collection

    mutating func beginBetCollection() throws(EngineError) {
        betCollectionStatus = bets.contains { $0 > 0 }
        try updateBetCollection()
    }

    mutating func updateBetCollection() throws(EngineError) {
        if !betCollectionStatus {
            try endBetCollection()
        } else if config.automations.contains(.betCollection) {
            try collectBets()
        }
    }

    mutating func endBetCollection() throws(EngineError) {
        // The river of a run with another to follow: back to the showdown before the first street each run repeats.
        if isLastStreet && streetReturnCount > 0 {
            streetIndex = streetReturnIndex! - 1
            streetReturnCount -= 1
        }
        if activeCount == 1 {
            foldedStatus = true
            try beginChipsPushing()
        } else if streetIndex == nil {
            try beginBlindOrStraddlePosting()
        } else if isLastStreet || allInStatus {
            try beginShowdown()
        } else {
            try beginDealing()
        }
    }

    func verifyBetCollection() throws(EngineError) {
        guard betCollectionStatus else { throw .noBetCollectionExpected }
    }

    mutating func collectBets() throws(EngineError) {
        betCollectionStatus = false
        let (collected, returned) = moveBetsIntoPots()
        record(.betsCollected(collected: collected, returned: returned))
        try updateBetCollection()
    }

    /// Moves bets into the pot. The largest bet is cut to the second largest and the excess returned, except for
    /// antes without trimming, which stay whole as dead money. When everyone else has folded, the winner's bet is
    /// left out entirely; it comes back with the pot.
    mutating func moveBetsIntoPots() -> (collected: [Int], returned: [Int]) {
        var collected = bets
        var returned = Array(repeating: 0, count: config.playerCount)
        var collectedPlayers = Array(players)
        if activeCount == 1, let winner = statuses.firstIndex(of: .active) {
            collected[winner] = 0
            collectedPlayers.removeAll { $0 == winner }
        }
        if streetIndex != nil || config.anteTrimming {
            let cutoff = bets.sorted()[bets.count - 2]
            for player in collectedPlayers where bets[player] > cutoff {
                returned[player] = bets[player] - cutoff
                stacks[player] += returned[player]
                payoffs[player] += returned[player]
                collected[player] = cutoff
            }
        }
        for player in collectedPlayers {
            bets[player] = 0
        }
        return (collected, returned)
    }

    // MARK: Blind or straddle posting

    /// The blind or straddle the player actually posts: heads-up the array is read in reverse, a live post's
    /// negative entry counts by its size, and a short stack posts what is left after the ante.
    func effectiveBlindOrStraddle(_ player: Int) -> Int {
        let blind = config.playerCount == 2 ? config.blindsOrStraddles[1 - player] : config.blindsOrStraddles[player]
        return min(abs(blind), config.startingStacks[player] - effectiveAnte(player))
    }

    mutating func beginBlindOrStraddlePosting() throws(EngineError) {
        blindOrStraddlePostingStatuses = players.map { effectiveBlindOrStraddle($0) > 0 }
        try updateBlindOrStraddlePosting()
    }

    mutating func updateBlindOrStraddlePosting() throws(EngineError) {
        if !blindOrStraddlePostingStatuses.contains(true) {
            try beginDealing()
        } else if config.automations.contains(.blindOrStraddlePosting),
                  let player = blindOrStraddlePostingStatuses.firstIndex(of: true) {
            try postBlindOrStraddle(player)
        }
    }

    func verifyBlindOrStraddlePosting(_ player: Int) throws(EngineError) {
        guard blindOrStraddlePostingStatuses[player] else { throw .noBlindOrStraddleExpected(player: player) }
    }

    mutating func postBlindOrStraddle(_ player: Int) throws(EngineError) {
        let amount = effectiveBlindOrStraddle(player)
        blindOrStraddlePostingStatuses[player] = false
        bets[player] = amount
        stacks[player] -= amount
        payoffs[player] -= amount
        record(.blindOrStraddlePosted(player: player, amount: amount))
        try updateBlindOrStraddlePosting()
    }
}
