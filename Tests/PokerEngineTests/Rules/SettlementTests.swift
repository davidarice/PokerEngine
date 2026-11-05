import Testing
@testable import PokerEngine

fileprivate extension HandState {
    /// Finishes this betting round, then deals each street of `board` and checks it through.
    func checkedDown(board: [String] = ["2c7d9h", "Ts", "3s"]) throws -> HandState {
        var state = try checkingDown()
        for street in board {
            state = try state.dealingStreet(street).checkingDown()
        }
        return state
    }
}

@Suite("Settlement")
struct SettlementTests {
    /// Three players limp and check to a river showdown in seat order. Player 0 holds aces, player 1 kings and
    /// player 2 queens; the default board helps nobody.
    private func riverShowdown(
        board: [String] = ["2c7d9h", "Ts", "3s"],
        automations: Set<HandConfig.Automation> = .bookkeeping
    ) throws -> HandState {
        try HandState(config: .test(stacks: [200, 200, 200], automations: automations))
            .dealingHoles("AsKsQsAhKhQh").checkedDown(board: board)
    }

    /// Heads-up, the button shoves before the flop and the big blind calls. Player 0 holds aces, player 1 kings.
    private func allIn(_ mode: HandConfig.Mode = .cashGame) throws -> HandState {
        try HandState(config: .test(mode, stacks: [100, 100])).dealingHoles("AsKsAhKh")
            .applying(.betOrRaise(player: 1, to: 100), .checkOrCall(player: 0))
    }

    /// Everyone is in before the flop and every hand is shown, so the last river card settles the hand. Aces are
    /// all in for 10, kings for 30 and queens for 60, and player 3's jacks cover them all.
    private func sidePotHand(automations: Set<HandConfig.Automation> = .bookkeeping) throws -> HandState {
        try HandState(config: .test(.tournament, stacks: [10, 30, 60, 200], automations: automations))
            .dealingHoles("AsKsQsJsAhKhQhJh")
            .applying(.betOrRaise(player: 2, to: 60), .checkOrCall(player: 3), .checkOrCall(player: 0))
            .applying(.checkOrCall(player: 1))
            .applying(.showHoleCards(player: 2), .showHoleCards(player: 3), .showHoleCards(player: 0))
            .applying(.showHoleCards(player: 1))
            .dealingStreet("2c7d9h").dealingStreet("Ts").dealingStreet("3s")
    }

    /// All in before the flop and shown down: players 0 and 1 hold the same ace-king, player 0 for only 10 chips,
    /// and player 2's four-five can win nothing.
    private func splitMainPotHand() throws -> HandState {
        try HandState(config: .test(.tournament, stacks: [10, 50, 50])).dealingHoles("AsAh4cKsKh5c")
            .applying(.betOrRaise(player: 2, to: 50), .checkOrCall(player: 0), .checkOrCall(player: 1))
            .applying(.showHoleCards(player: 2), .showHoleCards(player: 0), .showHoleCards(player: 1))
            .dealingStreet("2c7d9h").dealingStreet("Ts").dealingStreet("3s")
    }

    // MARK: Hand killing

