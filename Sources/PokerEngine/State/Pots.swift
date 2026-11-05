extension HandState {
    /// Collected chips as main and side pots, main pot first. Each pot is a layer of contributions; a player is
    /// eligible for a layer when active and in for at least that much, current bets included. Untrimmed antes
    /// are dead money in the first pot. Neighbouring layers with the same eligible players merge. Bets still in
    /// front of players are not in any pot until collected.
    ///
    /// Once chips pushing begins the list is frozen: amounts drop as chips are pushed, and a fully pushed pot stays
    /// listed with amount 0, so pot indices stay stable.
    public var pots: [Pot] {
        if let frozenPots { return frozenPots }
        guard payoffs.reduce(0, +) != -bets.reduce(0, +) else { return [] }
        var collected = players.map { -payoffs[$0] - bets[$0] }
        var committed = players.map { -payoffs[$0] }
        var amount = 0
        if !config.anteTrimming {
            for player in players {
                let ante = effectiveAnte(player)
                amount += ante
                collected[player] -= ante
                committed[player] -= ante
            }
        }
        var pots = [Pot]()
        var previousLevel = 0
        for level in Set(collected).sorted() {
            amount += collected.count { $0 >= level } * (level - previousLevel)
            let eligible = players.filter { committed[$0] >= level && statuses[$0] == .active }
            while let last = pots.last, last.eligiblePlayers == eligible {
                amount += pots.removeLast().amount
            }
            if amount > 0 {
                pots.append(Pot(amount: amount, eligiblePlayers: eligible))
            }
            amount = 0
            previousLevel = level
        }
        return pots
    }

    /// Every chip in the middle: collected pots plus bets in front of players.
    public var totalPot: Int {
        bets.reduce(0, +) + pots.reduce(0) { $0 + $1.amount }
    }

    /// Deviation B2: the pot left with nobody eligible if `player` gave up the hand now, as an index into `pots` as
    /// they would then stand: everyone still to act has called, unless one player is left, and bets are collected.
    /// Bets not yet collected count, and so do those calls: the round goes on while two players are active and the
    /// queue is not empty, and each player in it owes the largest bet, folded players' bets included. Testing only
    /// at the end of the round would not do, because a fold can make a later call strand a pot.
    func potAbandoned(byRemoving player: Int) -> Int? {
        var probe = self
        probe.statuses[player] = .folded
        // With one player left the round ends at once. That player must not "call" here, which would hide the loss.
        if probe.activeCount > 1 {
            let top = probe.maxBet
            // A fold is verified while its player is still first in the queue.
            for actor in probe.actorIndices where actor != player {
                let amount = min(probe.stacks[actor], top - probe.bets[actor])
                probe.bets[actor] += amount
                probe.stacks[actor] -= amount
                probe.payoffs[actor] -= amount
            }
        }
        _ = probe.moveBetsIntoPots()
        return probe.pots.firstIndex { $0.eligiblePlayers.isEmpty }
    }
}
