import Testing
@testable import PokerEngine

// The doctests of `pots`, `pot_amounts`, `total_pot_amount`, `showdown_index`, `can_kill_hand` and `street` in
// PokerKit's pokerkit/state.py, in that order. They run in PokerKit's default mode, a tournament. A doctest's echo of
// a card it was just given is not repeated; every derived value is. Where a doctest deals random cards the port
// names cards, and `show_or_muck_hole_cards()` with no argument becomes the show or muck PokerKit's run chose.

extension HandState {
    /// PokerKit's `showdown_index`.
    fileprivate var showdownIndex: Int? {
        guard case let .showdown(_, showOrder)? = pendingOperation else { return nil }
        return showOrder.first
    }
}

/// The `CheckingOrCalling` records a doctest prints, in order.
private func calls(_ records: (player: Int, amount: Int)...) -> [HandEvent] {
    records.map { .checkedOrCalled(player: $0.player, amount: $0.amount) }
}

@Suite("Ported: state.py doctests")
struct PortedStateDoctests {
    private static let postingOnly: Set<HandConfig.Automation> = [.antePosting, .betCollection, .blindOrStraddlePosting]

    // MARK: pots and pot_amounts

    /// The hand both doctests play, up to the call before the last one. Their cards are random and never read, so
    /// these are the port's; the final stacks asserted below are what PokerKit pays with them.
    private func sidePotHand() throws -> (start: HandState, beforeLastCall: HandState) {
        let start = try HandState(config: .test(
            .tournament, stacks: [50, 100, 200, 1000, 200, 100], anteTrimming: true
        )).dealing("AsAh", "KsKh", "QsQh", "JsJh", "TsTh", "9s9h")
        let raised = try start.apply(.betOrRaise(player: 2, to: 200))
        #expect(throws: EngineError.raiseNotAllowed(player: 3, reason: .noOpponentCanRespond)) {
            try raised.apply(.betOrRaise(player: 3, to: 1000))
        }
        let beforeLastCall = try raised.applying(
            .checkOrCall(player: 3), .checkOrCall(player: 4), .checkOrCall(player: 5), .checkOrCall(player: 0)
        )
        #expect(beforeLastCall.checksAndCalls == calls((3, 200), (4, 200), (5, 100), (0, 49)))
        return (start, beforeLastCall)
    }

    /// The doctests end by dealing the flop, turn and river; the all-in showdown PokerKit automates comes first.
    private func sidePotsToTheEnd(_ state: HandState) throws -> HandState {
        try state.applying(
            .showHoleCards(player: 2), .showHoleCards(player: 3), .showHoleCards(player: 4),
            .showHoleCards(player: 5), .showHoleCards(player: 0), .showHoleCards(player: 1)
        ).dealingStreet("2c3d4h").dealingStreet("6c").dealingStreet("7d")
    }

    @Test("pots: none until bets are collected, then a main pot and two side pots")
    func pots() throws {
        let (start, beforeLastCall) = try sidePotHand()
        #expect(start.pots.isEmpty)
        #expect(beforeLastCall.pots.isEmpty)

        let state = try beforeLastCall.apply(.checkOrCall(player: 1))
        #expect(state.checksAndCalls.last == .checkedOrCalled(player: 1, amount: 98))
        #expect(state.pots == [
            Pot(amount: 300, eligiblePlayers: [0, 1, 2, 3, 4, 5]),
            Pot(amount: 250, eligiblePlayers: [1, 2, 3, 4, 5]),
            Pot(amount: 300, eligiblePlayers: [2, 3, 4]),
        ])

        let end = try sidePotsToTheEnd(state)
        #expect(end.isHandComplete)
        #expect(end.stacks == [300, 250, 300, 800, 0, 0])
    }

    @Test("pot_amounts: the same hand, read as amounts")
    func potAmounts() throws {
        let (start, beforeLastCall) = try sidePotHand()
        #expect(start.pots.map(\.amount).isEmpty)
        #expect(beforeLastCall.pots.map(\.amount).isEmpty)

        let state = try beforeLastCall.apply(.checkOrCall(player: 1))
        #expect(state.checksAndCalls.last == .checkedOrCalled(player: 1, amount: 98))
        #expect(state.pots.map(\.amount) == [300, 250, 300])

        let end = try sidePotsToTheEnd(state)
        #expect(end.isHandComplete)
        #expect(end.stacks == [300, 250, 300, 800, 0, 0])
    }

    // MARK: total_pot_amount

    @Test("total_pot_amount: counts live bets as well as pots, until the chips are pulled")
    func totalPotAmount() throws {
        var state = HandState(config: .test(.tournament, stacks: [200, 200], antes: [0, 2], automations: []))
        #expect(state.totalPot == 0)

        // Setup.
        state = try state.apply(.postAnte(player: 0))
        #expect(state.events.last == .antePosted(player: 0, amount: 2))
        #expect(state.totalPot == 2)
        state = try state.apply(.collectBets)
        #expect(state.events.last == .betsCollected(collected: [2, 0], returned: [0, 0]))
        #expect(state.totalPot == 2)
        state = try state.apply(.postBlindOrStraddle(player: 0))
        #expect(state.events.last == .blindOrStraddlePosted(player: 0, amount: 2))
        #expect(state.totalPot == 4)
        state = try state.apply(.postBlindOrStraddle(player: 1))
        #expect(state.events.last == .blindOrStraddlePosted(player: 1, amount: 1))
        #expect(state.totalPot == 5)

        // Pre-flop.
        state = try state.dealingHoles("AcKcAdKd")
        #expect(state.totalPot == 5)
        state = try state.apply(.checkOrCall(player: 1))
        #expect(state.totalPot == 6)
        state = try state.applying(.checkOrCall(player: 0), .collectBets)
        #expect(state.events.last == .betsCollected(collected: [2, 2], returned: [0, 0]))

        // Flop.
        state = try state.applying(.burnCard(card("2c")))
        state = try state.applying(.dealBoard(card("Ah")), .dealBoard(card("Kh")), .dealBoard(card("As")))
        state = try state.applying(.checkOrCall(player: 0), .checkOrCall(player: 1))

        // Turn.
        state = try state.applying(.burnCard(card("2d")), .dealBoard(card("Ks")), .checkOrCall(player: 0))
        #expect(state.totalPot == 6)
        state = try state.apply(.betOrRaise(player: 1, to: 10))
        #expect(state.totalPot == 16)
        state = try state.apply(.betOrRaise(player: 0, to: 30))
        #expect(state.totalPot == 46)
        state = try state.apply(.checkOrCall(player: 1))
        #expect(state.totalPot == 66)
        state = try state.apply(.collectBets)
        #expect(state.events.last == .betsCollected(collected: [30, 30], returned: [0, 0]))
        #expect(state.totalPot == 66)

        // River.
        state = try state.applying(
            .burnCard(card("2h")), .dealBoard(card("2s")), .checkOrCall(player: 0), .checkOrCall(player: 1)
        )
        #expect(state.checksAndCalls == calls(
            (1, 1), (0, 0), (0, 0), (1, 0), (0, 0), (1, 20), (0, 0), (1, 0)
        ))

        // Showdown.
        state = try state.applying(.showHoleCards(player: 0), .muckHoleCards(player: 1))

        // Teardown.
        state = try state.apply(.pushChips)
        #expect(state.events.last == .chipsPushed(pot: 0, runout: nil, amounts: [66, 0]))
        #expect(state.totalPot == 66)
        state = try state.apply(.pullChips(player: 0))
        #expect(state.events.last == .chipsPulled(player: 0, amount: 66))
        #expect(state.totalPot == 0)
    }

    @Test("total_pot_amount: the forced bets count from the first action, and a fold-out empties it")
    func totalPotAmountFoldOut() throws {
        var state = try HandState(config: .test(.tournament, stacks: [200, 200], antes: [0, 2]))
            .dealingHoles("AsKsAhKh")
        #expect(state.totalPot == 5)
        state = try state.apply(.fold(player: 1))
        #expect(state.totalPot == 0)
    }

    // MARK: showdown_index

    @Test("showdown_index: nil until the last check, then each player in the show order")
    func showdownIndex() throws {
        var state = try HandState(config: .test(.tournament, stacks: [200, 200, 200], automations: Self.postingOnly))
            .dealing("JcJd", "KcKd", "QcQd")
            .applying(.betOrRaise(player: 2, to: 6), .checkOrCall(player: 0), .checkOrCall(player: 1))
        for street in ["AcAdAh", "2c"] {
            state = try state.dealingStreet(street)
                .applying(.checkOrCall(player: 0), .checkOrCall(player: 1), .checkOrCall(player: 2))
        }
        state = try state.dealingStreet("2d").applying(.checkOrCall(player: 0), .checkOrCall(player: 1))

        #expect(state.showdownIndex == nil)
        state = try state.apply(.checkOrCall(player: 2))
        #expect(state.checksAndCalls == calls(
            (0, 5), (1, 4), (0, 0), (1, 0), (2, 0), (0, 0), (1, 0), (2, 0), (0, 0), (1, 0), (2, 0)
        ))
        #expect(state.showdownIndex == 0)
        state = try state.apply(.showHoleCards(player: 0))
        #expect(state.events.last == .holeCardsShown(player: 0, cards: [card("Jc"), card("Jd")]))
        #expect(state.showdownIndex == 1)
        state = try state.apply(.showHoleCards(player: 1))
        #expect(state.events.last == .holeCardsShown(player: 1, cards: [card("Kc"), card("Kd")]))
        #expect(state.showdownIndex == 2)
        state = try state.apply(.muckHoleCards(player: 2))
        #expect(state.events.last == .holeCardsMucked(player: 2))
        #expect(state.showdownIndex == nil)
    }

    // MARK: can_kill_hand

    @Test("can_kill_hand: nobody before the river, then only the hands that can win nothing")
    func canKillHand() throws {
        var state = try HandState(config: .test(.tournament, stacks: [200, 200, 200], automations: Self.postingOnly))
            .dealing("JcJd", "QcQd", "KcKd")
            .applying(.betOrRaise(player: 2, to: 200), .checkOrCall(player: 0), .checkOrCall(player: 1))
        #expect(state.checksAndCalls == calls((0, 199), (1, 198)))
        state = try state.applying(.showHoleCards(player: 2), .showHoleCards(player: 0), .showHoleCards(player: 1))

        // `can_kill_hand()` names nobody; the engine's operation names a player, and any refusal will do here.
        state = try state.dealingStreet("AcAdAh").dealingStreet("2c")
        #expect(throws: EngineError.noHandToKill(player: 0)) { try state.apply(.killHand(player: 0)) }

        state = try state.dealingStreet("2d")
        #expect(state.pendingOperation == .killHand(players: [0, 1]))
        #expect(state.canApply(.killHand(player: 0)))
        #expect(state.canApply(.killHand(player: 1)))
        #expect(throws: EngineError.noHandToKill(player: 2)) { try state.apply(.killHand(player: 2)) }
    }

    // MARK: street

    @Test("street: nil during forced bets, each street in turn, nil from chips pushing on")
    func street() throws {
        var state = HandState(config: .test(.tournament, stacks: [200, 200], antes: [0, 2], automations: []))
        #expect(state.street == nil)

        // Setup.
        state = try state.applying(.postAnte(player: 0), .collectBets, .postBlindOrStraddle(player: 0))
        #expect(state.street == nil)
        state = try state.apply(.postBlindOrStraddle(player: 1))
        #expect(state.events == [
            .antePosted(player: 0, amount: 2),
            .betsCollected(collected: [2, 0], returned: [0, 0]),
            .blindOrStraddlePosted(player: 0, amount: 2),
            .blindOrStraddlePosted(player: 1, amount: 1),
        ])
        #expect(state.street == .preflop)

        // Pre-flop.
        state = try state.dealingHoles("AcKcAdKd").applying(.checkOrCall(player: 1), .checkOrCall(player: 0))
        #expect(state.street == .preflop)
        state = try state.apply(.collectBets)
        #expect(state.events.last == .betsCollected(collected: [2, 2], returned: [0, 0]))
        #expect(state.street == .flop)

        // Flop.
        state = try state.applying(.burnCard(card("2c")))
        state = try state.applying(.dealBoard(card("Ah")), .dealBoard(card("Kh")), .dealBoard(card("As")))
        state = try state.apply(.checkOrCall(player: 0))
        #expect(state.street == .flop)
        state = try state.apply(.checkOrCall(player: 1))
        #expect(state.street == .turn)

        // Turn.
        state = try state.applying(.burnCard(card("2d")), .dealBoard(card("Ks")), .checkOrCall(player: 0))
        #expect(state.street == .turn)
        state = try state.apply(.checkOrCall(player: 1))
        #expect(state.street == .river)

        // River.
        state = try state.applying(.burnCard(card("2h")), .dealBoard(card("2s")), .checkOrCall(player: 0))
        #expect(state.street == .river)
        state = try state.apply(.checkOrCall(player: 1))
        #expect(state.checksAndCalls == calls((1, 1), (0, 0), (0, 0), (1, 0), (0, 0), (1, 0), (0, 0), (1, 0)))
        #expect(state.street == .river)

        // Showdown.
        state = try state.apply(.showHoleCards(player: 0))
        #expect(state.street == .river)
        state = try state.apply(.muckHoleCards(player: 1))
        #expect(state.street == nil)

        // Teardown.
        state = try state.apply(.pushChips)
        #expect(state.events.last == .chipsPushed(pot: 0, runout: nil, amounts: [6, 0]))
        #expect(state.street == nil)
        state = try state.apply(.pullChips(player: 0))
        #expect(state.events.last == .chipsPulled(player: 0, amount: 6))
        #expect(state.street == nil)
    }

    @Test("street: a fold-out with everything automated goes straight to nil")
    func streetFoldOut() throws {
        var state = try HandState(config: .test(.tournament, stacks: [200, 200], antes: [0, 2]))
            .dealingHoles("AsKsAhKh")
        #expect(state.street == .preflop)
        state = try state.apply(.fold(player: 1))
        #expect(state.street == nil)
    }
}
