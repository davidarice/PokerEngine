import Testing
@testable import PokerEngine

// PokerKit's pokerkit/tests/test_rules.py. The source's Pot-Limit Omaha hand in test_2024_96 is not ported.
// Both sources automate dealing, and no hand here reaches a card that matters.

@Suite("Ported: test_rules.py")
struct PortedRulesTests {
    @Test("test_2024_96: a short all-in raise does not reopen the action for the player who raised before it")
    func rule96() throws {
        let state = try HandState(config: .test(
            .tournament, stacks: [650, 20000, 20000], anteTrimming: true, blinds: [100, 200], minBet: 200
        ))
            .dealingHoles("AsKsQsAhKhQh")
            .applying(.betOrRaise(player: 2, to: 600), .betOrRaise(player: 0, to: 650), .checkOrCall(player: 1))
        #expect(throws: EngineError.raiseNotAllowed(player: 2, reason: .actionNotReopened)) {
            try state.apply(.betOrRaise(player: 2, to: 1050))
        }
    }

    @Test("test_2024_96_a: short all-ins adding up to a full raise reopen the action, if the bettor calls or folds")
    func rule96A() throws {
        let state = try HandState(config: .test(
            .tournament, stacks: [20001, 20001, 20001, 1301, 1701], antes: [1, 1, 1, 1, 1], anteTrimming: true,
            blinds: [], minBet: 1
        ))
            .dealingHoles("AsKsQsJsTsAhKhQhJhTh")
            .applying(
                .betOrRaise(player: 0, to: 500), .betOrRaise(player: 1, to: 1000), .checkOrCall(player: 2),
                .betOrRaise(player: 3, to: 1300), .betOrRaise(player: 4, to: 1700)
            )

        var hypothetical = try state.apply(.checkOrCall(player: 0))
        #expect(hypothetical.legalActions?.betOrRaise == .raise(2200...20000))
        hypothetical = try hypothetical.apply(.checkOrCall(player: 1))
        #expect(hypothetical.legalActions?.betOrRaise == .raise(2200...20000))

        hypothetical = try state.apply(.fold(player: 0))
        #expect(hypothetical.legalActions?.betOrRaise == .raise(2200...20000))
        hypothetical = try hypothetical.apply(.checkOrCall(player: 1))
        #expect(hypothetical.legalActions?.betOrRaise == .raise(2200...20000))
    }
}
