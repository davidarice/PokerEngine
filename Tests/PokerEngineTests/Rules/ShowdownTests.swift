import Testing
@testable import PokerEngine

@Suite("Showdown")
struct ShowdownTests {
    /// Three players limp and check to the river, with player 0 to act. Player 0 holds aces, player 1 kings and
    /// player 2 queens, on a board that helps nobody.
    private func checkedToRiver(
        _ mode: HandConfig.Mode = .cashGame,
        stacks: [Int] = [200, 200, 200],
        holes: String = "AsKsQsAhKhQh",
        automations: Set<HandConfig.Automation> = .bookkeeping
    ) throws -> HandState {
        try HandState(config: .test(mode, stacks: stacks, automations: automations)).dealingHoles(holes).checkingDown()
            .dealingStreet("2c7d9h").checkingDown()
            .dealingStreet("Ts").checkingDown()
            .dealingStreet("3s")
    }

    /// `checkedToRiver` with the river checked too, which leaves all three players to show in seat order.
    private func riverShowdown(
        _ mode: HandConfig.Mode = .cashGame,
        holes: String = "AsKsQsAhKhQh",
        automations: Set<HandConfig.Automation> = .bookkeeping
    ) throws -> HandState {
        try checkedToRiver(mode, holes: holes, automations: automations).checkingDown()
    }

    /// Heads-up, the button shoves before the flop and the big blind calls. Player 0 holds aces, player 1 kings.
    private func allIn(_ mode: HandConfig.Mode = .cashGame, holes: String = "AsKsAhKh") throws -> HandState {
        try HandState(config: .test(mode, stacks: [100, 100])).dealingHoles(holes)
            .applying(.betOrRaise(player: 1, to: 100), .checkOrCall(player: 0))
    }

    /// `allIn` with both runout selections made, leaving only the shows.
    private func selected(holes: String = "AsKsAhKh") throws -> HandState {
        try allIn(holes: holes)
            .applying(.selectRunoutCount(player: 0, count: nil), .selectRunoutCount(player: 1, count: nil))
    }

    /// Answers each showdown with `shows` and deals the next street, up to the river card.
    private func runningOut(_ state: HandState, shows: [HandOperation]) throws -> HandState {
        try state.applying(shows).dealingStreet("2c7d9h")
            .applying(shows).dealingStreet("Ts")
            .applying(shows).dealingStreet("3s")
    }

    // MARK: Showdown order

    @Test("the last bettor or raiser of the final round shows first, then the seats after them (A14)")
    func lastAggressorShowsFirst() throws {
        let bet = try checkedToRiver().applying(
            .checkOrCall(player: 0), .betOrRaise(player: 1, to: 10), .checkOrCall(player: 2), .checkOrCall(player: 0)
        )
        #expect(bet.pendingOperation == .showdown(runoutSelectors: [], showOrder: [1, 2, 0]))
        let raised = try checkedToRiver().applying(
            .betOrRaise(player: 0, to: 10), .betOrRaise(player: 1, to: 30), .betOrRaise(player: 2, to: 60),
            .checkOrCall(player: 0), .checkOrCall(player: 1)
        )
        #expect(raised.pendingOperation == .showdown(runoutSelectors: [], showOrder: [2, 0, 1]))
    }

    @Test("a short all-in raiser is the last raiser, so shows first (A14)")
    func shortAllInRaiserShowsFirst() throws {
        // Player 1's 48-chip raise over a 100-chip bet is not a full raise.
        let state = try checkedToRiver(stacks: [300, 150, 300]).applying(
            .betOrRaise(player: 0, to: 100), .betOrRaise(player: 1, to: 148),
            .checkOrCall(player: 2), .checkOrCall(player: 0)
        )
        #expect(state.stacks == [150, 0, 150])
        #expect(state.pendingOperation == .showdown(runoutSelectors: [], showOrder: [1, 2, 0]))
    }

    @Test("with no bet in the final round, the first active seat left of the button shows first (A14)")
    func noBetPostflopOrder() throws {
        #expect(try riverShowdown().pendingOperation == .showdown(runoutSelectors: [], showOrder: [0, 1, 2]))
        let folded = try checkedToRiver().applying(.fold(player: 0)).checkingDown()
        #expect(folded.pendingOperation == .showdown(runoutSelectors: [], showOrder: [1, 2]))
    }

    @Test("a preflop all-in with no raise starts at the first-to-act seat, left of the big blind (A14)")
    func noBetPreflopOrder() throws {
        let state = try HandState(config: .test(.tournament, stacks: [2, 2, 2])).dealingHoles("AsKsQsAhKhQh")
            .checkingDown()
        #expect(state.pendingOperation == .showdown(runoutSelectors: [], showOrder: [2, 0, 1]))
    }

    @Test("heads-up with no raise before the flop, the button shows first; with equal blinds, the big blind (A14)")
    func headsUpNoBetPreflopOrder() throws {
        let called = try HandState(config: .test(.tournament, stacks: [200, 3], blinds: [2, 4], minBet: 4))
            .dealingHoles("AsKsAhKh").checkingDown()
        #expect(called.pendingOperation == .showdown(runoutSelectors: [], showOrder: [1, 0]))
        let equalBlinds = try HandState(config: .test(.tournament, stacks: [2, 2], blinds: [2, 2]))
            .dealingHoles("AsKsAhKh")
        #expect(equalBlinds.pendingOperation == .showdown(runoutSelectors: [], showOrder: [0, 1]))
    }

    @Test("anyone in the show order may show or muck out of turn")
    func outOfTurn() throws {
        let shown = try riverShowdown().applying(.showHoleCards(player: 2))
        #expect(shown.pendingOperation == .showdown(runoutSelectors: [], showOrder: [0, 1]))
        let mucked = try shown.applying(.muckHoleCards(player: 1))
        #expect(mucked.pendingOperation == .showdown(runoutSelectors: [], showOrder: [0]))
    }

    @Test("after an all-in, no card is dealt until every active hand is shown or mucked (A9)")
    func allInShowsBeforeNextCard() throws {
        var state = try allIn(.tournament)
        #expect(state.pendingOperation == .showdown(runoutSelectors: [], showOrder: [1, 0]))
        #expect(throws: EngineError.noDealExpected(.burn)) { try state.apply(.burnCard(.unknown)) }
        state = try state.applying(.showHoleCards(player: 1))
        #expect(state.pendingOperation == .showdown(runoutSelectors: [], showOrder: [0]))
        #expect(throws: EngineError.noDealExpected(.burn)) { try state.apply(.burnCard(.unknown)) }
        state = try state.applying(.showHoleCards(player: 0))
        #expect(state.pendingOperation == .burnCard(street: .flop, runout: 0))
    }

    // MARK: Runout selection

