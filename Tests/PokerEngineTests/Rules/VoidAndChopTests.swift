import Foundation
import Testing
@testable import PokerEngine

@Suite("Voiding a hand and chopping the blinds")
struct VoidAndChopTests {
    /// Three-handed with blinds of 1 and 2, the cards dealt, and the button (player 2) first to act. Player 0 holds
    /// aces, player 1 kings and player 2 queens.
    private func dealt(
        _ mode: HandConfig.Mode = .cashGame,
        stacks: [Int] = [200, 200, 200],
        antes: [Int] = [],
        blinds: [Int] = [1, 2]
    ) throws -> HandState {
        try HandState(config: .test(mode, stacks: stacks, antes: antes, blinds: blinds)).dealingHoles("AsKsQsAhKhQh")
    }

    // MARK: Voiding

    @Test("a void gives every player back their starting stack and ends the hand (B12)")
    func voidReturnsEveryChip() throws {
        let flop = try dealt().applying(.betOrRaise(player: 2, to: 6), .checkOrCall(player: 0), .fold(player: 1))
            .dealingStreet("2c7d9h").applying(.betOrRaise(player: 0, to: 10))
        let state = try flop.apply(.voidHand)
        #expect(state.isHandComplete)
        #expect(state.pendingOperation == nil)
        #expect(state.street == nil)
        #expect(state.stacks == [200, 200, 200])
        #expect(state.bets == [0, 0, 0])
        #expect(state.pots.isEmpty)
        #expect(state.totalPot == 0)
        #expect(state.events.last == .handVoided(returned: [16, 2, 6]))
        #expect(state.log.last?.isAutomated == false)
        #expect(state.results?.map(\.net) == [0, 0, 0])
        #expect(state.results?.map(\.won) == [0, 0, 0])
        #expect(state.results?.map(\.status) == [.active, .folded, .active])
        #expect(state.boards == [cards("2c7d9h")])
    }

    @Test("a void is accepted before a card is dealt, while forced bets are owed, and after the hand (B12)")
    func voidAtAnyPoint() throws {
        let start = try HandState(config: .test(stacks: [200, 200, 200])).apply(.voidHand)
        #expect(start.events.last == .handVoided(returned: [1, 2, 0]))
        #expect(start.stacks == [200, 200, 200])

        let owed = HandState(config: .test(stacks: [200, 200, 200], antes: [1, 1, 1], automations: []))
        #expect(owed.pendingOperation == .postAnte([0, 1, 2].map { ForcedBet(player: $0, amount: 1) }))
        #expect(try owed.apply(.voidHand).events.last == .handVoided(returned: [0, 0, 0]))

        // After the hand the winner hands back what they won, and nobody has won anything.
        let over = try dealt().applying(.betOrRaise(player: 2, to: 6), .fold(player: 0), .fold(player: 1))
        #expect(over.isHandComplete)
        #expect(over.stacks == [199, 198, 203])
        #expect(over.results?.map(\.won) == [0, 0, 3])
        let voided = try over.apply(.voidHand)
        #expect(voided.events.last == .handVoided(returned: [1, 2, -3]))
        #expect(voided.stacks == [200, 200, 200])
        #expect(voided.pots.isEmpty)
        #expect(voided.results?.map(\.net) == [0, 0, 0])
        #expect(voided.results?.map(\.won) == [0, 0, 0])
    }

    @Test("nothing is accepted after a void, not even a show after the hand (B12)")
    func nothingAfterAVoid() throws {
        let over = try dealt().applying(.betOrRaise(player: 2, to: 6), .fold(player: 0), .fold(player: 1))
        #expect(over.canApply(.showHoleCards(player: 2)))
        let voided = try over.apply(.voidHand)
        let operations: [HandOperation] = [
            .voidHand, .chopBlinds, .showHoleCards(player: 2), .muckHoleCards(player: 2), .pullChips(player: 2),
        ]
        for operation in operations {
            #expect(throws: EngineError.handComplete) { try voided.apply(operation) }
        }
    }

