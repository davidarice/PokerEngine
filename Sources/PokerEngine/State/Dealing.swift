// Burning and dealing. Every card comes from the dealer; nothing is dealt automatically.

/// What a street deals, in PokerKit's terms. This is the only place card counts live.
struct StreetSpec {
    let burnsCard: Bool
    let holeCardCount: Int
    let boardCardCount: Int
}

extension Street {
    /// The board and the burns are the same in both games; Omaha deals four hole cards to hold'em's two.
    func spec(_ variant: HandConfig.Variant) -> StreetSpec {
        switch self {
        case .preflop:
            StreetSpec(burnsCard: false, holeCardCount: variant == .potLimitOmahaHoldem ? 4 : 2, boardCardCount: 0)
        case .flop: StreetSpec(burnsCard: true, holeCardCount: 0, boardCardCount: 3)
        case .turn, .river: StreetSpec(burnsCard: true, holeCardCount: 0, boardCardCount: 1)
        }
    }
}

extension HandState {
    mutating func beginDealing() throws(EngineError) {
        streetIndex = streetIndex.map { $0 + 1 } ?? 0
        let spec = Street.allCases[streetIndex!].spec(config.variant)
        cardBurningStatus = spec.burnsCard
        boardDealingCount = spec.boardCardCount
        for player in players where statuses[player] == .active {
            holeDealingCounts[player] += spec.holeCardCount
        }
        try updateDealing()
    }

    mutating func updateDealing() throws(EngineError) {
        if !cardBurningStatus && !holeDealingCounts.contains(where: { $0 > 0 }) && boardDealingCount == 0 {
            try beginBetting()
        }
    }

    /// PokerKit's suggested dealee: the player owed the most cards, the lowest index on a tie.
    var holeDealeeIndex: Int? {
        guard let most = holeDealingCounts.max(), most > 0 else { return nil }
        return holeDealingCounts.firstIndex(of: most)
    }

    /// The board position of the first card of the street at `index`, counting every earlier street's cards.
    func firstBoardPosition(ofStreet index: Int) -> Int {
        Street.allCases[..<index].map { $0.spec(config.variant).boardCardCount }.reduce(0, +)
    }

    /// The board position the next board card goes to.
    var boardDealingPosition: Int {
        firstBoardPosition(ofStreet: streetIndex!) + currentStreet!.spec(config.variant).boardCardCount
            - boardDealingCount
    }

    /// The runout being dealt: how many cards the next board position already holds.
    var dealingRunout: Int {
        let position = boardDealingPosition
        return position < boardCards.count ? boardCards[position].count : 0
    }

    func verifyCardBurning(_ card: Card) throws(EngineError) {
        guard cardBurningStatus else { throw .noDealExpected(.burn) }
        try verifyUnseen(card)
    }

    mutating func burnCard(_ card: Card) throws(EngineError) {
        let runout = dealingRunout
        cardBurningStatus = false
        burnCards.append(card)
        record(.cardBurned(card, street: currentStreet!, runout: runout))
        try updateDealing()
    }

    func verifyHoleDealing(_ player: Int, _ card: Card) throws(EngineError) {
        guard holeDealingCounts[player] > 0 else { throw .noDealExpected(.holeCard(player: player)) }
        try verifyUnseen(card)
    }

    mutating func dealHole(_ player: Int, _ card: Card) throws(EngineError) {
        holeDealingCounts[player] -= 1
        holeCards[player].append(HoleCard(card: card, isFaceUp: false))
        dealtHoleCards[player].append(HoleCard(card: card, isFaceUp: false))
        record(.holeCardDealt(player: player, card: card))
        try updateDealing()
    }

    func verifyBoardDealing(_ card: Card) throws(EngineError) {
        guard !cardBurningStatus else { throw .burnRequired }
        guard boardDealingCount > 0 else { throw .noDealExpected(.boardCard) }
        try verifyUnseen(card)
    }

    mutating func dealBoard(_ card: Card) throws(EngineError) {
        let position = boardDealingPosition
        let runout = dealingRunout
        boardDealingCount -= 1
        if position == boardCards.count {
            boardCards.append([])
        }
        boardCards[position].append(card)
        record(.boardCardDealt(card, street: currentStreet!, runout: runout))
        try updateDealing()
    }

    /// Deviation B1: a known card can be dealt only once per hand. PokerKit just warns.
    func verifyUnseen(_ card: Card) throws(EngineError) {
        guard card != .unknown, let location = location(of: card) else { return }
        throw .duplicateCard(card, location: location)
    }

    /// Where a known card is. An active player's dealt cards count, not the live ones: a card the river forgot is
    /// still in that hand. Everyone else's cards are in the muck.
    func location(of card: Card) -> CardLocation? {
        let holder = players.first { player in
            statuses[player] == .active && dealtHoleCards[player].contains { $0.card == card }
        }
        if let holder {
            return .hole(player: holder)
        }
        if let runout = boardCards.lazy.compactMap({ $0.firstIndex(of: card) }).first {
            return .board(runout: runout)
        }
        if burnCards.contains(card) {
            return .burned
        }
        return muckedCards.contains(card) ? .mucked : nil
    }
}
