// The showdown: the runout-count choice and showing or mucking, in any order, interleaved. After an all-in it runs
// before the next card, and a cash player who kept a card face down is asked again after each street that follows.

/// What a validated show changes, as PokerKit's verifier returns it.
struct VerifiedShow {
    /// The event's cards: the list padded with `.unknown`, or the live cards for a show as is.
    let eventCards: [Card]
    let holeCards: [HoleCard]
    let dealtHoleCards: [HoleCard]
}

extension HandState {
    mutating func beginShowdown() throws(EngineError) {
        let boardCardsFollow = Street.allCases[(streetIndex! + 1)...]
            .contains { $0.spec(config.variant).boardCardCount > 0 }
        if !runoutCountSelectionFlag && config.mode != .tournament && boardCardsFollow {
            runoutCountSelectorStatuses = statuses.map { $0 == .active }
        }
        showdownIndices = rotated(from: openerIndex ?? 0).filter {
            statuses[$0] == .active && !holeCards[$0].allSatisfy(\.isFaceUp)
        }
        try updateShowdown()
    }

    mutating func updateShowdown() throws(EngineError) {
        // A post-hand show: the showdown is over and nothing follows from it.
        guard streetIndex != nil else { return }
        if !runoutCountSelectorStatuses.contains(true) && showdownIndices.isEmpty {
            try endShowdown()
        } else if config.automations.contains(.runoutCountSelection),
                  let player = runoutCountSelectorStatuses.firstIndex(of: true) {
            try selectRunoutCount(player, nil)
        }
    }

    mutating func endShowdown() throws(EngineError) {
        if !runoutCountSelectionFlag {
            runoutCountSelectionFlag = true
            if let selectedRunoutCount {
                streetReturnIndex = streetIndex! + 1
                streetReturnCount = selectedRunoutCount - 1
            }
        }
        if allInStatus && !isLastStreet {
            try beginDealing()
        } else {
            try beginHandKilling()
        }
    }

    // MARK: Runout count selection

    /// Never looks at the player's status: a selector who has mucked still has to choose, as in PokerKit.
    func verifyRunoutCountSelection(_ player: Int, _ count: Int?) throws(EngineError) {
        guard runoutCountSelectorStatuses[player] else { throw .noRunoutSelectionExpected(player: player) }
        // Deviation B5.
        if let count, !(1...Self.maximumRunoutCount).contains(count) {
            throw .invalidRunoutCount(count)
        }
    }

    /// Abstaining agrees with any count, and any disagreement means one run.
    mutating func selectRunoutCount(_ player: Int, _ count: Int?) throws(EngineError) {
        runoutCountSelectorStatuses[player] = false
        if let count {
            if selectedRunoutCount == nil {
                selectedRunoutCount = count
            } else if selectedRunoutCount != count {
                selectedRunoutCount = 1
            }
        }
        record(.runoutCountSelected(player: player, count: count))
        try updateShowdown()
    }

    // MARK: Showing and mucking

    /// The checks a show and a muck share, in PokerKit's order. PokerKit has no timing check while its street is nil,
    /// so during forced bets and from chips pushing on only the player's status is judged here.
    private func verifyShowdownTurn(_ player: Int) throws(EngineError) {
        if streetIndex != nil && showdownIndices.isEmpty {
            throw .noShowdownExpected(player: player)
        }
        guard statuses[player] == .active else { throw .playerNotInHand(player: player) }
        if streetIndex != nil && !showdownIndices.contains(player) {
            throw .noShowdownExpected(player: player)
        }
    }

    /// `listed` nil shows the live cards as they are. Checks run in PokerKit's order, and the checks only the port
    /// has run after them, so every input PokerKit rejects gets PokerKit's own error.
    func verifyHoleCardsShowing(_ player: Int, _ listed: [Card]?) throws(EngineError) -> VerifiedShow {
        try verifyShowdownTurn(player)
        let show: VerifiedShow
        if let listed {
            show = try verifyListedShow(player, listed)
        } else {
            show = try verifyShowAsIs(player)
        }
        if let pot = potLostToDeadHands(answering: player, keeping: show.holeCards) {
            throw .wouldAbandonPot(player: player, pot: pot)
        }
        // Deviation B9. Only `nil` and `[]` get here during forced bets; PokerKit accepts them and records an empty
        // show. A plain timing check first would replace PokerKit's refusals of a list or a muck.
        if streetIndex == nil && frozenPots == nil {
            throw .noShowdownExpected(player: player)
        }
        return show
    }

    /// Deviation B2 in Omaha: the pot nobody could win if `player` answered the river's showdown keeping `liveCards`,
    /// or mucking when nil, as an index into the pots as they would then stand. There a card kept face down is
    /// forgotten, and an Omaha hand needs two hole cards, so a player who has answered without two known cards cannot
    /// win, and PokerKit loses that pot without a word. Hands are only compared with two or more players left; a lone
    /// survivor is paid without that.
    func potLostToDeadHands(answering player: Int, keeping liveCards: [HoleCard]?) -> Int? {
        guard config.variant == .potLimitOmahaHoldem, isLastStreet else { return nil }
        var probe = self
        probe.showdownIndices.removeAll { $0 == player }
        if let liveCards {
            probe.holeCards[player] = liveCards
        } else {
            probe.holeCards[player] = []
            probe.statuses[player] = .mucked
        }
        guard probe.activeCount > 1 else { return nil }
        return probe.pots.firstIndex { pot in
            pot.eligiblePlayers.allSatisfy { eligible in
                !probe.showdownIndices.contains(eligible)
                    && probe.holeCards[eligible].count(where: { $0.card != .unknown }) < 2
            }
        }
    }

