import Testing
@testable import PokerEngine

@Suite("Betting")
struct BettingTests {
    private static let flop = "2c7d9h"

    private func threeHanded(_ stacks: [Int] = [200, 200, 200], mode: HandConfig.Mode = .cashGame) throws -> HandState {
        try HandState(config: .test(mode, stacks: stacks)).dealingHoles("AsKsQsAhKhQh")
    }

    @Test("preflop action starts left of the big blind, and the big blind closes it")
    func preflopOrder() throws {
        var state = try threeHanded()
        var actors = [Int?]()
        for player in [2, 0, 1] {
            actors.append(state.actor)
            state = try state.apply(.checkOrCall(player: player))
        }
        #expect(actors == [2, 0, 1])
        #expect(state.events.suffix(4) == [
            .checkedOrCalled(player: 2, amount: 2),
            .checkedOrCalled(player: 0, amount: 1),
            .checkedOrCalled(player: 1, amount: 0),
            .betsCollected(collected: [2, 2, 2], returned: [0, 0, 0]),
        ])
        #expect(state.pendingOperation == .burnCard(street: .flop, runout: 0))
        state = try state.dealingStreet(Self.flop)
        #expect(state.actor == 0)
    }

    @Test("heads-up, the button acts first before the flop and last after it")
    func headsUpOrder() throws {
        var state = try HandState(config: .test(stacks: [200, 200])).dealingHoles("AsKsAhKh")
        #expect(state.actor == 1)
        state = try state.applying(.checkOrCall(player: 1), .checkOrCall(player: 0)).dealingStreet(Self.flop)
        #expect(state.actor == 0)
    }

    @Test("a raise must add at least the larger of the last raise and the minimum bet")
    func minimumRaise() throws {
        var state = try threeHanded()
        #expect(state.legalActions == LegalActions(player: 2, canFold: true, toCall: 2, betOrRaise: .raise(4...200)))
        state = try state.applying(.betOrRaise(player: 2, to: 6))
        #expect(state.minRaiseTo == 10)
        #expect(state.legalActions == LegalActions(player: 0, canFold: true, toCall: 5, betOrRaise: .raise(10...200)))
        #expect(throws: EngineError.betBelowMinimum(amount: 9, minimum: 10)) { try state.apply(.betOrRaise(player: 0, to: 9)) }
        #expect(throws: EngineError.betAboveMaximum(amount: 201, maximum: 200)) {
            try state.apply(.betOrRaise(player: 0, to: 201))
        }
        state = try state.applying(.checkOrCall(player: 0), .checkOrCall(player: 1)).dealingStreet(Self.flop)
        #expect(state.legalActions == LegalActions(player: 0, canFold: true, toCall: 0, betOrRaise: .bet(2...194)))
        state = try state.applying(.checkOrCall(player: 0), .betOrRaise(player: 1, to: 10))
        #expect(state.minRaiseTo == 20)
        state = try state.applying(.betOrRaise(player: 2, to: 30))
        #expect(state.minRaiseTo == 50)
        #expect(state.toCall == 30)
        #expect(state.legalActions == LegalActions(player: 0, canFold: true, toCall: 30, betOrRaise: .raise(50...194)))
    }

    @Test("putting chips in is a bet only while nobody has bet on the street; a free check can still face a bet")
    func betOrRaiseLabel() throws {
        // Antes are collected before the first action, so the first player to put chips in bets.
        let antesOnly = try HandState(config: .test(stacks: [100, 100, 100, 100], antes: [1, 1, 1, 1], anteTrimming: true, blinds: []))
            .dealingHoles("AsKsQsJsAhKhQhJh")
        #expect(antesOnly.legalActions == LegalActions(player: 0, canFold: true, toCall: 0, betOrRaise: .bet(2...99)))
        let headsUpAntes = try HandState(config: .test(stacks: [100, 100], antes: [1, 1], anteTrimming: true, blinds: []))
            .dealingHoles("AsKsAhKh")
        #expect(headsUpAntes.legalActions?.betOrRaise == .bet(2...99))
        let bigBlindOption = try threeHanded().applying(.checkOrCall(player: 2), .checkOrCall(player: 0))
        #expect(bigBlindOption.legalActions == LegalActions(player: 1, canFold: true, toCall: 0, betOrRaise: .raise(4...200)))
        let livePoster = try HandState(config: .test(stacks: [200, 200, 200, 200], blinds: [1, 2, 0, -2]))
            .dealingHoles("AsKsQsJsAhKhQhJh").applying(.checkOrCall(player: 2))
        #expect(livePoster.legalActions == LegalActions(player: 3, canFold: true, toCall: 0, betOrRaise: .raise(4...200)))
    }

    @Test("an all-in for less than a full raise is allowed")
    func allInForLess() throws {
        let state = try threeHanded([200, 200, 3], mode: .tournament)
        #expect(state.legalActions == LegalActions(player: 2, canFold: true, toCall: 2, betOrRaise: .raise(3...3)))
    }

    @Test("the first raise of a street counts as full, even a short all-in (PokerKit betting OQ2)")
    func firstRaiseIsFull() throws {
        var state = try HandState(config: .test(stacks: [3, 200, 200, 200])).dealingHoles("AsKsQsJsAhKhQhJh")
            .applying(.checkOrCall(player: 2), .checkOrCall(player: 3), .betOrRaise(player: 0, to: 3))
        #expect(state.actor == 1)
        #expect(state.minRaiseTo == 5)
        state = try state.applying(.checkOrCall(player: 1))
        #expect(state.actor == 2)
        #expect(state.minRaiseTo != nil)
    }

    @Test("a short all-in raise does not reopen the action for players who already acted")
    func shortAllInDoesNotReopen() throws {
        let state = try threeHanded([200, 200, 150])
            .applying(.checkOrCall(player: 2), .checkOrCall(player: 0), .checkOrCall(player: 1))
            .dealingStreet(Self.flop)
            .applying(.betOrRaise(player: 0, to: 100), .checkOrCall(player: 1), .betOrRaise(player: 2, to: 148))
        #expect(state.legalActions == LegalActions(
            player: 0, canFold: true, toCall: 48, betOrRaise: .unavailable(.actionNotReopened)
        ))
        #expect(state.minRaiseTo == nil)
        #expect(throws: EngineError.raiseNotAllowed(player: 0, reason: .actionNotReopened)) {
            try state.apply(.betOrRaise(player: 0, to: 198))
        }
    }

    @Test("short all-ins that add up to a full raise reopen the action; one more closes it (PokerKit betting OQ4)")
    func cumulativeShortAllIns() throws {
        var state = try HandState(config: .test(
            .tournament, stacks: [20001, 20001, 20001, 1301, 1701, 1801], antes: [1, 1, 1, 1, 1, 1],
            anteTrimming: true, blinds: [], minBet: 1
        )).dealingHoles("AsKsQsJsTs9sAhKhQhJhTh9h")
        state = try state.applying(.betOrRaise(player: 0, to: 500), .betOrRaise(player: 1, to: 1000), .checkOrCall(player: 2))
        state = try state.applying(.betOrRaise(player: 3, to: 1300), .betOrRaise(player: 4, to: 1700))
        // 300 + 400 adds up to a full raise over 500, so player 1, who already raised, may raise again.
        let reopened = try state.applying(.fold(player: 5), .checkOrCall(player: 0))
        #expect(reopened.actor == 1)
        #expect(reopened.toCall == 700)
        #expect(reopened.minRaiseTo == 2200)
        state = try state.applying(.betOrRaise(player: 5, to: 1800), .checkOrCall(player: 0))
        #expect(state.actor == 1)
        #expect(state.legalActions?.toCall == 800)
        #expect(state.legalActions?.betOrRaise == .unavailable(.actionNotReopened))
    }

    @Test("short all-ins adding up to exactly a full raise reopen the action, and one more closes it (A3)")
    func shortAllInsAddUpExactly() throws {
        var state = try HandState(config: .test(stacks: [200, 200, 16, 22, 27, 200])).dealingHoles("AsKsQsJsTs9sAhKhQhJhTh9h")
        while let actor = state.actor {
            state = try state.apply(.checkOrCall(player: actor))
        }
        // 4 + 6 make exactly the 10-chip increment of player 0's bet, which is not all in.
        state = try state.dealingStreet("2c7d3h")
            .applying(.betOrRaise(player: 0, to: 10), .checkOrCall(player: 1), .betOrRaise(player: 2, to: 14))
            .applying(.betOrRaise(player: 3, to: 20))
        let reopened = try state.applying(.checkOrCall(player: 4), .checkOrCall(player: 5))
        #expect(reopened.legalActions == LegalActions(player: 0, canFold: true, toCall: 10, betOrRaise: .raise(30...198)))
        let closed = try state.applying(.betOrRaise(player: 4, to: 25), .checkOrCall(player: 5))
        #expect(closed.legalActions == LegalActions(player: 0, canFold: true, toCall: 15, betOrRaise: .unavailable(.actionNotReopened)))
    }

    @Test("whether an all-in reopens the action depends on the largest increment only, never on minBet (A3)")
    func reopeningIgnoresMinBet() throws {
        func limpedFlop(_ stacks: [Int], blinds: [Int], minBet: Int, holes: String) throws -> HandState {
            var state = try HandState(config: .test(stacks: stacks, blinds: blinds, minBet: minBet)).dealingHoles(holes)
            while let actor = state.actor {
                state = try state.apply(.checkOrCall(player: actor))
            }
            return try state.dealingStreet("2c7d3h")
        }
        // A 5-chip all-in bet under a minBet of 10 is still a full bet, so the earlier checker may raise.
        let subMinimumBet = try limpedFlop([200, 15, 18, 200], blinds: [5, 10], minBet: 10, holes: "AsKsQsJsAhKhQhJh")
            .applying(.checkOrCall(player: 0), .betOrRaise(player: 1, to: 5), .betOrRaise(player: 2, to: 8))
            .applying(.checkOrCall(player: 3))
        #expect(subMinimumBet.legalActions == LegalActions(player: 0, canFold: true, toCall: 8, betOrRaise: .raise(18...190)))
        // Two 3-chip all-ins add up to the 6-chip increment and reopen the action; the next short all-in closes it.
        let reclosed = try limpedFlop([300, 26, 300, 29, 32, 34], blinds: [10, 20], minBet: 20, holes: "AsKsQsJsTs9sAhKhQhJhTh9h")
            .applying(.checkOrCall(player: 0), .betOrRaise(player: 1, to: 6), .checkOrCall(player: 2))
            .applying(.betOrRaise(player: 3, to: 9), .betOrRaise(player: 4, to: 12), .betOrRaise(player: 5, to: 14))
            .applying(.checkOrCall(player: 0))
        #expect(reclosed.legalActions == LegalActions(player: 2, canFold: true, toCall: 8, betOrRaise: .unavailable(.actionNotReopened)))
    }

    @Test("a full all-in raise clears the short all-ins before it, so only the later ones count")
    func fullAllInClearsShortAllIns() throws {
        var state = try HandState(config: .test(stacks: [1002, 152, 302, 1002, 402, 502, 602]))
            .dealingHoles("AsKsQsJsTs9s8sAhKhQhJhTh9h8h")
        while let actor = state.actor {
            state = try state.apply(.checkOrCall(player: actor))
        }
        state = try state.dealingStreet("2c7d3h")
            .applying(.betOrRaise(player: 0, to: 100), .betOrRaise(player: 1, to: 150), .betOrRaise(player: 2, to: 300))
            .applying(.checkOrCall(player: 3), .betOrRaise(player: 4, to: 400), .betOrRaise(player: 5, to: 500))
            .applying(.betOrRaise(player: 6, to: 600), .checkOrCall(player: 0))
        // Player 3 called the full all-in to 300; since then 100 + 100 reopened the action and the last 100 closed it.
        #expect(state.legalActions == LegalActions(player: 3, canFold: true, toCall: 300, betOrRaise: .unavailable(.actionNotReopened)))
    }

    @Test("a raise over a short all-in raise is measured from the all-in (PokerKit extra (a))")
    func raiseOverShortAllIns() throws {
        let state = try HandState(config: .test(stacks: [200, 200, 11, 200, 12], blinds: [5, 10], minBet: 10))
            .dealingHoles("AcKcQcJcTcAdKdQdJdTd")
            .applying(.betOrRaise(player: 2, to: 11), .checkOrCall(player: 3), .betOrRaise(player: 4, to: 12))
            .applying(.checkOrCall(player: 0), .fold(player: 1))
        #expect(state.actor == 3)
        #expect(state.toCall == 1)
        #expect(state.minRaiseTo == 22)
    }

    @Test("a covered player can only call or fold")
    func coveredPlayer() throws {
        let state = try threeHanded([200, 200, 60])
            .applying(.checkOrCall(player: 2), .checkOrCall(player: 0), .checkOrCall(player: 1))
            .dealingStreet(Self.flop)
            .applying(.betOrRaise(player: 0, to: 100), .checkOrCall(player: 1))
        #expect(state.legalActions == LegalActions(player: 2, canFold: true, toCall: 58, betOrRaise: .unavailable(.playerIsCovered)))
        // Why raising is refused comes before the amount: PokerKit says "short all-in" here, not "above the maximum".
        #expect(throws: EngineError.raiseNotAllowed(player: 2, reason: .playerIsCovered)) {
            try state.apply(.betOrRaise(player: 2, to: 1000))
        }
    }

    @Test("betting or raising is refused when no opponent could call it: each is all in, folded or covered")
    func noOpponentCanRespond() throws {
        let state = try HandState(config: .test(stacks: [200, 50])).dealingHoles("AsKsAhKh")
            .applying(.betOrRaise(player: 1, to: 50))
        #expect(state.legalActions == LegalActions(
            player: 0, canFold: true, toCall: 48, betOrRaise: .unavailable(.noOpponentCanRespond)
        ))
        // Players 0 and 1 still hold chips, but no more than the bet they face.
        let covered = try HandState(config: .test(stacks: [30, 50, 100, 300])).dealingHoles("AsKsQsJsAhKhQhJh")
            .applying(.betOrRaise(player: 2, to: 100))
        #expect(covered.stacks == [29, 48, 0, 300])
        #expect(covered.legalActions == LegalActions(
            player: 3, canFold: true, toCall: 100, betOrRaise: .unavailable(.noOpponentCanRespond)
        ))
        // Player 0 folded, and player 2 is all in.
        let foldedOut = try threeHanded([200, 200, 50]).applying(.betOrRaise(player: 2, to: 50), .fold(player: 0))
        #expect(foldedOut.legalActions == LegalActions(
            player: 1, canFold: true, toCall: 48, betOrRaise: .unavailable(.noOpponentCanRespond)
        ))
        // Nobody has bet on the flop: player 0 folds for free while player 2 is all in, so even a bet is refused.
        let noBet = try threeHanded([200, 200, 3])
            .applying(.betOrRaise(player: 2, to: 3), .checkOrCall(player: 0), .checkOrCall(player: 1))
            .dealingStreet(Self.flop)
            .applying(.fold(player: 0))
        #expect(noBet.legalActions == LegalActions(
            player: 1, canFold: true, toCall: 0, betOrRaise: .unavailable(.noOpponentCanRespond)
        ))
        let refusal = #expect(throws: EngineError.self) { try noBet.apply(.betOrRaise(player: 1, to: 10)) }
        #expect(refusal == .raiseNotAllowed(player: 1, reason: .noOpponentCanRespond))
        #expect(refusal?.message() == "Player 2 cannot bet or raise: nobody else could call it.")
    }

    @Test("a player whose bet already covers every opponent is not asked to act")
    func coveringPlayerDoesNotAct() throws {
        // Heads-up, the small blind has less than the big blind and calls all in.
        let headsUp = try HandState(config: .test(.tournament, stacks: [200, 3], blinds: [2, 4], minBet: 4))
            .dealingHoles("AsKsAhKh").applying(.checkOrCall(player: 1))
        #expect(headsUp.actor == nil)
        #expect(headsUp.events.suffix(2) == [
            .checkedOrCalled(player: 1, amount: 1),
            .betsCollected(collected: [3, 3], returned: [1, 0]),
        ])
        // A straddle larger than either blind's whole stack.
        let straddle = try HandState(config: .test(stacks: [10, 10, 200], blinds: [1, 2, 50])).dealingHoles("AsKsQsAhKhQh")
            .applying(.checkOrCall(player: 0), .checkOrCall(player: 1))
        #expect(straddle.actor == nil)
        #expect(straddle.events.suffix(1) == [.betsCollected(collected: [10, 10, 10], returned: [0, 0, 40])])
    }

    @Test("with nobody left to raise against, the big blind's tournament option is a check: no raise, no fold")
    func optionWithNobodyToRespond() throws {
        // The button folded and the small blind completed all in, so a raise could never be called.
        let state = try threeHanded([2, 100, 100], mode: .tournament).applying(.fold(player: 2), .checkOrCall(player: 0))
        #expect(state.legalActions == LegalActions(
            player: 1, canFold: false, toCall: 0, betOrRaise: .unavailable(.noOpponentCanRespond)
        ))
        #expect(throws: EngineError.raiseNotAllowed(player: 1, reason: .noOpponentCanRespond)) {
            try state.apply(.betOrRaise(player: 1, to: 4))
        }
        #expect(throws: EngineError.cannotFoldWhenCheckIsFree(player: 1)) { try state.apply(.fold(player: 1)) }
        #expect(state.canApply(.checkOrCall(player: 1)))
    }

    @Test("a player who already acted and faces a short all-in is told the action is not reopened, even if nobody could respond")
    func notReopenedBeforeNoOpponent() throws {
        let state = try threeHanded([300, 150, 300])
            .applying(.checkOrCall(player: 2), .checkOrCall(player: 0), .checkOrCall(player: 1))
            .dealingStreet(Self.flop)
            .applying(.betOrRaise(player: 0, to: 100), .betOrRaise(player: 1, to: 148), .fold(player: 2))
        #expect(state.legalActions == LegalActions(player: 0, canFold: true, toCall: 48, betOrRaise: .unavailable(.actionNotReopened)))
    }

    @Test("folding when checking is free: allowed in cash games, refused in tournaments (PokerKit betting OQ12)")
    func freeFolds() throws {
        let cash = try threeHanded().applying(.checkOrCall(player: 2), .checkOrCall(player: 0))
        #expect(cash.legalActions?.canFold == true)
        #expect(cash.canApply(.fold(player: 1)))
        let tournament = try threeHanded(mode: .tournament).applying(.checkOrCall(player: 2), .checkOrCall(player: 0))
        #expect(tournament.legalActions?.canFold == false)
        #expect(throws: EngineError.cannotFoldWhenCheckIsFree(player: 1)) { try tournament.apply(.fold(player: 1)) }
    }

    @Test("only the player to act may act, and only during a betting round")
    func turnOrder() throws {
        let dealing = HandState(config: .test(stacks: [200, 200, 200]))
        #expect(throws: EngineError.noActionExpected) { try dealing.apply(.checkOrCall(player: 2)) }
        #expect(throws: EngineError.noActionExpected) { try dealing.apply(.fold(player: 0)) }
        #expect(throws: EngineError.noActionExpected) { try dealing.apply(.betOrRaise(player: 1, to: 6)) }
        let state = try threeHanded()
        #expect(throws: EngineError.notYourTurn(player: 0, actor: 2)) { try state.apply(.fold(player: 0)) }
        // The amount is checked only once it is the player's turn.
        #expect(throws: EngineError.notYourTurn(player: 1, actor: 2)) { try state.apply(.betOrRaise(player: 1, to: 1)) }
    }

    @Test("a nonexistent player index is reported before the phase, turn, amount and card checks, by every operation that names a player")
    func invalidPlayerFirst() throws {
        let dealing = HandState(config: .test(stacks: [200, 200, 200]))
        #expect(throws: EngineError.invalidPlayer(99)) { try dealing.apply(.fold(player: 99)) }
        #expect(throws: EngineError.invalidPlayer(-1)) { try dealing.apply(.postAnte(player: -1)) }
        let flop = try threeHanded().applying(.checkOrCall(player: 2), .checkOrCall(player: 0), .checkOrCall(player: 1))
        #expect(throws: EngineError.invalidPlayer(7)) { try flop.apply(.dealHole(player: 7, card: card("2c"))) }
        #expect(throws: EngineError.noDealExpected(.holeCard(player: 0))) { try flop.apply(.dealHole(player: 0, card: card("2c"))) }
        // As is already dealt while hole cards go out, then player 2 is to act, then the flop is due.
        for state in try [dealing.applying(.dealHole(player: 0, card: card("As"))), threeHanded(), flop] {
            for player in [-1, 3] {
                for operation: HandOperation in [
                    .postAnte(player: player), .postBlindOrStraddle(player: player), .dealHole(player: player, card: card("As")),
                    .fold(player: player), .checkOrCall(player: player), .betOrRaise(player: player, to: 1),
                    .selectRunoutCount(player: player, count: 2), .showHoleCards(player: player),
                    .muckHoleCards(player: player), .killHand(player: player), .pullChips(player: player),
                ] {
                    #expect(throws: EngineError.invalidPlayer(player), "\(operation)") { try state.apply(operation) }
                }
            }
        }
        // While blinds wait to be posted, an unchecked index would be read out of range.
        let manualBlinds = HandState(config: .test(stacks: [200, 200, 200], automations: [.antePosting, .betCollection]))
        #expect(throws: EngineError.invalidPlayer(3)) { try manualBlinds.apply(.postBlindOrStraddle(player: 3)) }
    }

    @Test("an uncalled bet is returned when bets are collected")
    func uncalledBet() throws {
        let state = try HandState(config: .test(stacks: [200, 30])).dealingHoles("AsKsAhKh")
            .applying(.checkOrCall(player: 1), .checkOrCall(player: 0))
            .dealingStreet(Self.flop)
            .applying(.betOrRaise(player: 0, to: 50), .checkOrCall(player: 1))
        #expect(state.events.suffix(2) == [
            .checkedOrCalled(player: 1, amount: 28),
            .betsCollected(collected: [28, 28], returned: [22, 0]),
        ])
        #expect(state.stacks == [170, 0])
        #expect(state.pots == [Pot(amount: 60, eligiblePlayers: [0, 1])])
        // Nobody can bet any more, and no card is dealt before the showdown.
        #expect(state.actor == nil)
        #expect(!state.canApply(.burnCard(.unknown)))
    }

    @Test("an uncalled raise is returned preflop, in a multi-way pot")
    func uncalledPreflopRaise() throws {
        let state = try HandState(config: .test(stacks: [200, 200, 40, 200])).dealingHoles("AsKsQsJsAhKhQhJh")
            .applying(.betOrRaise(player: 2, to: 40), .betOrRaise(player: 3, to: 120), .checkOrCall(player: 0))
            .applying(.fold(player: 1))
        #expect(state.events.suffix(2) == [
            .folded(player: 1),
            .betsCollected(collected: [120, 2, 40, 120], returned: [0, 0, 0, 0]),
        ])
        let raisedOver = try HandState(config: .test(stacks: [200, 200, 40, 200])).dealingHoles("AsKsQsJsAhKhQhJh")
            .applying(.betOrRaise(player: 2, to: 40), .betOrRaise(player: 3, to: 120), .fold(player: 0))
            .applying(.checkOrCall(player: 1))
        #expect(raisedOver.events.suffix(2) == [
            .checkedOrCalled(player: 1, amount: 118),
            .betsCollected(collected: [1, 120, 40, 120], returned: [0, 0, 0, 0]),
        ])
        let uncalled = try HandState(config: .test(stacks: [200, 200, 40, 200])).dealingHoles("AsKsQsJsAhKhQhJh")
            .applying(.betOrRaise(player: 2, to: 40), .betOrRaise(player: 3, to: 120), .fold(player: 0))
            .applying(.fold(player: 1))
        #expect(uncalled.events.suffix(2) == [
            .folded(player: 1),
            .betsCollected(collected: [1, 2, 40, 40], returned: [0, 0, 0, 80]),
        ])
        #expect(uncalled.stacks == [199, 198, 0, 160])
        #expect(uncalled.actor == nil)
        #expect(!uncalled.canApply(.burnCard(.unknown)))
    }

    @Test("an uncalled bet is returned to a player who folded, too")
    func uncalledBetReturnedAfterFold() throws {
        // The straddler folds the option while both remaining players are all in from their blinds.
        let state = try HandState(config: .test(stacks: [1, 2, 200, 200], blinds: [1, 2, 4])).dealingHoles("AsKsQsJsAhKhQhJh")
            .applying(.fold(player: 3), .fold(player: 2))
        #expect(state.events.suffix(2) == [
            .folded(player: 2),
            .betsCollected(collected: [1, 2, 2, 0], returned: [0, 0, 2, 0]),
        ])
        #expect(state.stacks == [0, 0, 198, 200])
        #expect(state.pots == [Pot(amount: 3, eligiblePlayers: [0, 1]), Pot(amount: 2, eligiblePlayers: [1])])
    }

    @Test("when everyone else folds, the winner's bet stays out of the pot")
    func foldOut() throws {
        let config = HandConfig.test(stacks: [200, 200, 200], automations: .bookkeeping.subtracting([.chipsPushing]))
        let state = try HandState(config: config).dealingHoles("AsKsQsAhKhQh")
            .applying(.betOrRaise(player: 2, to: 6), .fold(player: 0), .fold(player: 1))
        #expect(state.events.suffix(3) == [
            .folded(player: 0),
            .folded(player: 1),
            .betsCollected(collected: [1, 2, 0], returned: [0, 0, 0]),
        ])
        #expect(state.bets == [0, 0, 6])
        #expect(state.statuses == [.folded, .folded, .active])
        #expect(state.holeCards[0].isEmpty && state.holeCards[1].isEmpty)
        #expect(state.pots == [Pot(amount: 3, eligiblePlayers: [2])])
        #expect(state.totalPot == 9)
        #expect(state.actor == nil)
        #expect(!state.canApply(.burnCard(.unknown)))
    }
}