    @Test("a cash all-in before the river asks every active player for a runout count, the covering player too (A10)")
    func selectionOfferedToEveryActivePlayer() throws {
        // Player 2 folded, and player 0 covers player 1, so only player 0 has chips left.
        let state = try HandState(config: .test(stacks: [200, 50, 200])).dealingHoles("AsKsQsAhKhQh")
            .applying(.fold(player: 2), .betOrRaise(player: 0, to: 200), .checkOrCall(player: 1))
        #expect(state.stacks == [150, 0, 200])
        #expect(state.pendingOperation == .showdown(runoutSelectors: [0, 1], showOrder: [0, 1]))
    }

    @Test("the runout count is chosen once per hand: later showdowns do not ask again (A10)")
    func selectionOfferedOnce() throws {
        let state = try selected().applying(.showHoleCards(player: 1, cards: []), .showHoleCards(player: 0, cards: []))
            .dealingStreet("2c7d9h")
        #expect(state.pendingOperation == .showdown(runoutSelectors: [], showOrder: [0, 1]))
        #expect(throws: EngineError.noRunoutSelectionExpected(player: 0)) {
            try state.apply(.selectRunoutCount(player: 0, count: 1))
        }
    }

    @Test("the runout count is asked on the flop and turn, never on the river (A10)")
    func selectionOnlyBeforeTheRiver() throws {
        let holes = try HandState(config: .test(stacks: [100, 100])).dealingHoles("AsKsAhKh").checkingDown()
        let flop = try holes.dealingStreet("2c7d9h")
        let flopAllIn = try flop.applying(.betOrRaise(player: 0, to: 98), .checkOrCall(player: 1))
        #expect(flopAllIn.pendingOperation == .showdown(runoutSelectors: [0, 1], showOrder: [0, 1]))
        let turn = try flop.checkingDown().dealingStreet("Ts")
        let turnAllIn = try turn.applying(.betOrRaise(player: 0, to: 98), .checkOrCall(player: 1))
        #expect(turnAllIn.pendingOperation == .showdown(runoutSelectors: [0, 1], showOrder: [0, 1]))
        let riverAllIn = try turn.checkingDown().dealingStreet("3s")
            .applying(.betOrRaise(player: 0, to: 98), .checkOrCall(player: 1))
        #expect(riverAllIn.pendingOperation == .showdown(runoutSelectors: [], showOrder: [0, 1]))
        #expect(throws: EngineError.noRunoutSelectionExpected(player: 0)) {
            try riverAllIn.apply(.selectRunoutCount(player: 0, count: 1))
        }
    }

    @Test("tournaments never ask for a runout count")
    func noSelectionInTournaments() throws {
        let state = try allIn(.tournament)
        #expect(state.pendingOperation == .showdown(runoutSelectors: [], showOrder: [1, 0]))
        #expect(throws: EngineError.noRunoutSelectionExpected(player: 1)) {
            try state.apply(.selectRunoutCount(player: 1, count: nil))
        }
    }

    @Test("with runout automation, each selector abstains by itself, lowest seat first")
    func abstainAutomation() throws {
        let config = HandConfig.test(stacks: [100, 100], automations: .bookkeeping.union([.runoutCountSelection]))
        let state = try HandState(config: config).dealingHoles("AsKsAhKh")
            .applying(.betOrRaise(player: 1, to: 100), .checkOrCall(player: 0))
        #expect(state.log.suffix(3) == [
            LogEntry(
                event: .betsCollected(collected: [100, 100], returned: [0, 0]), isAutomated: true, operationIndex: 5
            ),
            LogEntry(event: .runoutCountSelected(player: 0, count: nil), isAutomated: true, operationIndex: 5),
            LogEntry(event: .runoutCountSelected(player: 1, count: nil), isAutomated: true, operationIndex: 5),
        ])
        #expect(state.pendingOperation == .showdown(runoutSelectors: [], showOrder: [1, 0]))
    }

    @Test("selections and shows interleave in any order, and the hand moves on after the last of them")
    func selectionsAndShowsInterleave() throws {
        var state = try allIn().applying(.showHoleCards(player: 0))
        #expect(state.pendingOperation == .showdown(runoutSelectors: [0, 1], showOrder: [1]))
        state = try state.applying(.selectRunoutCount(player: 1, count: nil))
        #expect(state.pendingOperation == .showdown(runoutSelectors: [0], showOrder: [1]))
        state = try state.applying(.showHoleCards(player: 1))
        #expect(state.pendingOperation == .showdown(runoutSelectors: [0], showOrder: []))
        state = try state.applying(.selectRunoutCount(player: 0, count: 1))
        #expect(state.pendingOperation == .burnCard(street: .flop, runout: 0))
    }

    @Test("a selection is credited to the player it names, whoever is first in line (B5)")
    func selectionCreditsNamedPlayer() throws {
        let state = try allIn().applying(.selectRunoutCount(player: 1, count: 1))
        #expect(state.events.last == .runoutCountSelected(player: 1, count: 1))
        #expect(state.pendingOperation == .showdown(runoutSelectors: [0], showOrder: [1, 0]))
        #expect(throws: EngineError.noRunoutSelectionExpected(player: 1)) {
            try state.apply(.selectRunoutCount(player: 1, count: 1))
        }
        // PokerKit's bug reads player 0 as a count of 0.
        let both = try state.applying(.selectRunoutCount(player: 0, count: 1))
        #expect(both.events.last == .runoutCountSelected(player: 0, count: 1))
    }

    @Test("runout counts below 1 are refused, and the selector can still choose (B5)")
    func nonPositiveRunoutCounts() throws {
        let state = try allIn()
        #expect(throws: EngineError.invalidRunoutCount(0)) { try state.apply(.selectRunoutCount(player: 0, count: 0)) }
        #expect(throws: EngineError.invalidRunoutCount(-1)) {
            try state.apply(.selectRunoutCount(player: 1, count: -1))
        }
        #expect(state.pendingOperation == .showdown(runoutSelectors: [0, 1], showOrder: [1, 0]))
    }

    @Test("whether the player may choose is checked before the count")
    func selectorCheckedBeforeCount() throws {
        let state = try allIn().applying(.selectRunoutCount(player: 0, count: 1))
        #expect(throws: EngineError.noRunoutSelectionExpected(player: 0)) {
            try state.apply(.selectRunoutCount(player: 0, count: 0))
        }
        let betting = try HandState(config: .test(stacks: [100, 100])).dealingHoles("AsKsAhKh")
        #expect(throws: EngineError.noRunoutSelectionExpected(player: 0)) {
            try betting.apply(.selectRunoutCount(player: 0, count: 5))
        }
    }

    @Test("a player who folded is not asked for a runout count")
    func foldedPlayerDoesNotChoose() throws {
        let state = try HandState(config: .test(stacks: [200, 50, 200])).dealingHoles("AsKsQsAhKhQh")
            .applying(.fold(player: 2), .betOrRaise(player: 0, to: 200), .checkOrCall(player: 1))
        #expect(throws: EngineError.noRunoutSelectionExpected(player: 2)) {
            try state.apply(.selectRunoutCount(player: 2, count: 1))
        }
    }

    @Test("a player who mucks at an all-in still has to choose a runout count (A10)")
    func muckerStillChooses() throws {
        let state = try allIn().applying(.muckHoleCards(player: 1))
        #expect(state.statuses == [.active, .mucked])
        #expect(state.pendingOperation == .showdown(runoutSelectors: [0, 1], showOrder: [0]))
        let chosen = try state.applying(.selectRunoutCount(player: 1, count: 1))
        #expect(chosen.events.last == .runoutCountSelected(player: 1, count: 1))
        #expect(chosen.pendingOperation == .showdown(runoutSelectors: [0], showOrder: [0]))
    }

    // MARK: Re-asks

    @Test("a cash hand kept face down is asked again after each runout street, starting from player 0 (A9)")
    func reaskAfterEachStreet() throws {
        var state = try selected()
        #expect(state.pendingOperation == .showdown(runoutSelectors: [], showOrder: [1, 0]))
        let keptDown: [HandOperation] = [.showHoleCards(player: 1, cards: []), .showHoleCards(player: 0, cards: [])]
        state = try state.applying(keptDown).dealingStreet("2c7d9h")
        #expect(state.pendingOperation == .showdown(runoutSelectors: [], showOrder: [0, 1]))
        state = try state.applying(keptDown).dealingStreet("Ts")
        #expect(state.pendingOperation == .showdown(runoutSelectors: [], showOrder: [0, 1]))
        state = try state.applying(keptDown).dealingStreet("3s")
        #expect(state.pendingOperation == .showdown(runoutSelectors: [], showOrder: [0, 1]))
    }

    @Test("only hands with a card face down are asked again: a full show ends the player's part")
    func reaskSkipsShownHands() throws {
        let partly = try selected().applying(.showHoleCards(player: 1), .showHoleCards(player: 0, cards: cards("As")))
            .dealingStreet("2c7d9h")
        #expect(partly.pendingOperation == .showdown(runoutSelectors: [], showOrder: [0]))
        let shown = try selected().applying(.showHoleCards(player: 1), .showHoleCards(player: 0))
            .dealingStreet("2c7d9h")
        #expect(shown.pendingOperation == .burnCard(street: .turn, runout: 0))
    }

    @Test("a re-ask goes by the cards face up now: showing the other card turns the first back down")
    func reaskFollowsLiveCards() throws {
        let state = try selected().applying(.showHoleCards(player: 1), .showHoleCards(player: 0, cards: cards("As")))
            .dealingStreet("2c7d9h").applying(.showHoleCards(player: 0, cards: cards("Ah")))
        #expect(state.holeCards[0] == [up("Ah"), down("As")])
        let turn = try state.dealingStreet("Ts")
        #expect(turn.pendingOperation == .showdown(runoutSelectors: [], showOrder: [0]))
    }

    // MARK: Showing and mucking

    @Test("a muck is recorded as a muck, so replaying the operations gives the same hand")
    func muckIsReplayed() throws {
        let state = try riverShowdown().applying(.muckHoleCards(player: 1))
        #expect(state.operations.last == .muckHoleCards(player: 1))
        #expect(try HandState.replay(config: state.config, operations: state.operations) == state)
    }

    @Test("a show as is turns every hole card face up in its current order and leaves the player active")
    func showAsIs() throws {
        let state = try riverShowdown().applying(.showHoleCards(player: 0))
        #expect(state.holeCards[0] == [up("As"), up("Ah")])
        #expect(state.events.last == .holeCardsShown(player: 0, cards: cards("AsAh")))
        #expect(state.statuses[0] == .active)
    }

    @Test("a listed full show turns the cards face up in the listed order")
    func listedShowReorders() throws {
        let state = try riverShowdown().applying(.showHoleCards(player: 0, cards: cards("AhAs")))
        #expect(state.holeCards[0] == [up("Ah"), up("As")])
        #expect(state.events.last == .holeCardsShown(player: 0, cards: cards("AhAs")))
    }

    @Test("a show as is keeps the order an earlier partial show left")
    func showAsIsAfterPartialShow() throws {
        let state = try selected().applying(.showHoleCards(player: 1), .showHoleCards(player: 0, cards: cards("Ah")))
            .dealingStreet("2c7d9h").applying(.showHoleCards(player: 0))
        #expect(state.holeCards[0] == [up("Ah"), up("As")])
        #expect(state.events.last == .holeCardsShown(player: 0, cards: cards("AhAs")))
    }

    @Test("a muck removes the player from the hand and from the show order, and empties the live cards")
    func muck() throws {
        let state = try riverShowdown().applying(.muckHoleCards(player: 1))
        #expect(state.events.last == .holeCardsMucked(player: 1))
        #expect(state.statuses == [.active, .mucked, .active])
        #expect(state.holeCards[1].isEmpty)
        #expect(state.pendingOperation == .showdown(runoutSelectors: [], showOrder: [0, 2]))
    }

    @Test("a cash partial show on the flop puts the shown card first and keeps the other face down")
    func partialShowOnTheFlop() throws {
        let state = try HandState(config: .test(stacks: [100, 100])).dealingHoles("AsKsAhKh").checkingDown()
            .dealingStreet("2c7d9h").applying(.betOrRaise(player: 0, to: 98), .checkOrCall(player: 1))
            .applying(.showHoleCards(player: 0, cards: cards("Ah")))
        #expect(state.holeCards[0] == [up("Ah"), down("As")])
        #expect(state.events.last == .holeCardsShown(player: 0, cards: cards("Ah??")))
    }

    @Test("a cash partial show on the river forgets the card kept face down (A13)")
    func partialShowOnTheRiver() throws {
        let state = try riverShowdown().applying(.showHoleCards(player: 0, cards: cards("Ah")))
        #expect(state.holeCards[0] == [up("Ah"), down("??")])
        #expect(state.events.last == .holeCardsShown(player: 0, cards: cards("Ah??")))
        #expect(state.statuses[0] == .active)
    }

    @Test("a list may not hold an unknown card, wherever it stands: a card is shown or left out (B14)")
    func unknownEntriesRefused() throws {
        for list in ["??Ah", "Ah??", "??"] {
            #expect(throws: EngineError.cannotShowUnknownCard(player: 0)) {
                try allIn().apply(.showHoleCards(player: 0, cards: cards(list)))
            }
            #expect(throws: EngineError.cannotShowUnknownCard(player: 0)) {
                try riverShowdown().apply(.showHoleCards(player: 0, cards: cards(list)))
            }
        }
        let state = try allIn().applying(.showHoleCards(player: 0, cards: cards("Ah")))
        #expect(state.holeCards[0] == [up("Ah"), down("As")])
        #expect(state.events.last == .holeCardsShown(player: 0, cards: cards("Ah??")))
    }

    @Test("an unknown card in a list is refused only after PokerKit's own checks pass (B14)")
    func unknownEntryRefusedLast() throws {
        #expect(throws: EngineError.tooManyCardsShown(player: 0, count: 3)) {
            try riverShowdown().apply(.showHoleCards(player: 0, cards: cards("As????")))
        }
        #expect(throws: EngineError.mustShowAllCards(player: 0)) {
            try riverShowdown(.tournament).apply(.showHoleCards(player: 0, cards: cards("As??")))
        }
        #expect(throws: EngineError.playerNotInHand(player: 0)) {
            try riverShowdown().applying(.muckHoleCards(player: 0)).apply(.showHoleCards(player: 0, cards: cards("??")))
        }
    }

    @Test("an empty show keeps both cards face down: scanned before the river, forgotten on it (A13)")
    func emptyShow() throws {
        let allInShow = try allIn().applying(.showHoleCards(player: 0, cards: []))
        #expect(allInShow.holeCards[0] == [down("As"), down("Ah")])
        #expect(allInShow.events.last == .holeCardsShown(player: 0, cards: cards("????")))
        let riverShow = try riverShowdown().applying(.showHoleCards(player: 0, cards: []))
        #expect(riverShow.holeCards[0] == [down("??"), down("??")])
        #expect(riverShow.statuses[0] == .active)
    }

    @Test("a river re-ask answered with [] turns a card shown earlier face down as unknown")
    func riverReaskHidesShownCard() throws {
        let river = try runningOut(
            selected(), shows: [.showHoleCards(player: 1, cards: []), .showHoleCards(player: 0, cards: cards("Ah"))]
        )
        #expect(river.holeCards[0] == [up("Ah"), down("As")])
        let state = try river.applying(.showHoleCards(player: 0, cards: []))
        #expect(state.holeCards[0] == [down("??"), down("??")])
    }

    @Test("forgotten cards no longer count towards the player's hand, and face-down cards never count as shown")
    func forgottenCardsLeaveTheHand() throws {
        let state = try riverShowdown()
        #expect(state.hand(of: 0)?.description == "One pair (AsAh7d9hTs)")
        #expect(state.hand(of: 0, faceUpOnly: true)?.description == "High card (2c7d9hTs3s)")
        let forgotten = try state.applying(.showHoleCards(player: 0, cards: cards("Ah")))
        #expect(forgotten.hand(of: 0)?.description == "High card (Ah7d9hTs3s)")
        #expect(forgotten.hand(of: 0, faceUpOnly: true)?.description == "High card (Ah7d9hTs3s)")
    }

    // MARK: Revealing unknown cards

    @Test("cards dealt as unknown are revealed by listing them, in any order")
    func revealUnknownCards() throws {
        let holes = "??KsQs??KhQh"
        let state = try riverShowdown(holes: holes).applying(.showHoleCards(player: 0, cards: cards("AdAc")))
        #expect(state.holeCards[0] == [up("Ad"), up("Ac")])
        #expect(state.events.last == .holeCardsShown(player: 0, cards: cards("AdAc")))
        let reordered = try riverShowdown(holes: holes).applying(.showHoleCards(player: 0, cards: cards("AcAd")))
        #expect(reordered.holeCards[0] == [up("Ac"), up("Ad")])
    }

    @Test("an unknown card is revealed alongside a scanned one, in either order")
    func revealBesideKnownCard() throws {
        let holes = "??KsQsAhKhQh"
        let first = try riverShowdown(holes: holes).applying(.showHoleCards(player: 0, cards: cards("AdAh")))
        #expect(first.holeCards[0] == [up("Ad"), up("Ah")])
        let second = try riverShowdown(holes: holes).applying(.showHoleCards(player: 0, cards: cards("AhAd")))
        #expect(second.holeCards[0] == [up("Ah"), up("Ad")])
    }

    @Test("a cash player may reveal one unknown card and keep the other face down")
    func partialReveal() throws {
        let state = try allIn(holes: "??Ks??Kh").applying(.showHoleCards(player: 0, cards: cards("Ad")))
        #expect(state.holeCards[0] == [up("Ad"), down("??")])
        #expect(state.events.last == .holeCardsShown(player: 0, cards: cards("Ad??")))
    }

    @Test("a later show can finish a partial reveal, naming the card already revealed")
    func secondShowFinishesReveal() throws {
        let state = try selected(holes: "??Ks??Kh")
            .applying(.showHoleCards(player: 0, cards: cards("Ad")), .showHoleCards(player: 1))
            .dealingStreet("2c7d9h").applying(.showHoleCards(player: 0, cards: cards("AdAc")))
        #expect(state.holeCards[0] == [up("Ad"), up("Ac")])
    }

    @Test("once revealed, a card is seen: dealing it again is a duplicate, in the hand or in the muck (B1)")
    func revealedCardIsSeen() throws {
        let revealed = try selected(holes: "??Ks??Kh")
            .applying(.showHoleCards(player: 0, cards: cards("Ad")), .showHoleCards(player: 1))
        let flop = try revealed.applying(.burnCard(.unknown), .dealBoard(card("2c")))
        #expect(throws: EngineError.duplicateCard(card("Ad"), location: .hole(player: 0))) {
            try flop.apply(.dealBoard(card("Ad")))
        }
        let mucked = try flop.applying(.dealBoard(card("7d")), .dealBoard(card("9h")), .muckHoleCards(player: 0))
        #expect(throws: EngineError.duplicateCard(card("Ad"), location: .mucked)) {
            try mucked.apply(.burnCard(card("Ad")))
        }
    }

    // MARK: Refused shows

    @Test("showing as is while a card is unknown is refused in both modes: list the cards instead")
    func showAsIsWithUnknownCard() throws {
        let holes = "??KsQs??KhQh"
        #expect(throws: EngineError.cannotShowUnknownCard(player: 0)) {
            try riverShowdown(holes: holes).apply(.showHoleCards(player: 0))
        }
        #expect(throws: EngineError.cannotShowUnknownCard(player: 0)) {
            try riverShowdown(.tournament, holes: holes).apply(.showHoleCards(player: 0))
        }
        #expect(throws: EngineError.cannotShowUnknownCard(player: 0)) {
            try allIn(.tournament, holes: "??Ks??Kh").apply(.showHoleCards(player: 0))
        }
        #expect(throws: EngineError.cannotShowUnknownCard(player: 1)) {
            try allIn(holes: "As??Ah??").apply(.showHoleCards(player: 1))
        }
        #expect(try allIn(holes: "As??Ah??").canApply(.showHoleCards(player: 0)))
    }

    @Test("listing more cards than the player holds is refused")
    func tooManyCards() throws {
        let state = try riverShowdown()
        #expect(throws: EngineError.tooManyCardsShown(player: 0, count: 3)) {
            try state.apply(.showHoleCards(player: 0, cards: cards("AsAhKd")))
        }
        #expect(throws: EngineError.tooManyCardsShown(player: 0, count: 3)) {
            try state.apply(.showHoleCards(player: 0, cards: cards("As????")))
        }
    }

    @Test("tournament partial shows are refused at an all-in and on the river, in any form")
    func tournamentPartialShows() throws {
        for state in [try allIn(.tournament), try riverShowdown(.tournament)] {
            #expect(throws: EngineError.mustShowAllCards(player: 1)) {
                try state.apply(.showHoleCards(player: 1, cards: cards("Ks")))
            }
            #expect(throws: EngineError.mustShowAllCards(player: 1)) {
                try state.apply(.showHoleCards(player: 1, cards: cards("Ks??")))
            }
            #expect(throws: EngineError.mustShowAllCards(player: 1)) {
                try state.apply(.showHoleCards(player: 1, cards: []))
            }
        }
    }

    @Test("a tournament player may muck at an all-in")
    func tournamentAllInMuck() throws {
        let state = try allIn(.tournament).applying(.muckHoleCards(player: 1))
        #expect(state.statuses == [.active, .mucked])
        #expect(state.pendingOperation == .showdown(runoutSelectors: [], showOrder: [0]))
    }

    @Test("the player left at a tournament showdown with nobody all in may keep the cards face down (B13)")
    func tournamentLastPlayerKeeps() throws {
        let state = try riverShowdown(.tournament).applying(.muckHoleCards(player: 0), .muckHoleCards(player: 1))
        let kept = try state.apply(.showHoleCards(player: 2, cards: []))
        #expect(kept.isHandComplete)
        #expect(kept.results?[2].net == 4)
        #expect(kept.results?[2].shown == false)
        #expect(kept.results?[2].holeCards == [down("Qs"), down("Qh")])
        let partial = try state.apply(.showHoleCards(player: 2, cards: cards("Qh")))
        #expect(partial.results?[2].holeCards == [down("Qs"), up("Qh")])
        #expect(try state.apply(.showHoleCards(player: 2)).results?[2].shown == true)
        #expect(throws: EngineError.cannotShowUnknownCard(player: 2)) {
            try state.apply(.showHoleCards(player: 2, cards: cards("Qh??")))
        }
    }

    @Test("a tournament player must still show every card while another hand is in, or after an all-in (B13)")
    func tournamentKeepRefused() throws {
        let twoLeft = try riverShowdown(.tournament).applying(.muckHoleCards(player: 0))
        #expect(throws: EngineError.mustShowAllCards(player: 1)) {
            try twoLeft.apply(.showHoleCards(player: 1, cards: []))
        }
        let allInLeft = try allIn(.tournament).applying(.muckHoleCards(player: 1))
        #expect(throws: EngineError.mustShowAllCards(player: 0)) {
            try allInLeft.apply(.showHoleCards(player: 0, cards: []))
        }
        // A river all-in for less is an all-in too, though both callers have chips behind.
        let shove = try checkedToRiver(.tournament, stacks: [50, 200, 200]).applying(
            .betOrRaise(player: 0, to: 48), .checkOrCall(player: 1), .checkOrCall(player: 2),
            .muckHoleCards(player: 1), .muckHoleCards(player: 2)
        )
        #expect(shove.stacks == [0, 150, 150])
        #expect(throws: EngineError.mustShowAllCards(player: 0)) {
            try shove.apply(.showHoleCards(player: 0, cards: []))
        }
        #expect(shove.canApply(.showHoleCards(player: 0)))
    }

    @Test("a player who folded, mucked or was killed is no longer in the hand")
    func playerNotInHand() throws {
        let folded = try checkedToRiver().applying(.checkOrCall(player: 0), .checkOrCall(player: 1), .fold(player: 2))
        #expect(throws: EngineError.playerNotInHand(player: 2)) { try folded.apply(.showHoleCards(player: 2)) }
        #expect(throws: EngineError.playerNotInHand(player: 2)) { try folded.apply(.muckHoleCards(player: 2)) }
        let mucked = try riverShowdown().applying(.muckHoleCards(player: 1))
        #expect(throws: EngineError.playerNotInHand(player: 1)) { try mucked.apply(.showHoleCards(player: 1)) }
        #expect(throws: EngineError.playerNotInHand(player: 1)) { try mucked.apply(.muckHoleCards(player: 1)) }
        let killed = try riverShowdown()
            .applying(.showHoleCards(player: 0), .showHoleCards(player: 1), .showHoleCards(player: 2))
        #expect(killed.statuses == [.active, .killed, .killed])
        #expect(throws: EngineError.playerNotInHand(player: 1)) { try killed.apply(.showHoleCards(player: 1)) }
        #expect(throws: EngineError.playerNotInHand(player: 1)) { try killed.apply(.muckHoleCards(player: 1)) }
    }

    @Test("a player out of the show order has nothing to show: all cards face up, or no showdown under way")
    func noShowdownExpected() throws {
        let reasked = try selected().applying(.showHoleCards(player: 0), .showHoleCards(player: 1, cards: []))
            .dealingStreet("2c7d9h")
        #expect(reasked.pendingOperation == .showdown(runoutSelectors: [], showOrder: [1]))
        #expect(throws: EngineError.noShowdownExpected(player: 0)) { try reasked.apply(.showHoleCards(player: 0)) }
        #expect(throws: EngineError.noShowdownExpected(player: 0)) { try reasked.apply(.muckHoleCards(player: 0)) }
        let betting = try checkedToRiver()
        #expect(throws: EngineError.noShowdownExpected(player: 0)) { try betting.apply(.showHoleCards(player: 0)) }
        let dealing = try HandState(config: .test(stacks: [200, 200])).dealingHoles("AsKsAh")
        #expect(throws: EngineError.noShowdownExpected(player: 0)) { try dealing.apply(.muckHoleCards(player: 0)) }
    }

    @Test("with no showdown under way, a folded player hears that, not that they left the hand")
    func timingBeforeStatus() throws {
        let state = try checkedToRiver().applying(.fold(player: 0))
        #expect(throws: EngineError.noShowdownExpected(player: 0)) { try state.apply(.showHoleCards(player: 0)) }
    }

    @Test("a listed card must be one the player was dealt, even another player's (B6)")
    func shownCardNotDealt() throws {
        let state = try riverShowdown()
        #expect(throws: EngineError.shownCardNotDealt(player: 0, card: card("2d"))) {
            try state.apply(.showHoleCards(player: 0, cards: cards("2d")))
        }
        #expect(throws: EngineError.shownCardNotDealt(player: 0, card: card("2d"))) {
            try state.apply(.showHoleCards(player: 0, cards: cards("As2d")))
        }
        #expect(throws: EngineError.shownCardNotDealt(player: 0, card: card("Ks"))) {
            try state.apply(.showHoleCards(player: 0, cards: cards("Ks")))
        }
    }

    @Test("a player with one unknown card can reveal one card only (B6)")
    func oneRevealPerUnknownCard() throws {
        let state = try riverShowdown(holes: "??KsQsAhKhQh")
        #expect(throws: EngineError.shownCardNotDealt(player: 0, card: card("2d"))) {
            try state.apply(.showHoleCards(player: 0, cards: cards("Ad2d")))
        }
    }

    @Test("a revealed card must be unseen everywhere else (B1)")
    func revealMustBeUnseen() throws {
        let state = try HandState(config: .test(stacks: [200, 200, 200, 200])).dealingHoles("??KsQs5c??KhQh5d")
            .applying(.checkOrCall(player: 2), .fold(player: 3)).checkingDown()
            .applying(.burnCard(card("6c")), .dealBoard(card("2c")), .dealBoard(card("7d")), .dealBoard(card("9h")))
            .checkingDown()
            .dealingStreet("Ts").checkingDown()
            .dealingStreet("3s").checkingDown()
        #expect(throws: EngineError.duplicateCard(card("Ks"), location: .hole(player: 1))) {
            try state.apply(.showHoleCards(player: 0, cards: cards("Ks")))
        }
        #expect(throws: EngineError.duplicateCard(card("2c"), location: .board(runout: 0))) {
            try state.apply(.showHoleCards(player: 0, cards: cards("2c")))
        }
        #expect(throws: EngineError.duplicateCard(card("6c"), location: .burned)) {
            try state.apply(.showHoleCards(player: 0, cards: cards("6c")))
        }
        #expect(throws: EngineError.duplicateCard(card("5d"), location: .mucked)) {
            try state.apply(.showHoleCards(player: 0, cards: cards("5d")))
        }
        let mucked = try state.applying(.muckHoleCards(player: 2))
        #expect(throws: EngineError.duplicateCard(card("Qh"), location: .mucked)) {
            try mucked.apply(.showHoleCards(player: 0, cards: cards("Qh")))
        }
    }

    @Test("a known card listed twice is refused, whether or not it was dealt (B1)")
    func cardListedTwice() throws {
        let state = try riverShowdown()
        #expect(throws: EngineError.duplicateCard(card("As"), location: .sameOperation)) {
            try state.apply(.showHoleCards(player: 0, cards: cards("AsAs")))
        }
        #expect(throws: EngineError.duplicateCard(card("2d"), location: .sameOperation)) {
            try state.apply(.showHoleCards(player: 0, cards: cards("2d2d")))
        }
    }

    @Test("PokerKit's refusals come before the port's own card checks")
    func portChecksComeLast() throws {
        let state = try riverShowdown(.tournament)
        #expect(throws: EngineError.tooManyCardsShown(player: 0, count: 3)) {
            try state.apply(.showHoleCards(player: 0, cards: cards("2d2d2d")))
        }
        #expect(throws: EngineError.mustShowAllCards(player: 0)) {
            try state.apply(.showHoleCards(player: 0, cards: cards("2d")))
        }
        let done = try HandState(config: .test(stacks: [200, 200, 200])).dealingHoles("AsKsQsAhKhQh")
            .applying(.fold(player: 2), .fold(player: 0))
        #expect(throws: EngineError.mustShowAllCards(player: 1)) {
            try done.apply(.showHoleCards(player: 1, cards: cards("2d")))
        }
    }

    @Test("a muck refused for its timing gets that refusal, even where it would also abandon a pot")
    func mucksTimingRefusalsComeBeforeB2() throws {
        let outOfOrder = try HandState(config: .test(stacks: [100, 20, 100])).dealingHoles("AsKsQsAhKhQh").applying(
            .betOrRaise(player: 2, to: 100), .checkOrCall(player: 0), .checkOrCall(player: 1),
            .muckHoleCards(player: 2), .showHoleCards(player: 0)
        )
        let noOrder = try outOfOrder.applying(.showHoleCards(player: 1))
        for state in [outOfOrder, noOrder] {
            #expect(state.potAbandoned(byRemoving: 0) == 1)
            #expect(throws: EngineError.noShowdownExpected(player: 0)) { try state.apply(.muckHoleCards(player: 0)) }
        }
    }

    @Test("a misread that a listed show repeats is corrected in every operation that holds it (B6)")
    func misreadRepeatedByListedShows() throws {
        let deal = HandOperation.dealHole(player: 0, card: card("Ad"))
        let fixedShow = HandOperation.showHoleCards(player: 0, cards: cards("AdAh"))
        let state = try riverShowdown().applying(.showHoleCards(player: 0, cards: cards("AsAh")))
        let show = state.operations.count - 1

        #expect(throws: ReplayError(
            operationIndex: show, operation: state.operations[show],
            error: .shownCardNotDealt(player: 0, card: card("As"))
        )) {
            try state.replacingOperation(at: 0, with: deal)
        }
        #expect(throws: ReplayError(
            operationIndex: show, operation: fixedShow, error: .shownCardNotDealt(player: 0, card: card("Ad"))
        )) {
            try state.replacingOperation(at: show, with: fixedShow)
        }

        var corrected = state.operations
        corrected[0] = deal
        corrected[show] = fixedShow
        let replayed = try HandState.replay(config: state.config, operations: corrected)
        #expect(replayed.holeCards[0].map(\.card) == cards("AdAh"))
    }

    @Test("a repeated misread stays in the hand after one edit if an unknown card can take it (B6)")
    func misreadRepeatedOverAnUnknownCard() throws {
        let state = try riverShowdown(holes: "??KsQsAhKhQh").applying(.showHoleCards(player: 0, cards: cards("Ah")))
        let dealt = try #require(state.operations.firstIndex(of: .dealHole(player: 0, card: card("Ah"))))
        let edited = try state.replacingOperation(at: dealt, with: .dealHole(player: 0, card: card("Ad")))
        #expect(edited.dealtHoleCards[0].map(\.card) == cards("AhAd"))
    }

    // MARK: Forced bets

    @Test("while forced bets are posted nothing can be shown or mucked, in either mode (B9)")
    func showsDuringForcedBets() throws {
        for mode in [HandConfig.Mode.cashGame, .tournament] {
            let config = HandConfig.test(mode, stacks: [200, 200], antes: [1, 1], anteTrimming: true, automations: [])
            let antes = HandState(config: config)
            let collection = try antes.applying(.postAnte(player: 0), .postAnte(player: 1))
            let blinds = try collection.applying(.collectBets)
            for state in [antes, collection, blinds] {
                #expect(throws: EngineError.noShowdownExpected(player: 0)) {
                    try state.apply(.showHoleCards(player: 0))
                }
                #expect(throws: EngineError.noShowdownExpected(player: 0)) {
                    try state.apply(.showHoleCards(player: 0, cards: []))
                }
                #expect(throws: EngineError.tooManyCardsShown(player: 0, count: 1)) {
                    try state.apply(.showHoleCards(player: 0, cards: cards("As")))
                }
                #expect(throws: EngineError.mustShowAllCards(player: 0)) { try state.apply(.muckHoleCards(player: 0)) }
            }
        }
    }

    // MARK: Forgotten cards

    @Test("a card forgotten on the river is still held: another player cannot reveal it (B1)")
    func forgottenCardIsStillHeld() throws {
        let state = try riverShowdown(holes: "??KsQs??KhQh").applying(.showHoleCards(player: 1, cards: cards("Kh")))
        #expect(state.holeCards[1] == [up("Kh"), down("??")])
        #expect(throws: EngineError.duplicateCard(card("Ks"), location: .hole(player: 1))) {
            try state.apply(.showHoleCards(player: 0, cards: cards("Ks")))
        }
    }

    @Test("once the forgetter is killed, the forgotten card is in the muck (B1)")
    func forgottenCardOfKilledPlayer() throws {
        // Player 0's ace beats player 1's king, the only cards still in play.
        let state = try riverShowdown(holes: "??KsQs??KhQh").applying(
            .showHoleCards(player: 1, cards: cards("Kh")), .showHoleCards(player: 0, cards: cards("Ac")),
            .muckHoleCards(player: 2)
        )
        #expect(state.statuses == [.active, .killed, .mucked])
        #expect(throws: EngineError.duplicateCard(card("Ks"), location: .mucked)) {
            try state.apply(.showHoleCards(player: 0, cards: cards("AcKs")))
        }
    }

    @Test("a card revealed by the show that kills its holder is in the muck for the winner's reveal (B1)")
    func revealedCardOfKilledPlayer() throws {
        let state = try HandState(config: .test(stacks: [200, 200])).dealingHoles("????2dAs")
            .checkingDown().dealingStreet("7c9dJh").checkingDown().dealingStreet("Qs").checkingDown()
            .dealingStreet("4h").checkingDown()
            .applying(.showHoleCards(player: 1, cards: cards("As")), .showHoleCards(player: 0, cards: cards("3c2d")))
        #expect(state.statuses == [.killed, .active])
        #expect(throws: EngineError.duplicateCard(card("3c"), location: .mucked)) {
            try state.apply(.showHoleCards(player: 1, cards: cards("3cAs")))
        }
    }

    @Test("a card shown at an all-in and forgotten on the river cannot be revealed by another player (B1)")
    func shownThenForgottenCard() throws {
        let river = try runningOut(
            selected(holes: "As??Ah??"),
            shows: [.showHoleCards(player: 0, cards: cards("As")), .showHoleCards(player: 1, cards: [])]
        )
        let state = try river.applying(.showHoleCards(player: 0, cards: []))
        #expect(state.holeCards[0] == [down("??"), down("??")])
        #expect(throws: EngineError.duplicateCard(card("As"), location: .hole(player: 0))) {
            try state.apply(.showHoleCards(player: 1, cards: cards("As")))
        }
    }

    @Test("post-hand, a forgotten card comes back only as itself, not another card or another player's (B6)")
    func forgottenSlotRefills() throws {
        // Everyone keeps both cards face down, so every hand plays the board and the pot is chopped.
        let state = try riverShowdown().applying(
            .showHoleCards(player: 0, cards: []), .showHoleCards(player: 1, cards: []),
            .showHoleCards(player: 2, cards: [])
        )
        #expect(state.isHandComplete)
        #expect(state.holeCards[0] == [down("??"), down("??")])
        #expect(throws: EngineError.shownCardNotDealt(player: 0, card: card("2d"))) {
            try state.apply(.showHoleCards(player: 0, cards: cards("As2d")))
        }
        #expect(throws: EngineError.shownCardNotDealt(player: 0, card: card("Ks"))) {
            try state.apply(.showHoleCards(player: 0, cards: cards("KsAs")))
        }
        let shown = try state.applying(.showHoleCards(player: 0, cards: cards("AhAs")))
        #expect(shown.holeCards[0] == [up("Ah"), up("As")])
    }

    @Test("showing as is after a river forget is refused until the cards are listed")
    func showAsIsAfterRiverForget() throws {
        let state = try riverShowdown().applying(
            .showHoleCards(player: 0, cards: []), .showHoleCards(player: 1, cards: []),
            .showHoleCards(player: 2, cards: [])
        )
        #expect(throws: EngineError.cannotShowUnknownCard(player: 0)) { try state.apply(.showHoleCards(player: 0)) }
    }

    @Test("a slot dealt unknown can still be revealed post-hand after the river left it face down")
    func revealAfterRiverForget() throws {
        // Player 0 shows the ace it was dealt; every other hand is out, so the hand ends there.
        let state = try riverShowdown(holes: "??KsQsAhKhQh").applying(
            .showHoleCards(player: 0, cards: cards("Ah")), .muckHoleCards(player: 1), .muckHoleCards(player: 2)
        )
        #expect(state.isHandComplete)
        #expect(state.holeCards[0] == [up("Ah"), down("??")])
        let shown = try state.applying(.showHoleCards(player: 0, cards: cards("AhAd")))
        #expect(shown.holeCards[0] == [up("Ah"), up("Ad")])
    }

    @Test("a forgotten slot is no reveal slot: only a slot dealt unknown takes a new card (B6)")
    func forgottenSlotIsNotARevealSlot() throws {
        // Player 0 was dealt one unknown card and the ace of hearts, then forgot both on the river.
        let state = try riverShowdown(holes: "??KsQsAhKhQh").applying(
            .showHoleCards(player: 0, cards: []), .showHoleCards(player: 1, cards: []),
            .showHoleCards(player: 2, cards: [])
        )
        #expect(state.holeCards[0] == [down("??"), down("??")])
        #expect(throws: EngineError.shownCardNotDealt(player: 0, card: card("Ac"))) {
            try state.apply(.showHoleCards(player: 0, cards: cards("AdAc")))
        }
        let shown = try state.applying(.showHoleCards(player: 0, cards: cards("AdAh")))
        #expect(shown.holeCards[0] == [up("Ad"), up("Ah")])
    }

    // MARK: Post-hand shows

    @Test("post-hand shows start when chips pushing begins, not before (B9)")
    func postHandShowsStartAtPushing() throws {
        let killing = try riverShowdown(automations: .bookkeeping.subtracting([.handKilling, .chipsPushing]))
            .applying(.showHoleCards(player: 0), .showHoleCards(player: 1), .muckHoleCards(player: 2))
        #expect(killing.pendingOperation == .killHand(players: [1]))
        #expect(throws: EngineError.noShowdownExpected(player: 0)) { try killing.apply(.showHoleCards(player: 0)) }
        let pushing = try killing.applying(.killHand(player: 1))
        #expect(pushing.pendingOperation == .pushChips(pot: 0, runout: nil))
        #expect(pushing.canApply(.showHoleCards(player: 0)))
        #expect(throws: EngineError.mustShowAllCards(player: 0)) { try pushing.apply(.muckHoleCards(player: 0)) }
    }

    @Test("a post-hand show must show every card and a post-hand muck is refused, in both modes (B9)")
    func postHandShowsAreFull() throws {
        for mode in [HandConfig.Mode.cashGame, .tournament] {
            let state = try HandState(config: .test(mode, stacks: [200, 200, 200])).dealingHoles("AsKsQsAhKhQh")
                .applying(.fold(player: 2), .fold(player: 0))
            #expect(state.isHandComplete)
            #expect(throws: EngineError.mustShowAllCards(player: 1)) {
                try state.apply(.showHoleCards(player: 1, cards: cards("Ks")))
            }
            #expect(throws: EngineError.mustShowAllCards(player: 1)) {
                try state.apply(.showHoleCards(player: 1, cards: []))
            }
            #expect(throws: EngineError.mustShowAllCards(player: 1)) { try state.apply(.muckHoleCards(player: 1)) }
            #expect(throws: EngineError.tooManyCardsShown(player: 1, count: 3)) {
                try state.apply(.showHoleCards(player: 1, cards: cards("KsKh2c")))
            }
            #expect(state.canApply(.showHoleCards(player: 1)))
            #expect(state.canApply(.showHoleCards(player: 1, cards: cards("KhKs"))))
        }
    }

    @Test("a show after completion updates the results and moves no chips (B9)")
    func showAfterCompletion() throws {
        let state = try HandState(config: .test(stacks: [200, 200, 200])).dealingHoles("AsKsQsAhKhQh")
            .applying(.fold(player: 2), .fold(player: 0))
        #expect(state.results?[1] == PlayerResult(
            player: 1, net: 1, won: 1, status: .active, holeCards: [down("Ks"), down("Kh")], shown: false
        ))
        let shown = try state.applying(.showHoleCards(player: 1))
        #expect(shown.results?[1] == PlayerResult(
            player: 1, net: 1, won: 1, status: .active, holeCards: [up("Ks"), up("Kh")], shown: true
        ))
        #expect(shown.stacks == [199, 201, 200])
        #expect(shown.pendingOperation == nil)
        #expect(shown.isHandComplete)
        // Nothing stops a second show: the cards are simply face up already.
        #expect(try shown.applying(.showHoleCards(player: 1)).holeCards[1] == [up("Ks"), up("Kh")])
    }

    @Test("a post-hand show before a manual push changes who that push pays (B9)")
    func postHandShowChangesPush() throws {
        let pushing = try riverShowdown(automations: .bookkeeping.subtracting([.chipsPushing])).applying(
            .showHoleCards(player: 0, cards: []), .showHoleCards(player: 1, cards: []),
            .showHoleCards(player: 2, cards: [])
        )
        #expect(pushing.pendingOperation == .pushChips(pot: 0, runout: 0))
        let chopped = try pushing.applying(.pushChips)
        #expect(chopped.events.contains(.chipsPushed(pot: 0, runout: 0, amounts: [2, 2, 2])))
        let shown = try pushing.applying(.showHoleCards(player: 1, cards: cards("KsKh")))
        #expect(shown.pendingOperation == .pushChips(pot: 0, runout: 0))
        let paid = try shown.applying(.pushChips)
        #expect(paid.events.suffix(2) == [
            .chipsPushed(pot: 0, runout: 0, amounts: [0, 6, 0]),
            .chipsPulled(player: 1, amount: 6),
        ])
    }

    @Test("a post-hand show is the dealer's own log entry and sets nothing off")
    func postHandShowLog() throws {
        let state = try HandState(config: .test(stacks: [200, 200, 200])).dealingHoles("AsKsQsAhKhQh")
            .applying(.fold(player: 2), .fold(player: 0))
        #expect(state.operations.count == 8)
        #expect(state.log.count == 13)
        let shown = try state.applying(.showHoleCards(player: 1))
        #expect(shown.operations.count == 9)
        #expect(shown.log.suffix(2) == [
            LogEntry(event: .chipsPulled(player: 1, amount: 3), isAutomated: true, operationIndex: 7),
            LogEntry(event: .holeCardsShown(player: 1, cards: cards("KsKh")), isAutomated: false, operationIndex: 8),
        ])
    }

    @Test("post-hand, a survivor still holding unknown cards must list them, in both modes (B9)")
    func postHandUnknownCards() throws {
        for mode in [HandConfig.Mode.cashGame, .tournament] {
            let config = HandConfig.test(
                mode, stacks: [200, 200, 200], automations: .bookkeeping.subtracting([.chipsPushing, .chipsPulling])
            )
            let pushing = try HandState(config: config).dealingHoles("As??QsAh??Qh")
                .applying(.fold(player: 2), .fold(player: 0))
            #expect(pushing.pendingOperation == .pushChips(pot: 0, runout: nil))
            #expect(throws: EngineError.cannotShowUnknownCard(player: 1)) {
                try pushing.apply(.showHoleCards(player: 1))
            }
            let pulling = try pushing.applying(.pushChips)
            #expect(pulling.pendingOperation == .pullChips(players: [1]))
            #expect(throws: EngineError.cannotShowUnknownCard(player: 1)) {
                try pulling.apply(.showHoleCards(player: 1))
            }
            let done = try pulling.applying(.pullChips(player: 1))
            #expect(done.isHandComplete)
            #expect(throws: EngineError.cannotShowUnknownCard(player: 1)) { try done.apply(.showHoleCards(player: 1)) }
            let shown = try done.applying(.showHoleCards(player: 1, cards: cards("KsKh")))
            #expect(shown.holeCards[1] == [up("Ks"), up("Kh")])
            #expect(shown.results?[1].holeCards == [up("Ks"), up("Kh")])
            #expect(shown.results?[1].shown == true)
        }
    }

    @Test("after a tournament river shove and a fold, an unknown hand must still be listed in full")
    func riverShoveThenFold() throws {
        let state = try checkedToRiver(.tournament, holes: "??KsQs??KhQh")
            .applying(.betOrRaise(player: 0, to: 198), .fold(player: 1), .fold(player: 2))
        #expect(state.isHandComplete)
        #expect(throws: EngineError.cannotShowUnknownCard(player: 0)) { try state.apply(.showHoleCards(player: 0)) }
        #expect(throws: EngineError.mustShowAllCards(player: 0)) {
            try state.apply(.showHoleCards(player: 0, cards: cards("Ad")))
        }
        #expect(state.canApply(.showHoleCards(player: 0, cards: cards("AdAc"))))
    }

    @Test("a post-hand show is checked for its player before anything else, like any operation")
    func postHandInvalidPlayer() throws {
        let state = try HandState(config: .test(stacks: [200, 200, 200])).dealingHoles("AsKsQsAhKhQh")
            .applying(.fold(player: 2), .fold(player: 0))
        #expect(throws: EngineError.invalidPlayer(3)) { try state.apply(.showHoleCards(player: 3)) }
        #expect(throws: EngineError.invalidPlayer(-1)) { try state.apply(.muckHoleCards(player: -1)) }
    }
}