    private func verifyShowAsIs(_ player: Int) throws(EngineError) -> VerifiedShow {
        let live = holeCards[player]
        // A live unknown is a card dealt unscanned or one the river forgot. Labelled by meaning: a tournament gets
        // PokerKit's refusal for a card not shown, or a bare assertion after the hand.
        guard !live.contains(where: { $0.card == .unknown }) else { throw .cannotShowUnknownCard(player: player) }
        return VerifiedShow(
            eventCards: live.map(\.card),
            holeCards: live.map { HoleCard(card: $0.card, isFaceUp: true) },
            dealtHoleCards: dealtHoleCards[player].map { HoleCard(card: $0.card, isFaceUp: true) }
        )
    }

    private func verifyListedShow(_ player: Int, _ listed: [Card]) throws(EngineError) -> VerifiedShow {
        let live = holeCards[player]
        guard listed.count <= live.count else { throw .tooManyCardsShown(player: player, count: listed.count) }
        let shown = listed.filter { $0 != .unknown }
        var newLive = shown.map { HoleCard(card: $0, isFaceUp: true) }
        // Cards kept face down stay in the hand until the last run's river, where they are forgotten
        // (DECISIONS.md A13).
        if !isLastStreet {
            let kept = live.map(\.card).filter { $0 != .unknown && !shown.contains($0) }
            newLive += kept.prefix(live.count - shown.count).map { HoleCard(card: $0, isFaceUp: false) }
        }
        newLive += Array(repeating: HoleCard(card: .unknown, isFaceUp: false), count: live.count - newLive.count)

        // Deviation B13: the player left at a showdown with nobody all in wins without tabling (TDA 2026 Rule 18-B).
        if config.mode == .tournament && shown.count < live.count && (activeCount > 1 || allInStatus) {
            throw .mustShowAllCards(player: player)
        }
        if streetIndex == nil && newLive.contains(where: { !$0.isFaceUp }) {
            throw .mustShowAllCards(player: player)
        }
        // Deviation B14: a card is shown or left out, so an unknown entry can only be a card the camera missed.
        if listed.contains(.unknown) {
            throw .cannotShowUnknownCard(player: player)
        }
        return VerifiedShow(
            eventCards: listed + Array(repeating: .unknown, count: live.count - listed.count),
            holeCards: newLive,
            dealtHoleCards: try dealtRecord(of: player, afterShowing: shown)
        )
    }

    /// The player's dealt cards with `shown` turned face up. A card that is not among them reveals the first slot
    /// dealt unscanned; with none left it contradicts the scan (deviation B6). That is why a live `.unknown` is not
    /// always a reveal: a slot the river forgot belongs to its scanned card. PokerKit has that card back in its deck
    /// and lets anyone show it, but two copies of one physical card would break deviation B1.
    private func dealtRecord(of player: Int, afterShowing shown: [Card]) throws(EngineError) -> [HoleCard] {
        var seen = Set<Card>()
        for card in shown where !seen.insert(card).inserted {
            throw .duplicateCard(card, location: .sameOperation)
        }
        var record = dealtHoleCards[player]
        for card in shown {
            if let slot = record.firstIndex(where: { $0.card == card }) {
                record[slot] = HoleCard(card: card, isFaceUp: true)
            } else if let slot = record.firstIndex(where: { $0.card == .unknown }) {
                try verifyUnseen(card)
                record[slot] = HoleCard(card: card, isFaceUp: true)
            } else {
                throw .shownCardNotDealt(player: player, card: card)
            }
        }
        return record
    }

    /// The status stays `.active`: a hand kept face down plays the board (DECISIONS.md A13).
    mutating func showHoleCards(_ player: Int, _ show: VerifiedShow) throws(EngineError) {
        if streetIndex != nil {
            showdownIndices.removeAll { $0 == player }
        }
        holeCards[player] = show.holeCards
        dealtHoleCards[player] = show.dealtHoleCards
        record(.holeCardsShown(player: player, cards: show.eventCards))
        try updateShowdown()
    }

    func verifyHoleCardsMucking(_ player: Int) throws(EngineError) {
        try verifyShowdownTurn(player)
        if streetIndex == nil {
            throw .mustShowAllCards(player: player)
        }
        if let pot = potAbandoned(byRemoving: player) ?? potLostToDeadHands(answering: player, keeping: nil) {
            throw .wouldAbandonPot(player: player, pot: pot)
        }
    }

    mutating func muckHoleCards(_ player: Int) throws(EngineError) {
        showdownIndices.removeAll { $0 == player }
        muckHand(player, as: .mucked)
        record(.holeCardsMucked(player: player))
        try updateShowdown()
    }

    /// Takes a hand out of play, for a fold, a muck or a kill. The muck gets the scanned cards, including any the
    /// river forgot, and `dealtHoleCards` keeps them for `results`.
    mutating func muckHand(_ player: Int, as newStatus: PlayerStatus) {
        muckedCards += dealtHoleCards[player].map(\.card)
        holeCards[player] = []
        statuses[player] = newStatus
    }
}
