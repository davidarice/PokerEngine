import Testing
@testable import PokerEngine

// The 11 No-Limit Texas Hold'em hands of PokerKit's pokerkit/tests/test_wsop/test_2023_43_5.py, hands played on Day 5
// of the 2023 World Series of Poker Event #43. The other variants' hands are not ported, test_2023_54_4.py has no
// No-Limit Texas Hold'em hand, and each hand's closing hand-history round trip loads PHH, which the engine does not
// read.
//
// The source fixes the deck, then draws from it; here each card is named where it is dealt, in the same order. Its
// `show_or_muck_hole_cards()` becomes the show PokerKit's run chose.

@Suite("Ported: test_wsop/test_2023_43_5.py")
struct PortedWSOP2023Event43Tests {
    /// The source's `game`: every bookkeeping step by hand, a big-blind ante, and PokerKit's default mode, a
    /// tournament. Each hand opens by posting these same forced bets.
    private func posted(_ stacks: [Int], ante: Int, blinds: [Int]) throws -> HandState {
        try HandState(config: .test(
            .tournament, stacks: stacks, antes: [0, ante], blinds: blinds, minBet: blinds[1], automations: []
        )).applying(
            .postAnte(player: 1), .collectBets, .postBlindOrStraddle(player: 0), .postBlindOrStraddle(player: 1)
        )
    }

    @Test("test_1_00_02_07: a bet called on every street, then a river showdown with a hand killed")
    func hand1() throws {
        var state = try posted([7380000, 2500000, 5110000, 10170000, 4545000], ante: 120000, blinds: [40000, 80000])
        #expect(state.totalPot == 240000)

        // Pre-flop
        state = try state.dealingHoles("7s Js Td 6d Qh 4s 8h 8c 5h 7h").applying(
            .fold(player: 2), .betOrRaise(player: 3, to: 170000), .fold(player: 4), .fold(player: 0),
            .checkOrCall(player: 1), .collectBets
        )
        #expect(state.totalPot == 500000)

        // Flop
        state = try state.dealingStreet("JcTs2d").applying(
            .checkOrCall(player: 1), .betOrRaise(player: 3, to: 140000), .checkOrCall(player: 1), .collectBets
        )
        #expect(state.totalPot == 780000)

        // Turn
        state = try state.dealingStreet("As").applying(
            .checkOrCall(player: 1), .betOrRaise(player: 3, to: 325000), .checkOrCall(player: 1), .collectBets
        )
        #expect(state.totalPot == 1430000)

        // River
        state = try state.dealingStreet("Qs").applying(
            .checkOrCall(player: 1), .betOrRaise(player: 3, to: 600000), .checkOrCall(player: 1), .collectBets
        )
        #expect(state.totalPot == 2630000)

        // Showdown
        state = try state.applying(.showHoleCards(player: 3), .showHoleCards(player: 1))

        state = try state.applying(.killHand(player: 3), .pushChips, .pullChips(player: 1))
        #expect(state.totalPot == 0)
        #expect(state.stacks == [7340000, 3775000, 5110000, 8935000, 4545000])
    }

    @Test("test_2_00_08_38: a preflop raising war ends in a fold-out")
    func hand2() throws {
        var state = try posted([3775000, 5110000, 8935000, 4545000, 7340000], ante: 120000, blinds: [40000, 80000])
        #expect(state.totalPot == 240000)

        // Pre-flop
        state = try state.dealingHoles("Th Qs Ac Qc As 5d 4s 5h Js Qh").applying(
            .betOrRaise(player: 2, to: 170000), .fold(player: 3), .checkOrCall(player: 4), .fold(player: 0),
            .betOrRaise(player: 1, to: 875000), .fold(player: 2), .betOrRaise(player: 4, to: 4990000),
            .fold(player: 1), .collectBets
        )
        #expect(state.totalPot == 6195000)

        state = try state.applying(.pushChips, .pullChips(player: 4))
        #expect(state.totalPot == 0)
        #expect(state.stacks == [3735000, 4115000, 8765000, 4545000, 8545000])
    }

