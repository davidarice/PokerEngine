import Testing
@testable import PokerEngine

// The No-Limit Texas Hold'em parts of PokerKit's pokerkit/tests/test_state.py. Other variants' parts are not ported.
//
// A source hand that names no mode runs in PokerKit's default, a tournament. PokerKit's show-or-muck automation has no
// engine counterpart, so each port enters what PokerKit's run decided: show when all in or able to win, else muck.
// `complete_bet_or_raise_to()` with no amount means the minimum. The engine refuses before it judges an amount, so
// the refused ports pass the usual minimum.

extension HandState {
    fileprivate var pushes: [HandEvent] {
        events.filter { if case .chipsPushed = $0 { true } else { false } }
    }
}

@Suite("Ported: test_state.py")
struct PortedStateTests {
    private static let manualPushing: Set<HandConfig.Automation> = .bookkeeping.subtracting([.chipsPushing])

    /// For a source that automates hole dealing and never looks at the cards.
    private func dealt(_ config: HandConfig) throws -> HandState {
        let cards = "AsAhKsKhQsQhJsJhTsTh9s9h"
        return try HandState(config: config).dealingHoles(String(cards.prefix(config.playerCount * 4)))
    }

    /// `test_chips_pushing` ends every hand on a royal flush on the board, so all pots chop. With the source's 10%
    /// rake dropped, each stack just ends where it started, which says little about the pushes. The hands therefore
    /// also assert the pushes, with the amounts PokerKit records without rake.
    private func pushingChoppedPots(_ state: HandState, count: Int) throws -> HandState {
        var state = try state.dealingStreet("TsJsQs").dealingStreet("Ks").dealingStreet("As")
        for _ in 0..<count {
            state = try state.apply(.pushChips)
        }
        return state
    }

    // MARK: test_all_ins

