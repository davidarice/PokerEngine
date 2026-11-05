import Testing
@testable import PokerEngine

@Suite("Running the board more than once")
struct RunoutTests {
    /// Heads-up, all in on a flop of 2c7d9h with nothing chosen yet. Player 0 holds aces, player 1 kings.
    private func flopAllIn(
        stacks: [Int] = [100, 100],
        automations: Set<HandConfig.Automation> = .bookkeeping
    ) throws -> HandState {
        try HandState(config: .test(stacks: stacks, automations: automations)).dealingHoles("AsKsAhKh")
            .applying(.checkOrCall(player: 1), .checkOrCall(player: 0))
            .dealingStreet("2c7d9h")
            .applying(.betOrRaise(player: 0, to: 98), .checkOrCall(player: 1))
    }

    /// Three players all in before the flop with nothing chosen yet, holding aces, kings and queens.
    private func threeWayAllIn(automations: Set<HandConfig.Automation> = .bookkeeping) throws -> HandState {
        try HandState(config: .test(stacks: [100, 100, 100], automations: automations)).dealingHoles("AsKsQsAhKhQh")
            .applying(.betOrRaise(player: 2, to: 100), .checkOrCall(player: 0), .checkOrCall(player: 1))
    }

    /// `flopAllIn` run twice, with both hands shown, leaving the first burn.
    private func twoRuns(automations: Set<HandConfig.Automation> = .bookkeeping) throws -> HandState {
        try flopAllIn(automations: automations).applying(selecting([2, 2])).applying(shows(0, 1))
    }

    private func selecting(_ counts: [Int?]) -> [HandOperation] {
        counts.enumerated().map { .selectRunoutCount(player: $0, count: $1) }
    }

    private func shows(_ players: Int...) -> [HandOperation] {
        players.map { .showHoleCards(player: $0) }
    }

    private func keepsCards(_ player: Int) -> HandOperation {
        .showHoleCards(player: player, cards: [])
    }

    private func pushes(_ state: HandState) -> [HandEvent] {
        state.events.filter { if case .chipsPushed = $0 { true } else { false } }
    }

    // MARK: The count

    @Test("abstaining agrees with any count, and any disagreement runs once (A10)", arguments: [
        ([2, nil], 2),
        ([nil, 2], 2),
        ([3, 3], 3),
        ([nil, nil], 1),
        ([1, 1], 1),
        ([1, nil], 1),
        ([2, 3], 1),
        ([2, 1], 1),
        ([1, 2], 1),
    ] as [([Int?], Int)])
    func consensus(counts: [Int?], runs: Int) throws {
        let state = try flopAllIn().applying(selecting(counts)).applying(shows(0, 1))
        #expect(state.runoutCount == runs)
        #expect(state.boards.count == runs)
    }

    @Test("once a table has disagreed, a third player matching the first count changes nothing (A10)")
    func disagreementIsFinal() throws {
        let state = try threeWayAllIn().applying(selecting([2, 3, 2])).applying(shows(0, 1, 2))
        #expect(state.runoutCount == 1)
    }

    @Test("a player who mucks has still chosen for the table (A10)")
    func muckedPlayerSetsTheCount() throws {
        let state = try threeWayAllIn().applying(.muckHoleCards(player: 2)).applying(selecting([nil, nil, 2]))
            .applying(shows(0, 1))
        #expect(state.runoutCount == 2)
    }

    @Test("the count takes effect when the first showdown ends, not before (A10)")
    func countTakesEffectLate() throws {
        var state = try flopAllIn().applying(selecting([2, 2])).applying(shows(0))
        #expect(state.runoutCount == 1)
        #expect(state.boards == [cards("2c7d9h")])
        state = try state.applying(shows(1))
        #expect(state.runoutCount == 2)
        #expect(state.boards == [cards("2c7d9h"), cards("2c7d9h")])
    }

