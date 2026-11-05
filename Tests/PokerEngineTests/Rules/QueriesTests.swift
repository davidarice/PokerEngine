import Testing
@testable import PokerEngine

@Suite("Queries, log and replay")
struct QueriesTests {
    @Test("side pots layer contributions, and only players in for a layer are eligible for it")
    func sidePots() throws {
        let state = try HandState(config: .test(stacks: [10, 30, 60, 200])).dealingHoles("AsKsQsJsAhKhQhJh")
            .applying(.betOrRaise(player: 2, to: 60), .checkOrCall(player: 3), .checkOrCall(player: 0), .checkOrCall(player: 1))
        #expect(state.stacks == [0, 0, 0, 140])
        #expect(state.pots == [
            Pot(amount: 40, eligiblePlayers: [0, 1, 2, 3]),
            Pot(amount: 60, eligiblePlayers: [1, 2, 3]),
            Pot(amount: 60, eligiblePlayers: [2, 3]),
        ])
        #expect(state.totalPot == 160)
        #expect(state.actor == nil)
        #expect(!state.canApply(.burnCard(.unknown)))
    }

    @Test("a folded player's chips stay in the pot, and live bets are not in a pot until collected")
    func foldedChipsAndLiveBets() throws {
        var state = try HandState(config: .test(stacks: [200, 200, 200])).dealingHoles("AsKsQsAhKhQh")
            .applying(.betOrRaise(player: 2, to: 6), .checkOrCall(player: 0), .checkOrCall(player: 1))
            .dealingStreet("2h7s9d")
            .applying(.checkOrCall(player: 0), .betOrRaise(player: 1, to: 10), .betOrRaise(player: 2, to: 30))
            .applying(.fold(player: 0))
        #expect(state.pots == [Pot(amount: 18, eligiblePlayers: [1, 2])])
        #expect(state.totalPot == 58)
        state = try state.applying(.checkOrCall(player: 1))
        #expect(state.pots == [Pot(amount: 78, eligiblePlayers: [1, 2])])
    }

    @Test("hands are evaluated from known hole cards and the board")
    func hands() throws {
        let preflop = try HandState(config: .test(stacks: [200, 200, 200])).dealingHoles("AsKhQdAcKdQc")
            .applying(.betOrRaise(player: 2, to: 6), .checkOrCall(player: 0), .checkOrCall(player: 1))
        #expect(preflop.hand(of: 0) == nil)
        let flop = try preflop.dealingStreet("2h7s9d")
        #expect(flop.hand(of: 0)?.description == "One pair (AsAc2h7s9d)")
        #expect(flop.hand(of: 1)?.description == "One pair (KhKd2h7s9d)")
        // Nothing is face up before the showdown, so the board alone is too few cards.
        #expect(flop.hand(of: 0, faceUpOnly: true) == nil)
        let folded = try flop.applying(.checkOrCall(player: 0), .betOrRaise(player: 1, to: 10), .fold(player: 2))
        #expect(folded.hand(of: 2) == nil)
    }

    /// Three-handed, checked down to the river on 2h7s9dJc5s, with nothing shown: aces, kings and queens in
    /// player order.
    private func checkedRiver() throws -> HandState {
        try HandState(config: .test(stacks: [200, 200, 200])).dealingHoles("AsKhQdAcKdQc")
            .applying(.betOrRaise(player: 2, to: 6), .checkOrCall(player: 0), .checkOrCall(player: 1))
            .dealingStreet("2h7s9d").checkingDown()
            .dealingStreet("Jc").checkingDown()
            .dealingStreet("5s").checkingDown()
    }

    @Test("a beaten hand is ranked from the cards results keeps, after it has left the state")
    func beatenHand() throws {
        let state = try checkedRiver()
            .applying(.showHoleCards(player: 0), .showHoleCards(player: 1), .showHoleCards(player: 2))
        #expect(state.statuses == [.active, .killed, .killed])
        #expect(state.hand(of: 1) == nil)
        #expect(state.dealtHand(of: 1)?.description == "One pair (KhKd7s9dJc)")
        #expect(state.dealtHand(of: 1, faceUpOnly: true)?.description == "One pair (KhKd7s9dJc)")
        #expect(state.dealtHand(of: 2)?.description == "One pair (QdQc7s9dJc)")
        #expect(state.dealtHand(of: 0)?.description == "One pair (AsAc7s9dJc)")
        #expect(state.dealtHand(of: 0) == state.hand(of: 0))
    }

    @Test("a hand kept face down on the last river is ranked from its scanned cards, and so is a mucked one")
    func keptAndMuckedHands() throws {
        let state = try checkedRiver()
            .applying(.showHoleCards(player: 0, cards: []), .muckHoleCards(player: 1), .muckHoleCards(player: 2))
        #expect(state.statuses == [.active, .mucked, .mucked])
        // The river forgot the winner's cards, so `hand(of:)` has only the board left to rank.
        #expect(state.hand(of: 0)?.description == "High card (2h7s9dJc5s)")
        #expect(state.dealtHand(of: 0)?.description == "One pair (AsAc7s9dJc)")
        #expect(state.dealtHand(of: 1)?.description == "One pair (KhKd7s9dJc)")
        // Nothing was shown, so face up only, each is the board's own rank.
        #expect(state.dealtHand(of: 0, faceUpOnly: true)?.description == "High card (2h7s9dJc5s)")
        #expect(state.dealtHand(of: 1, faceUpOnly: true)?.description == "High card (2h7s9dJc5s)")
    }

    @Test("a folded hand is ranked with the whole board, cards dealt after the fold included")
    func foldedHand() throws {
        let state = try HandState(config: .test(stacks: [200, 200, 200])).dealingHoles("AsKhQdAcKdQc")
            .applying(.betOrRaise(player: 2, to: 6), .checkOrCall(player: 0), .checkOrCall(player: 1))
            .dealingStreet("2h7s9d")
            .applying(.checkOrCall(player: 0), .betOrRaise(player: 1, to: 10), .fold(player: 2))
            .applying(.checkOrCall(player: 0))
            .dealingStreet("Jc").checkingDown().dealingStreet("5s").checkingDown()
            .applying(.showHoleCards(player: 0), .muckHoleCards(player: 1))
        #expect(state.statuses == [.active, .mucked, .folded])
        #expect(state.hand(of: 2) == nil)
        #expect(state.dealtHand(of: 2)?.description == "One pair (QdQc7s9dJc)")
    }

    @Test("there is no dealt hand under five known cards, on a run that does not exist, or with an unknown board card")
    func noDealtHand() throws {
        let preflop = try HandState(config: .test(stacks: [200, 200, 200])).dealingHoles("AsKhQdAcKdQc")
            .applying(.fold(player: 2), .fold(player: 0))
        #expect(preflop.isHandComplete)
        #expect(preflop.dealtHand(of: 1) == nil)

        let river = try checkedRiver()
        #expect(river.dealtHand(of: 0)?.description == "One pair (AsAc7s9dJc)")
        #expect(river.dealtHand(of: 0, board: 1) == nil)

        let unknownFlop = try HandState(config: .test(stacks: [200, 200, 200])).dealingHoles("AsKhQdAcKdQc")
            .applying(.betOrRaise(player: 2, to: 6), .checkOrCall(player: 0), .checkOrCall(player: 1))
            .applying(.burnCard(.unknown), .dealBoard(card("2h")), .dealBoard(.unknown), .dealBoard(card("9d")))
            .applying(.betOrRaise(player: 0, to: 2), .fold(player: 1), .fold(player: 2))
        #expect(unknownFlop.isHandComplete)
        #expect(unknownFlop.dealtHand(of: 0) == nil)
    }

    @Test("an unscanned hole card is left out, and the cards that were scanned are ranked")
    func dealtHandWithAnUnscannedCard() throws {
        let state = try HandState(config: .test(stacks: [200, 200, 200])).dealingHoles("AsKh??AcKdQc")
            .applying(.betOrRaise(player: 2, to: 6), .checkOrCall(player: 0), .checkOrCall(player: 1))
            .dealingStreet("2h7s9d").checkingDown().dealingStreet("Jc")
            .applying(.betOrRaise(player: 0, to: 2), .fold(player: 1), .fold(player: 2))
        #expect(state.isHandComplete)
        #expect(state.dealtHand(of: 2)?.description == "High card (Qc2h7s9dJc)")
    }

    @Test("on several runs, each board ranks the beaten hand on its own")
    func dealtHandOnSeveralRuns() throws {
        let state = try HandState(config: .test(stacks: [100, 100])).dealingHoles("AsKsAhKh")
            .applying(.checkOrCall(player: 1), .checkOrCall(player: 0))
            .dealingStreet("2c7d9h")
            .applying(.betOrRaise(player: 0, to: 98), .checkOrCall(player: 1))
            .applying(.selectRunoutCount(player: 0, count: 2), .selectRunoutCount(player: 1, count: 2))
            .applying(.showHoleCards(player: 0), .showHoleCards(player: 1))
            .dealingStreet("Td").dealingStreet("3s").dealingStreet("4c").dealingStreet("5d")
        #expect(state.statuses == [.active, .killed])
        #expect(state.dealtHand(of: 1, board: 0)?.description == "One pair (KsKh7d9hTd)")
        #expect(state.dealtHand(of: 1, board: 1)?.description == "One pair (KsKh7d9h5d)")
        #expect(state.dealtHand(of: 1, board: 2) == nil)
    }

    @Test("the log marks automated events and the operation that caused them")
    func logEntries() throws {
        let state = try HandState(config: .test(stacks: [200, 200])).dealingHoles("AsKsAhKh")
            .applying(.checkOrCall(player: 1), .checkOrCall(player: 0))
        #expect(state.operations.count == 6)
        #expect(state.log.suffix(3) == [
            LogEntry(event: .checkedOrCalled(player: 1, amount: 1), isAutomated: false, operationIndex: 4),
            LogEntry(event: .checkedOrCalled(player: 0, amount: 0), isAutomated: false, operationIndex: 5),
            LogEntry(event: .betsCollected(collected: [2, 2], returned: [0, 0]), isAutomated: true, operationIndex: 5),
        ])
    }

    @Test("replay rebuilds the state, and replacing an operation corrects a misread card")
    func replay() throws {
        let config = HandConfig.test(stacks: [200, 200])
        let state = try HandState(config: config).dealingHoles("AsKsAhKh").applying(.betOrRaise(player: 1, to: 6))
        #expect(try HandState.replay(config: config, operations: state.operations) == state)
        let corrected = try state.replacingOperation(at: 2, with: .dealHole(player: 0, card: card("Ad")))
        #expect(corrected.holeCards[0].map(\.card) == [card("As"), card("Ad")])
        #expect(corrected.bets == state.bets)
        #expect(throws: ReplayError(
            operationIndex: 3, operation: .dealHole(player: 1, card: card("Kh")),
            error: .duplicateCard(card("Kh"), location: .hole(player: 0))
        )) {
            try state.replacingOperation(at: 2, with: .dealHole(player: 0, card: card("Kh")))
        }
    }

    @Test("a rejected operation leaves the state unchanged, and canApply agrees with apply")
    func rejectedOperations() throws {
        let state = try HandState(config: .test(stacks: [200, 200])).dealingHoles("AsKsAhKh")
        #expect(state.canApply(.checkOrCall(player: 1)))
        #expect(!state.canApply(.checkOrCall(player: 0)))
        #expect(throws: EngineError.notYourTurn(player: 0, actor: 1)) { try state.apply(.checkOrCall(player: 0)) }
        #expect(state.operations.count == 4)
    }

    @Test("showdown and settlement operations are not expected during betting")
    func settlementOperationsDuringBetting() throws {
        let state = try HandState(config: .test(stacks: [200, 200])).dealingHoles("AsKsAhKh")
        #expect(throws: EngineError.noShowdownExpected(player: 0)) { try state.apply(.showHoleCards(player: 0)) }
        #expect(throws: EngineError.noShowdownExpected(player: 1)) { try state.apply(.muckHoleCards(player: 1)) }
        #expect(throws: EngineError.noRunoutSelectionExpected(player: 0)) { try state.apply(.selectRunoutCount(player: 0, count: 2)) }
        #expect(throws: EngineError.noHandToKill(player: 0)) { try state.apply(.killHand(player: 0)) }
        #expect(throws: EngineError.noChipsToPush) { try state.apply(.pushChips) }
        #expect(throws: EngineError.noChipsToPull(player: 1)) { try state.apply(.pullChips(player: 1)) }
    }

    @Test("error messages name players through the UI's labels")
    func errorMessages() {
        let seats = ["Ana", "Ben", "Cy"]
        #expect(EngineError.notYourTurn(player: 0, actor: 2).message(naming: { seats[$0] }) == "It is Cy's turn, not Ana's.")
        #expect(EngineError.duplicateCard(card("As"), location: .hole(player: 1)).message(naming: { seats[$0] })
            == "As is already in Ben's hand.")
        #expect(EngineError.invalidPlayer(7).message(naming: { seats[$0] }) == "There is no player with index 7.")
        // Only the refusal: whether the player may fold, or must call rather than check, depends on the state.
        #expect(EngineError.raiseNotAllowed(player: 1, reason: .actionNotReopened).message(naming: { seats[$0] })
            == "Ben cannot raise: the all-in was not a full raise.")
        #expect(EngineError.raiseNotAllowed(player: 1, reason: .playerIsCovered).message(naming: { seats[$0] })
            == "Ben cannot raise: the bet covers their stack.")
        #expect(EngineError.raiseNotAllowed(player: 1, reason: .noOpponentCanRespond).message(naming: { seats[$0] })
            == "Ben cannot bet or raise: nobody else could call it.")
    }

    @Test("every message about a player uses the UI's label for that player")
    func everyMessageUsesTheLabel() {
        let errors: [EngineError] = [
            .noAnteExpected(player: 1), .noBlindOrStraddleExpected(player: 1), .noDealExpected(.holeCard(player: 1)),
            .duplicateCard(card("As"), location: .hole(player: 1)), .notYourTurn(player: 1, actor: 1),
            .cannotFoldWhenCheckIsFree(player: 1), .raiseNotAllowed(player: 1, reason: .playerIsCovered),
            .raiseNotAllowed(player: 1, reason: .actionNotReopened),
            .raiseNotAllowed(player: 1, reason: .noOpponentCanRespond), .noRunoutSelectionExpected(player: 1),
            .noShowdownExpected(player: 1), .playerNotInHand(player: 1), .tooManyCardsShown(player: 1, count: 3),
            .cannotShowUnknownCard(player: 1), .mustShowAllCards(player: 1),
            .shownCardNotDealt(player: 1, card: card("As")), .wouldAbandonPot(player: 1, pot: 0),
            .noHandToKill(player: 1), .noChipsToPull(player: 1),
        ]
        for error in errors {
            let message = error.message(naming: { "Seat \($0)" })
            #expect(message.contains("Seat 1"), "\(error)")
            #expect(!message.contains("Player"), "\(error)")
        }
    }

    @Test("every error has a sentence for the dealer; one at the wrong moment says so, rather than that nothing exists")
    func everyErrorMessage() {
        let messages: [(EngineError, String)] = [
            (.handComplete, "The hand is over."),
            (.invalidPlayer(7), "There is no player with index 7."),
            (.noAnteExpected(player: 0), "Player 1 has no ante to post."),
            (.noBetCollectionExpected, "Bets cannot be collected now."),
            (.noBlindOrStraddleExpected(player: 0), "Player 1 cannot post a blind or straddle now."),
            (.noDealExpected(.burn), "No card should be burned now."),
            (.noDealExpected(.holeCard(player: 2)), "Player 3 should not be dealt a hole card now."),
            (.noDealExpected(.boardCard), "No board card should be dealt now."),
            (.burnRequired, "Burn a card before dealing the board."),
            (.duplicateCard(card("As"), location: .hole(player: 1)), "As is already in Player 2's hand."),
            (.duplicateCard(card("As"), location: .board(runout: 0)), "As is already on the board."),
            (.duplicateCard(card("As"), location: .board(runout: 1)), "As is already on board 2."),
            (.duplicateCard(card("As"), location: .burned), "As is already burned."),
            (.duplicateCard(card("As"), location: .mucked), "As is already in the muck."),
            (.duplicateCard(card("As"), location: .sameOperation), "As is listed twice."),
            (.noActionExpected, "Nobody is due to act."),
            (.notYourTurn(player: 0, actor: 2), "It is Player 3's turn, not Player 1's."),
            (.cannotFoldWhenCheckIsFree(player: 1), "Player 2 can check, so folding is not allowed in a tournament."),
            (.betBelowMinimum(amount: 9, minimum: 10), "9 is below the minimum of 10."),
            (.betAboveMaximum(amount: 201, maximum: 200), "201 is above the maximum of 200."),
            (.raiseNotAllowed(player: 1, reason: .playerIsCovered), "Player 2 cannot raise: the bet covers their stack."),
            (.raiseNotAllowed(player: 1, reason: .actionNotReopened), "Player 2 cannot raise: the all-in was not a full raise."),
            (.raiseNotAllowed(player: 1, reason: .noOpponentCanRespond), "Player 2 cannot bet or raise: nobody else could call it."),
            (.noRunoutSelectionExpected(player: 0), "Player 1 has no runout count to choose."),
            (.invalidRunoutCount(0), "0 is not a valid number of runouts."),
            (.noShowdownExpected(player: 0), "Player 1 has nothing to show or muck now."),
            (.playerNotInHand(player: 0), "Player 1 is no longer in the hand."),
            (.tooManyCardsShown(player: 0, count: 3), "Player 1 cannot show 3 cards."),
            (.cannotShowUnknownCard(player: 0), "Scan Player 1's cards to show them."),
            (.mustShowAllCards(player: 0), "Player 1 must show every card."),
            (.shownCardNotDealt(player: 0, card: card("As")), "As was not dealt to Player 1."),
            (.wouldAbandonPot(player: 0, pot: 0), "If Player 1 gave up the hand, nobody could win the main pot."),
            (.wouldAbandonPot(player: 0, pot: 1), "If Player 1 gave up the hand, nobody could win side pot 1."),
            (.wouldAbandonPot(player: 0, pot: 2), "If Player 1 gave up the hand, nobody could win side pot 2."),
            (.unknownBoardCard(runout: 0, position: 4), "Scan board card 5 of run 1 to settle the hand."),
            (.unknownBoardCard(runout: 1, position: 0), "Scan board card 1 of run 2 to settle the hand."),
            (.noHandToKill(player: 0), "Player 1's hand cannot be killed now."),
            (.noChipsToPush, "Chips cannot be pushed now."),
            (.noChipsToPull(player: 0), "Player 1 cannot pull chips now."),
        ]
        for (error, message) in messages {
            #expect(error.message() == message)
        }
    }

    @Test("messages never trap, whatever numbers a decoded error carries")
    func extremeMessagePayloads() {
        #expect(!EngineError.notYourTurn(player: .max, actor: .max).message().isEmpty)
        #expect(!EngineError.unknownBoardCard(runout: .max, position: .max).message(naming: { _ in "" }).isEmpty)
        #expect(!EngineError.duplicateCard(.unknown, location: .board(runout: .max)).message().isEmpty)
    }
}
