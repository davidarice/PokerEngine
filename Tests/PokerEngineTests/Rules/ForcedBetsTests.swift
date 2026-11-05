import Testing
@testable import PokerEngine

@Suite("Forced bets")
struct ForcedBetsTests {
    @Test("bookkeeping posts the blinds, then the hand waits for the first hole card")
    func automatedBlinds() {
        let state = HandState(config: .test(stacks: [200, 200, 200]))
        #expect(state.log == [
            LogEntry(event: .blindOrStraddlePosted(player: 0, amount: 1), isAutomated: true, operationIndex: nil),
            LogEntry(event: .blindOrStraddlePosted(player: 1, amount: 2), isAutomated: true, operationIndex: nil),
        ])
        #expect(state.stacks == [199, 198, 200])
        #expect(state.bets == [1, 2, 0])
        #expect(state.totalPot == 3)
        #expect(state.pots == [])
        #expect(state.street == .preflop)
        #expect(state.pendingOperation == .dealHoleCard(player: 0, cardIndex: 0))
    }

    @Test("without automation, forced bets may be posted in any order and the owed amounts are listed")
    func manualPosting() throws {
        var state = HandState(config: .test(stacks: [200, 200, 200], antes: [1, 1, 1], anteTrimming: true, automations: []))
        #expect(state.pendingOperation == .postAnte([
            ForcedBet(player: 0, amount: 1), ForcedBet(player: 1, amount: 1), ForcedBet(player: 2, amount: 1),
        ]))
        #expect(throws: EngineError.invalidPlayer(3)) { try state.apply(.postAnte(player: 3)) }
        #expect(throws: EngineError.noBlindOrStraddleExpected(player: 0)) { try state.apply(.postBlindOrStraddle(player: 0)) }
        state = try state.applying(.postAnte(player: 2), .postAnte(player: 0))
        #expect(throws: EngineError.noAnteExpected(player: 2)) { try state.apply(.postAnte(player: 2)) }
        state = try state.applying(.postAnte(player: 1))
        #expect(state.pendingOperation == .collectBets)
        state = try state.applying(.collectBets)
        #expect(state.log.last?.event == .betsCollected(collected: [1, 1, 1], returned: [0, 0, 0]))
        #expect(state.pendingOperation == .postBlindOrStraddle([ForcedBet(player: 0, amount: 1), ForcedBet(player: 1, amount: 2)]))
        #expect(throws: EngineError.noBetCollectionExpected) { try state.apply(.collectBets) }
        state = try state.applying(.postBlindOrStraddle(player: 1), .postBlindOrStraddle(player: 0))
        #expect(state.bets == [1, 2, 0])
        #expect(state.pendingOperation == .dealHoleCard(player: 0, cardIndex: 0))
        #expect(throws: EngineError.invalidPlayer(9)) { try state.apply(.postAnte(player: 9)) }
        #expect(throws: EngineError.noAnteExpected(player: 2)) { try state.apply(.postAnte(player: 2)) }
    }

    @Test("heads-up, the arrays are read in reverse: player 0 is the big blind and pays a big-blind ante")
    func headsUpReversal() throws {
        // PokerKit betting OQ7: the ante written for position 1 is paid by player 0.
        let state = HandState(config: .test(.tournament, stacks: [200, 200], antes: [0, 5], blinds: [1, 2]))
        #expect(state.events.prefix(2) == [
            .antePosted(player: 0, amount: 5),
            .betsCollected(collected: [5, 0], returned: [0, 0]),
        ])
        #expect(state.bets == [2, 1])
        let dealt = try state.dealingHoles("AsKsAhKh")
        #expect(dealt.actor == 1)
        // With equal blinds the big blind acts first preflop.
        let equalBlinds = try HandState(config: .test(stacks: [200, 200], blinds: [2, 2])).dealingHoles("AsKsAhKh")
        #expect(equalBlinds.actor == 0)
        // Only the payer's own stack caps the ante: the 3-chip button does not cut player 0's 5-chip ante.
        let shortButton = HandState(config: .test(.tournament, stacks: [200, 3], antes: [0, 5], blinds: [1, 2]))
        #expect(shortButton.events.first == .antePosted(player: 0, amount: 5))
        #expect(shortButton.stacks == [193, 2])
    }

    @Test("heads-up, the reversed blinds also decide who opens: with no small blind, or a live post, the button acts first")
    func headsUpOpener() throws {
        let bigBlindOnly = try HandState(config: .test(stacks: [200, 200], blinds: [0, 2])).dealingHoles("AsKsAhKh")
        #expect(bigBlindOnly.bets == [2, 0])
        #expect(bigBlindOnly.legalActions == LegalActions(player: 1, canFold: true, toCall: 2, betOrRaise: .raise(4...200)))
        let livePost = try HandState(config: .test(stacks: [200, 200], blinds: [-2, 2])).dealingHoles("AsKsAhKh")
        #expect(livePost.bets == [2, 2])
        #expect(livePost.legalActions == LegalActions(player: 1, canFold: true, toCall: 0, betOrRaise: .raise(4...200)))
    }

    @Test("a short big blind posts what it has, and callers owe only that (PokerKit betting OQ5)")
    func shortBigBlind() throws {
        let state = try HandState(config: .test(stacks: [200, 1, 200])).dealingHoles("AsKsQsAhKhQh")
        #expect(state.bets == [1, 1, 0])
        #expect(state.actor == 2)
        #expect(state.toCall == 1)
        #expect(state.minRaiseTo == 3)
    }

    @Test("a big-blind ante is taken before the blind, and is dead money in the first pot (PokerKit betting OQ6)")
    func bigBlindAnteBeforeBlind() {
        let state = HandState(config: .test(.tournament, stacks: [200, 3, 200], antes: [0, 2]))
        #expect(state.events == [
            .antePosted(player: 1, amount: 2),
            .betsCollected(collected: [0, 2, 0], returned: [0, 0, 0]),
            .blindOrStraddlePosted(player: 0, amount: 1),
            .blindOrStraddlePosted(player: 1, amount: 1),
        ])
        #expect(state.stacks == [199, 0, 200])
        #expect(state.pots == [Pot(amount: 2, eligiblePlayers: [0, 1, 2])])
        #expect(state.totalPot == 4)
    }

    @Test("trimmed antes: a full ante above everyone else's short ante gets its excess back")
    func anteTrimming() {
        let state = HandState(config: .test(.tournament, stacks: [3, 3, 200], antes: [5, 5, 5], anteTrimming: true, blinds: []))
        #expect(state.events.last == .betsCollected(collected: [3, 3, 3], returned: [0, 0, 2]))
        #expect(state.stacks == [0, 0, 197])
        #expect(state.pots == [Pot(amount: 9, eligiblePlayers: [0, 1, 2])])
    }

    @Test("after trimming refunds part of an ante, the blind is still capped at the starting stack minus the full ante")
    func blindAfterTrimmedAnte() {
        let state = HandState(config: .test(.tournament, stacks: [3, 6, 3], antes: [5, 5, 5], anteTrimming: true))
        #expect(state.events == [
            .antePosted(player: 0, amount: 3),
            .antePosted(player: 1, amount: 5),
            .antePosted(player: 2, amount: 3),
            .betsCollected(collected: [3, 3, 3], returned: [0, 2, 0]),
            .blindOrStraddlePosted(player: 1, amount: 1),
        ])
        #expect(state.stacks == [0, 2, 0])
    }

    @Test("straddles: action starts left of the largest one; a button straddle puts the small blind first")
    func straddles() throws {
        // PokerKit betting OQ1: minimum raise over a 1/2/4 straddle is minBet + 4 = 6, not 8.
        let utg = try HandState(config: .test(stacks: Array(repeating: 200, count: 6), blinds: [1, 2, 4]))
            .dealingHoles("AsKsQsJsTs9sAhKhQhJhTh9h")
        #expect(utg.actor == 3)
        #expect(utg.minRaiseTo == 6)
        let button = try HandState(config: .test(stacks: Array(repeating: 200, count: 6), blinds: [1, 2, 0, 0, 0, 4]))
            .dealingHoles("AsKsQsJsTs9sAhKhQhJhTh9h")
        #expect(button.actor == 0)
        #expect(button.toCall == 3)
        #expect(button.minRaiseTo == 6)
    }

    @Test("a live post is posted like a blind but does not move the opener, and gets the option")
    func livePost() throws {
        var state = try HandState(config: .test(stacks: [200, 200, 200, 200], blinds: [1, 2, 0, -2]))
            .dealingHoles("AsKsQsJsAhKhQhJh")
        #expect(state.bets == [1, 2, 0, 2])
        #expect(state.actor == 2)
        state = try state.applying(.checkOrCall(player: 2))
        #expect(state.actor == 3)
        #expect(state.toCall == 0)
        #expect(state.minRaiseTo == 4)
    }
}
