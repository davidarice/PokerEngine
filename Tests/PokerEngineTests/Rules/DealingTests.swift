import Testing
@testable import PokerEngine

@Suite("Dealing")
struct DealingTests {
    @Test("suggests one hole card to each player in turn, but accepts any player still owed a card")
    func holeDealingOrder() throws {
        var state = HandState(config: .test(stacks: [200, 200, 200]))
        state = try state.applying(.dealHole(player: 2, card: card("As")))
        #expect(state.pendingOperation == .dealHoleCard(player: 0, cardIndex: 0))
        state = try state.applying(.dealHole(player: 2, card: card("Ks")))
        #expect(throws: EngineError.noDealExpected(.holeCard(player: 2))) {
            try state.apply(.dealHole(player: 2, card: card("Qs")))
        }
        #expect(throws: EngineError.invalidPlayer(-1)) { try state.apply(.dealHole(player: -1, card: card("Qs"))) }
        state = try state.applying(.dealHole(player: 1, card: card("Qs")))
        #expect(state.pendingOperation == .dealHoleCard(player: 0, cardIndex: 0))
        state = try state.applying(.dealHole(player: 0, card: card("Js")))
        #expect(state.pendingOperation == .dealHoleCard(player: 0, cardIndex: 1))
        state = try state.applying(.dealHole(player: 0, card: card("Ts")), .dealHole(player: 1, card: card("9s")))
        #expect(state.pendingOperation == .act(player: 2))
        #expect(state.holeCards.map { $0.map(\.card) } == [
            [card("Js"), card("Ts")], [card("Qs"), card("9s")], [card("As"), card("Ks")],
        ])
        #expect(state.holeCards.joined().allSatisfy { !$0.isFaceUp })
    }

    @Test("each street burns first, then deals its board cards one at a time")
    func boardDealing() throws {
        var state = try HandState(config: .test(stacks: [200, 200])).dealingHoles("AsKsAhKh")
            .applying(.checkOrCall(player: 1), .checkOrCall(player: 0))
        #expect(state.pendingOperation == .burnCard(street: .flop, runout: 0))
        #expect(state.boards == [[]])
        #expect(state.runoutCount == 1)
        #expect(throws: EngineError.burnRequired) { try state.apply(.dealBoard(card("2c"))) }
        #expect(throws: EngineError.noDealExpected(.holeCard(player: 0))) { try state.apply(.dealHole(player: 0, card: card("2c"))) }
        state = try state.applying(.burnCard(card("3c")))
        #expect(throws: EngineError.noDealExpected(.burn)) { try state.apply(.burnCard(card("4c"))) }
        var pending = [PendingOperation?]()
        for text in ["2c", "7d", "9h"] {
            pending.append(state.pendingOperation)
            state = try state.applying(.dealBoard(card(text)))
        }
        #expect(pending == [
            .dealBoardCard(street: .flop, runout: 0, cardIndex: 0, cardCount: 3),
            .dealBoardCard(street: .flop, runout: 0, cardIndex: 1, cardCount: 3),
            .dealBoardCard(street: .flop, runout: 0, cardIndex: 2, cardCount: 3),
        ])
        #expect(state.events.suffix(4) == [
            .cardBurned(card("3c"), street: .flop, runout: 0),
            .boardCardDealt(card("2c"), street: .flop, runout: 0),
            .boardCardDealt(card("7d"), street: .flop, runout: 0),
            .boardCardDealt(card("9h"), street: .flop, runout: 0),
        ])
        #expect(state.boards == [[card("2c"), card("7d"), card("9h")]])
        #expect(state.runoutCount == 1)
        #expect(state.pendingOperation == .act(player: 0))
        #expect(throws: EngineError.noDealExpected(.boardCard)) { try state.apply(.dealBoard(card("Tc"))) }
        state = try state.applying(.checkOrCall(player: 0), .checkOrCall(player: 1))
        #expect(state.pendingOperation == .burnCard(street: .turn, runout: 0))
        state = try state.dealingStreet("Tc")
        #expect(state.street == .turn)
        #expect(state.boards == [[card("2c"), card("7d"), card("9h"), card("Tc")]])
    }

    @Test("unscanned cards are dealt as unknown anywhere")
    func unknownCards() throws {
        let state = try HandState(config: .test(stacks: [200, 200]))
            .dealingHoles("??Ks????")
            .applying(.checkOrCall(player: 1), .checkOrCall(player: 0))
            .applying(.burnCard(.unknown), .dealBoard(.unknown), .dealBoard(card("Qd")), .dealBoard(.unknown))
        #expect(state.holeCards[0].map(\.card) == [.unknown, .unknown])
        #expect(state.holeCards[1].map(\.card) == [card("Ks"), .unknown])
        #expect(state.boards == [[.unknown, card("Qd"), .unknown]])
        #expect(state.hand(of: 1) == nil)
    }

    @Test("a known card can be dealt only once (DECISIONS.md B1)")
    func duplicateCards() throws {
        var state = try HandState(config: .test(stacks: [200, 200, 200])).dealingHoles("AsKsQs")
        #expect(throws: EngineError.duplicateCard(card("As"), location: .hole(player: 0))) {
            try state.apply(.dealHole(player: 1, card: card("As")))
        }
        state = try state.dealingHoles("AhKhQh").applying(.fold(player: 2), .checkOrCall(player: 0), .checkOrCall(player: 1))
        #expect(throws: EngineError.duplicateCard(card("Qs"), location: .mucked)) { try state.apply(.burnCard(card("Qs"))) }
        state = try state.applying(.burnCard(card("2c")))
        #expect(throws: EngineError.duplicateCard(card("2c"), location: .burned)) { try state.apply(.dealBoard(card("2c"))) }
        state = try state.applying(.dealBoard(card("3c")), .dealBoard(.unknown), .dealBoard(.unknown))
        #expect(throws: EngineError.duplicateCard(card("3c"), location: .board(runout: 0))) {
            try state.applying(.checkOrCall(player: 0), .checkOrCall(player: 1), .burnCard(card("3c")))
        }
    }

    @Test("a duplicate of a board card names the run, whichever position the card is in")
    func duplicateBoardCardLocation() throws {
        let flop = try HandState(config: .test(stacks: [200, 200])).dealingHoles("AsKsAhKh")
            .applying(.checkOrCall(player: 1), .checkOrCall(player: 0)).dealingStreet("2c3c4c")
            .applying(.checkOrCall(player: 0), .checkOrCall(player: 1))
        #expect(throws: EngineError.duplicateCard(card("4c"), location: .board(runout: 0))) {
            try flop.apply(.burnCard(card("4c")))
        }
    }

    @Test("a dealt card scanned at the wrong moment reports the timing, as PokerKit does, not the duplicate")
    func dealtCardAtWrongMoment() throws {
        let holes = try HandState(config: .test(stacks: [200, 200, 200])).dealingHoles("AsKsQs")
        #expect(throws: EngineError.noDealExpected(.burn)) { try holes.apply(.burnCard(card("As"))) }
        #expect(throws: EngineError.noDealExpected(.holeCard(player: 0))) {
            try holes.applying(.dealHole(player: 0, card: card("Ah"))).apply(.dealHole(player: 0, card: card("Ks")))
        }
        let preflopDone = try holes.dealingHoles("AhKhQh")
            .applying(.fold(player: 2), .checkOrCall(player: 0), .checkOrCall(player: 1))
        #expect(throws: EngineError.burnRequired) { try preflopDone.apply(.dealBoard(card("As"))) }
        let flop = try preflopDone.dealingStreet("3c????")
        #expect(throws: EngineError.noDealExpected(.boardCard)) { try flop.apply(.dealBoard(card("As"))) }
    }
}