    @Test("test_3_00_15_36: a river raise takes it, and a street with no bet collects nothing")
    func hand3() throws {
        var state = try posted([4100000, 8775000, 4550000, 8525000, 3750000], ante: 150000, blinds: [50000, 100000])
        #expect(state.totalPot == 300000)

        // Pre-flop
        state = try state.dealingHoles("Qd Ts 4c 7s Qc 8s 2d 3s 5h Tc").applying(
            .fold(player: 2), .fold(player: 3), .betOrRaise(player: 4, to: 200000), .fold(player: 0),
            .checkOrCall(player: 1), .collectBets
        )
        #expect(state.totalPot == 600000)

        // Flop
        state = try state.dealingStreet("Th8c5d").applying(
            .checkOrCall(player: 1), .betOrRaise(player: 4, to: 175000), .checkOrCall(player: 1), .collectBets
        )
        #expect(state.totalPot == 950000)

        // Turn
        state = try state.dealingStreet("9d").applying(.checkOrCall(player: 1), .checkOrCall(player: 4))
        #expect(state.totalPot == 950000)

        // River
        state = try state.dealingStreet("Jd").applying(
            .betOrRaise(player: 1, to: 225000), .betOrRaise(player: 4, to: 700000), .fold(player: 1), .collectBets
        )
        #expect(state.totalPot == 1875000)

        state = try state.applying(.pushChips, .pullChips(player: 4))
        #expect(state.totalPot == 0)
        #expect(state.stacks == [4050000, 8025000, 4550000, 8525000, 4550000])
    }

    @Test("test_4_00_18_39: the blinds play heads-up, and a turn bet takes it")
    func hand4() throws {
        var state = try posted([8025000, 4550000, 8525000, 4550000, 4050000], ante: 150000, blinds: [50000, 100000])
        #expect(state.totalPot == 300000)

        // Pre-flop
        state = try state.dealingHoles("Qd 5h Jc 9h Jd 8s 3s 7c 4d 6s").applying(
            .fold(player: 2), .fold(player: 3), .fold(player: 4), .checkOrCall(player: 0), .checkOrCall(player: 1),
            .collectBets
        )
        #expect(state.totalPot == 350000)

        // Flop
        state = try state.dealingStreet("2s5s2d").applying(
            .checkOrCall(player: 0), .betOrRaise(player: 1, to: 175000), .checkOrCall(player: 0), .collectBets
        )
        #expect(state.totalPot == 700000)

        // Turn
        state = try state.dealingStreet("As").applying(
            .checkOrCall(player: 0), .betOrRaise(player: 1, to: 300000), .fold(player: 0), .collectBets
        )
        #expect(state.totalPot == 1000000)

        state = try state.applying(.pushChips, .pullChips(player: 1))
        #expect(state.totalPot == 0)
        #expect(state.stacks == [7750000, 4825000, 8525000, 4550000, 4050000])
    }

    @Test("test_62_02_51_10: the small blind's shove takes the big blind's ante and blind")
    func hand62() throws {
        var state = try posted([19050000, 2575000, 2575000, 3125000, 2375000], ante: 225000, blinds: [75000, 150000])
        #expect(state.totalPot == 450000)

        // Pre-flop
        state = try state.dealingHoles("Kc 8s 9d Tc As 8h 4s 8c 2d 4c").applying(
            .fold(player: 2), .fold(player: 3), .fold(player: 4), .betOrRaise(player: 0, to: 2350000),
            .fold(player: 1), .collectBets
        )
        #expect(state.totalPot == 2725000)

        state = try state.applying(.pushChips, .pullChips(player: 0))
        #expect(state.totalPot == 0)
        #expect(state.stacks == [19425000, 2200000, 2575000, 3125000, 2375000])
    }

    @Test("test_63_02_53_09: an uncontested shove from the middle")
    func hand63() throws {
        var state = try posted([2200000, 2575000, 3125000, 2375000, 19425000], ante: 225000, blinds: [75000, 150000])
        #expect(state.totalPot == 450000)

        // Pre-flop
        state = try state.dealingHoles("4h Qd Td Ad Js 3c 6d 2s 5s 6c").applying(
            .fold(player: 2), .betOrRaise(player: 3, to: 2375000), .fold(player: 4), .fold(player: 0),
            .fold(player: 1), .collectBets
        )
        #expect(state.totalPot == 2825000)

        state = try state.applying(.pushChips, .pullChips(player: 3))
        #expect(state.totalPot == 0)
        #expect(state.stacks == [2125000, 2200000, 3125000, 2825000, 19425000])
    }

    @Test("test_64_02_54_12: the small blind shoves over a raise")
    func hand64() throws {
        var state = try posted([2200000, 3125000, 2825000, 19425000, 2125000], ante: 225000, blinds: [75000, 150000])
        #expect(state.totalPot == 450000)

        // Pre-flop
        state = try state.dealingHoles("3s Kh Jd Ks 8d 3d 6c 5h 4c 2d").applying(
            .fold(player: 2), .betOrRaise(player: 3, to: 300000), .fold(player: 4),
            .betOrRaise(player: 0, to: 2200000), .fold(player: 1), .fold(player: 3), .collectBets
        )
        #expect(state.totalPot == 2875000)

        state = try state.applying(.pushChips, .pullChips(player: 0))
        #expect(state.totalPot == 0)
        #expect(state.stacks == [2875000, 2750000, 2825000, 19125000, 2125000])
    }