    @Test("test_all_ins, 1st hand: a big blind all in for a dead ante and the blind")
    func allIns1() throws {
        var state = try HandState(config: .test(.tournament, stacks: [6, 4, 1], antes: [0, 2]))
            .dealing("AcAd", "KcKd", "QcQd")
        #expect(throws: EngineError.raiseNotAllowed(player: 2, reason: .playerIsCovered)) {
            try state.apply(.betOrRaise(player: 2, to: 4))
        }
        state = try state.apply(.checkOrCall(player: 2))
        #expect(throws: EngineError.raiseNotAllowed(player: 0, reason: .noOpponentCanRespond)) {
            try state.apply(.betOrRaise(player: 0, to: 4))
        }
        state = try state.applying(
            .checkOrCall(player: 0), .showHoleCards(player: 2), .showHoleCards(player: 0), .showHoleCards(player: 1)
        ).dealingStreet("QhQs2c").dealingStreet("3c").dealingStreet("4c")
        #expect(state.isHandComplete)
        #expect(state.stacks == [6, 0, 5])
    }

    @Test("test_all_ins, 2nd hand: uniform antes, with a player all in for part of the ante")
    func allIns2() throws {
        var state = try HandState(config: .test(.tournament, stacks: [6, 4, 1], antes: [2, 2, 2], anteTrimming: true))
            .dealing("AcAd", "KcKd", "QcQd")
        #expect(throws: EngineError.raiseNotAllowed(player: 0, reason: .noOpponentCanRespond)) {
            try state.apply(.betOrRaise(player: 0, to: 4))
        }
        state = try state.applying(
            .checkOrCall(player: 0), .showHoleCards(player: 2), .showHoleCards(player: 0), .showHoleCards(player: 1)
        ).dealingStreet("QhQs2c").dealingStreet("3c").dealingStreet("4c")
        #expect(state.isHandComplete)
        #expect(state.stacks == [8, 0, 3])
    }

    @Test("test_all_ins, 3rd hand: everyone all in from the forced bets, so nobody acts")
    func allIns3() throws {
        let state = try HandState(config: .test(.tournament, stacks: [3, 4, 1], antes: [2, 2, 2], anteTrimming: true))
            .dealing("AcAd", "KcKd", "QcQd")
            .applying(.showHoleCards(player: 2), .showHoleCards(player: 0), .showHoleCards(player: 1))
            .dealingStreet("QhQs2c").dealingStreet("3c").dealingStreet("4c")
        #expect(state.isHandComplete)
        #expect(state.stacks == [4, 1, 3])
    }

    @Test("test_all_ins, 4th hand: six players, five stack sizes, and one winner of every pot")
    func allIns4() throws {
        var state = try HandState(config: .test(
            .tournament, stacks: [3, 4, 6, 1, 2, 2], antes: [2, 2, 2, 2, 2, 2], anteTrimming: true
        )).dealing("AcAd", "KcKd", "QcQd", "JcJd", "TcTd", "9c9d")
        #expect(throws: EngineError.raiseNotAllowed(player: 2, reason: .noOpponentCanRespond)) {
            try state.apply(.betOrRaise(player: 2, to: 4))
        }
        state = try state.applying(
            .checkOrCall(player: 2), .showHoleCards(player: 2), .showHoleCards(player: 3), .showHoleCards(player: 4),
            .showHoleCards(player: 5), .showHoleCards(player: 0), .showHoleCards(player: 1)
        ).dealingStreet("QhQs2c").dealingStreet("3c").dealingStreet("4c")
        #expect(state.isHandComplete)
        #expect(state.stacks == [0, 0, 18, 0, 0, 0])
    }

    @Test("test_all_ins, 5th hand: a blind all in preflop while the others bet on until the flop")
    func allIns5() throws {
        let state = try HandState(config: .test(.tournament, stacks: [200, 2, 200], anteTrimming: true))
            .dealing("AcAd", "KcKd", "QcQd")
            .applying(.betOrRaise(player: 2, to: 100), .checkOrCall(player: 0))
            .dealingStreet("QhQs2c")
            .applying(.betOrRaise(player: 0, to: 100), .checkOrCall(player: 2))
            .applying(.showHoleCards(player: 0), .showHoleCards(player: 1), .showHoleCards(player: 2))
            .dealingStreet("3c").dealingStreet("4c")
        #expect(state.isHandComplete)
        #expect(state.stacks == [0, 0, 402])
    }

    @Test("test_all_ins, 6th hand: a small blind covered by the raise can only call or fold")
    func allIns6() throws {
        var state = try HandState(config: .test(.tournament, stacks: [2, 200, 200], anteTrimming: true))
            .dealing("AcAd", "KcKd", "QcQd")
            .applying(.betOrRaise(player: 2, to: 100))
        // PokerKit says "Short all-in cannot be raised."; DECISIONS.md D labels a covered player by meaning.
        #expect(throws: EngineError.raiseNotAllowed(player: 0, reason: .playerIsCovered)) {
            try state.apply(.betOrRaise(player: 0, to: 198))
        }
        state = try state.applying(.checkOrCall(player: 0), .checkOrCall(player: 1))
            .dealingStreet("QhQs2c")
            .applying(.betOrRaise(player: 1, to: 100), .checkOrCall(player: 2))
            .applying(.showHoleCards(player: 1), .showHoleCards(player: 2), .showHoleCards(player: 0))
            .dealingStreet("3c").dealingStreet("4c")
        #expect(state.isHandComplete)
        #expect(state.stacks == [0, 0, 402])
    }

    // MARK: test_preflop_opener

    @Test("test_preflop_opener: the action starts left of the largest blind or straddle")
    func preflopOpener() throws {
        func actor(_ blinds: [Int], players: Int) throws -> Int? {
            try dealt(.test(.tournament, stacks: Array(repeating: 200, count: players), blinds: blinds)).actor
        }
        #expect(try actor([1, 2], players: 2) == 1)
        #expect(try actor([1, 2], players: 3) == 2)
        #expect(try actor([1, 2], players: 6) == 2)
        #expect(try actor([1, 2, 4], players: 6) == 3)
        #expect(try actor([1, 2, 4, 8], players: 6) == 4)
        #expect(try actor([1, 2, 0, 0, 0, 4], players: 6) == 0)
        #expect(try actor([1, 2, 4, 0, 0, 8], players: 6) == 0)
    }

    // MARK: test_chips_pushing

    @Test("test_chips_pushing, 1st hand: heads-up, one chopped pot, one push")
    func chipsPushing1() throws {
        let state = try pushingChoppedPots(
            HandState(config: .test(
                .tournament, stacks: [100, 10], anteTrimming: true, automations: Self.manualPushing
            ))
                .dealing("2c3c", "2d3d")
                .applying(.betOrRaise(player: 1, to: 10), .checkOrCall(player: 0))
                .applying(.showHoleCards(player: 1), .showHoleCards(player: 0)),
            count: 1
        )
        #expect(state.isHandComplete)
        #expect(state.stacks == [100, 10])
        #expect(state.pushes == [.chipsPushed(pot: 0, runout: 0, amounts: [10, 10])])
    }

    @Test("test_chips_pushing, 2nd hand: three stacks, main pot pushed before the side pot")
    func chipsPushing2() throws {
        let state = try pushingChoppedPots(
            HandState(config: .test(
                .tournament, stacks: [100, 10, 1000], anteTrimming: true, automations: Self.manualPushing
            ))
                .dealing("2c3c", "2d3d", "2h3h")
                .applying(.betOrRaise(player: 2, to: 1000), .checkOrCall(player: 0), .checkOrCall(player: 1))
                .applying(.showHoleCards(player: 2), .showHoleCards(player: 0), .showHoleCards(player: 1)),
            count: 2
        )
        #expect(state.isHandComplete)
        #expect(state.stacks == [100, 10, 1000])
        #expect(state.pushes == [
            .chipsPushed(pot: 0, runout: 0, amounts: [10, 10, 10]),
            .chipsPushed(pot: 1, runout: 0, amounts: [90, 0, 90]),
        ])
    }

    @Test("test_chips_pushing, 3rd hand: four stacks, three pots")
    func chipsPushing3() throws {
        let state = try pushingChoppedPots(
            HandState(config: .test(
                .tournament, stacks: [100, 10, 10000, 1000], anteTrimming: true, automations: Self.manualPushing
            ))
                .dealing("2c3c", "2d3d", "2h3h", "2s3s")
                .applying(
                    .betOrRaise(player: 2, to: 10000), .checkOrCall(player: 3), .checkOrCall(player: 0),
                    .checkOrCall(player: 1)
                )
                .applying(
                    .showHoleCards(player: 2), .showHoleCards(player: 3), .showHoleCards(player: 0),
                    .showHoleCards(player: 1)
                ),
            count: 3
        )
        #expect(state.isHandComplete)
        #expect(state.stacks == [100, 10, 10000, 1000])
        #expect(state.pushes == [
            .chipsPushed(pot: 0, runout: 0, amounts: [10, 10, 10, 10]),
            .chipsPushed(pot: 1, runout: 0, amounts: [90, 0, 90, 90]),
            .chipsPushed(pot: 2, runout: 0, amounts: [0, 0, 900, 900]),
        ])
    }

    @Test("test_chips_pushing, 4th hand: five stacks, four pots")
    func chipsPushing4() throws {
        let state = try pushingChoppedPots(
            HandState(config: .test(
                .tournament, stacks: [100, 10, 100000, 10000, 1000], anteTrimming: true,
                automations: Self.manualPushing
            ))
                .dealing("2c3c", "2d3d", "2h3h", "2s3s", "4c5c")
                .applying(
                    .betOrRaise(player: 2, to: 100000), .checkOrCall(player: 3), .checkOrCall(player: 4),
                    .checkOrCall(player: 0), .checkOrCall(player: 1)
                )
                .applying(
                    .showHoleCards(player: 2), .showHoleCards(player: 3), .showHoleCards(player: 4),
                    .showHoleCards(player: 0), .showHoleCards(player: 1)
                ),
            count: 4
        )
        #expect(state.isHandComplete)
        #expect(state.stacks == [100, 10, 100000, 10000, 1000])
        #expect(state.pushes == [
            .chipsPushed(pot: 0, runout: 0, amounts: [10, 10, 10, 10, 10]),
            .chipsPushed(pot: 1, runout: 0, amounts: [90, 0, 90, 90, 90]),
            .chipsPushed(pot: 2, runout: 0, amounts: [0, 0, 900, 900, 900]),
            .chipsPushed(pot: 3, runout: 0, amounts: [0, 0, 9000, 9000, 0]),
        ])
    }

    // The source's 5th hand expects [82, 116] with a 10% rake. Its 6th is the same hand with no-flop-no-drop, so
    // without rake the two are one hand, and the 6th's [82, 118] is the value here.
    @Test("test_chips_pushing, 5th and 6th hands: a fold-out, with unknown hole cards")
    func chipsPushingFoldOut() throws {
        let state = try HandState(config: .test(
            .tournament, stacks: [100, 100], anteTrimming: true, automations: Self.manualPushing
        ))
            .dealing("????", "????")
            .applying(
                .betOrRaise(player: 1, to: 6), .betOrRaise(player: 0, to: 18), .betOrRaise(player: 1, to: 54),
                .fold(player: 0), .pushChips
            )
        #expect(state.isHandComplete)
        #expect(state.stacks == [82, 118])
        #expect(state.pushes == [.chipsPushed(pot: 0, runout: nil, amounts: [0, 18])])
    }

    // MARK: test_unknown_showdown

    @Test("test_unknown_showdown, adapted to B2: unknown hands may reveal or muck, but the last muck is refused")
    func unknownShowdown() throws {
        var state = try HandState(config: .test(.tournament, stacks: [200, 200, 200], anteTrimming: true))
            .dealing("????", "????", "????")
            .applying(.checkOrCall(player: 2), .checkOrCall(player: 0), .checkOrCall(player: 1))
        for street in ["TsJsQs", "Ks", "As"] {
            state = try state.dealingStreet(street)
                .applying(.checkOrCall(player: 0), .checkOrCall(player: 1), .checkOrCall(player: 2))
        }

        let reveal = try Card.parse("TcJc")
        for player in [0, 1, 2] {
            // PokerKit gives all three refusals one message, "A card is not shown in final showdown."; the engine
            // labels a show as is by its meaning. The player left may keep cards face down (B13), so a list is
            // refused only for its unknown entries (B14).
            let listed: EngineError = player < 2
                ? .mustShowAllCards(player: player) : .cannotShowUnknownCard(player: player)
            #expect(throws: EngineError.cannotShowUnknownCard(player: player)) {
                try state.apply(.showHoleCards(player: player))
            }
            #expect(throws: listed) {
                try state.apply(.showHoleCards(player: player, cards: Card.parse("????")))
            }
            #expect(throws: listed) {
                try state.apply(.showHoleCards(player: player, cards: Card.parse("??2d")))
            }
            #expect(state.canApply(.showHoleCards(player: player, cards: reveal)))
            if player < 2 {
                #expect(state.canApply(.muckHoleCards(player: player)))
                state = try state.apply(.muckHoleCards(player: player))
                #expect(state.events.last == .holeCardsMucked(player: player))
            }
        }

        // PokerKit lets the third player muck too, and the pot's 6 chips vanish with nobody eligible. B2 refuses that
        // muck, so the hand can only end with this player showing or keeping the cards face down (B13), and the pot
        // is paid to the only player left.
        #expect(throws: EngineError.wouldAbandonPot(player: 2, pot: 0)) { try state.apply(.muckHoleCards(player: 2)) }
        #expect(state.canApply(.showHoleCards(player: 2, cards: [])))
        state = try state.apply(.showHoleCards(player: 2, cards: reveal))

        #expect(state.isHandComplete)
        #expect(state.pots == [Pot(amount: 0, eligiblePlayers: [2])])
        #expect(state.pots.map(\.amount) == [0])
        #expect(state.totalPot == 0)
        #expect(state.config.startingStacks == [200, 200, 200])
        #expect(state.stacks == [198, 198, 204])
    }

    // MARK: test_post_bets

    @Test("test_post_bets: a live post is not a blind for the opener, and its poster keeps the option")
    func postBets() throws {
        func config(_ blinds: [Int]) -> HandConfig {
            .test(.tournament, stacks: Array(repeating: 200, count: 6), anteTrimming: true, blinds: blinds)
        }
        #expect(try dealt(config([1, 2])).actor == 2)
        #expect(try dealt(config([1, 2, -2])).actor == 2)
        #expect(try dealt(config([1, 2, 0, -2])).actor == 2)
        #expect(try dealt(config([1, 2, 0, 0, -2])).actor == 2)
        #expect(try dealt(config([1, 2, -2, 0, 0, -2])).actor == 2)
        #expect(try dealt(config([2, 2])).actor == 2)
        #expect(try dealt(config([1, 2, 4])).actor == 3)
        #expect(try dealt(config([1, 2, 4, -2, -2])).actor == 3)

        // The source's last check is on the flop, which its automation deals right after player 1's check.
        let state = try dealt(config([1, 2, 0, 0, -2, -2]))
            .applying(
                .checkOrCall(player: 2), .checkOrCall(player: 3), .checkOrCall(player: 4), .checkOrCall(player: 5),
                .checkOrCall(player: 0), .checkOrCall(player: 1)
            )
            .dealingStreet("2c7d3h")
            .applying(.checkOrCall(player: 0))
        #expect(state.checksAndCalls == [
            .checkedOrCalled(player: 2, amount: 2),
            .checkedOrCalled(player: 3, amount: 2),
            .checkedOrCalled(player: 4, amount: 0),
            .checkedOrCalled(player: 5, amount: 0),
            .checkedOrCalled(player: 0, amount: 1),
            .checkedOrCalled(player: 1, amount: 0),
            .checkedOrCalled(player: 0, amount: 0),
        ])
    }

    // MARK: test_nonstandard_folds

    @Test("test_nonstandard_folds, adapted to B2: the free fold that would burn the top side pot is refused")
    func nonstandardFolds() throws {
        // A hand history runs as a cash game, with runout selection automated.
        let startingStacks = [2198, 945, 852, 3348, 1687, 1262, 3657, 3966]
        var state = try HandState(config: .test(
            stacks: startingStacks, antes: Array(repeating: 125, count: 8), blinds: [250, 500], minBet: 125,
            automations: .bookkeeping.union([.runoutCountSelection])
        ))
            .dealing("9h5c", "KsQh", "7sQd", "2dKc", "8c6d", "Td9s", "8hQs", "9cKh")
            .applying(
                .betOrRaise(player: 2, to: 645), .checkOrCall(player: 3), .betOrRaise(player: 4, to: 1288),
                .checkOrCall(player: 5), .checkOrCall(player: 6), .checkOrCall(player: 7), .checkOrCall(player: 0),
                .checkOrCall(player: 1), .checkOrCall(player: 2), .betOrRaise(player: 3, to: 3178),
                .checkOrCall(player: 4), .fold(player: 6), .checkOrCall(player: 7), .checkOrCall(player: 0)
            )
            .dealingStreet("2h6c4h")
            .applying(.fold(player: 3))

        // The source's player 7 folds here as well, and PokerKit burns the 2210 chips only players 3 and 7 had
        // covered. B2 refuses the fold, so player 7 checks and shows, and wins that pot. The index is 5 while the
        // pots stand apart; kills merge the lower ones before the push, so PokerKit's record calls it pot 3.
        #expect(state.legalActions?.canFold == false)
        #expect(throws: EngineError.wouldAbandonPot(player: 7, pot: 5)) { try state.apply(.fold(player: 7)) }
        state = try state.apply(.checkOrCall(player: 7))
        #expect(throws: EngineError.wouldAbandonPot(player: 7, pot: 5)) { try state.apply(.muckHoleCards(player: 7)) }

        state = try state.applying(
            .showHoleCards(player: 0, cards: Card.parse("9h5c")),
            .showHoleCards(player: 1, cards: Card.parse("KsQh")),
            .showHoleCards(player: 2, cards: Card.parse("7sQd")),
            .showHoleCards(player: 4, cards: Card.parse("8c6d")),
            .showHoleCards(player: 5, cards: Card.parse("Td9s")),
            .showHoleCards(player: 7, cards: Card.parse("9cKh"))
        ).dealingStreet("Th").dealingStreet("5d")

        #expect(state.isHandComplete)
        #expect(startingStacks.reduce(0, +) - state.stacks.reduce(0, +) == 0)
        #expect(state.stacks == [1533, 0, 0, 45, 1851, 9369, 2244, 2873])
    }

    // MARK: test_folded_status

    // The source plays Rhode Island Hold'em, so these are hold'em hands written for the same question, not ports.
    @Test("test_folded_status, rewritten on hold'em: only a fold-out sets it, never a showdown")
    func foldedStatus() throws {
        func toRiver() throws -> HandState {
            var state = try HandState(config: .test(.tournament, stacks: [200, 200, 200], anteTrimming: true))
                .dealing("AsAh", "KsKh", "QsQh")
                .applying(.checkOrCall(player: 2), .checkOrCall(player: 0), .checkOrCall(player: 1))
            for street in ["2c7d9h", "Jc"] {
                state = try state.dealingStreet(street)
                    .applying(.checkOrCall(player: 0), .checkOrCall(player: 1), .checkOrCall(player: 2))
            }
            return try state.dealingStreet("3s")
        }

        let contested = try toRiver().applying(
            .betOrRaise(player: 0, to: 4), .checkOrCall(player: 1), .checkOrCall(player: 2),
            .showHoleCards(player: 0), .showHoleCards(player: 1), .showHoleCards(player: 2)
        )
        #expect(contested.isHandComplete)
        #expect(contested.stacks == [212, 194, 194])
        #expect(!contested.foldedStatus)

        let mucked = try toRiver().applying(
            .checkOrCall(player: 0), .checkOrCall(player: 1), .checkOrCall(player: 2),
            .muckHoleCards(player: 0), .muckHoleCards(player: 1), .showHoleCards(player: 2)
        )
        #expect(mucked.isHandComplete)
        #expect(mucked.stacks == [198, 198, 204])
        #expect(!mucked.foldedStatus)

        let preflop = try HandState(config: .test(.tournament, stacks: [200, 200, 200], anteTrimming: true))
            .dealing("AsAh", "KsKh", "QsQh")
            .applying(.betOrRaise(player: 2, to: 6), .fold(player: 0), .fold(player: 1))
        #expect(preflop.isHandComplete)
        #expect(preflop.stacks == [199, 198, 203])
        #expect(preflop.foldedStatus)

        let river = try toRiver().applying(.betOrRaise(player: 0, to: 4), .fold(player: 1), .fold(player: 2))
        #expect(river.isHandComplete)
        #expect(river.stacks == [204, 198, 198])
        #expect(river.foldedStatus)
    }

    // MARK: test_full_and_short_all_ins

    @Test("test_full_and_short_all_ins: a short all-in after a full one does not reopen the action")
    func fullAndShortAllIns() throws {
        let betting: [HandOperation] = [
            .betOrRaise(player: 2, to: 16), .checkOrCall(player: 3), .betOrRaise(player: 0, to: 19),
            .checkOrCall(player: 1),
        ]

        var state = try dealt(.test(stacks: [19, 200, 16, 200], anteTrimming: true)).applying(betting)
        #expect(state.actor == 3)
        #expect(throws: EngineError.raiseNotAllowed(player: 3, reason: .actionNotReopened)) {
            try state.apply(.betOrRaise(player: 3, to: 33))
        }

        state = try dealt(.test(stacks: [19, 200, 200, 200], anteTrimming: true)).applying(betting)
        #expect(state.actor == 2)
        #expect(throws: EngineError.raiseNotAllowed(player: 2, reason: .actionNotReopened)) {
            try state.apply(.betOrRaise(player: 2, to: 33))
        }
        state = try state.apply(.checkOrCall(player: 2))
        #expect(state.actor == 3)
        #expect(throws: EngineError.raiseNotAllowed(player: 3, reason: .actionNotReopened)) {
            try state.apply(.betOrRaise(player: 3, to: 33))
        }
    }

    // MARK: test_can_win_now

    @Test("test_can_win_now: the hands that can win no pot are the ones to kill, side pots included")
    func canWinNow() throws {
        var state = try HandState(config: .test(
            stacks: [76, 181, 300, 117, 5, 66, 27], antes: Array(repeating: 1, count: 7), anteTrimming: true,
            automations: [.antePosting, .betCollection, .blindOrStraddlePosting, .runoutCountSelection]
        ))
            .dealing("QhTs", "8h2s", "AsKh", "4s6d", "Ah6c", "TcQd", "4dQc")
            .applying(
                .betOrRaise(player: 2, to: 114), .betOrRaise(player: 3, to: 116), .fold(player: 4),
                .checkOrCall(player: 5), .checkOrCall(player: 6), .checkOrCall(player: 0), .checkOrCall(player: 1),
                .fold(player: 2)
            )
            .applying(
                .showHoleCards(player: 3), .showHoleCards(player: 5), .showHoleCards(player: 6),
                .showHoleCards(player: 0), .showHoleCards(player: 1)
            )
            .dealingStreet("7c2hTd").dealingStreet("Kc").dealingStreet("Qs")

        // `can_win_now` and `hand_killing_statuses` together: exactly players 3 and 6 can win nothing.
        #expect(state.pendingOperation == .killHand(players: [3, 6]))

        state = try state.applying(
            .killHand(player: 3), .killHand(player: 6), .pushChips, .pushChips, .pushChips,
            .pullChips(player: 0), .pullChips(player: 1), .pullChips(player: 5)
        )
        #expect(state.isHandComplete)
        #expect(state.results?.map(\.net) == [143, 4, -115, -117, -1, 113, -27])
    }

    // MARK: test_short_all_ins

    @Test("test_short_all_ins: short all-ins adding up to a full raise reopen the bettor's action, not the caller's")
    func shortAllIns() throws {
        var state = try HandState(config: .test(
            .tournament, stacks: [1002, 152, 1002, 202], anteTrimming: true,
            automations: [.antePosting, .betCollection, .blindOrStraddlePosting]
        ))
            .dealing("AsAd", "KsKd", "QsQd", "JsJd")
            .applying(
                .checkOrCall(player: 2), .checkOrCall(player: 3), .checkOrCall(player: 0), .checkOrCall(player: 1)
            )
            .dealingStreet("2c3c4c")
            .applying(
                .betOrRaise(player: 0, to: 100), .betOrRaise(player: 1, to: 150), .checkOrCall(player: 2),
                .betOrRaise(player: 3, to: 200)
            )
        #expect(state.canApply(.betOrRaise(player: 0, to: 300)))

        state = try state.apply(.checkOrCall(player: 0))
        #expect(state.actor == 2)
        #expect(state.toCall == 50)
        #expect(throws: EngineError.raiseNotAllowed(player: 2, reason: .actionNotReopened)) {
            try state.apply(.betOrRaise(player: 2, to: 300))
        }
    }
}