    @Test("counts run up to a deck's worth of cards, and the rest are refused (B5)")
    func maximumRunoutCount() throws {
        let maximum = HandState.maximumRunoutCount
        #expect(maximum == 52)
        let state = try flopAllIn()
        #expect(throws: EngineError.invalidRunoutCount(maximum + 1)) {
            try state.apply(.selectRunoutCount(player: 0, count: maximum + 1))
        }
        #expect(throws: EngineError.invalidRunoutCount(Int.max)) {
            try state.apply(.selectRunoutCount(player: 0, count: .max))
        }
        let most = try state.applying(selecting([maximum, maximum])).applying(shows(0, 1))
        #expect(most.runoutCount == maximum)
        #expect(most.boards == Array(repeating: cards("2c7d9h"), count: maximum))
    }

    // MARK: Dealing

    @Test("the board goes back after each run, to the street the all-in left off (A11)")
    func streetGoesBack() throws {
        var state = try twoRuns()
        #expect(state.pendingOperation == .burnCard(street: .turn, runout: 0))
        state = try state.dealingStreet("Td")
        #expect(state.pendingOperation == .burnCard(street: .river, runout: 0))
        state = try state.apply(.burnCard(.unknown))
        #expect(state.pendingOperation == .dealBoardCard(street: .river, runout: 0, cardIndex: 0, cardCount: 1))
        state = try state.apply(.dealBoard(card("3s")))
        #expect(state.street == .turn)
        #expect(state.pendingOperation == .burnCard(street: .turn, runout: 1))
        state = try state.apply(.burnCard(.unknown))
        #expect(state.pendingOperation == .dealBoardCard(street: .turn, runout: 1, cardIndex: 0, cardCount: 1))
        state = try state.applying(.dealBoard(card("Kc")))
        #expect(state.pendingOperation == .burnCard(street: .river, runout: 1))
        state = try state.dealingStreet("Qd")
        #expect(state.isHandComplete)
    }

    @Test("the log says which run each burn and board card belongs to")
    func eventsNameTheRun() throws {
        let state = try twoRuns().dealingStreet("Td").dealingStreet("3s")
            .applying(.burnCard(card("8d")), .dealBoard(card("Kc")))
        #expect(Array(state.events.suffix(3)) == [
            .boardCardDealt(card("3s"), street: .river, runout: 0),
            .cardBurned(card("8d"), street: .turn, runout: 1),
            .boardCardDealt(card("Kc"), street: .turn, runout: 1),
        ])
    }

    @Test("a run from before the flop repeats every street, burns included (A11)")
    func preflopAllInRepeatsEveryStreet() throws {
        var state = try threeWayAllIn().applying(selecting([2, nil, 2])).applying(shows(0, 1, 2))
            .dealingStreet("2c7d9h").dealingStreet("Td").dealingStreet("3s")
        #expect(state.street == .flop)
        #expect(state.pendingOperation == .burnCard(street: .flop, runout: 1))
        #expect(throws: EngineError.burnRequired) { try state.apply(.dealBoard(card("Kc"))) }
        state = try state.dealingStreet("Kc4c5d")
        #expect(state.pendingOperation == .burnCard(street: .turn, runout: 1))
        state = try state.dealingStreet("8h").dealingStreet("Jd")
        #expect(state.boards == [cards("2c7d9hTd3s"), cards("Kc4c5d8hJd")])
    }

    @Test("a run from the turn repeats only the river")
    func turnAllInRepeatsTheRiver() throws {
        let state = try HandState(config: .test(stacks: [100, 100])).dealingHoles("AsKsAhKh").checkingDown()
            .dealingStreet("2c7d9h").checkingDown()
            .dealingStreet("Td")
            .applying(.betOrRaise(player: 0, to: 98), .checkOrCall(player: 1))
            .applying(selecting([3, 3])).applying(shows(0, 1))
            .dealingStreet("3s").dealingStreet("Kc").dealingStreet("Qd")
        #expect(state.boards == [cards("2c7d9hTd3s"), cards("2c7d9hTdKc"), cards("2c7d9hTdQd")])
        // 200 chips over three runs: 68, 66 and 66. The kings win the second run only.
        #expect(pushes(state) == [
            .chipsPushed(pot: 0, runout: 0, amounts: [68, 0]),
            .chipsPushed(pot: 0, runout: 1, amounts: [0, 66]),
            .chipsPushed(pot: 0, runout: 2, amounts: [66, 0]),
        ])
    }

    @Test("a run not dealt yet is only the shared cards and what it has so far")
    func boardsBuildUp() throws {
        var state = try twoRuns().dealingStreet("Td")
        #expect(state.boards == [cards("2c7d9hTd"), cards("2c7d9h")])
        state = try state.dealingStreet("3s")
        #expect(state.boards == [cards("2c7d9hTd3s"), cards("2c7d9h")])
        state = try state.dealingStreet("Kc")
        #expect(state.boards == [cards("2c7d9hTd3s"), cards("2c7d9hKc")])
    }

    @Test("a known card is refused from every run, and the error names where it is (B1)")
    func duplicatesAcrossRuns() throws {
        let state = try twoRuns().dealingStreet("Td").dealingStreet("3s")
            .applying(.burnCard(card("8d")), .dealBoard(card("Kc")), .burnCard(.unknown))
        #expect(throws: EngineError.duplicateCard(card("7d"), location: .board(runout: 0))) {
            try state.apply(.dealBoard(card("7d")))
        }
        #expect(throws: EngineError.duplicateCard(card("3s"), location: .board(runout: 0))) {
            try state.apply(.dealBoard(card("3s")))
        }
        #expect(throws: EngineError.duplicateCard(card("Kc"), location: .board(runout: 1))) {
            try state.apply(.dealBoard(card("Kc")))
        }
        #expect(throws: EngineError.duplicateCard(card("8d"), location: .burned)) {
            try state.apply(.dealBoard(card("8d")))
        }
    }

    // MARK: Settlement

    @Test("each run pays its share of each pot, main pot first (A12)")
    func eachRunPaysItsShare() throws {
        let state = try HandState(config: .test(stacks: [100, 50, 30])).dealingHoles("AsKsQsAhKhQh")
            .applying(.betOrRaise(player: 2, to: 30), .betOrRaise(player: 0, to: 100), .checkOrCall(player: 1))
            .applying(selecting([3, 3, 3])).applying(shows(0, 1, 2))
            .dealingStreet("2c7d9h").dealingStreet("Td").dealingStreet("3s")
            .dealingStreet("Qc4c5d").dealingStreet("8h").dealingStreet("Jd")
            .dealingStreet("Kc6c6d").dealingStreet("8d").dealingStreet("2d")
        // The main pot of 90 splits evenly. The side pot of 40 leaves 1 over, for the first run.
        let expected: [HandEvent] = [
            .chipsPushed(pot: 0, runout: 0, amounts: [30, 0, 0]),
            .chipsPushed(pot: 0, runout: 1, amounts: [0, 0, 30]),
            .chipsPushed(pot: 0, runout: 2, amounts: [0, 30, 0]),
            .chipsPushed(pot: 1, runout: 0, amounts: [14, 0, 0]),
            .chipsPushed(pot: 1, runout: 1, amounts: [13, 0, 0]),
            .chipsPushed(pot: 1, runout: 2, amounts: [0, 13, 0]),
        ]
        #expect(pushes(state) == expected)
        #expect(state.stacks == [107, 43, 30])
        #expect(state.results?.map(\.won) == [57, 43, 30])
    }

    @Test("a tie on one run splits only that run's share")
    func tieOnOneRun() throws {
        let state = try HandState(config: .test(stacks: [100, 100])).dealingHoles("AsKsAhKh")
            .applying(.betOrRaise(player: 1, to: 100), .checkOrCall(player: 0))
            .applying(selecting([2, 2])).applying(shows(0, 1))
            .dealingStreet("TcJcQc").dealingStreet("Kc").dealingStreet("Ac")
            .dealingStreet("2d7d9h").dealingStreet("Td").dealingStreet("3s")
        #expect(pushes(state) == [
            .chipsPushed(pot: 0, runout: 0, amounts: [50, 50]),
            .chipsPushed(pot: 0, runout: 1, amounts: [100, 0]),
        ])
    }

    @Test("a pot too small for every run has nothing to push on the later ones (A12)")
    func potSmallerThanTheRunCount() throws {
        let state = try HandState(config: .test(stacks: [100, 100, 1], antes: [0, 0, 1]))
            .dealingHoles("AsKsQsAhKhQh")
            .applying(.betOrRaise(player: 0, to: 100), .checkOrCall(player: 1))
            .applying(selecting([2, 2, 2])).applying(shows(0, 1, 2))
            .dealingStreet("2c7d9h").dealingStreet("Td").dealingStreet("3s")
            .dealingStreet("Qc4c5d").dealingStreet("8h").dealingStreet("Jd")
        #expect(state.statuses == [.active, .killed, .active])
        // The queens win the 1-chip pot's second run, which holds nothing.
        #expect(pushes(state) == [
            .chipsPushed(pot: 0, runout: 0, amounts: [1, 0, 0]),
            .chipsPushed(pot: 1, runout: 0, amounts: [100, 0, 0]),
            .chipsPushed(pot: 1, runout: 1, amounts: [100, 0, 0]),
        ])
    }

    @Test("winning every run leaves one player, who is paid as a single survivor (A12)")
    func scoop() throws {
        let state = try twoRuns().dealingStreet("Td").dealingStreet("3s").dealingStreet("4c").dealingStreet("5d")
        #expect(state.statuses == [.active, .killed])
        #expect(pushes(state) == [.chipsPushed(pot: 0, runout: nil, amounts: [200, 0])])
        #expect(state.runoutCount == 2)
    }

    @Test("only a player who cannot win any run is killed, each run judged on its own board")
    func killedOnlyAfterLosingEveryRun() throws {
        // The kings win the second run with a hand worse than the four aces of the first.
        let state = try threeWayAllIn().applying(selecting([2, 2, 2])).applying(shows(0, 1, 2))
            .dealingStreet("AcAd2c").dealingStreet("7d").dealingStreet("9h")
            .dealingStreet("Kc4c5d").dealingStreet("8h").dealingStreet("Jd")
        #expect(state.statuses == [.active, .active, .killed])
        #expect(pushes(state) == [
            .chipsPushed(pot: 0, runout: 0, amounts: [150, 0, 0]),
            .chipsPushed(pot: 0, runout: 1, amounts: [0, 150, 0]),
        ])
    }

    @Test("settling hundreds of pushes does not recurse deep enough to overflow a thread's stack")
    func hundredsOfPushes() throws {
        // Ten players, nine pots and every hole card unscanned: four aces play on 48 boards, so every pot is tied on
        // every board. Before pushing became a loop this overflowed the test's stack in a debug build.
        let config = HandConfig.test(stacks: [1100, 1000, 900, 800, 700, 600, 500, 400, 300, 200])
        var state = HandState(config: config)
        while case let .dealHoleCard(player, _)? = state.pendingOperation {
            state = try state.apply(.dealHole(player: player, card: .unknown))
        }
        state = try state.checkingDown().dealingStreet("AsAhAd").checkingDown().dealingStreet("Ac")
            .apply(.betOrRaise(player: 0, to: 1098))
            .checkingDown()
            .applying(selecting(Array(repeating: 48, count: 10)))
        var rivers = Rank.allCases.flatMap { rank in Suit.allCases.map { Card.known(rank, $0) } }
            .filter { !cards("AsAhAdAc").contains($0) }
        while !state.isHandComplete {
            switch state.pendingOperation {
            case let .showdown(_, showOrder):
                state = try state.apply(keepsCards(showOrder[0]))
            case .burnCard:
                state = try state.apply(.burnCard(.unknown))
            default:
                state = try state.apply(.dealBoard(rivers.removeFirst()))
            }
        }
        #expect(state.runoutCount == 48)
        #expect(pushes(state).count == 432)
        #expect(state.stacks.reduce(0, +) == 6500)
        #expect(try HandState(json: state.json()) == state, "The largest hand fits a stored document")
    }

    @Test("hands are ranked board by board")
    func handsRankedByBoard() throws {
        let state = try twoRuns().dealingStreet("Td").dealingStreet("3s").dealingStreet("Kc").dealingStreet("Qd")
        #expect(state.hand(of: 0, board: 0)?.category == .onePair)
        #expect(state.hand(of: 1, board: 0)?.category == .onePair)
        #expect(state.hand(of: 0, board: 1)?.category == .onePair)
        #expect(state.hand(of: 1, board: 1)?.category == .threeOfAKind)
        #expect(state.hand(of: 1, board: 1, faceUpOnly: true)?.category == .threeOfAKind)
    }

    @Test("a board that does not exist has no hand, as in PokerKit")
    func noHandOnAMissingBoard() throws {
        let agreed = try flopAllIn().applying(selecting([2, 2]))
        #expect(agreed.runoutCount == 1)
        #expect(agreed.hand(of: 0, board: 1) == nil)
        #expect(agreed.hand(of: 0, board: 2, faceUpOnly: true) == nil)
        #expect(agreed.hand(of: 0, board: -1) == nil)
        #expect(try agreed.applying(shows(0, 1)).hand(of: 0, board: 1)?.category == .onePair)
    }

    @Test("a post-hand show between pushes can change a later run")
    func showBetweenRuns() throws {
        let kept = [keepsCards(0), keepsCards(1)]
        var state = try flopAllIn(automations: .bookkeeping.subtracting([.chipsPushing]))
            .applying(selecting([2, 2])).applying(kept)
            .dealingStreet("Td").applying(kept).dealingStreet("3s").applying(kept)
            .dealingStreet("Kc").applying(kept).dealingStreet("Qd").applying(kept)
        #expect(state.pendingOperation == .pushChips(pot: 0, runout: 0))
        state = try state.applying(.pushChips, .showHoleCards(player: 1, cards: cards("KsKh")), .pushChips)
        #expect(pushes(state) == [
            .chipsPushed(pot: 0, runout: 0, amounts: [50, 50]),
            .chipsPushed(pot: 0, runout: 1, amounts: [0, 100]),
        ])
    }

    // MARK: Re-asks and concessions

    @Test("a hand kept face down is asked again after every street of every run, the street going back between runs (A11)")
    func reaskOnEveryRun() throws {
        let asked = PendingOperation.showdown(runoutSelectors: [], showOrder: [1])
        var state = try flopAllIn().applying(selecting([2, 2])).applying(shows(0)).applying(keepsCards(1))
            .dealingStreet("Td")
        #expect(state.pendingOperation == asked)
        #expect(state.street == .turn)
        state = try state.applying(keepsCards(1)).dealingStreet("3s")
        // No showdown on this river: the street has already gone back.
        #expect(state.pendingOperation == asked)
        #expect(state.street == .flop)
        #expect(state.holeCards[1] == [down("Ks"), down("Kh")])
        #expect(throws: EngineError.noDealExpected(.burn)) { try state.apply(.burnCard(.unknown)) }
        state = try state.applying(keepsCards(1)).dealingStreet("Kc")
        #expect(state.pendingOperation == asked)
        state = try state.applying(keepsCards(1)).dealingStreet("Qd")
        #expect(state.pendingOperation == asked)
        #expect(state.street == .river)
    }

    @Test("only the last run's river forgets cards kept face down (A13)")
    func onlyTheLastRiverForgets() throws {
        let state = try flopAllIn(automations: .bookkeeping.subtracting([.handKilling]))
            .applying(selecting([2, 2])).applying(shows(0)).applying(keepsCards(1))
            .dealingStreet("Td").applying(keepsCards(1))
            .dealingStreet("3s").applying(keepsCards(1))
            .dealingStreet("Kc").applying(keepsCards(1))
            .dealingStreet("Qd")
        #expect(state.holeCards[1] == [down("Ks"), down("Kh")])
        // Unshown kings play the board on both runs, so the aces win both and the kings are to be killed.
        let forgotten = try state.applying(keepsCards(1))
        #expect(forgotten.holeCards[1] == [down("??"), down("??")])
        #expect(forgotten.pendingOperation == .killHand(players: [1]))
        let settled = try forgotten.applying(.killHand(player: 1))
        #expect(settled.results?[1].holeCards == [down("Ks"), down("Kh")])
        #expect(settled.stacks == [200, 0])
    }

    @Test("a concession deals only the next street, so the boards end up uneven (A15)")
    func concessionBeforeTheFirstRun() throws {
        let state = try flopAllIn().applying(selecting([2, 2])).applying(shows(0)).applying(.muckHoleCards(player: 1))
        #expect(state.pendingOperation == .burnCard(street: .turn, runout: 0))
        let settled = try state.dealingStreet("Td")
        #expect(settled.isHandComplete)
        #expect(settled.boards == [cards("2c7d9hTd"), cards("2c7d9h")])
        #expect(pushes(settled) == [.chipsPushed(pot: 0, runout: nil, amounts: [200, 0])])
    }

    @Test("a concession on the last street of a run ends the hand before the next run")
    func concessionBeforeTheRewind() throws {
        let state = try flopAllIn().applying(selecting([2, 2])).applying(shows(0)).applying(keepsCards(1))
            .dealingStreet("Td").applying(.muckHoleCards(player: 1)).dealingStreet("3s")
        #expect(state.isHandComplete)
        #expect(state.boards == [cards("2c7d9hTd3s"), cards("2c7d9h")])
    }

    @Test("a concession between runs deals one street of the next run")
    func concessionBetweenRuns() throws {
        let state = try flopAllIn().applying(selecting([2, 2])).applying(shows(0)).applying(keepsCards(1))
            .dealingStreet("Td").applying(keepsCards(1))
            .dealingStreet("3s").applying(.muckHoleCards(player: 1))
        #expect(state.pendingOperation == .burnCard(street: .turn, runout: 1))
        let settled = try state.dealingStreet("Kc")
        #expect(settled.isHandComplete)
        #expect(settled.boards == [cards("2c7d9hTd3s"), cards("2c7d9hKc")])
        #expect(pushes(settled) == [.chipsPushed(pot: 0, runout: nil, amounts: [200, 0])])
    }

    @Test("a muck between runs that would abandon a side pot is refused (B2)")
    func abandonedPotBetweenRuns() throws {
        let state = try HandState(config: .test(stacks: [100, 100, 50])).dealingHoles("AsKsQsAhKhQh")
            .applying(.betOrRaise(player: 2, to: 50), .betOrRaise(player: 0, to: 100), .checkOrCall(player: 1))
            .applying(selecting([2, 2, 2])).applying(keepsCards(0), keepsCards(1), .showHoleCards(player: 2))
            .dealingStreet("2c7d9h").applying(.muckHoleCards(player: 0), keepsCards(1))
            .dealingStreet("Td").applying(keepsCards(1))
            .dealingStreet("3s")
        #expect(throws: EngineError.wouldAbandonPot(player: 1, pot: 1)) {
            try state.apply(.muckHoleCards(player: 1))
        }
    }

    // MARK: Unknown cards

    @Test("an unknown card on any run blocks the last deal of the last run, naming that run's position (B4)")
    func unknownCardOnALaterRun() throws {
        let state = try twoRuns().dealingStreet("Td").dealingStreet("3s").dealingStreet("Kc")
            .apply(.burnCard(.unknown))
        #expect(throws: EngineError.unknownBoardCard(runout: 1, position: 4)) { try state.apply(.dealBoard(.unknown)) }
        let known = try state.apply(.dealBoard(card("Qd")))
        #expect(known.isHandComplete)
        let firstRun = try twoRuns().dealingStreet("Td").dealingStreet("??").dealingStreet("Kc")
            .apply(.burnCard(.unknown))
        #expect(throws: EngineError.unknownBoardCard(runout: 0, position: 4)) {
            try firstRun.apply(.dealBoard(card("Qd")))
        }
    }

    @Test("with unknown cards on two runs the error names the first run's, whatever the positions (B4)")
    func unknownCardsOnTwoRuns() throws {
        let state = try twoRuns().dealingStreet("Td").dealingStreet("??").dealingStreet("??")
            .apply(.burnCard(.unknown))
        #expect(throws: EngineError.unknownBoardCard(runout: 0, position: 4)) {
            try state.apply(.dealBoard(card("Qd")))
        }
    }

    @Test("an unknown shared card is reported on the first run (B4)")
    func unknownSharedCard() throws {
        let state = try HandState(config: .test(stacks: [100, 100])).dealingHoles("AsKsAhKh").checkingDown()
            .dealingStreet("2c??9h")
            .applying(.betOrRaise(player: 0, to: 98), .checkOrCall(player: 1))
            .applying(selecting([2, 2])).applying(shows(0, 1))
            .dealingStreet("Td").dealingStreet("3s").dealingStreet("Kc").apply(.burnCard(.unknown))
        #expect(throws: EngineError.unknownBoardCard(runout: 0, position: 1)) {
            try state.apply(.dealBoard(card("Qd")))
        }
    }

    @Test("a lone survivor is paid whatever a run left unknown (B4)")
    func unknownCardOnAConcession() throws {
        let state = try flopAllIn().applying(selecting([2, 2])).applying(shows(0)).applying(keepsCards(1))
            .dealingStreet("Td").applying(keepsCards(1))
            .dealingStreet("3s").applying(.muckHoleCards(player: 1))
            .dealingStreet("??")
        #expect(state.isHandComplete)
        #expect(state.stacks == [200, 0])
        #expect(state.hand(of: 0, board: 1) == nil)
    }

    @Test("when the deck runs out nothing is reshuffled: every card stays where it went (B1)")
    func noReshuffle() throws {
        let rest = Rank.allCases.flatMap { rank in Suit.allCases.map { Card.known(rank, $0) } }
            .filter { !cards("AsAhKsKh2c").contains($0) }
        var state = try HandState(config: .test(stacks: [100, 100])).dealingHoles("AsKsAhKh")
            .applying(.betOrRaise(player: 1, to: 100), .checkOrCall(player: 0))
            .applying(selecting([10, 10])).applying(shows(0, 1))
            .apply(.burnCard(card("2c")))
        for card in rest {
            if case .burnCard? = state.pendingOperation {
                state = try state.apply(.burnCard(.unknown))
            }
            state = try state.apply(.dealBoard(card))
        }
        // The last 47 cards fill nine runs and two thirds of the tenth flop.
        #expect(state.pendingOperation == .dealBoardCard(street: .flop, runout: 9, cardIndex: 2, cardCount: 3))
        #expect(throws: EngineError.duplicateCard(card("2c"), location: .burned)) {
            try state.apply(.dealBoard(card("2c")))
        }
        #expect(throws: EngineError.duplicateCard(card("2d"), location: .board(runout: 0))) {
            try state.apply(.dealBoard(card("2d")))
        }
        #expect(state.canApply(.dealBoard(.unknown)))
    }

    // MARK: Replay

    @Test("a hand run twice replays to the same state, and a card on a later run can be corrected")
    func replay() throws {
        let state = try twoRuns().dealingStreet("Td").dealingStreet("3s").dealingStreet("Kc").dealingStreet("Qd")
        #expect(try HandState.replay(config: state.config, operations: state.operations) == state)
        let index = try #require(state.operations.lastIndex(of: .dealBoard(card("Kc"))))
        let corrected = try state.replacingOperation(at: index, with: .dealBoard(card("4c")))
        #expect(corrected.boards == [cards("2c7d9hTd3s"), cards("2c7d9h4cQd")])
        #expect(corrected.stacks == [200, 0])
    }
}