    @Test("test_65_02_56_12: the big blind reraises a raise and takes it")
    func hand65() throws {
        var state = try posted([2750000, 2825000, 19125000, 2125000, 2875000], ante: 225000, blinds: [75000, 150000])
        #expect(state.totalPot == 450000)

        // Pre-flop
        state = try state.dealingHoles("8c Qd Kh Ks Kd 2c Js 5h 5s 6c").applying(
            .betOrRaise(player: 2, to: 300000), .fold(player: 3), .fold(player: 4), .fold(player: 0),
            .betOrRaise(player: 1, to: 2600000), .fold(player: 2), .collectBets
        )
        #expect(state.totalPot == 3200000)

        state = try state.applying(.pushChips, .pullChips(player: 1))
        #expect(state.totalPot == 0)
        #expect(state.stacks == [2675000, 3200000, 18825000, 2125000, 2875000])
    }

    @Test("test_66_02_57_27: a flop bet takes a called preflop raise")
    func hand66() throws {
        var state = try posted([3200000, 18825000, 2125000, 2875000, 2675000], ante: 225000, blinds: [75000, 150000])
        #expect(state.totalPot == 450000)

        // Pre-flop
        state = try state.dealingHoles("7s Jc 8c Ks Td 5s 3c 2s Jd 5d").applying(
            .fold(player: 2), .betOrRaise(player: 3, to: 400000), .fold(player: 4), .fold(player: 0),
            .checkOrCall(player: 1), .collectBets
        )
        #expect(state.totalPot == 1100000)

        // Flop
        state = try state.dealingStreet("8dAdQc").applying(
            .checkOrCall(player: 1), .betOrRaise(player: 3, to: 350000), .fold(player: 1), .collectBets
        )
        #expect(state.totalPot == 1450000)

        state = try state.applying(.pushChips, .pullChips(player: 3))
        #expect(state.totalPot == 0)
        #expect(state.stacks == [3125000, 18200000, 2125000, 3575000, 2675000])
    }

    @Test("test_67_03_00_32: the big blind shoves over a completed small blind")
    func hand67() throws {
        var state = try posted([18200000, 2125000, 3575000, 2675000, 3125000], ante: 225000, blinds: [75000, 150000])
        #expect(state.totalPot == 450000)

        // Pre-flop
        state = try state.dealingHoles("Th Ac Js Kh 5d 2c 5c 4s 3h 3s").applying(
            .fold(player: 2), .fold(player: 3), .fold(player: 4), .checkOrCall(player: 0),
            .betOrRaise(player: 1, to: 1900000), .fold(player: 0), .collectBets
        )
        #expect(state.totalPot == 2275000)

        state = try state.applying(.pushChips, .pullChips(player: 1))
        #expect(state.totalPot == 0)
        #expect(state.stacks == [18050000, 2275000, 3575000, 2675000, 3125000])
    }

    @Test("test_68_03_02_41: an all-in preflop shows down before the board, then the short stack's hand is killed")
    func hand68() throws {
        var state = try posted([2275000, 3575000, 2675000, 3125000, 18050000], ante: 225000, blinds: [75000, 150000])
        #expect(state.totalPot == 450000)

        // Pre-flop
        state = try state.dealingHoles("8d 9d 6c Js Ac 3s 9c 5h 4h Kc").applying(
            .fold(player: 2), .fold(player: 3), .betOrRaise(player: 4, to: 300000), .fold(player: 0),
            .betOrRaise(player: 1, to: 3350000), .checkOrCall(player: 4), .collectBets
        )
        #expect(state.totalPot == 7000000)

        // Showdown
        state = try state.applying(.showHoleCards(player: 1), .showHoleCards(player: 4))

        // Flop
        state = try state.dealingStreet("2c8cTh")
        #expect(state.totalPot == 7000000)

        // Turn
        state = try state.dealingStreet("Ah")
        #expect(state.totalPot == 7000000)

        // River
        state = try state.dealingStreet("6d")
        #expect(state.totalPot == 7000000)

        state = try state.applying(.killHand(player: 1), .pushChips, .pullChips(player: 4))
        #expect(state.totalPot == 0)
        #expect(state.stacks == [2200000, 0, 2675000, 3125000, 21700000])
    }
}
