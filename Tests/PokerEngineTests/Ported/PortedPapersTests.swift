import Testing
@testable import PokerEngine

// The Dwan-Ivey and Antonius-Blom hands of PokerKit's pokerkit/tests/test_papers.py. Its READMETestCase tests are the
// README samples line for line, so PortedReadmeTests.swift ports them. Its hand-history tests load PHH, which the
// engine does not read: those two are ported as an export of the same actions. The other tests are other variants.

extension HandState {
    /// The hand's betting: everything up to the all-in on the turn. Player 1, Patrik Antonius, folds preflop.
    fileprivate func bettingToTheTurnAllIn() throws -> HandState {
        try applying(
            .betOrRaise(player: 2, to: 7000), .betOrRaise(player: 0, to: 23000), .fold(player: 1),
            .checkOrCall(player: 2)
        )
        .dealingStreet("Jc3d5c")
        .applying(.betOrRaise(player: 0, to: 35000), .checkOrCall(player: 2))
        .dealingStreet("4h")
        .applying(
            .betOrRaise(player: 0, to: 90000), .betOrRaise(player: 2, to: 232600),
            .betOrRaise(player: 0, to: 1067100), .checkOrCall(player: 2)
        )
    }
}

@Suite("Ported: test_papers.py")
struct PortedPapersTests {
    @Test("test_figure_2: the first televised million-dollar pot, in PokerKit's default tournament mode")
    func figure2() throws {
        let state = try HandState(config: .test(
            .tournament, stacks: [1125600, 2000000, 553500], antes: [500, 500, 500], anteTrimming: true,
            blinds: [1000, 2000], minBet: 2000
        ))
            .dealing("Ac2d", "5h7s", "7h6h")
            .bettingToTheTurnAllIn()
            .applying(.showHoleCards(player: 0), .showHoleCards(player: 2))
            .dealingStreet("Jh")
        #expect(state.isHandComplete)
        #expect(state.stacks == [572100, 1997500, 1109500])
    }

    // A hand history runs as a cash game with runout selection automated, and its "sm" lines list the shown cards.
    @Test("test_dwan_ivey_2009: the same hand from its hand history, with Antonius's cards never scanned")
    func dwanIvey2009() throws {
        let state = try HandState(config: .test(
            stacks: [1125600, 2000000, 553500], antes: [500, 500, 500], anteTrimming: true,
            blinds: [1000, 2000, 0], minBet: 2000, automations: .bookkeeping.union([.runoutCountSelection])
        ))
            .dealing("Ac2d", "????", "7h6h")
            .bettingToTheTurnAllIn()
            .applying(
                .showHoleCards(player: 0, cards: Card.parse("Ac2d")),
                .showHoleCards(player: 2, cards: Card.parse("7h6h"))
            )
            .dealingStreet("Jh")
        #expect(state.isHandComplete)
        #expect(state.stacks == [572100, 1997500, 1109500])
        // The test's own actions, in its order.
        let actions = [
            "d dh p1 Ac2d", "d dh p2 ????", "d dh p3 7h6h", "p3 cbr 7000", "p1 cbr 23000", "p2 f", "p3 cc",
            "d db Jc3d5c", "p1 cbr 35000", "p3 cc", "d db 4h", "p1 cbr 90000", "p3 cbr 232600", "p1 cbr 1067100",
            "p3 cc", "p1 sm Ac2d", "p3 sm 7h6h", "d db Jh",
        ]
        #expect(try state.phh().contains("actions = [\(actions.map { "'\($0)'" }.joined(separator: ", "))]\n"))
    }

    // PokerKit's stacks are 1259450.25 and 678473.5. Every amount here is 4 times its own, so all are whole numbers,
    // and each raise stays the pot-sized or minimum raise it was.
    @Test("test_antonius_blom_2009: the largest online pot, in Pot-Limit Omaha, from its hand history")
    func antoniusBlom2009() throws {
        let state = try HandState(config: .test(
            variant: .potLimitOmahaHoldem, stacks: [5_037_801, 2_713_894], anteTrimming: true, blinds: [2000, 4000],
            minBet: 4000, automations: .bookkeeping.union([.runoutCountSelection])
        ))
            .dealing("Ah3sKsKh", "6d9s7d8h")
            .applying(
                .betOrRaise(player: 1, to: 12000), .betOrRaise(player: 0, to: 36000),
                .betOrRaise(player: 1, to: 108_000), .betOrRaise(player: 0, to: 324_000), .checkOrCall(player: 1)
            )
            .dealingStreet("4s5c2h")
            .applying(
                .betOrRaise(player: 0, to: 364_000), .betOrRaise(player: 1, to: 1_740_000),
                .betOrRaise(player: 0, to: 3_116_000), .checkOrCall(player: 1),
                .showHoleCards(player: 0, cards: Card.parse("Ah3sKsKh")),
                .showHoleCards(player: 1, cards: Card.parse("6d9s7d8h"))
            )
            .dealingStreet("5h")
            .dealingStreet("9c")
        #expect(state.isHandComplete)
        #expect(state.stacks == [7_751_695, 0])
        let actions = [
            "d dh p1 Ah3sKsKh", "d dh p2 6d9s7d8h", "p2 cbr 12000", "p1 cbr 36000", "p2 cbr 108000", "p1 cbr 324000",
            "p2 cc", "d db 4s5c2h", "p1 cbr 364000", "p2 cbr 1740000", "p1 cbr 3116000", "p2 cc", "p1 sm Ah3sKsKh",
            "p2 sm 6d9s7d8h", "d db 5h", "d db 9c",
        ]
        #expect(try state.phh().hasPrefix("variant = 'PO'\n"))
        #expect(try state.phh().contains("actions = [\(actions.map { "'\($0)'" }.joined(separator: ", "))]\n"))
    }
}
