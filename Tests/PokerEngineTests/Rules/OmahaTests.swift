import Testing
@testable import PokerEngine

/// Every number here is PokerKit 0.7.7's, from `PotLimitOmahaHoldem` with the same cards and actions.
@Suite("Pot-Limit Omaha")
struct OmahaTests {
    /// Player 0 holds four aces, player 1 four kings and player 2 four queens, dealt one card at a time.
    private static let threeHoles = "AsKsQsAhKhQhAdKdQdAcKcQc"

    private func omaha(
        _ mode: HandConfig.Mode = .cashGame, stacks: [Int], minBet: Int = 2
    ) -> HandConfig {
        .test(mode, variant: .potLimitOmahaHoldem, stacks: stacks, minBet: minBet)
    }

    /// Heads-up, checked to the river's showdown on 2d7h9sTh3d: player 0 shows first, then player 1.
    private func headsUpRiver() throws -> HandState {
        try HandState(config: omaha(stacks: [100, 100])).dealingHoles("AsKsAhKhAdKdAcKc").checkingDown()
            .dealingStreet("2d7h9s").checkingDown().dealingStreet("Th").checkingDown()
            .dealingStreet("3d").checkingDown()
    }

    // MARK: Dealing and betting

    @Test("each player is dealt four hole cards, one at a time round the table, and no fifth")
    func fourHoleCards() throws {
        var hand = HandState(config: omaha(stacks: [200, 200, 200]))
        #expect(hand.pendingOperation == .dealHoleCard(player: 0, cardIndex: 0))
        hand = try hand.dealingHoles("AsKsQsAhKhQhAdKdQd")
        #expect(hand.pendingOperation == .dealHoleCard(player: 0, cardIndex: 3))
        #expect(throws: EngineError.noDealExpected(.holeCard(player: 1))) {
            try hand.applying(.dealHole(player: 1, card: card("Kc")), .dealHole(player: 1, card: card("2c")))
        }
        hand = try hand.dealingHoles("AcKcQc")
        #expect(hand.holeCards.map(\.count) == [4, 4, 4])
        #expect(hand.pendingOperation == .act(player: 2))
        #expect(throws: EngineError.noDealExpected(.holeCard(player: 0))) {
            try hand.apply(.dealHole(player: 0, card: card("2c")))
        }
    }

    @Test("the largest bet or raise is a call plus the pot after it, and a larger one is refused")
    func potLimit() throws {
        var hand = try HandState(config: omaha(stacks: [200, 200, 200])).dealingHoles(Self.threeHoles)
        #expect(hand.legalActions?.betOrRaise == .raise(4...7))
        hand = try hand.apply(.betOrRaise(player: 2, to: 7))
        #expect(hand.legalActions?.betOrRaise == .raise(12...23))
        hand = try hand.applying(.checkOrCall(player: 0), .checkOrCall(player: 1)).dealingStreet("2c7d9h")
        #expect(hand.totalPot == 21)
        #expect(hand.legalActions?.betOrRaise == .bet(2...21))
        #expect(hand.maxRaiseTo == 21)
        #expect(throws: EngineError.betAboveMaximum(amount: 22, maximum: 21)) {
            try hand.apply(.betOrRaise(player: 0, to: 22))
        }
    }

    @Test("heads-up, each raise and re-raise is capped at the pot it makes")
    func potLimitHeadsUp() throws {
        var hand = try HandState(config: omaha(stacks: [500, 500])).dealingHoles("AsKsAhKhAdKdAcKc")
        #expect(hand.legalActions?.betOrRaise == .raise(4...6))
        hand = try hand.apply(.betOrRaise(player: 1, to: 6))
        #expect(hand.legalActions?.betOrRaise == .raise(10...18))
        hand = try hand.apply(.betOrRaise(player: 0, to: 18))
        #expect(hand.legalActions?.betOrRaise == .raise(30...54))
        #expect(throws: EngineError.betAboveMaximum(amount: 55, maximum: 54)) {
            try hand.apply(.betOrRaise(player: 1, to: 55))
        }
    }

    @Test("a short stack caps the raise, and a minimum raise above the pot is also the maximum")
    func potLimitEdges() throws {
        let short = try HandState(config: omaha(stacks: [200, 200, 5])).dealingHoles(Self.threeHoles)
        #expect(short.legalActions?.betOrRaise == .raise(4...5))
        let bigMinimum = try HandState(config: omaha(stacks: [200, 200, 200], minBet: 10)).dealingHoles(Self.threeHoles)
        #expect(bigMinimum.legalActions?.betOrRaise == .raise(12...12))
    }

    // MARK: Hands

    @Test("a hand uses exactly two hole cards and three from the board, so four aces make one pair")
    func twoHoleCards() throws {
        let river = try HandState(config: omaha(stacks: [100, 100])).dealingHoles("AsKhAhKdAdQhAcJh").checkingDown()
            .dealingStreet("2s7s9s").checkingDown().dealingStreet("Ts").checkingDown().dealingStreet("3h")
        #expect(river.hand(of: 0)?.description == "One pair (AsAh7s9sTs)")
        #expect(river.dealtHand(of: 0)?.description == "One pair (AsAh7s9sTs)")
        #expect(river.hand(of: 0, faceUpOnly: true) == nil)
        #expect(try river.phh().hasPrefix("variant = 'PO'\n"))
    }

    @Test("a hand kept face down on the river is forgotten and has no hand, so it cannot win the pot")
    func keptHandOnTheRiver() throws {
        let kept = try headsUpRiver().apply(.showHoleCards(player: 0, cards: []))
        #expect(kept.hand(of: 0) == nil)
        #expect(kept.dealtHand(of: 0)?.description == "One pair (AsAh7h9sTh)")
        // Two cards are a hand: player 1's kings take the pot from the aces nobody saw.
        let shown = try kept.apply(.showHoleCards(player: 1, cards: cards("KsKh")))
        #expect(shown.results?.map(\.net) == [-2, 2])
        #expect(shown.results?.map(\.status) == [.killed, .active])
        // A muck leaves player 0 alone, paid without a look at the cards.
        #expect(try kept.apply(.muckHoleCards(player: 1)).results?.map(\.net) == [2, -2])
    }

    @Test("an answer that would leave a pot with no possible winner is refused, a Keep as well as a muck (B2)")
    func deadHandsCannotAbandonAPot() throws {
        let kept = try headsUpRiver().apply(.showHoleCards(player: 0, cards: []))
        #expect(throws: EngineError.wouldAbandonPot(player: 1, pot: 0)) {
            try kept.apply(.showHoleCards(player: 1, cards: []))
        }
        #expect(throws: EngineError.wouldAbandonPot(player: 1, pot: 0)) {
            try kept.apply(.showHoleCards(player: 1, cards: cards("Ks")))
        }
        #expect(!kept.canApply(.showHoleCards(player: 1, cards: [])))
        #expect(kept.canApply(.showHoleCards(player: 1)))
    }

    @Test("the refusal lands on the answer that loses the pot for certain, even with a player still to answer (B2)")
    func deadHandsInASidePot() throws {
        // Player 0 is all in before the flop; players 1 and 2 bet into a side pot on the flop and check it down.
        var hand = try HandState(config: omaha(stacks: [8, 200, 200])).dealingHoles(Self.threeHoles)
            .applying(.checkOrCall(player: 2), .betOrRaise(player: 0, to: 8), .checkOrCall(player: 1),
                      .checkOrCall(player: 2))
            .dealingStreet("2d7h9s").applying(.betOrRaise(player: 1, to: 10), .checkOrCall(player: 2))
            .dealingStreet("Th").checkingDown().dealingStreet("3d").checkingDown()
        #expect(hand.pots == [Pot(amount: 24, eligiblePlayers: [0, 1, 2]), Pot(amount: 20, eligiblePlayers: [1, 2])])
        #expect(hand.pendingOperation == .showdown(runoutSelectors: [], showOrder: [0, 1, 2]))
        hand = try hand.apply(.showHoleCards(player: 1, cards: []))
        #expect(throws: EngineError.wouldAbandonPot(player: 2, pot: 1)) {
            try hand.apply(.showHoleCards(player: 2, cards: []))
        }
        hand = try hand.applying(.showHoleCards(player: 2), .showHoleCards(player: 0))
        #expect(hand.results?.map(\.net) == [16, -18, 2])
    }

    @Test("the player left at a tournament showdown may keep the cards face down: nobody compares hands (B13)")
    func tournamentKeep() throws {
        let hand = try HandState(config: omaha(.tournament, stacks: [200, 200, 200])).dealingHoles(Self.threeHoles)
            .checkingDown().dealingStreet("2d7h9s").checkingDown().dealingStreet("Th").checkingDown()
            .dealingStreet("3d").checkingDown()
            .applying(.muckHoleCards(player: 0), .muckHoleCards(player: 1), .showHoleCards(player: 2, cards: []))
        #expect(hand.isHandComplete)
        #expect(hand.results?.map(\.net) == [-2, -2, 4])
    }

    @Test("a Texas Hold'em config is the default, and an Omaha one says so")
    func variant() throws {
        #expect(HandConfig.test(stacks: [100, 100]).variant == .noLimitTexasHoldem)
        #expect(omaha(stacks: [100, 100]).variant == .potLimitOmahaHoldem)
        #expect(try HandState(config: .test(stacks: [100, 100])).phh().hasPrefix("variant = 'NT'\n"))
    }
}