    @Test("hands that can win nothing are killed by themselves, and the survivor is paid whole (pots OQ13)")
    func automaticKilling() throws {
        let state = try riverShowdown()
            .applying(.showHoleCards(player: 0), .showHoleCards(player: 1), .showHoleCards(player: 2))
        #expect(state.events.suffix(4) == [
            .handKilled(player: 1),
            .handKilled(player: 2),
            .chipsPushed(pot: 0, runout: nil, amounts: [6, 0, 0]),
            .chipsPulled(player: 0, amount: 6),
        ])
        #expect(state.statuses == [.active, .killed, .killed])
        #expect(state.holeCards[1].isEmpty && state.holeCards[2].isEmpty)
        #expect(state.stacks == [204, 198, 198])
    }

    @Test("settlement is logged under the show that set it off, each step marked automated")
    func settlementLog() throws {
        let state = try riverShowdown().applying(.showHoleCards(player: 0), .showHoleCards(player: 1))
        let last = state.operations.count
        let settled = try state.applying(.showHoleCards(player: 2))
        #expect(settled.log.suffix(5) == [
            LogEntry(event: .holeCardsShown(player: 2, cards: cards("QsQh")), isAutomated: false, operationIndex: last),
            LogEntry(event: .handKilled(player: 1), isAutomated: true, operationIndex: last),
            LogEntry(event: .handKilled(player: 2), isAutomated: true, operationIndex: last),
            LogEntry(
                event: .chipsPushed(pot: 0, runout: nil, amounts: [6, 0, 0]), isAutomated: true, operationIndex: last
            ),
            LogEntry(event: .chipsPulled(player: 0, amount: 6), isAutomated: true, operationIndex: last),
        ])
    }

    @Test("without automation the dealer kills each listed hand, in any order")
    func manualKilling() throws {
        var state = try riverShowdown(automations: .bookkeeping.subtracting([.handKilling]))
            .applying(.showHoleCards(player: 0), .showHoleCards(player: 1), .showHoleCards(player: 2))
        #expect(state.pendingOperation == .killHand(players: [1, 2]))
        state = try state.applying(.killHand(player: 2))
        #expect(state.events.last == .handKilled(player: 2))
        #expect(state.pendingOperation == .killHand(players: [1]))
        #expect(state.statuses == [.active, .active, .killed])
        state = try state.applying(.killHand(player: 1))
        #expect(state.isHandComplete)
        #expect(state.stacks == [204, 198, 198])
    }

    @Test("only a hand listed for killing can be killed")
    func noHandToKill() throws {
        let showdown = try riverShowdown(automations: .bookkeeping.subtracting([.handKilling]))
        #expect(throws: EngineError.noHandToKill(player: 1)) { try showdown.apply(.killHand(player: 1)) }
        let killing = try showdown
            .applying(.showHoleCards(player: 0), .showHoleCards(player: 1), .showHoleCards(player: 2))
        #expect(throws: EngineError.noHandToKill(player: 0)) { try killing.apply(.killHand(player: 0)) }
    }

    @Test("a hand that ties the best shown hand is not killed")
    func tiedHandSurvives() throws {
        let state = try riverShowdown(board: ["TdJdQd", "Kd", "Ad"])
            .applying(.showHoleCards(player: 0), .showHoleCards(player: 1), .showHoleCards(player: 2))
        #expect(state.statuses == [.active, .active, .active])
        #expect(state.events.suffix(4) == [
            .chipsPushed(pot: 0, runout: 0, amounts: [2, 2, 2]),
            .chipsPulled(player: 0, amount: 2),
            .chipsPulled(player: 1, amount: 2),
            .chipsPulled(player: 2, amount: 2),
        ])
    }

    @Test("a hand that can still win a side pot is not killed, whatever beats it in the main pot")
    func sidePotHandSurvives() throws {
        let state = try sidePotHand()
        #expect(state.statuses == [.active, .active, .active, .killed])
    }

    @Test("a hand kept face down on the river plays the board, so a shown hand that beats the board kills it (A13)")
    func faceDownHandIsKilled() throws {
        let state = try riverShowdown().applying(
            .showHoleCards(player: 0), .showHoleCards(player: 1, cards: []), .showHoleCards(player: 2, cards: [])
        )
        #expect(state.statuses == [.active, .killed, .killed])
        #expect(state.stacks == [204, 198, 198])
    }

    // MARK: Pots

    @Test("a mucked player drops out of every pot's eligible players")
    func muckLosesEligibility() throws {
        let state = try riverShowdown()
        #expect(state.pots == [Pot(amount: 6, eligiblePlayers: [0, 1, 2])])
        #expect(try state.applying(.muckHoleCards(player: 0)).pots == [Pot(amount: 6, eligiblePlayers: [1, 2])])
    }

    @Test("the main pot is pushed first, then each side pot, to the best hand eligible for it")
    func sidePotsPushInOrder() throws {
        let state = try sidePotHand()
        #expect(state.events.suffix(7) == [
            HandEvent.handKilled(player: 3),
            .chipsPushed(pot: 0, runout: 0, amounts: [40, 0, 0, 0]),
            .chipsPushed(pot: 1, runout: 0, amounts: [0, 60, 0, 0]),
            .chipsPushed(pot: 2, runout: 0, amounts: [0, 0, 60, 0]),
            .chipsPulled(player: 0, amount: 40),
            .chipsPulled(player: 1, amount: 60),
            .chipsPulled(player: 2, amount: 60),
        ])
        #expect(state.stacks == [40, 60, 60, 140])
    }

    @Test("folded chips and dead antes go to the winner")
    func foldedChipsAndDeadAntes() throws {
        // The big blind's 2-chip ante is dead money, and player 0 folds its small blind.
        let state = try HandState(config: .test(.tournament, stacks: [200, 200, 200], antes: [0, 2]))
            .dealingHoles("AsKsQsAhKhQh")
            .applying(.betOrRaise(player: 2, to: 6), .fold(player: 0), .checkOrCall(player: 1))
            .checkedDown()
        #expect(state.pots == [Pot(amount: 15, eligiblePlayers: [1, 2])])
        let settled = try state.applying(.showHoleCards(player: 1), .showHoleCards(player: 2))
        #expect(settled.events.suffix(3) == [
            .handKilled(player: 2),
            .chipsPushed(pot: 0, runout: nil, amounts: [0, 15, 0]),
            .chipsPulled(player: 1, amount: 15),
        ])
        #expect(settled.stacks == [199, 207, 194])
    }

    @Test("a tied pot is split evenly, and the odd chip goes to the lowest-index winner")
    func splitPotOddChip() throws {
        // Player 0's small blind is dead, leaving 5 chips between players 1 and 2.
        let state = try HandState(config: .test(stacks: [200, 200, 200])).dealingHoles("AsKsQsAhKhQh")
            .applying(.checkOrCall(player: 2), .fold(player: 0))
            .checkedDown(board: ["TdJdQd", "Kd", "Ad"])
            .applying(.showHoleCards(player: 1), .showHoleCards(player: 2))
        #expect(state.events.suffix(3) == [
            .chipsPushed(pot: 0, runout: 0, amounts: [0, 3, 2]),
            .chipsPulled(player: 1, amount: 3),
            .chipsPulled(player: 2, amount: 2),
        ])
    }

    @Test("on a three-way tie, the whole remainder goes to the lowest-index winner (A12)")
    func threeWayOddChips() throws {
        // Player 1 folds the big blind: 8 chips among three players is 2 each with 2 over.
        let state = try HandState(config: .test(stacks: [200, 200, 200, 200])).dealingHoles("AsKsQsJsAhKhQhJh")
            .applying(.checkOrCall(player: 2), .checkOrCall(player: 3), .checkOrCall(player: 0), .fold(player: 1))
            .checkedDown(board: ["TdJdQd", "Kd", "Ad"])
            .applying(.showHoleCards(player: 0), .showHoleCards(player: 2), .showHoleCards(player: 3))
        #expect(state.events.suffix(4) == [
            .chipsPushed(pot: 0, runout: 0, amounts: [4, 0, 2, 2]),
            .chipsPulled(player: 0, amount: 4),
            .chipsPulled(player: 2, amount: 2),
            .chipsPulled(player: 3, amount: 2),
        ])
    }

    @Test("a tied main pot is split while the side pot still goes to its own winner")
    func splitMainPotBesideSidePot() throws {
        let state = try splitMainPotHand()
        #expect(state.events.suffix(5) == [
            .handKilled(player: 2),
            .chipsPushed(pot: 0, runout: 0, amounts: [15, 15, 0]),
            .chipsPushed(pot: 1, runout: 0, amounts: [0, 80, 0]),
            .chipsPulled(player: 0, amount: 15),
            .chipsPulled(player: 1, amount: 95),
        ])
        #expect(state.stacks == [15, 95, 0])
    }

    @Test("a heads-up all-in shown down pays the survivor on the single-player path, with no runout (pots OQ13)")
    func singleSurvivorPath() throws {
        let state = try allIn(.tournament).applying(.showHoleCards(player: 1), .showHoleCards(player: 0))
            .dealingStreet("2c3d4h").dealingStreet("7s").dealingStreet("9h")
        #expect(state.events.suffix(3) == [
            .handKilled(player: 1),
            .chipsPushed(pot: 0, runout: nil, amounts: [200, 0]),
            .chipsPulled(player: 0, amount: 200),
        ])
        #expect(state.stacks == [200, 0])
    }

    @Test("unshown cash hands play the board, so the pot is chopped whatever they hold (A13, pots OQ11)")
    func unshownHandsPlayTheBoard() throws {
        let state = try HandState(config: .test(stacks: [100, 100])).dealingHoles("Ac7cAd2d")
            .checkedDown(board: ["KsQsJh", "4d", "3c"])
            .applying(.showHoleCards(player: 0, cards: []), .showHoleCards(player: 1, cards: []))
        #expect(state.statuses == [.active, .active])
        #expect(state.events.suffix(3) == [
            .chipsPushed(pot: 0, runout: 0, amounts: [2, 2]),
            .chipsPulled(player: 0, amount: 2),
            .chipsPulled(player: 1, amount: 2),
        ])
        #expect(state.stacks == [100, 100])
    }

    // MARK: Manual pushing and pulling

    @Test("from chips pushing on the street is nil and the pots are frozen: amounts drop, emptied pots stay listed")
    func frozenPots() throws {
        var state = try sidePotHand(automations: .bookkeeping.subtracting([.chipsPushing]))
        #expect(state.street == nil)
        #expect(state.pendingOperation == .pushChips(pot: 0, runout: 0))
        #expect(state.pots == [
            Pot(amount: 40, eligiblePlayers: [0, 1, 2]),
            Pot(amount: 60, eligiblePlayers: [1, 2]),
            Pot(amount: 60, eligiblePlayers: [2]),
        ])
        state = try state.applying(.pushChips)
        #expect(state.pendingOperation == .pushChips(pot: 1, runout: 0))
        #expect(state.bets == [40, 0, 0, 0])
        #expect(state.totalPot == 160)
        #expect(state.pots == [
            Pot(amount: 0, eligiblePlayers: [0, 1, 2]),
            Pot(amount: 60, eligiblePlayers: [1, 2]),
            Pot(amount: 60, eligiblePlayers: [2]),
        ])
        state = try state.applying(.pushChips)
        #expect(state.pendingOperation == .pushChips(pot: 2, runout: 0))
        #expect(state.bets == [40, 60, 0, 0])
        state = try state.applying(.pushChips)
        #expect(state.pots == [
            Pot(amount: 0, eligiblePlayers: [0, 1, 2]),
            Pot(amount: 0, eligiblePlayers: [1, 2]),
            Pot(amount: 0, eligiblePlayers: [2]),
        ])
        #expect(state.isHandComplete)
        #expect(state.totalPot == 0)
    }

    @Test("without automation, winners pull their chips in any order")
    func manualPulls() throws {
        var state = try sidePotHand(automations: .bookkeeping.subtracting([.chipsPulling]))
        #expect(state.pendingOperation == .pullChips(players: [0, 1, 2]))
        #expect(state.bets == [40, 60, 60, 0])
        #expect(state.stacks == [0, 0, 0, 140])
        state = try state.applying(.pullChips(player: 2))
        #expect(state.events.last == .chipsPulled(player: 2, amount: 60))
        #expect(state.pendingOperation == .pullChips(players: [0, 1]))
        #expect(state.bets == [40, 60, 0, 0])
        #expect(state.stacks == [0, 0, 60, 140])
        #expect(state.totalPot == 100)
        state = try state.applying(.pullChips(player: 0), .pullChips(player: 1))
        #expect(state.isHandComplete)
        #expect(state.stacks == [40, 60, 60, 140])
    }

    @Test("chips can be pushed only while a pot is pending")
    func noChipsToPush() throws {
        let showdown = try riverShowdown()
        #expect(throws: EngineError.noChipsToPush) { try showdown.apply(.pushChips) }
        let pulling = try sidePotHand(automations: .bookkeeping.subtracting([.chipsPulling]))
        #expect(throws: EngineError.noChipsToPush) { try pulling.apply(.pushChips) }
    }

    @Test("chips can be pulled only by a player with chips to pull, once pushing is over")
    func noChipsToPull() throws {
        let pushing = try sidePotHand(automations: .bookkeeping.subtracting([.chipsPushing, .chipsPulling]))
        #expect(throws: EngineError.noChipsToPull(player: 0)) { try pushing.apply(.pullChips(player: 0)) }
        let pulling = try pushing.applying(.pushChips, .pushChips, .pushChips)
        #expect(throws: EngineError.noChipsToPull(player: 3)) { try pulling.apply(.pullChips(player: 3)) }
        let pulled = try pulling.applying(.pullChips(player: 0))
        #expect(throws: EngineError.noChipsToPull(player: 0)) { try pulled.apply(.pullChips(player: 0)) }
    }

    // MARK: Fold-outs

    @Test("a fold-out pushes the pot to the last player, and the pull brings their own bet back with it (A8)")
    func foldOutSettles() throws {
        let state = try HandState(config: .test(stacks: [200, 200, 200])).dealingHoles("AsKsQsAhKhQh")
            .applying(.betOrRaise(player: 2, to: 6), .fold(player: 0), .fold(player: 1))
        #expect(state.events.suffix(3) == [
            .betsCollected(collected: [1, 2, 0], returned: [0, 0, 0]),
            .chipsPushed(pot: 0, runout: nil, amounts: [0, 0, 3]),
            .chipsPulled(player: 2, amount: 9),
        ])
        #expect(state.bets == [0, 0, 0])
        #expect(state.stacks == [199, 198, 203])
        #expect(state.pots == [Pot(amount: 0, eligiblePlayers: [2])])
        #expect(state.totalPot == 0)
        #expect(state.street == nil)
        #expect(state.foldedStatus)
    }

    @Test("a fold-out winner's returned bet is not counted in won (A8)")
    func foldOutWon() throws {
        let state = try HandState(config: .test(stacks: [200, 200, 200])).dealingHoles("AsKsQsAhKhQh")
            .applying(.betOrRaise(player: 2, to: 6), .fold(player: 0), .fold(player: 1))
        #expect(state.results?[2].won == 3)
        #expect(state.results?[2].net == 3)
    }

    @Test("a manual fold-out waits for the push and the pull, on the single-player path")
    func manualFoldOut() throws {
        let config = HandConfig.test(
            stacks: [200, 200, 200], automations: .bookkeeping.subtracting([.chipsPushing, .chipsPulling])
        )
        var state = try HandState(config: config).dealingHoles("AsKsQsAhKhQh")
            .applying(.betOrRaise(player: 2, to: 6), .fold(player: 0), .fold(player: 1))
        #expect(state.pendingOperation == .pushChips(pot: 0, runout: nil))
        state = try state.applying(.pushChips)
        #expect(state.bets == [0, 0, 9])
        #expect(state.pendingOperation == .pullChips(players: [2]))
        state = try state.applying(.pullChips(player: 2))
        #expect(state.stacks == [199, 198, 203])
        #expect(state.isHandComplete)
    }

    // MARK: Results

    @Test("results are nil until the hand is complete")
    func resultsWaitForCompletion() throws {
        let pulling = try riverShowdown(automations: .bookkeeping.subtracting([.chipsPulling]))
            .applying(.showHoleCards(player: 0), .showHoleCards(player: 1), .showHoleCards(player: 2))
        #expect(pulling.pendingOperation == .pullChips(players: [0]))
        #expect(pulling.results == nil)
        #expect(try pulling.applying(.pullChips(player: 0)).results != nil)
    }

    @Test("results give every player's net, winnings, status, scanned cards and whether they were shown")
    func results() throws {
        let state = try HandState(config: .test(stacks: [200, 200, 200, 200])).dealingHoles("AsKsQsJsAhKhQhJh")
            .checkingDown().dealingStreet("2c7d9h").applying(.checkOrCall(player: 0), .checkOrCall(player: 1))
            .applying(.checkOrCall(player: 2), .fold(player: 3))
            .checkedDown(board: ["Ts", "3s"])
            .applying(.showHoleCards(player: 0), .showHoleCards(player: 1), .muckHoleCards(player: 2))
        #expect(state.results == [
            PlayerResult(player: 0, net: 6, won: 8, status: .active, holeCards: [up("As"), up("Ah")], shown: true),
            PlayerResult(player: 1, net: -2, won: 0, status: .killed, holeCards: [up("Ks"), up("Kh")], shown: true),
            PlayerResult(
                player: 2, net: -2, won: 0, status: .mucked, holeCards: [down("Qs"), down("Qh")], shown: false
            ),
            PlayerResult(
                player: 3, net: -2, won: 0, status: .folded, holeCards: [down("Js"), down("Jh")], shown: false
            ),
        ])
    }

    @Test("won adds up every pot a player was pushed")
    func resultsAcrossPots() throws {
        let state = try splitMainPotHand()
        #expect(state.results?.map(\.won) == [15, 95, 0])
        #expect(state.results?.map(\.net) == [5, 45, -50])
    }

    @Test("results keep cards in deal order with reveals filled in, while the live cards keep the listed order")
    func resultsWithReveals() throws {
        let state = try HandState(config: .test(stacks: [200, 200])).dealingHoles("??KsAhKh").checkedDown()
            .applying(.showHoleCards(player: 0, cards: cards("AhAd")), .muckHoleCards(player: 1))
        #expect(state.holeCards[0] == [up("Ah"), up("Ad")])
        #expect(state.results?[0].holeCards == [up("Ad"), up("Ah")])
        #expect(state.results?[0].shown == true)
    }

    @Test("a card never revealed stays unknown in the results, and a reveal fills the first unknown slot")
    func resultsWithUnrevealedCard() throws {
        let holes = try HandState(config: .test(stacks: [200, 200])).dealingHoles("??Ks??Kh").checkedDown()
        let listedFirst = try holes.applying(.showHoleCards(player: 0, cards: cards("Ad")), .showHoleCards(player: 1))
        #expect(listedFirst.results?[0].holeCards == [up("Ad"), down("??")])
        #expect(listedFirst.results?[0].shown == false)
        // The list cannot say which slot a card is in: an unknown entry is refused (B14).
        #expect(throws: EngineError.cannotShowUnknownCard(player: 0)) {
            try holes.apply(.showHoleCards(player: 0, cards: cards("??Ad")))
        }
    }

    @Test("results keep a card the river forgot, face down, though the live hand has lost it (A13)")
    func resultsKeepForgottenCards() throws {
        let state = try riverShowdown().applying(
            .showHoleCards(player: 0, cards: cards("Ah")), .showHoleCards(player: 1, cards: []),
            .showHoleCards(player: 2, cards: [])
        )
        #expect(state.holeCards[0] == [up("Ah"), down("??")])
        #expect(state.results?.map(\.holeCards) == [
            [down("As"), up("Ah")], [down("Ks"), down("Kh")], [down("Qs"), down("Qh")],
        ])
    }

    @Test("results mark each card shown at any point, so both cards count even if never face up together")
    func resultsShownAtAnyPoint() throws {
        let state = try allIn()
            .applying(.selectRunoutCount(player: 0, count: nil), .selectRunoutCount(player: 1, count: nil))
            .applying(.showHoleCards(player: 1, cards: []), .showHoleCards(player: 0, cards: cards("As")))
            .dealingStreet("2c7d9h")
            .applying(.showHoleCards(player: 1, cards: []), .showHoleCards(player: 0, cards: cards("Ah")))
            .dealingStreet("Ts")
            .applying(.showHoleCards(player: 1, cards: []), .showHoleCards(player: 0, cards: []))
            .dealingStreet("3s")
            .applying(.showHoleCards(player: 1, cards: []), .showHoleCards(player: 0, cards: []))
        #expect(state.holeCards[0] == [down("??"), down("??")])
        #expect(state.results?[0].holeCards == [up("As"), up("Ah")])
        #expect(state.results?[0].shown == true)
    }

    @Test("results count a card as shown even if a later re-ask turned it back down")
    func resultsShownIsMonotonic() throws {
        let kept: [HandOperation] = [
            .showHoleCards(player: 1, cards: []), .showHoleCards(player: 0, cards: cards("Ah")),
        ]
        let river = try allIn()
            .applying(.selectRunoutCount(player: 0, count: nil), .selectRunoutCount(player: 1, count: nil))
            .applying(kept).dealingStreet("2c7d9h")
            .applying(kept).dealingStreet("Ts")
            .applying(kept).dealingStreet("3s")
        let state = try river.applying(.showHoleCards(player: 1, cards: []), .showHoleCards(player: 0, cards: []))
        #expect(state.holeCards[0] == [down("??"), down("??")])
        #expect(state.results?[0].holeCards == [down("As"), up("Ah")])
        #expect(state.results?[0].shown == false)
    }

    // MARK: Completion

    @Test("pendingOperation is nil exactly when the hand is complete, at every step of a hand played by hand")
    func pendingOperationUntilComplete() throws {
        var state = HandState(config: .test(stacks: [200, 200], automations: []))
        let operations: [HandOperation] = [
            .postBlindOrStraddle(player: 0), .postBlindOrStraddle(player: 1),
            .dealHole(player: 0, card: card("As")), .dealHole(player: 1, card: card("Ks")),
            .dealHole(player: 0, card: card("Ah")), .dealHole(player: 1, card: card("Kh")),
            .checkOrCall(player: 1), .checkOrCall(player: 0), .collectBets,
            .burnCard(.unknown), .dealBoard(card("2c")), .dealBoard(card("7d")), .dealBoard(card("9h")),
            .checkOrCall(player: 0), .checkOrCall(player: 1),
            .burnCard(.unknown), .dealBoard(card("Ts")),
            .checkOrCall(player: 0), .checkOrCall(player: 1),
            .burnCard(.unknown), .dealBoard(card("3s")),
            .checkOrCall(player: 0), .checkOrCall(player: 1),
            .showHoleCards(player: 0), .showHoleCards(player: 1),
            .killHand(player: 1), .pushChips, .pullChips(player: 0),
        ]
        for operation in operations {
            #expect(state.pendingOperation != nil, "\(operation)")
            #expect(!state.isHandComplete, "\(operation)")
            state = try state.apply(operation)
        }
        #expect(state.pendingOperation == nil)
        #expect(state.isHandComplete)
        #expect(state.stacks == [202, 198])
    }

    @Test("a complete hand refuses everything but a show or a muck with handComplete, even for a bad player index")
    func handComplete() throws {
        let state = try riverShowdown()
            .applying(.showHoleCards(player: 0), .showHoleCards(player: 1), .showHoleCards(player: 2))
        for operation: HandOperation in [
            .postAnte(player: 0), .collectBets, .postBlindOrStraddle(player: 0), .burnCard(.unknown),
            .dealHole(player: 0, card: card("2d")), .dealBoard(card("2d")), .fold(player: 0), .checkOrCall(player: 0),
            .betOrRaise(player: 0, to: 4), .selectRunoutCount(player: 0, count: 1), .killHand(player: 0), .pushChips,
            .pullChips(player: 0), .fold(player: 9),
        ] {
            #expect(throws: EngineError.handComplete, "\(operation)") { try state.apply(operation) }
        }
        #expect(state.canApply(.showHoleCards(player: 0)))
        #expect(throws: EngineError.mustShowAllCards(player: 0)) { try state.apply(.muckHoleCards(player: 0)) }
    }

    @Test("while chips wait to be pushed or pulled the hand is not over, so an operation gets its own refusal")
    func operationsDuringPushingAndPulling() throws {
        let automations: Set<HandConfig.Automation> = .bookkeeping.subtracting([.chipsPushing, .chipsPulling])
        let pushing = try HandState(config: .test(stacks: [200, 200, 200], automations: automations))
            .dealingHoles("AsKsQsAhKhQh")
            .applying(.betOrRaise(player: 2, to: 6), .fold(player: 0), .fold(player: 1))
        #expect(pushing.pendingOperation == .pushChips(pot: 0, runout: nil))
        let pulling = try pushing.applying(.pushChips)
        #expect(pulling.pendingOperation == .pullChips(players: [2]))
        for state in [pushing, pulling] {
            #expect(!state.isHandComplete)
            #expect(throws: EngineError.noActionExpected) { try state.apply(.fold(player: 2)) }
            #expect(throws: EngineError.noBetCollectionExpected) { try state.apply(.collectBets) }
            #expect(throws: EngineError.noDealExpected(.burn)) { try state.apply(.burnCard(.unknown)) }
        }
    }

    // MARK: Abandoned pots (B2)

    @Test("the straddler cannot fold the option once the only opponent is all in below the blinds (B2, M2 soak)")
    func straddlerCannotAbandonBlinds() throws {
        let state = try HandState(config: .test(stacks: [100, 100, 100, 3], blinds: [2, 4, 8]))
            .dealingHoles("AsKsQsJsAhKhQhJh")
            .applying(.checkOrCall(player: 3), .fold(player: 0), .fold(player: 1))
        // Nothing is collected yet: the pot a fold would abandon is made of bets still in front of the players.
        #expect(state.pots == [])
        #expect(state.bets == [2, 4, 8, 3])
        #expect(state.legalActions == LegalActions(
            player: 2, canFold: false, toCall: 0, betOrRaise: .unavailable(.noOpponentCanRespond)
        ))
        #expect(throws: EngineError.wouldAbandonPot(player: 2, pot: 1)) { try state.apply(.fold(player: 2)) }
        #expect(!state.canApply(.fold(player: 2)))
        #expect(state.canApply(.checkOrCall(player: 2)))
    }

    @Test("in a tournament the free fold is refused first, so the pot is never the reason (B2)")
    func freeFoldRefusalComesFirst() throws {
        let state = try HandState(config: .test(.tournament, stacks: [100, 100, 100, 3], blinds: [2, 4, 8]))
            .dealingHoles("AsKsQsJsAhKhQhJh")
            .applying(.checkOrCall(player: 3), .fold(player: 0), .fold(player: 1))
        #expect(throws: EngineError.cannotFoldWhenCheckIsFree(player: 2)) { try state.apply(.fold(player: 2)) }
    }

    @Test("a free fold by the last player in for a side pot is refused (B2, pots OQ8)")
    func freeFoldStrandsSidePot() throws {
        let state = try HandState(config: .test(stacks: [10, 100, 100])).dealingHoles("AsKsQsAhKhQh")
            .applying(.betOrRaise(player: 2, to: 50), .checkOrCall(player: 0), .checkOrCall(player: 1))
            .dealingStreet("2c7d9h").applying(.fold(player: 1))
        #expect(state.pots == [Pot(amount: 30, eligiblePlayers: [0, 2]), Pot(amount: 80, eligiblePlayers: [2])])
        #expect(state.legalActions?.canFold == false)
        #expect(throws: EngineError.wouldAbandonPot(player: 2, pot: 1)) { try state.apply(.fold(player: 2)) }
    }

    @Test("a fold stands while a player still to act can call the layer it leaves; the last of them must call (B2)")
    func refusalLandsOnLaterPlayer() throws {
        // Both live posts are above the big blind, so once they fold only a call covers the top layer.
        let posts = try HandState(config: .test(stacks: [200, 200, 200, 200], blinds: [1, 2, -3, -3]))
            .dealingHoles("AsKsQsJsAhKhQhJh").applying(.fold(player: 2))
        #expect(posts.legalActions?.canFold == true)
        let state = try posts.applying(.fold(player: 3))
        #expect(state.legalActions?.canFold == false)
        #expect(throws: EngineError.wouldAbandonPot(player: 0, pot: 1)) { try state.apply(.fold(player: 0)) }
        #expect(!state.canApply(.fold(player: 0)))
        let called = try state.applying(.checkOrCall(player: 0), .checkOrCall(player: 1))
        #expect(called.pots == [Pot(amount: 12, eligiblePlayers: [0, 1])])
    }

    @Test("a small blind too short for the top layer still may not fold: its call gives the big blind a turn (B2)")
    func refusedPlayerCannotReachTheLayer() throws {
        let state = try HandState(config: .test(stacks: [2, 200, 200, 200], blinds: [1, 2, -3, -3]))
            .dealingHoles("AsKsQsJsAhKhQhJh").applying(.fold(player: 2), .fold(player: 3))
        #expect(throws: EngineError.wouldAbandonPot(player: 0, pot: 1)) { try state.apply(.fold(player: 0)) }
        let called = try state.applying(.checkOrCall(player: 0), .checkOrCall(player: 1))
        #expect(called.pots == [Pot(amount: 8, eligiblePlayers: [0, 1]), Pot(amount: 3, eligiblePlayers: [1])])
    }

    @Test("unequal live posts: the uncalled top of the bigger one comes back, and the rest still needs a caller (B2)")
    func unequalLivePosts() throws {
        let state = try HandState(config: .test(stacks: [200, 200, 200, 200], blinds: [1, 2, -4, -3]))
            .dealingHoles("AsKsQsJsAhKhQhJh").applying(.fold(player: 2), .fold(player: 3))
        #expect(throws: EngineError.wouldAbandonPot(player: 0, pot: 1)) { try state.apply(.fold(player: 0)) }
        let called = try state.applying(.checkOrCall(player: 0), .checkOrCall(player: 1))
        #expect(called.pots == [Pot(amount: 15, eligiblePlayers: [0, 1])])
    }

    @Test("a fold facing a large call is accepted while later players can still cover the layers (B2)")
    func foldAcceptedAtLargeCall() throws {
        let state = try HandState(config: .test(stacks: [200, 200, 200, 100], blinds: [1, 2, -150, -3]))
            .dealingHoles("AsKsQsJsAhKhQhJh").applying(.fold(player: 2))
        #expect(state.legalActions?.toCall == 97)
        #expect(state.legalActions?.canFold == true)
        let folded = try state.applying(.fold(player: 3))
        #expect(throws: EngineError.wouldAbandonPot(player: 0, pot: 1)) { try folded.apply(.fold(player: 0)) }
    }

    @Test("a fold is refused at once when nobody still to act has the chips to reach the layer (B2)")
    func shortPlayersCannotCover() throws {
        let state = try HandState(config: .test(stacks: [2, 2, 200, 200], blinds: [1, 2, -3, -3]))
            .dealingHoles("AsKsQsJsAhKhQhJh").applying(.fold(player: 2))
        #expect(state.legalActions?.canFold == false)
        #expect(throws: EngineError.wouldAbandonPot(player: 3, pot: 1)) { try state.apply(.fold(player: 3)) }
        #expect(!state.canApply(.fold(player: 3)))
    }

    @Test("the folder is not one of the callers: a fold stands when only its own chips could match a folded post (B2)")
    func folderIsNotACaller() throws {
        // Nobody left can reach player 2's 10, so 8 of it comes back. A call by player 3 would match it instead,
        // and leave a layer with nobody eligible.
        let state = try HandState(config: .test(stacks: [2, 2, 200, 200], blinds: [1, 2, -10, 0]))
            .dealingHoles("AsKsQsJsAhKhQhJh").applying(.fold(player: 2))
        #expect(state.legalActions?.canFold == true)
        let called = try state.applying(.fold(player: 3), .checkOrCall(player: 0))
        #expect(called.pots == [Pot(amount: 6, eligiblePlayers: [0, 1])])
        #expect(called.stacks == [0, 0, 198, 200])
    }

    @Test("a fold is refused mid-round, with players still to act, if none of them can reach the layer (B2)")
    func midRoundRefusal() throws {
        let state = try HandState(config: .test(stacks: [3, 3, 100, 100, 3], blinds: [1, 2, -5, -4, 0]))
            .dealingHoles("AsKsQsJsTsAhKhQhJhTh").applying(.fold(player: 2))
        #expect(state.actor == 3)
        #expect(state.legalActions?.canFold == false)
        #expect(throws: EngineError.wouldAbandonPot(player: 3, pot: 1)) { try state.apply(.fold(player: 3)) }
    }

    @Test("once the top layer is called the last opponent may fold, and the caller's bet stays uncollected (B2)")
    func foldAfterTheLayerIsCalled() throws {
        let config = HandConfig.test(
            stacks: [100, 100, 100, 100, 100], blinds: [1, 2, -5, -4, 0],
            automations: .bookkeeping.subtracting([.chipsPushing])
        )
        let state = try HandState(config: config).dealingHoles("AsKsQsJsTsAhKhQhJhTh")
            .applying(.fold(player: 2), .fold(player: 3), .fold(player: 4))
        #expect(throws: EngineError.wouldAbandonPot(player: 0, pot: 1)) { try state.apply(.fold(player: 0)) }
        let settled = try state.applying(.checkOrCall(player: 0), .fold(player: 1))
        #expect(settled.pots == [Pot(amount: 11, eligiblePlayers: [0])])
        #expect(settled.bets == [5, 0, 0, 0, 0])
    }

    @Test("the last player eligible for any pot cannot muck (B2, PokerKit's test_unknown_showdown)")
    func lastPlayerCannotMuck() throws {
        let state = try riverShowdown().applying(.muckHoleCards(player: 0), .muckHoleCards(player: 1))
        #expect(throws: EngineError.wouldAbandonPot(player: 2, pot: 0)) { try state.apply(.muckHoleCards(player: 2)) }
        #expect(!state.canApply(.muckHoleCards(player: 2)))
        #expect(state.canApply(.showHoleCards(player: 2)))
    }

    @Test("the last contender for a side pot cannot muck, though the main pot still has a player (B2, pots OQ7)")
    func lastSidePotPlayerCannotMuck() throws {
        let state = try HandState(config: .test(.tournament, stacks: [10, 100, 100])).dealingHoles("AsKsQsAhKhQh")
            .applying(.betOrRaise(player: 2, to: 50), .checkOrCall(player: 0), .checkOrCall(player: 1))
            .checkedDown()
            .applying(.showHoleCards(player: 0), .muckHoleCards(player: 1))
        #expect(state.pots == [Pot(amount: 30, eligiblePlayers: [0, 2]), Pot(amount: 80, eligiblePlayers: [2])])
        #expect(throws: EngineError.wouldAbandonPot(player: 2, pot: 1)) { try state.apply(.muckHoleCards(player: 2)) }
    }

    // MARK: Concessions (A15, B3)

    @Test("a concession at an all-in still deals the next street, then pays as a fold-out (A15, pots OQ10)")
    func concessionDealsNextStreet() throws {
        var state = try allIn(.tournament).applying(.muckHoleCards(player: 1), .showHoleCards(player: 0))
        #expect(state.pendingOperation == .burnCard(street: .flop, runout: 0))
        #expect(!state.isHandComplete)
        state = try state.dealingStreet("2c7d9h")
        #expect(state.events.suffix(2) == [
            .chipsPushed(pot: 0, runout: nil, amounts: [200, 0]),
            .chipsPulled(player: 0, amount: 200),
        ])
        #expect(state.boards == [cards("2c7d9h")])
        #expect(state.foldedStatus)
    }

    @Test("a concession leaving a player with chips behind plays out the same way (B3)")
    func concessionWithChipsBehind() throws {
        // Player 0 covers player 1, so the rest of player 0's stack comes back.
        let conceded = try HandState(config: .test(.tournament, stacks: [200, 50, 200])).dealingHoles("AsKsQsAhKhQh")
            .applying(.fold(player: 2), .betOrRaise(player: 0, to: 200), .checkOrCall(player: 1))
            .applying(.muckHoleCards(player: 1))
        #expect(conceded.stacks == [150, 0, 200])
        #expect(throws: EngineError.wouldAbandonPot(player: 0, pot: 0)) {
            try conceded.apply(.muckHoleCards(player: 0))
        }
        var state = try conceded.applying(.showHoleCards(player: 0))
        #expect(state.pendingOperation == .burnCard(street: .flop, runout: 0))
        state = try state.dealingStreet("2c7d9h")
        #expect(state.events.suffix(2) == [
            .chipsPushed(pot: 0, runout: nil, amounts: [100, 0, 0]),
            .chipsPulled(player: 0, amount: 100),
        ])
        #expect(state.stacks == [250, 0, 200])
        #expect(state.foldedStatus)
    }

    @Test("a muck at a three-way all-in leaves two hands to run out and be evaluated, so it is no fold-out")
    func mucksLeavingTwoPlayersPlayOn() throws {
        var state = try HandState(config: .test(.tournament, stacks: [100, 100, 100])).dealingHoles("AsKsQsAhKhQh")
            .applying(.betOrRaise(player: 2, to: 100), .checkOrCall(player: 0), .checkOrCall(player: 1))
            .applying(.muckHoleCards(player: 2), .showHoleCards(player: 0), .showHoleCards(player: 1))
        #expect(state.pots == [Pot(amount: 300, eligiblePlayers: [0, 1])])
        state = try state.dealingStreet("2c7d9h").dealingStreet("Ts")
        #expect(state.pendingOperation == .burnCard(street: .river, runout: 0))
        state = try state.dealingStreet("3s")
        #expect(state.stacks == [300, 0, 0])
        #expect(!state.foldedStatus)
    }

    @Test("a hand that all but one player muck at a river showdown is not a fold-out")
    func muckedDownIsNotFoldOut() throws {
        let state = try riverShowdown()
            .applying(.muckHoleCards(player: 0), .muckHoleCards(player: 1), .showHoleCards(player: 2))
        #expect(state.isHandComplete)
        #expect(!state.foldedStatus)
    }

    // MARK: Unknown board cards (B4)

    @Test("the river deal of an all-in with every hand shown throws while the board holds an unknown card (B4)")
    func unknownCardThrowsFromRiverDeal() throws {
        let river = try allIn(.tournament).applying(.showHoleCards(player: 1), .showHoleCards(player: 0))
            .dealingStreet("2c7d9h").dealingStreet("Ts").applying(.burnCard(.unknown))
        #expect(throws: EngineError.unknownBoardCard(runout: 0, position: 4)) { try river.apply(.dealBoard(.unknown)) }
        #expect(river.pendingOperation == .dealBoardCard(street: .river, runout: 0, cardIndex: 0, cardCount: 1))
        #expect(river.operations.last == .burnCard(.unknown))
    }

    @Test("a known river card throws too, naming the first unknown card on the board (B4)")
    func knownRiverCardThrows() throws {
        let river = try allIn(.tournament).applying(.showHoleCards(player: 1), .showHoleCards(player: 0))
            .dealingStreet("2c??9h").dealingStreet("??").applying(.burnCard(.unknown))
        #expect(throws: EngineError.unknownBoardCard(runout: 0, position: 1)) {
            try river.apply(.dealBoard(card("3s")))
        }
    }

    @Test("a river card that throws from its own deal is fixed by dealing the scanned card (B4)")
    func riverDealFixedByDealing() throws {
        let river = try allIn(.tournament).applying(.showHoleCards(player: 1), .showHoleCards(player: 0))
            .dealingStreet("2c7d9h").dealingStreet("Ts").applying(.burnCard(.unknown))
        #expect(!river.canApply(.dealBoard(.unknown)))
        let settled = try river.applying(.dealBoard(card("3s")))
        #expect(settled.isHandComplete)
        #expect(settled.stacks == [200, 0])
    }

    @Test("the last river show throws while the board holds an unknown card, and the show stays pending (B4)")
    func unknownCardThrowsFromLastShow() throws {
        let state = try riverShowdown(board: ["2c7d9h", "??", "3s"])
            .applying(.showHoleCards(player: 0), .showHoleCards(player: 1))
        #expect(throws: EngineError.unknownBoardCard(runout: 0, position: 3)) {
            try state.apply(.showHoleCards(player: 2))
        }
        #expect(throws: EngineError.unknownBoardCard(runout: 0, position: 3)) {
            try state.apply(.showHoleCards(player: 2, cards: cards("Qs")))
        }
        #expect(throws: EngineError.unknownBoardCard(runout: 0, position: 3)) {
            try state.apply(.showHoleCards(player: 2, cards: []))
        }
        #expect(state.pendingOperation == .showdown(runoutSelectors: [], showOrder: [2]))
    }

    @Test("the last muck of a three-way river showdown throws, because two hands still need evaluating (B4)")
    func unknownCardThrowsFromLastMuck() throws {
        let state = try riverShowdown(board: ["??7d9h", "Ts", "3s"])
            .applying(.showHoleCards(player: 0), .showHoleCards(player: 1))
        #expect(throws: EngineError.unknownBoardCard(runout: 0, position: 0)) {
            try state.apply(.muckHoleCards(player: 2))
        }
        #expect(state.statuses == [.active, .active, .active])
    }

    @Test("a river re-ask lets the unknown river deal through, and its last show throws instead (B4)")
    func unknownCardThrowsFromRiverReask() throws {
        let kept: [HandOperation] = [.showHoleCards(player: 1, cards: []), .showHoleCards(player: 0, cards: [])]
        let reask = try allIn()
            .applying(.selectRunoutCount(player: 0, count: nil), .selectRunoutCount(player: 1, count: nil))
            .applying(kept).dealingStreet("2c7d9h")
            .applying(kept).dealingStreet("Ts")
            .applying(kept).dealingStreet("??")
        #expect(reask.pendingOperation == .showdown(runoutSelectors: [], showOrder: [0, 1]))
        let last = try reask.applying(.showHoleCards(player: 0))
        #expect(throws: EngineError.unknownBoardCard(runout: 0, position: 4)) {
            try last.apply(.showHoleCards(player: 1))
        }
    }

    @Test("replacingOperation fixes an unknown card dealt by an earlier operation (B4)")
    func unknownCardFixedByReplacing() throws {
        let state = try riverShowdown(board: ["??7d9h", "Ts", "3s"])
            .applying(.showHoleCards(player: 0), .showHoleCards(player: 1))
        let index = try #require(state.operations.firstIndex(of: .dealBoard(.unknown)))
        let corrected = try state.replacingOperation(at: index, with: .dealBoard(card("2c")))
        #expect(corrected.boards == [cards("2c7d9hTs3s")])
        let settled = try corrected.applying(.showHoleCards(player: 2))
        #expect(settled.isHandComplete)
        #expect(settled.stacks == [204, 198, 198])
    }

    @Test("replacing a card with an unknown one fails at the operation that would then throw (B4)")
    func replacingIntroducesUnknownCard() throws {
        let state = try allIn(.tournament).applying(.showHoleCards(player: 1), .showHoleCards(player: 0))
            .dealingStreet("2c7d9h").dealingStreet("Ts").dealingStreet("3s")
        #expect(state.isHandComplete)
        let flopCard = try #require(state.operations.firstIndex(of: .dealBoard(card("2c"))))
        let river = try #require(state.operations.firstIndex(of: .dealBoard(card("3s"))))
        #expect(throws: ReplayError(
            operationIndex: river, operation: .dealBoard(card("3s")), error: .unknownBoardCard(runout: 0, position: 0)
        )) {
            try state.replacingOperation(at: flopCard, with: .dealBoard(.unknown))
        }
    }

    @Test("with an unknown board card a last river check, call or fold is accepted and stops at the show order (B4)")
    func riverBettingDoesNotThrow() throws {
        let river = try HandState(config: .test(stacks: [200, 200, 200])).dealingHoles("AsKsQsAhKhQh")
            .checkedDown(board: ["??7d9h", "Ts"]).dealingStreet("3s")
        let checked = try river.checkingDown()
        #expect(checked.pendingOperation == .showdown(runoutSelectors: [], showOrder: [0, 1, 2]))
        let bet = try river.applying(.betOrRaise(player: 0, to: 10), .checkOrCall(player: 1))
        let called = try bet.applying(.checkOrCall(player: 2))
        #expect(called.pendingOperation == .showdown(runoutSelectors: [], showOrder: [0, 1, 2]))
        let folded = try bet.applying(.fold(player: 2))
        #expect(folded.pendingOperation == .showdown(runoutSelectors: [], showOrder: [0, 1]))
    }

    @Test("with an unknown board card a river fold-out settles without evaluation (B4)")
    func riverFoldOutWithUnknownBoard() throws {
        let state = try HandState(config: .test(stacks: [200, 200, 200])).dealingHoles("AsKsQsAhKhQh")
            .checkedDown(board: ["??7d9h", "Ts"]).dealingStreet("3s")
            .applying(.betOrRaise(player: 0, to: 10), .fold(player: 1), .fold(player: 2))
        #expect(state.events.suffix(3) == [
            .betsCollected(collected: [0, 0, 0], returned: [0, 0, 0]),
            .chipsPushed(pot: 0, runout: nil, amounts: [6, 0, 0]),
            .chipsPulled(player: 0, amount: 16),
        ])
    }

    @Test("with an unknown board card a manual collection is accepted and stops at the show order (B4)")
    func manualCollectionDoesNotThrow() throws {
        let config = HandConfig.test(stacks: [200, 200, 200], automations: .bookkeeping.subtracting([.betCollection]))
        let river = try HandState(config: config).dealingHoles("AsKsQsAhKhQh").checkingDown().applying(.collectBets)
            .checkedDown(board: ["??7d9h", "Ts"]).dealingStreet("3s")
            .applying(.betOrRaise(player: 0, to: 10), .checkOrCall(player: 1), .checkOrCall(player: 2))
        #expect(river.pendingOperation == .collectBets)
        let collected = try river.applying(.collectBets)
        #expect(collected.pendingOperation == .showdown(runoutSelectors: [], showOrder: [0, 1, 2]))
    }

    @Test("before the river, a last selection or show moves on to dealing, whatever the board holds (B4)")
    func showdownBeforeTheRiverDoesNotThrow() throws {
        let flop = try HandState(config: .test(stacks: [100, 100])).dealingHoles("AsKsAhKh").checkingDown()
            .dealingStreet("??7d9h").applying(.betOrRaise(player: 0, to: 98), .checkOrCall(player: 1))
        let lastSelection = try flop.applying(
            .showHoleCards(player: 0), .showHoleCards(player: 1),
            .selectRunoutCount(player: 0, count: nil), .selectRunoutCount(player: 1, count: nil)
        )
        #expect(lastSelection.pendingOperation == .burnCard(street: .turn, runout: 0))
        let lastShow = try flop.applying(
            .selectRunoutCount(player: 0, count: nil), .selectRunoutCount(player: 1, count: nil),
            .showHoleCards(player: 0), .showHoleCards(player: 1)
        )
        #expect(lastShow.pendingOperation == .burnCard(street: .turn, runout: 0))
    }

    @Test("a last show or muck that leaves one player settles without evaluating the board (B4)")
    func loneSurvivorSettlesWithUnknownBoard() throws {
        let showdown = try HandState(config: .test(stacks: [200, 200])).dealingHoles("AsKsAhKh")
            .checkedDown(board: ["??7d9h", "Ts", "3s"])
        let lastMuck = try showdown.applying(.showHoleCards(player: 0), .muckHoleCards(player: 1))
        #expect(lastMuck.events.suffix(2) == [
            .chipsPushed(pot: 0, runout: nil, amounts: [4, 0]),
            .chipsPulled(player: 0, amount: 4),
        ])
        let lastShow = try showdown.applying(.muckHoleCards(player: 0), .showHoleCards(player: 1))
        #expect(lastShow.events.suffix(2) == [
            .chipsPushed(pot: 0, runout: nil, amounts: [0, 4]),
            .chipsPulled(player: 1, amount: 4),
        ])
    }

    @Test("an unknown river card after an all-in concession settles without evaluation (B4)")
    func unknownRiverAfterConcession() throws {
        let state = try HandState(config: .test(.tournament, stacks: [100, 100])).dealingHoles("AsKsAhKh")
            .checkingDown().dealingStreet("2c7d9h").checkingDown().dealingStreet("Ts")
            .applying(.betOrRaise(player: 0, to: 98), .checkOrCall(player: 1))
            .applying(.muckHoleCards(player: 1), .showHoleCards(player: 0))
            .dealingStreet("??")
        #expect(state.isHandComplete)
        #expect(state.events.suffix(2) == [
            .chipsPushed(pot: 0, runout: nil, amounts: [200, 0]),
            .chipsPulled(player: 0, amount: 200),
        ])
    }
}
