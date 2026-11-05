import Testing
@testable import PokerEngine

// The No-Limit Texas Hold'em samples of PokerKit's README.rst, which pokerkit/tests/test_papers.py runs line for line
// as READMETestCase.test_hellmuth_wiggins and test_dwan_ivey. The other samples are other variants.

@Suite("Ported: README.rst")
struct PortedReadmeTests {
    // Chips are `Int`, so an `inf` stack becomes 10_000_000, and `inf` in the final stacks becomes what PokerKit reports
    // for that stack.
    @Test("test_hellmuth_wiggins: the 4-runout hand between Phil Hellmuth and Ernest Wiggins")
    func hellmuthWiggins() throws {
        var state = HandState(config: .test(
            stacks: [10_000_000, 116400, 86900, 10_000_000, 50000, 10_000_000], antes: [0, 0, 0, 0, 0, 600],
            blinds: [200, 400, 800], minBet: 400
        ))

        // Below are the pre-flop dealings and actions.
        state = try state.dealing("JsTh", "Ah9d", "KsKc", "5c2h", "6h5h", "6s3s")
        state = try state.applying(
            .fold(player: 3), .betOrRaise(player: 4, to: 2800), .fold(player: 5), .checkOrCall(player: 0),
            .betOrRaise(player: 1, to: 12600), .checkOrCall(player: 2), .checkOrCall(player: 4),
            .checkOrCall(player: 0)
        )

        // Below are the flop dealing and actions.
        state = try state.dealingStreet("9hTs9s").applying(
            .checkOrCall(player: 0), .betOrRaise(player: 1, to: 17000), .betOrRaise(player: 2, to: 36000),
            .fold(player: 4), .fold(player: 0), .betOrRaise(player: 1, to: 103800), .checkOrCall(player: 2)
        )

        // Below is selecting the number of runouts. PokerKit's automation has both players show here too.
        state = try state.applying(
            .selectRunoutCount(player: 1, count: 4), .selectRunoutCount(player: 2, count: nil),
            .showHoleCards(player: 1), .showHoleCards(player: 2)
        )

        // Below are the four runouts.
        state = try state.dealingStreet("Jh").dealingStreet("Ad")
            .dealingStreet("Kh").dealingStreet("3c")
            .dealingStreet("7s").dealingStreet("8s")
            .dealingStreet("Qc").dealingStreet("Kd")

        // Below are the final stacks.
        #expect(state.isHandComplete)
        #expect(state.stacks == [9_987_400, 79400, 149700, 10_000_000, 37400, 9_999_400])
    }

    @Test("A Sample No-Limit Texas Hold'em Hand, and test_dwan_ivey: the first televised million-dollar pot")
    func dwanIvey() throws {
        var state = HandState(config: .test(
            .tournament, stacks: [1125600, 10_000_000, 553500], antes: [500, 500, 500], anteTrimming: true,
            blinds: [1000, 2000], minBet: 2000
        ))

        // Below are the pre-flop dealings and actions.
        for (player, cards) in ["Ac2d", "????", "7h6h"].enumerated() {
            for card in try Card.parse(cards) {
                state = try state.apply(.dealHole(player: player, card: card))
            }
        }
        state = try state.applying(
            .betOrRaise(player: 2, to: 7000), .betOrRaise(player: 0, to: 23000), .fold(player: 1),
            .checkOrCall(player: 2)
        )

        // Below are the flop dealing and actions.
        state = try state.dealingStreet("Jc3d5c")
            .applying(.betOrRaise(player: 0, to: 35000), .checkOrCall(player: 2))

        // Below are the turn dealing and actions.
        state = try state.dealingStreet("4h").applying(
            .betOrRaise(player: 0, to: 90000), .betOrRaise(player: 2, to: 232600),
            .betOrRaise(player: 0, to: 1067100), .checkOrCall(player: 2)
        )

        // Below is the river dealing. PokerKit's automation has both players show before it.
        state = try state.applying(.showHoleCards(player: 0), .showHoleCards(player: 2)).dealingStreet("Jh")

        // Below are the final stacks.
        #expect(state.isHandComplete)
        #expect(state.stacks == [572100, 9_997_500, 1109500])
    }
}