    @Test("a voided hand keeps its record: replay and JSON give it back, and PHH cannot write it (B12)")
    func voidedHandIsStored() throws {
        let voided = try dealt().applying(.betOrRaise(player: 2, to: 6)).apply(.voidHand)
        #expect(voided.operations.last == .voidHand)
        #expect(voided.results?.map(\.holeCards) == [
            [down("As"), down("Ah")], [down("Ks"), down("Kh")], [down("Qs"), down("Qh")],
        ])
        #expect(try HandState.replay(config: voided.config, operations: voided.operations) == voided)
        #expect(try HandState(json: voided.json()) == voided)
        #expect(throws: PHHExportError.handVoided) { try voided.phh() }
    }

    // MARK: Chopping the blinds

    @Test("when everyone else folds to the blinds, they may take their blinds back and end the hand (B12)")
    func chop() throws {
        let foldedToBlinds = try dealt().applying(.fold(player: 2))
        #expect(foldedToBlinds.pendingOperation == .act(player: 0))
        #expect(foldedToBlinds.canApply(.chopBlinds))
        let state = try foldedToBlinds.apply(.chopBlinds)
        #expect(state.isHandComplete)
        #expect(state.stacks == [200, 200, 200])
        #expect(state.events.last == .blindsChopped(returned: [1, 2, 0]))
        #expect(state.results?.map(\.net) == [0, 0, 0])
        #expect(state.results?.map(\.status) == [.active, .active, .folded])
        #expect(throws: PHHExportError.blindsChopped) { try state.phh() }
        #expect(throws: EngineError.handComplete) { try state.apply(.voidHand) }
        #expect(throws: EngineError.handComplete) { try state.apply(.showHoleCards(player: 0)) }
        #expect(try HandState(json: state.json()) == state)
    }

    @Test("heads-up, the blinds may chop before the button acts (B12)")
    func headsUpChop() throws {
        let state = try HandState(config: .test(stacks: [100, 100])).dealingHoles("AsKsAhKh")
        #expect(state.pendingOperation == .act(player: 1))
        #expect(try state.apply(.chopBlinds).events.last == .blindsChopped(returned: [2, 1]))
    }

    @Test("a small blind all in for its blind can chop with the big blind to act (B12)")
    func shortSmallBlindChop() throws {
        let state = try dealt(stacks: [1, 200, 200]).applying(.fold(player: 2))
        #expect(state.pendingOperation == .act(player: 1))
        let chopped = try state.apply(.chopBlinds)
        #expect(chopped.events.last == .blindsChopped(returned: [1, 2, 0]))
        #expect(chopped.stacks == [1, 200, 200])
    }

    @Test("with a big-blind ante the big blind takes the ante back too: it is the big blind's own (B12)")
    func chopWithABigBlindAnte() throws {
        let state = try dealt(antes: [0, 2]).applying(.fold(player: 2))
        #expect(state.totalPot == 5)
        #expect(try state.apply(.chopBlinds).events.last == .blindsChopped(returned: [1, 4, 0]))
    }

    @Test("the blinds cannot chop once either has put in more, while anyone else is in, or after the flop (B12)")
    func chopRefusedByTheAction() throws {
        let completed = try dealt().applying(.fold(player: 2), .checkOrCall(player: 0))
        #expect(completed.pendingOperation == .act(player: 1))
        #expect(throws: EngineError.cannotChopBlinds) { try completed.apply(.chopBlinds) }
        let raised = try dealt().applying(.fold(player: 2), .betOrRaise(player: 0, to: 6))
        #expect(throws: EngineError.cannotChopBlinds) { try raised.apply(.chopBlinds) }
        #expect(throws: EngineError.cannotChopBlinds) { try dealt().apply(.chopBlinds) }
        let flop = try dealt().applying(.fold(player: 2), .checkOrCall(player: 0), .checkOrCall(player: 1))
            .dealingStreet("2c7d9h")
        #expect(flop.pendingOperation == .act(player: 0))
        #expect(throws: EngineError.cannotChopBlinds) { try flop.apply(.chopBlinds) }
        #expect(throws: EngineError.cannotChopBlinds) {
            try HandState(config: .test(stacks: [200, 200, 200])).apply(.chopBlinds)
        }
    }

    @Test("a tournament never chops, and a pot with chips from anyone else cannot be chopped (B12)")
    func chopRefusedByTheGame() throws {
        #expect(throws: EngineError.cannotChopBlinds) {
            try dealt(.tournament).applying(.fold(player: 2)).apply(.chopBlinds)
        }
        // The button's ante would have no owner.
        #expect(throws: EngineError.cannotChopBlinds) {
            try dealt(antes: [1, 1, 1]).applying(.fold(player: 2)).apply(.chopBlinds)
        }
        // With no small blind posted there is nobody to chop with.
        #expect(throws: EngineError.cannotChopBlinds) {
            try dealt(blinds: [0, 2]).applying(.fold(player: 2)).apply(.chopBlinds)
        }
        // A live post by a player who then folded is dead money.
        let fourHanded = try HandState(config: .test(stacks: [200, 200, 200, 200], blinds: [1, 2, -2]))
            .dealingHoles("AsKsQsJsAhKhQhJh").applying(.fold(player: 2), .fold(player: 3))
        #expect(fourHanded.pendingOperation == .act(player: 0))
        #expect(throws: EngineError.cannotChopBlinds) { try fourHanded.apply(.chopBlinds) }
        // A straddler acts after the blinds, so is still in when the action reaches them.
        let straddled = try HandState(config: .test(stacks: [200, 200, 200, 200], blinds: [1, 2, 4]))
            .dealingHoles("AsKsQsJsAhKhQhJh").applying(.fold(player: 3))
        #expect(straddled.pendingOperation == .act(player: 0))
        #expect(throws: EngineError.cannotChopBlinds) { try straddled.apply(.chopBlinds) }
    }

    @Test("after the hand, a chop is refused because the hand is over")
    func chopOnAFinishedHand() throws {
        let over = try dealt().applying(.betOrRaise(player: 2, to: 6), .fold(player: 0), .fold(player: 1))
        #expect(throws: EngineError.handComplete) { try over.apply(.chopBlinds) }
    }

    @Test("the dealer's message for a refused chop says when the blinds may chop")
    func chopMessage() {
        #expect(EngineError.cannotChopBlinds.message() == """
            The blinds can chop only in a cash game, before the flop, once everyone else has folded, with nothing in \
            the pot but their blinds and antes.
            """)
    }
}
