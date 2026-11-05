import Foundation
import PokerEngine
import PokerEngineObservation
import Testing

// The code in README.md. Every `swift` block there is a region of this file, in the same order, and `blocksAreRegions`
// fails if the two differ. This file imports only the public API, so the README's code compiles for a client, and it
// runs here: its `#expect` lines are the README's statements of what the state holds.

@MainActor
@Suite("README")
struct ReadmeTests {
    private static let source = URL(fileURLWithPath: #filePath)
    private static let readme = URL(fileURLWithPath: "../../../README.md", relativeTo: source)

    /// The body of each `swift` fence, without the fence lines.
    private static func blocks(in markdown: String) -> [String] {
        var blocks = [String]()
        var block: [Substring]?
        for line in markdown.split(separator: "\n", omittingEmptySubsequences: false) {
            if block == nil, line == "```swift" {
                block = []
            } else if line == "```", let finished = block {
                blocks.append(finished.joined(separator: "\n"))
                block = nil
            } else {
                block?.append(line)
            }
        }
        return blocks
    }

    /// The lines between each `README: begin` and `README: end` marker, without the marker's indentation. A line with
    /// anything else in those columns stays whole, so a line commented out at the margin cannot pass for the README's.
    private static func regions(in source: String) -> [String] {
        var regions = [String]()
        var region: [Substring]?
        var indent = 0
        for line in source.split(separator: "\n", omittingEmptySubsequences: false) {
            let trimmed = line.drop { $0 == " " }
            if trimmed == "// README: begin" {
                region = []
                indent = line.count - trimmed.count
            } else if trimmed == "// README: end", let finished = region {
                regions.append(finished.joined(separator: "\n"))
                region = nil
            } else {
                region?.append(line.prefix(indent).allSatisfy { $0 == " " } ? line.dropFirst(indent) : line)
            }
        }
        return regions
    }

    private static let threeHanded: HandConfig = {
        do {
            return try HandConfig(
                mode: .cashGame, startingStacks: [200, 200, 200], blindsOrStraddles: [1, 2], minBet: 2
            )
        } catch {
            preconditionFailure("Invalid config: \(error)")
        }
    }()

    private static func threeHanded(without removed: Set<HandConfig.Automation>) throws -> HandConfig {
        try HandConfig(
            mode: .cashGame, startingStacks: [200, 200, 200], blindsOrStraddles: [1, 2], minBet: 2,
            automations: Set.bookkeeping.subtracting(removed)
        )
    }

    private static func tournament() throws -> HandConfig {
        try HandConfig(mode: .tournament, startingStacks: [200, 200, 200], blindsOrStraddles: [1, 2], minBet: 2)
    }

    private static func headsUp() throws -> HandConfig {
        try HandConfig(mode: .cashGame, startingStacks: [100, 100], blindsOrStraddles: [1, 2], minBet: 2)
    }

    /// The README's full hand, up to the showdown.
    private static let toTheShowdown: [HandOperation] = [
        .dealHole(player: 0, card: .known(.seven, .hearts)), .dealHole(player: 1, card: .known(.queen, .diamonds)),
        .dealHole(player: 2, card: .known(.ace, .spades)), .dealHole(player: 0, card: .known(.two, .clubs)),
        .dealHole(player: 1, card: .known(.jack, .diamonds)), .dealHole(player: 2, card: .known(.king, .clubs)),
        .betOrRaise(player: 2, to: 6), .fold(player: 0), .checkOrCall(player: 1),
        .burnCard(.unknown), .dealBoard(.known(.jack, .clubs)), .dealBoard(.known(.eight, .diamonds)),
        .dealBoard(.known(.three, .spades)),
        .checkOrCall(player: 1), .betOrRaise(player: 2, to: 10), .checkOrCall(player: 1),
        .burnCard(.unknown), .dealBoard(.known(.two, .diamonds)), .checkOrCall(player: 1), .checkOrCall(player: 2),
        .burnCard(.unknown), .dealBoard(.known(.nine, .hearts)),
        .betOrRaise(player: 1, to: 20), .checkOrCall(player: 2),
    ]

    private static func atTheShowdown() throws -> HandState {
        try HandState.replay(config: threeHanded, operations: toTheShowdown)
    }

    /// A hand with every hole card dealt unscanned, ready for the first action.
    private static func dealt(_ config: HandConfig) throws -> HandState {
        var hand = HandState(config: config)
        for player in Array(0..<config.playerCount) + Array(0..<config.playerCount) {
            hand = try hand.apply(.dealHole(player: player, card: .unknown))
        }
        return hand
    }

    /// Four players on the flop after everyone limped, with blinds of 50 and 100 and `minBet` 100.
    private static func limpedFlop(stacks: [Int], then operations: [HandOperation]) throws -> HandState {
        var hand = try dealt(HandConfig(
            mode: .cashGame, startingStacks: stacks, blindsOrStraddles: [50, 100], minBet: 100
        ))
        for operation: HandOperation in [
            .checkOrCall(player: 2), .checkOrCall(player: 3), .checkOrCall(player: 0), .checkOrCall(player: 1),
            .burnCard(.unknown), .dealBoard(.unknown), .dealBoard(.unknown), .dealBoard(.unknown),
        ] + operations {
            hand = try hand.apply(operation)
        }
        return hand
    }

    /// Three players all in on 9h5c2d, with every run count entered: KsKd, 7c7d and AsAd in player order.
    private static func allInOnTheFlop() throws -> HandState {
        var hand = HandState(config: try HandConfig(
            mode: .cashGame, startingStacks: [100, 100, 100], blindsOrStraddles: [1, 2], minBet: 2
        ))
        for (index, card) in try Card.parse("Ks7cAsKd7dAd").enumerated() {
            hand = try hand.apply(.dealHole(player: index % 3, card: card))
        }
        for operation: HandOperation in [
            .checkOrCall(player: 2), .checkOrCall(player: 0), .checkOrCall(player: 1),
            .burnCard(.unknown), .dealBoard(.known(.nine, .hearts)), .dealBoard(.known(.five, .clubs)),
            .dealBoard(.known(.two, .diamonds)),
            .betOrRaise(player: 0, to: 98), .checkOrCall(player: 1), .checkOrCall(player: 2),
            .selectRunoutCount(player: 0, count: nil), .selectRunoutCount(player: 1, count: nil),
            .selectRunoutCount(player: 2, count: nil),
        ] {
            hand = try hand.apply(operation)
        }
        return hand
    }

    /// Heads-up, checked to the river's betting, on Qh9h5h3h3c. Player 0's KsKd beats player 1's 7c7d only if shown.
    private static func headsUpRiver() throws -> HandState {
        var river = HandState(config: try headsUp())
        for (index, card) in try Card.parse("Ks7cKd7d").enumerated() {
            river = try river.apply(.dealHole(player: index % 2, card: card))
        }
        for operation: HandOperation in [
            .checkOrCall(player: 1), .checkOrCall(player: 0),
            .burnCard(.unknown), .dealBoard(.known(.queen, .hearts)), .dealBoard(.known(.nine, .hearts)),
            .dealBoard(.known(.five, .hearts)), .checkOrCall(player: 0), .checkOrCall(player: 1),
            .burnCard(.unknown), .dealBoard(.known(.three, .hearts)), .checkOrCall(player: 0), .checkOrCall(player: 1),
            .burnCard(.unknown), .dealBoard(.known(.three, .clubs)),
        ] {
            river = try river.apply(operation)
        }
        return river
    }

    @Test("every swift block in the README is a region of this file, in the same order")
    func blocksAreRegions() throws {
        let markdown = try String(contentsOf: Self.readme, encoding: .utf8)
        let blocks = Self.blocks(in: markdown)
        let regions = Self.regions(in: try String(contentsOf: Self.source, encoding: .utf8))
        #expect(!blocks.isEmpty)
        #expect(blocks.count == regions.count)
        for (block, region) in zip(blocks, regions) {
            #expect(block == region)
        }
        // `blocks(in:)` reads one form of fence, so a Swift block in any other form would go unchecked.
        #expect(markdown.matches(of: /(?i)(?:`{3,}|~{3,})[ \t]*swift\b/).count == blocks.count)
    }

    @Test("a hand, operation by operation")
    func fullHand() throws {
        // README: begin
        // Blinds of 1 and 2, three players with 200 each.
        // Player 0 is the small blind, player 1 the big blind and player 2 the button.
        let config = try HandConfig(
            mode: .cashGame, startingStacks: [200, 200, 200], blindsOrStraddles: [1, 2], minBet: 2
        )

        // `automations` defaults to `.bookkeeping`, so a new hand has already posted its blinds.
        var hand = HandState(config: config)
        #expect(hand.bets == [1, 2, 0])
        #expect(hand.stacks == [199, 198, 200])
        #expect(hand.pendingOperation == .dealHoleCard(player: 0, cardIndex: 0))

        // Hole cards, one operation per card, starting from player 0.
        hand = try hand.apply(.dealHole(player: 0, card: .known(.seven, .hearts)))
        #expect(hand.pendingOperation == .dealHoleCard(player: 1, cardIndex: 0))
        hand = try hand.apply(.dealHole(player: 1, card: .known(.queen, .diamonds)))
        hand = try hand.apply(.dealHole(player: 2, card: .known(.ace, .spades)))
        hand = try hand.apply(.dealHole(player: 0, card: .known(.two, .clubs)))
        hand = try hand.apply(.dealHole(player: 1, card: .known(.jack, .diamonds)))
        hand = try hand.apply(.dealHole(player: 2, card: .known(.king, .clubs)))

        // Preflop. The button acts first, facing the big blind.
        #expect(hand.street == .preflop)
        #expect(hand.pendingOperation == .act(player: 2))
        #expect(hand.legalActions?.canFold == true)
        #expect(hand.legalActions?.toCall == 2)
        #expect(hand.legalActions?.betOrRaise == .raise(4...200))
        hand = try hand.apply(.betOrRaise(player: 2, to: 6))   // `to` is a total for the street
        #expect(hand.pendingOperation == .act(player: 0))
        #expect(hand.legalActions?.toCall == 5)
        hand = try hand.apply(.fold(player: 0))
        #expect(hand.legalActions?.toCall == 4)
        hand = try hand.apply(.checkOrCall(player: 1))         // a call of 4

        // Betting is over, so the bets have moved to the pot by themselves.
        #expect(hand.bets == [0, 0, 0])
        #expect(hand.totalPot == 13)
        #expect(hand.statuses == [.folded, .active, .active])

        // The flop. A burn comes first, and its card is rarely seen.
        #expect(hand.pendingOperation == .burnCard(street: .flop, runout: 0))
        hand = try hand.apply(.burnCard(.unknown))
        #expect(hand.pendingOperation
            == .dealBoardCard(street: .flop, runout: 0, cardIndex: 0, cardCount: 3))
        hand = try hand.apply(.dealBoard(.known(.jack, .clubs)))
        hand = try hand.apply(.dealBoard(.known(.eight, .diamonds)))
        hand = try hand.apply(.dealBoard(.known(.three, .spades)))

        // Player 0 has folded, so player 1 is first to act. Nobody has bet, so `toCall` of 0 is a check.
        #expect(hand.pendingOperation == .act(player: 1))
        #expect(hand.legalActions?.toCall == 0)
        #expect(hand.legalActions?.betOrRaise == .bet(2...194))
        hand = try hand.apply(.checkOrCall(player: 1))         // a check
        hand = try hand.apply(.betOrRaise(player: 2, to: 10))
        hand = try hand.apply(.checkOrCall(player: 1))         // a call

        // The turn.
        hand = try hand.apply(.burnCard(.unknown))
        hand = try hand.apply(.dealBoard(.known(.two, .diamonds)))
        hand = try hand.apply(.checkOrCall(player: 1))
        hand = try hand.apply(.checkOrCall(player: 2))

        // The river.
        hand = try hand.apply(.burnCard(.unknown))
        hand = try hand.apply(.dealBoard(.known(.nine, .hearts)))
        hand = try hand.apply(.betOrRaise(player: 1, to: 20))
        hand = try hand.apply(.checkOrCall(player: 2))

        // The showdown. The last bettor shows first, and pots go to hands shown face up.
        #expect(hand.pendingOperation == .showdown(runoutSelectors: [], showOrder: [1, 2]))
        #expect(hand.hand(of: 1)?.description == "One pair (QdJdJc8d9h)")
        hand = try hand.apply(.showHoleCards(player: 1))
        hand = try hand.apply(.muckHoleCards(player: 2))

        // Nothing is left to enter: the pot was pushed and pulled by itself.
        #expect(hand.isHandComplete)
        #expect(hand.pendingOperation == nil)
        #expect(hand.stacks == [199, 237, 164])
        #expect(hand.boards == [try Card.parse("Jc8d3s2d9h")])
        #expect(hand.results?.map(\.net) == [-1, 37, -36])
        #expect(hand.results?.map(\.won) == [0, 73, 0])
        #expect(hand.results?.map(\.status) == [.folded, .active, .mucked])
        #expect(hand.results?.map(\.shown) == [false, true, false])
        #expect(hand.operations.count == 26)
        // README: end
    }

    @Test("undo takes back one operation")
    func undo() throws {
        let config = Self.threeHanded
        // README: begin
        let session = TableSession(config: config)
        try session.apply(.dealHole(player: 0, card: .known(.seven, .hearts)))
        #expect(session.state.operations.count == 1)
        #expect(session.canUndo)

        session.undo()
        #expect(session.state == HandState(config: config))
        #expect(!session.canUndo)
        // README: end
    }

    @Test("undo gets past a burn the app entered by itself only by taking the burn back too")
    func undoPastABurn() throws {
        // The call that ended the preflop betting, then the burn.
        let session = TableSession(state: try HandState.replay(
            config: Self.threeHanded, operations: Array(Self.toTheShowdown.prefix(10))
        ))
        session.undo()
        #expect(session.state.pendingOperation == .burnCard(street: .flop, runout: 0))
        session.undo()
        #expect(session.state.pendingOperation == .act(player: 1))
    }

    @Test("the status line covers every state of a hand")
    func statusLine() throws {
        // README: begin
        func prompt(for hand: HandState, naming name: (Int) -> String) -> String {
            func list(_ players: [Int]) -> String { players.map(name).joined(separator: ", ") }

            return switch hand.pendingOperation {
            // Cards. Arm the camera for the two deals, and enter a burn at once (see Burns below).
            case .burnCard:
                "Burn a card"                                // .burnCard(.unknown)
            case let .dealHoleCard(player, _):
                "Deal to \(name(player))"                    // .dealHole(player: player, card: card)
            case let .dealBoardCard(street, runout, cardIndex, cardCount):
                "Run \(runout + 1): \(street) card \(cardIndex + 1) of \(cardCount)"  // .dealBoard(card)

            // Betting. Build the action bar from `legalActions`.
            case let .act(player):
                "\(name(player)) to act"                     // .fold, .checkOrCall or .betOrRaise

            // The showdown. Everyone listed needs an operation, in any order.
            case let .showdown(runoutSelectors, showOrder):  // .selectRunoutCount for `runoutSelectors`,
                if runoutSelectors.isEmpty {                 // .showHoleCards or .muckHoleCards for `showOrder`
                    "\(name(showOrder[0])) to show or muck"
                } else {
                    "Runs to choose: \(list(runoutSelectors))"
                }

            // The hand is over. Read `results`.
            case nil:
                "Hand complete"

            // Reached only when the matching automation is off. `.bookkeeping` has them all on.
            case let .postAnte(owed):
                "Antes to post: \(list(owed.map(\.player)))"     // .postAnte(player:)
            case .collectBets:
                "Collect the bets"                               // .collectBets
            case let .postBlindOrStraddle(owed):
                "Blinds to post: \(list(owed.map(\.player)))"    // .postBlindOrStraddle(player:)
            case let .killHand(players):
                "Hands to kill: \(list(players))"                // .killHand(player:)
            case .pushChips:
                "Push the pot"                                   // .pushChips
            case let .pullChips(players):
                "Chips to pull: \(list(players))"                // .pullChips(player:)
            }
        }
        // README: end

        func name(_ player: Int) -> String { "Seat \(player + 1)" }
        let config = try HandConfig(
            mode: .cashGame, startingStacks: [100, 100], antes: [1, 1], anteTrimming: true, blindsOrStraddles: [1, 2],
            minBet: 2, automations: []
        )
        var prompts = [String]()
        var hand = HandState(config: config)
        for operation: HandOperation in [
            .postAnte(player: 0), .postAnte(player: 1), .collectBets,
            .postBlindOrStraddle(player: 0), .postBlindOrStraddle(player: 1),
            .dealHole(player: 0, card: .known(.ace, .spades)), .dealHole(player: 1, card: .known(.king, .spades)),
            .dealHole(player: 0, card: .known(.ace, .hearts)), .dealHole(player: 1, card: .known(.king, .hearts)),
            .betOrRaise(player: 1, to: 99), .checkOrCall(player: 0), .collectBets,
            .selectRunoutCount(player: 0, count: nil), .selectRunoutCount(player: 1, count: nil),
            .showHoleCards(player: 0), .showHoleCards(player: 1),
            .burnCard(.unknown), .dealBoard(.known(.two, .clubs)), .dealBoard(.known(.three, .clubs)),
            .dealBoard(.known(.seven, .diamonds)), .burnCard(.unknown), .dealBoard(.known(.eight, .diamonds)),
            .burnCard(.unknown), .dealBoard(.known(.nine, .hearts)), .killHand(player: 1), .pushChips,
            .pullChips(player: 0),
        ] {
            prompts.append(prompt(for: hand, naming: name))
            hand = try hand.apply(operation)
        }
        #expect(hand.isHandComplete)
        prompts.append(prompt(for: hand, naming: name))
        #expect(prompts == [
            "Antes to post: Seat 1, Seat 2", "Antes to post: Seat 2", "Collect the bets",
            "Blinds to post: Seat 1, Seat 2", "Blinds to post: Seat 2",
            "Deal to Seat 1", "Deal to Seat 2", "Deal to Seat 1", "Deal to Seat 2",
            "Seat 2 to act", "Seat 1 to act", "Collect the bets",
            "Runs to choose: Seat 1, Seat 2", "Runs to choose: Seat 2",
            "Seat 2 to show or muck", "Seat 2 to show or muck",
            "Burn a card", "Run 1: flop card 1 of 3", "Run 1: flop card 2 of 3", "Run 1: flop card 3 of 3",
            "Burn a card", "Run 1: turn card 1 of 1", "Burn a card", "Run 1: river card 1 of 1",
            "Hands to kill: Seat 2", "Push the pot", "Chips to pull: Seat 1", "Hand complete",
        ])
    }

    @Test("the action bar comes from legalActions")
    func actionBar() throws {
        // README: begin
        func buttons(for actions: LegalActions) -> [String] {
            var buttons = actions.canFold ? ["Fold"] : []
            buttons.append(actions.toCall == 0 ? "Check" : "Call \(actions.toCall)")
            switch actions.betOrRaise {
            case let .bet(amounts):
                buttons.append("Bet \(amounts)")             // for example "Bet 2...194"
            case let .raise(amounts):
                buttons.append("Raise to \(amounts)")        // for example "Raise to 4...200"
            case .unavailable:
                break
            }
            return buttons
        }
        // README: end

        var hand = try HandState.replay(config: Self.threeHanded, operations: Array(Self.toTheShowdown.prefix(6)))
        #expect(hand.legalActions.map(buttons) == ["Fold", "Call 2", "Raise to 4...200"])
        hand = try hand.apply(.betOrRaise(player: 2, to: 200))
        #expect(hand.legalActions.map(buttons) == ["Fold", "Call 199"])
        hand = try hand.apply(.checkOrCall(player: 0))
        hand = try hand.apply(.fold(player: 1))
        hand = try hand.apply(.selectRunoutCount(player: 0, count: nil))
        #expect(hand.legalActions == nil)

        // On the flop nobody has bet, and only a cash game offers a free fold.
        let flop = Array(Self.toTheShowdown.prefix(13))
        let cash = try HandState.replay(config: Self.threeHanded, operations: flop)
        #expect(cash.legalActions.map(buttons) == ["Fold", "Check", "Bet 2...194"])
        let tournament = try HandState.replay(config: Self.tournament(), operations: flop)
        #expect(tournament.legalActions.map(buttons) == ["Check", "Bet 2...194"])
    }

    @Test("canApply enables the showdown's optional moves")
    func showdownChoices() throws {
        var hand = try Self.atTheShowdown()
        // README: begin
        // Player 1 may show both cards, show one, keep both face down or muck.
        #expect(hand.canApply(.showHoleCards(player: 1)))
        #expect(hand.canApply(.showHoleCards(player: 1, cards: [.known(.queen, .diamonds)])))
        #expect(hand.canApply(.showHoleCards(player: 1, cards: [])))
        #expect(hand.canApply(.muckHoleCards(player: 1)))

        // If player 1 mucks, player 2 may not: nobody would be left to win the pot.
        hand = try hand.apply(.muckHoleCards(player: 1))
        #expect(!hand.canApply(.muckHoleCards(player: 2)))

        // So player 2 keeps the cards face down and takes the pot, and `results` does not count them as shown.
        #expect(hand.pendingOperation == .showdown(runoutSelectors: [], showOrder: [2]))
        hand = try hand.apply(.showHoleCards(player: 2, cards: []))
        #expect(hand.isHandComplete)
        #expect(hand.results?[2].shown == false)
        // README: end

        // The log still has a row for that show, with no card in it.
        #expect(hand.log.contains { $0.event == .holeCardsShown(player: 2, cards: [.unknown, .unknown]) })

        // The river forgot those cards, so a later show must list them, and `results` has the list.
        #expect(throws: EngineError.cannotShowUnknownCard(player: 2)) { try hand.apply(.showHoleCards(player: 2)) }
        #expect(!hand.canApply(.showHoleCards(player: 2)))
        let listed = try #require(hand.results?[2].holeCards.map(\.card))
        #expect(hand.canApply(.showHoleCards(player: 2, cards: listed)))
        hand = try hand.apply(.showHoleCards(player: 2, cards: listed))
        #expect(hand.results?[2].shown == true)
    }

    @Test("an unscanned hole card turns Show off until the cards are listed or the deal is corrected")
    func unscannedHoleCard() throws {
        var operations = Self.toTheShowdown
        operations[5] = .dealHole(player: 2, card: .unknown)
        operations.append(.muckHoleCards(player: 1))
        let listed: [Card] = [.known(.ace, .spades), .known(.king, .clubs)]

        // In a cash game the player left can still keep the cards face down.
        let cash = try HandState.replay(config: Self.threeHanded, operations: operations)
        #expect(!cash.canApply(.showHoleCards(player: 2)))
        #expect(!cash.canApply(.muckHoleCards(player: 2)))
        #expect(cash.canApply(.showHoleCards(player: 2, cards: [])))
        #expect(cash.canApply(.showHoleCards(player: 2, cards: listed)))

        // The player left at a tournament showdown with nobody all in may keep the cards face down too.
        let tournament = try HandState.replay(config: Self.tournament(), operations: operations)
        #expect(!tournament.canApply(.showHoleCards(player: 2)))
        #expect(!tournament.canApply(.muckHoleCards(player: 2)))
        #expect(tournament.canApply(.showHoleCards(player: 2, cards: [])))
        #expect(tournament.canApply(.showHoleCards(player: 2, cards: [.known(.ace, .spades)])))
        #expect(tournament.canApply(.showHoleCards(player: 2, cards: listed)))

        // After an all-in every hand is tabled, so the player left cannot keep, and only the full list is left.
        let allIn = try HandState.replay(config: Self.tournament(), operations: Array(operations[..<6]) + [
            .betOrRaise(player: 2, to: 200), .fold(player: 0), .checkOrCall(player: 1), .muckHoleCards(player: 1),
        ])
        #expect(!allIn.canApply(.showHoleCards(player: 2)))
        #expect(!allIn.canApply(.muckHoleCards(player: 2)))
        #expect(!allIn.canApply(.showHoleCards(player: 2, cards: [])))
        #expect(!allIn.canApply(.showHoleCards(player: 2, cards: [.known(.ace, .spades)])))
        #expect(allIn.canApply(.showHoleCards(player: 2, cards: listed)))

        let corrected = try allIn.replacingOperation(
            at: 5, with: .dealHole(player: 2, card: .known(.king, .clubs))
        )
        #expect(corrected.canApply(.showHoleCards(player: 2)))

        // A list holding `.unknown` is refused in either mode, so a rescan that misses the second ace cannot pass
        // for a partial show, which would give the pot to the jacks.
        let missed: [Card] = [.known(.ace, .spades), .unknown]
        let aces: [Card] = [.known(.ace, .spades), .known(.ace, .hearts)]
        let shown = try HandState.replay(
            config: Self.threeHanded, operations: operations.dropLast() + [.showHoleCards(player: 1)]
        )
        #expect(throws: EngineError.cannotShowUnknownCard(player: 2)) {
            try shown.apply(.showHoleCards(player: 2, cards: missed))
        }
        let partial = try shown.apply(.showHoleCards(player: 2, cards: [.known(.ace, .spades)]))
        #expect(partial.results?.map(\.won) == [0, 73, 0])
        #expect(try shown.apply(.showHoleCards(player: 2, cards: aces)).results?.map(\.won) == [0, 0, 73])
        #expect(!tournament.canApply(.showHoleCards(player: 2, cards: missed)))

        // After the hand the same list is refused, so a card `results` holds as `.unknown` needs a scan first.
        let kept = try cash.apply(.showHoleCards(player: 2, cards: []))
        #expect(kept.results?[2].holeCards.map(\.card) == missed)
        #expect(!kept.canApply(.showHoleCards(player: 2, cards: missed)))
        #expect(kept.canApply(.showHoleCards(player: 2, cards: listed)))
    }

    @Test("a tournament refuses a partial show and accepts a muck, except that the player left may keep the cards")
    func tournamentShows() throws {
        let hand = try HandState.replay(config: Self.tournament(), operations: Self.toTheShowdown)
        for cards: [Card] in [[.known(.queen, .diamonds)], []] {
            #expect(throws: EngineError.mustShowAllCards(player: 1)) {
                try hand.apply(.showHoleCards(player: 1, cards: cards))
            }
        }
        let mucked = try hand.apply(.muckHoleCards(player: 1))
        #expect(!mucked.canApply(.muckHoleCards(player: 2)))
        #expect(mucked.canApply(.showHoleCards(player: 2)))

        // Nobody is all in, so the player left wins without tabling, and no card counts as shown.
        let kept = try mucked.apply(.showHoleCards(player: 2, cards: []))
        #expect(kept.isHandComplete)
        #expect(kept.results?[2].shown == false)
        #expect(kept.results?[2].holeCards.contains(where: \.isFaceUp) == false)
    }

    @Test("the blinds may chop once everyone else folds, and a void gives every chip back, even after the hand")
    func chopAndVoid() throws {
        var hand = try Self.dealt(Self.threeHanded)
        let paid = try Self.atTheShowdown().apply(.showHoleCards(player: 1)).apply(.showHoleCards(player: 2))
        #expect(paid.results?.map(\.won) == [0, 73, 0])
        // README: begin
        // Player 2 folds, and the blinds agree to chop.
        hand = try hand.apply(.fold(player: 2))
        #expect(hand.canApply(.chopBlinds))
        hand = try hand.apply(.chopBlinds)
        #expect(hand.isHandComplete)
        #expect(hand.results?.map(\.net) == [0, 0, 0])

        // Another hand was paid out before two of one card turned up. A void gives every chip back.
        let voided = try paid.apply(.voidHand)
        #expect(voided.stacks == voided.config.startingStacks)
        #expect(voided.results?.map(\.won) == [0, 0, 0])
        #expect(voided.operations.last == .voidHand)
        // README: end

        // The log's last row says what each player got back, and nothing is accepted after either, not even a show.
        #expect(hand.log.last?.event == .blindsChopped(returned: [1, 2, 0]))
        #expect(voided.log.last?.event == .handVoided(returned: [1, -37, 36]))
        #expect(!hand.canApply(.showHoleCards(player: 0)))
        #expect(!voided.canApply(.showHoleCards(player: 1)))
        #expect(!voided.canApply(.voidHand))

        // The chop is refused once either blind has put in more, and with another player's ante in the pot. A
        // big-blind ante goes back to the big blind.
        let folded = try Self.dealt(Self.threeHanded).apply(.fold(player: 2))
        #expect(!(try folded.apply(.checkOrCall(player: 0))).canApply(.chopBlinds))
        let antes = try HandConfig(
            mode: .cashGame, startingStacks: [200, 200, 200], antes: [1, 1, 1], anteTrimming: true,
            blindsOrStraddles: [1, 2], minBet: 2
        )
        #expect(!(try Self.dealt(antes).apply(.fold(player: 2)).canApply(.chopBlinds)))
        let bigBlindAnte = try HandConfig(
            mode: .cashGame, startingStacks: [200, 200, 200], antes: [0, 2], blindsOrStraddles: [1, 2], minBet: 2
        )
        let chopped = try Self.dealt(bigBlindAnte).apply(.fold(player: 2)).apply(.chopBlinds)
        #expect(chopped.log.last?.event == .blindsChopped(returned: [1, 4, 0]))

        // A tournament never chops.
        #expect(!(try Self.dealt(Self.tournament()).apply(.fold(player: 2)).canApply(.chopBlinds)))
    }

    @Test("when everyone folds to a lone blind no chips move, and the winner is the only active player")
    func walk() throws {
        var hand = HandState(config: try HandConfig(
            mode: .cashGame, startingStacks: [100, 100, 100], blindsOrStraddles: [2], minBet: 2
        ))
        for player in [0, 1, 2, 0, 1, 2] {
            hand = try hand.apply(.dealHole(player: player, card: .unknown))
        }
        hand = try hand.apply(.fold(player: 1))
        hand = try hand.apply(.fold(player: 2))
        #expect(hand.isHandComplete)
        #expect(hand.results?.map(\.won) == [0, 0, 0])
        #expect(hand.results?.map(\.net) == [0, 0, 0])
        #expect(hand.results?.map(\.status) == [.active, .folded, .folded])
    }

    @Test("hand(of:) counts cards nobody saw unless it is told not to")
    func faceUpOnly() throws {
        // Player 2 wins on the flop with nothing shown, so only the default can name a hand.
        let flop = try HandState.replay(
            config: Self.threeHanded, operations: Self.toTheShowdown.prefix(15) + [.fold(player: 1)]
        )
        #expect(flop.isHandComplete)
        #expect(flop.hand(of: 2)?.description == "High card (AsKcJc8d3s)")
        #expect(flop.hand(of: 2, faceUpOnly: true) == nil)

        // Player 1 wins on the river with nothing shown. Face up, that is the board's own rank.
        let river = try HandState.replay(
            config: Self.threeHanded, operations: Self.toTheShowdown.prefix(23) + [.fold(player: 2)]
        )
        #expect(river.isHandComplete)
        #expect(river.hand(of: 1)?.description == "One pair (QdJdJc8d9h)")
        #expect(river.hand(of: 1, faceUpOnly: true)?.description == "High card (Jc8d3s2d9h)")

        // Cards kept face down on the last river are forgotten, so only the board is left to rank.
        let showdown = try Self.atTheShowdown()
        #expect(showdown.hand(of: 1)?.description == "One pair (QdJdJc8d9h)")
        let kept = try showdown.apply(.muckHoleCards(player: 2)).apply(.showHoleCards(player: 1, cards: []))
        #expect(kept.isHandComplete)
        #expect(kept.hand(of: 1)?.description == "High card (Jc8d3s2d9h)")
        // The cards `results` keeps are not forgotten.
        #expect(kept.dealtHand(of: 1)?.description == "One pair (QdJdJc8d9h)")
        #expect(kept.dealtHand(of: 1, faceUpOnly: true)?.description == "High card (Jc8d3s2d9h)")
    }

    @Test("a beaten hand leaves the state at settlement, and dealtHand still names it")
    func beatenHand() throws {
        var hand = try Self.atTheShowdown().apply(.showHoleCards(player: 1))
        hand = try hand.apply(.showHoleCards(player: 2))
        // README: begin
        // Both players showed, and player 2 lost. The state has let go of the cards, but `dealtHand(of:)` ranks them.
        #expect(hand.statuses == [.folded, .active, .killed])
        #expect(hand.holeCards[2].isEmpty)
        #expect(hand.hand(of: 2) == nil)
        #expect(hand.dealtHand(of: 2)?.description == "High card (AsKcJc8d9h)")

        // Player 0 folded before the flop and is ranked with the whole board. Nothing was shown, so face up only,
        // that is the board's own rank.
        #expect(hand.dealtHand(of: 0)?.description == "One pair (2cJc8d2d9h)")
        #expect(hand.dealtHand(of: 0, faceUpOnly: true)?.description == "High card (Jc8d3s2d9h)")
        // README: end
        #expect(hand.results?[2].holeCards.map(\.card) == (try Card.parse("AsKc")))
        #expect(hand.results?[0].holeCards.contains(where: \.isFaceUp) == false)
    }

    @Test("dealtHand names a beaten hand whichever settlement steps were entered by hand")
    func beatenHandEnteredByHand() throws {
        let shows: [HandOperation] = Self.toTheShowdown + [.showHoleCards(player: 1), .showHoleCards(player: 2)]
        let steps: [(removed: HandConfig.Automation, entered: HandOperation)] = [
            (.handKilling, .killHand(player: 2)),
            (.chipsPushing, .pushChips),
            (.chipsPulling, .pullChips(player: 1)),
        ]
        for step in steps {
            let hand = try HandState.replay(
                config: Self.threeHanded(without: [step.removed]), operations: shows + [step.entered]
            )
            #expect(hand.isHandComplete)
            #expect(hand.statuses == [.folded, .active, .killed])
            #expect(hand.dealtHand(of: 2)?.description == "High card (AsKcJc8d9h)")
        }
    }

    @Test("a stored hand names a beaten hand the same, even after a show after the hand")
    func beatenHandAfterALaterShow() throws {
        let hand = try Self.atTheShowdown()
            .apply(.showHoleCards(player: 1, cards: [.known(.jack, .diamonds)]))
            .apply(.showHoleCards(player: 2))
            .apply(.showHoleCards(player: 1, cards: [.known(.queen, .diamonds), .known(.jack, .diamonds)]))
        #expect(hand.statuses == [.folded, .active, .killed])
        let stored = try HandState(json: try hand.json())
        for player in 0..<3 {
            #expect(stored.dealtHand(of: player) == hand.dealtHand(of: player))
            #expect(stored.dealtHand(of: player, faceUpOnly: true) == hand.dealtHand(of: player, faceUpOnly: true))
        }
        #expect(stored.dealtHand(of: 2)?.description == "High card (AsKcJc8d9h)")
        #expect(stored.dealtHand(of: 1, faceUpOnly: true)?.description == "One pair (QdJdJc8d9h)")
    }

    @Test("with pushes entered by hand, a show before the push can change who is paid")
    func showBeforeAPush() throws {
        let hand = try HandState.replay(
            config: Self.threeHanded(without: [.chipsPushing]),
            operations: Self.toTheShowdown + [
                .showHoleCards(player: 1, cards: []), .showHoleCards(player: 2, cards: []),
            ]
        )
        #expect(hand.pendingOperation == .pushChips(pot: 0, runout: 0))
        #expect(!hand.isHandComplete)
        #expect(hand.results == nil)

        // Nobody showed, so the pot is chopped, unless a show at this point takes it.
        #expect(try hand.apply(.pushChips).results?.map(\.won) == [0, 37, 36])
        let listed: [Card] = [.known(.queen, .diamonds), .known(.jack, .diamonds)]
        #expect(hand.canApply(.showHoleCards(player: 1, cards: listed)))
        #expect(!hand.canApply(.showHoleCards(player: 1, cards: [.known(.queen, .diamonds), .unknown])))
        let shown = try hand.apply(.showHoleCards(player: 1, cards: listed))
        #expect(try shown.apply(.pushChips).results?.map(\.won) == [0, 73, 0])
    }

    @Test("a winner the others folded to may show after the hand")
    func postHandShow() throws {
        var hand = try HandState.replay(
            config: Self.threeHanded, operations: Self.toTheShowdown.prefix(7) + [.fold(player: 0), .fold(player: 1)]
        )
        // README: begin
        // The hand is over, and player 2 won it when the others folded. Offer "Show anyway".
        #expect(hand.isHandComplete)
        #expect(hand.canApply(.showHoleCards(player: 2)))
        #expect(hand.results?[2].shown == false)
        #expect(!hand.canApply(.showHoleCards(player: 1)))     // player 1 folded
        // README: end
        #expect(throws: EngineError.mustShowAllCards(player: 2)) {
            try hand.apply(.showHoleCards(player: 2, cards: [.known(.ace, .spades)]))
        }
        hand = try hand.apply(.showHoleCards(player: 2))
        #expect(hand.results?[2].shown == true)
        #expect(hand.stacks == [199, 198, 203])

        // The show stays allowed for a player who already showed, which is why the README checks `shown` too.
        #expect(hand.canApply(.showHoleCards(player: 2)))
    }

    @Test("an error's message goes to the dealer, in a method and in a closure")
    func errors() throws {
        let seats = [5, 7, 2]
        let session = TableSession(config: Self.threeHanded)
        // README: begin
        func name(_ player: Int) -> String { "Seat \(seats[player])" }

        func enter(_ operation: HandOperation) -> String? {
            do {
                try session.apply(operation)
                return nil
            } catch {
                return error.message(naming: name)     // `error` is an `EngineError` here
            }
        }
        // README: end

        #expect(enter(.fold(player: 0)) == "Nobody is due to act.")
        #expect(enter(.dealHole(player: 0, card: .known(.ace, .spades))) == nil)
        #expect(enter(.dealHole(player: 1, card: .known(.ace, .spades))) == "As is already in Seat 5's hand.")

        var alert: String?
        // README: begin
        let buttonAction = {
            do throws(EngineError) {
                try session.apply(.fold(player: 0))
            } catch {
                alert = error.message(naming: name)
            }
        }
        // README: end
        buttonAction()
        #expect(alert == "Nobody is due to act.")
    }

    @Test("an all-in runs the board twice, and the remainder goes to the first run")
    func allIn() throws {
        // README: begin
        let config = try HandConfig(
            mode: .cashGame, startingStacks: [100, 100, 100], blindsOrStraddles: [1, 2], minBet: 2
        )
        var hand = try HandState.replay(config: config, operations: [
            .dealHole(player: 0, card: .known(.seven, .hearts)),
            .dealHole(player: 1, card: .known(.ace, .spades)),
            .dealHole(player: 2, card: .known(.king, .hearts)),
            .dealHole(player: 0, card: .known(.two, .clubs)),
            .dealHole(player: 1, card: .known(.ace, .hearts)),
            .dealHole(player: 2, card: .known(.king, .clubs)),
            .checkOrCall(player: 2),                 // the button calls 2
            .fold(player: 0),                        // the small blind leaves 1 chip in the pot
            .checkOrCall(player: 1),                 // the big blind checks
            .burnCard(.unknown),
            .dealBoard(.known(.king, .spades)),
            .dealBoard(.known(.seven, .diamonds)),
            .dealBoard(.known(.two, .hearts)),
            .betOrRaise(player: 1, to: 98),          // all in
            .checkOrCall(player: 2),                 // also all in, so nobody can bet again
        ])

        // Before any more cards, both players choose a run count and show or muck, in any order.
        #expect(hand.pendingOperation == .showdown(runoutSelectors: [1, 2], showOrder: [1, 2]))
        hand = try hand.apply(.selectRunoutCount(player: 1, count: 2))
        hand = try hand.apply(.selectRunoutCount(player: 2, count: 2))
        hand = try hand.apply(.showHoleCards(player: 1))
        hand = try hand.apply(.showHoleCards(player: 2))
        #expect(hand.runoutCount == 2)

        // The first run.
        #expect(hand.pendingOperation == .burnCard(street: .turn, runout: 0))
        hand = try hand.apply(.burnCard(.unknown))
        hand = try hand.apply(.dealBoard(.known(.five, .clubs)))
        hand = try hand.apply(.burnCard(.unknown))
        hand = try hand.apply(.dealBoard(.known(.nine, .diamonds)))

        // The second run deals the same streets again, with burns of its own.
        #expect(hand.pendingOperation == .burnCard(street: .turn, runout: 1))
        hand = try hand.apply(.burnCard(.unknown))
        hand = try hand.apply(.dealBoard(.known(.ace, .diamonds)))
        hand = try hand.apply(.burnCard(.unknown))
        hand = try hand.apply(.dealBoard(.known(.three, .hearts)))

        // Each run has a board, and the cards dealt before the all-in are on both.
        #expect(hand.isHandComplete)
        #expect(hand.boards == [try Card.parse("Ks7d2h5c9d"), try Card.parse("Ks7d2hAd3h")])

        // Three kings win the first run and three aces the second. The pot of 201 splits across
        // the runs, and the odd chip goes to the first.
        #expect(hand.results?.map(\.won) == [0, 100, 101])
        #expect(hand.stacks == [99, 100, 101])

        // PHH cannot write a second board.
        #expect(throws: PHHExportError.multipleRunouts(count: 2)) { try hand.phh() }
        // README: end
    }

    @Test("a player who mucks before choosing a count stays listed, and no card comes until that entry is made")
    func muckBeforeACount() throws {
        var hand = try HandState.replay(config: Self.headsUp(), operations: [
            .dealHole(player: 0, card: .known(.ace, .spades)), .dealHole(player: 1, card: .known(.king, .spades)),
            .dealHole(player: 0, card: .known(.ace, .hearts)), .dealHole(player: 1, card: .known(.king, .hearts)),
            .betOrRaise(player: 1, to: 100), .checkOrCall(player: 0),
            .muckHoleCards(player: 1), .selectRunoutCount(player: 0, count: 2), .showHoleCards(player: 0),
        ])
        #expect(hand.statuses == [.active, .mucked])
        #expect(hand.pendingOperation == .showdown(runoutSelectors: [1], showOrder: []))
        #expect(throws: EngineError.noDealExpected(.burn)) { try hand.apply(.burnCard(.unknown)) }

        hand = try hand.apply(.selectRunoutCount(player: 1, count: nil))
        #expect(hand.pendingOperation == .burnCard(street: .flop, runout: 0))
        #expect(hand.runoutCount == 2)
    }

    @Test("each answer at an all-in replaces the last, so Keep must list any card already up")
    func askedAgain() throws {
        /// A heads-up all-in where player 0 shows the 4d, which pairs the board, and then answers `keep` after each
        /// street. Player 1 has shown king high.
        func played(keep: (HandState) -> [Card]) throws -> HandState {
            var hand = try HandState.replay(
                config: Self.headsUp(),
                operations: [
                    .dealHole(player: 0, card: .known(.four, .diamonds)),
                    .dealHole(player: 1, card: .known(.seven, .hearts)),
                    .dealHole(player: 0, card: .known(.two, .clubs)),
                    .dealHole(player: 1, card: .known(.nine, .spades)),
                    .betOrRaise(player: 1, to: 100), .checkOrCall(player: 0),
                    .selectRunoutCount(player: 0, count: nil), .selectRunoutCount(player: 1, count: nil),
                    .showHoleCards(player: 1), .showHoleCards(player: 0, cards: [.known(.four, .diamonds)]),
                ]
            )
            var board = try Card.parse("Ks4sJh3hQc")[...]
            while let pending = hand.pendingOperation {
                switch pending {
                case .burnCard:
                    hand = try hand.apply(.burnCard(.unknown))
                case .dealBoardCard:
                    let card = board.popFirst()
                    hand = try hand.apply(.dealBoard(try #require(card)))
                default:
                    #expect(pending == .showdown(runoutSelectors: [], showOrder: [0]))
                    hand = try hand.apply(.showHoleCards(player: 0, cards: keep(hand)))
                }
            }
            return hand
        }

        let kept = try played { $0.holeCards[0].filter(\.isFaceUp).map(\.card) }
        #expect(kept.results?.map(\.won) == [200, 0])

        // `[]` takes the 4d back, so the hand loses to king high, and `results` still marks that card.
        let takenBack = try played { _ in [] }
        #expect(takenBack.results?.map(\.won) == [0, 200])
        #expect(takenBack.results?[0].holeCards.map(\.isFaceUp) == [true, false])
        #expect(takenBack.results?[0].shown == false)

        // So does a list of the other card alone. `.unknown` in place of the 4d is refused.
        #expect(try played { _ in [.known(.two, .clubs)] }.results?.map(\.won) == [0, 200])
        #expect(throws: EngineError.cannotShowUnknownCard(player: 0)) {
            try played { _ in [.unknown, .known(.two, .clubs)] }
        }

        // Keep lists the 4d on every ask, so correcting that card must change each of those shows.
        let listing: HandOperation = .showHoleCards(player: 0, cards: [.known(.four, .diamonds)])
        #expect(kept.operations.filter { $0 == listing }.count == 4)
        var corrected = kept.operations
        corrected[0] = .dealHole(player: 0, card: .known(.four, .clubs))
        let session = TableSession(state: kept)
        let refusal = #expect(throws: ReplayError.self) {
            try session.replaceOperations(with: corrected)
        }
        #expect(refusal?.error == .shownCardNotDealt(player: 0, card: .known(.four, .diamonds)))
        try session.replaceOperations(with: corrected.map {
            $0 == listing ? .showHoleCards(player: 0, cards: [.known(.four, .clubs)]) : $0
        })
        #expect(session.state.results?.map(\.won) == [200, 0])
        #expect(session.state.results?[0].holeCards.map(\.card) == (try Card.parse("4c2c")))
    }

    @Test("between runs, a kept hand's ask reads the street of the all-in")
    func streetBetweenRuns() throws {
        var hand = try HandState.replay(
            config: Self.headsUp(),
            operations: [
                .dealHole(player: 0, card: .known(.four, .diamonds)),
                .dealHole(player: 1, card: .known(.seven, .hearts)),
                .dealHole(player: 0, card: .known(.two, .clubs)),
                .dealHole(player: 1, card: .known(.nine, .spades)),
                .betOrRaise(player: 1, to: 100), .checkOrCall(player: 0),
                .selectRunoutCount(player: 0, count: 2), .selectRunoutCount(player: 1, count: 2),
                .showHoleCards(player: 1), .showHoleCards(player: 0, cards: []),
            ]
        )
        var board = try Card.parse("Ks4sJh3hQc")[...]
        while hand.boards[0].count < 5 {
            switch hand.pendingOperation {
            case .burnCard:
                hand = try hand.apply(.burnCard(.unknown))
            case .dealBoardCard:
                let card = board.popFirst()
                hand = try hand.apply(.dealBoard(try #require(card)))
            default:
                hand = try hand.apply(.showHoleCards(player: 0, cards: []))
            }
        }
        #expect(hand.pendingOperation == .showdown(runoutSelectors: [], showOrder: [0]))
        #expect(hand.street == .preflop)
        #expect(hand.boards.map(\.count) == [5, 0])

        // Only the last river forgets cards, so a Keep on this one leaves them known.
        hand = try hand.apply(.showHoleCards(player: 0, cards: []))
        #expect(hand.holeCards[0].map(\.card) == (try Card.parse("4d2c")))
    }

    @Test("a deal that would settle the hand is refused only with an unknown board card and two players left")
    func settlingDeal() throws {
        let allIn: [HandOperation] = [
            .dealHole(player: 0, card: .known(.ace, .spades)), .dealHole(player: 1, card: .known(.king, .spades)),
            .dealHole(player: 0, card: .known(.ace, .hearts)), .dealHole(player: 1, card: .known(.king, .hearts)),
            .betOrRaise(player: 1, to: 100), .checkOrCall(player: 0),
            .selectRunoutCount(player: 0, count: nil), .selectRunoutCount(player: 1, count: nil),
        ]
        let flop: [HandOperation] = [
            .burnCard(.unknown), .dealBoard(.known(.two, .clubs)), .dealBoard(.known(.three, .diamonds)),
        ]
        let config = try Self.headsUp()

        // Both hands are shown, so the river settles the hand.
        let river = try HandState.replay(
            config: config,
            operations: allIn + [.showHoleCards(player: 0), .showHoleCards(player: 1)] + flop + [
                .dealBoard(.known(.seven, .hearts)), .burnCard(.unknown), .dealBoard(.known(.eight, .spades)),
                .burnCard(.unknown),
            ]
        )
        let session = TableSession(state: river)
        #expect(throws: EngineError.unknownBoardCard(runout: 0, position: 4)) {
            try session.apply(.dealBoard(.unknown))
        }

        // The refused deal is not recorded, so the scanned card can follow it.
        #expect(session.state == river)
        try session.apply(.dealBoard(.known(.jack, .clubs)))
        #expect(session.state.isHandComplete)

        // With one player left no hands are compared, so an unknown card settles it too.
        let conceded = try HandState.replay(
            config: config,
            operations: allIn + [.showHoleCards(player: 0, cards: []), .muckHoleCards(player: 1)] + flop
        )
        #expect(try conceded.apply(.dealBoard(.unknown)).isHandComplete)
    }

    @Test("four runs always fit, and a smaller count frees a hand the deck cannot fill")
    func deckRunsOut() throws {
        /// Plays a preflop all-in until the hand ends or no card is left.
        func played(players: Int, count: Int, burnsFromTheDeck: Bool) throws -> HandState {
            var deck = Rank.allCases.flatMap { rank in Suit.allCases.map { Card.known(rank, $0) } }[...]
            var hand = HandState(config: try HandConfig(
                mode: .cashGame, startingStacks: Array(repeating: 100, count: players), blindsOrStraddles: [1, 2],
                minBet: 2
            ))
            while let pending = hand.pendingOperation {
                switch pending {
                case let .dealHoleCard(player, _):
                    hand = try hand.apply(.dealHole(player: player, card: deck.removeFirst()))
                case let .act(player):
                    let allIn = hand.bets.contains(100)
                    hand = try hand.apply(allIn ? .checkOrCall(player: player) : .betOrRaise(player: player, to: 100))
                case let .showdown(selectors, showOrder):
                    hand = try hand.apply(selectors.first.map { .selectRunoutCount(player: $0, count: count) }
                        ?? .showHoleCards(player: showOrder[0]))
                case .burnCard where !burnsFromTheDeck:
                    hand = try hand.apply(.burnCard(.unknown))
                case .burnCard:
                    guard let card = deck.popFirst() else { return hand }
                    hand = try hand.apply(.burnCard(card))
                default:
                    guard let card = deck.popFirst() else { return hand }
                    hand = try hand.apply(.dealBoard(card))
                }
            }
            return hand
        }

        #expect(try played(players: 10, count: 4, burnsFromTheDeck: true).isHandComplete)
        #expect(try !played(players: 10, count: 5, burnsFromTheDeck: true).isHandComplete)

        // Burns entered as `.unknown` take no card, so nine runs fit heads-up and the tenth has no cards left.
        let stuck = try played(players: 2, count: 10, burnsFromTheDeck: false)
        #expect(!stuck.isHandComplete)

        // Nothing warned of this: at the all-in, six operations in, `canApply` accepts any count up to the limit.
        let allIn = try HandState.replay(config: stuck.config, operations: Array(stuck.operations.prefix(6)))
        #expect(allIn.canApply(.selectRunoutCount(player: 0, count: HandState.maximumRunoutCount)))

        // Ten operations reach the first burn, and each of the nine runs that stay takes eight.
        let session = TableSession(state: stuck)
        try session.replaceOperations(with: stuck.operations.prefix(10 + 9 * 8).map { operation in
            if case let .selectRunoutCount(player, _) = operation {
                .selectRunoutCount(player: player, count: 9)
            } else {
                operation
            }
        })
        #expect(session.state.isHandComplete)
        #expect(session.state.boards.count == 9)
    }

    @Test("the table deals each hand and takes its chips back")
    func tableState() throws {
        // README: begin
        // Three players sit down, and the button starts on seat 5.
        var table = try TableState(stakes: .init(mode: .cashGame, smallBlind: 1, bigBlind: 2), buttonSeat: 5)
        try table.sit(2, stack: 300)
        try table.sit(5, stack: 150)
        try table.sit(7, stack: 200)

        let deal = try table.nextHand()
        #expect(deal.seats == [7, 2, 5])               // `deal.seats[i]` is the seat of player i
        let session = TableSession(config: deal.config)
        // README: end

        while case let .dealHoleCard(player, _)? = session.state.pendingOperation {
            try session.apply(.dealHole(player: player, card: .unknown))
        }
        // The button, seat 5, folds, then the small blind, seat 7.
        try session.apply(.fold(player: 2))
        try session.apply(.fold(player: 0))
        #expect(session.state.isHandComplete)

        // README: begin
        // Everyone folded to the big blind, on seat 2. The chips go back to the seats, and the button moves on.
        try table.finish(session.state, of: deal)
        #expect(table.stacks == [2: 301, 5: 150, 7: 199])
        #expect(try table.nextHand().seats.last == 7)
        // README: end

        // The next hand, dealt above, folds to the big blind, now on seat 5.
        let second = try #require(table.hand)
        var hand = HandState(config: second.config)
        while case let .dealHoleCard(player, _)? = hand.pendingOperation {
            hand = try hand.apply(.dealHole(player: player, card: .unknown))
        }
        try table.finish(hand.apply(.fold(player: 2)).apply(.fold(player: 0)), of: second)
        #expect(table.stacks == [2: 300, 5: 151, 7: 199])

        // README: begin
        // A new player takes seat 3, seat 7 moves to seat 9, seat 2 passes seat 5 fifty chips, and the blinds go up.
        try table.sit(3, stack: 200)
        try table.changeSeat(from: 7, to: 9)
        try table.setStack(of: 2, to: 250)
        try table.setStack(of: 5, to: 201)
        table.stakes.smallBlind = 2
        table.stakes.bigBlind = 4
        try table.moveButton(to: 9)

        let afterTheBreak = try table.nextHand()
        #expect(afterTheBreak.seats == [2, 3, 5, 9])
        #expect(afterTheBreak.config.startingStacks == [250, 200, 201, 199])
        #expect(afterTheBreak.config.blindsOrStraddles == [2, 4, 0, 0])
        // README: end
    }

    @Test("seats map to player indices, and stacks go back to the seats")
    func seats() throws {
        // README: begin
        // Seats 2, 5, 7 and 9 are in the hand, and the button is on seat 5.
        var stacksBySeat = [2: 300, 5: 150, 7: 200, 9: 120]
        let seats = HandConfig.playerOrder(occupiedSeats: [2, 5, 7, 9], buttonSeat: 5)
        #expect(seats == [7, 9, 2, 5])                 // `seats[i]` is the seat of player i

        let config = try HandConfig(
            mode: .cashGame,
            startingStacks: seats.map { stacksBySeat[$0, default: 0] },
            blindsOrStraddles: [1, 2],
            minBet: 2
        )
        #expect(config.startingStacks == [200, 120, 300, 150])
        // README: end

        var hand = HandState(config: config)
        for player in 0..<4 {
            for rank: Rank in [.two, .three] {
                hand = try hand.apply(.dealHole(player: player, card: .known(rank, Suit.allCases[player])))
            }
        }
        for operation: HandOperation in [.fold(player: 2), .fold(player: 3), .fold(player: 0)] {
            hand = try hand.apply(operation)
        }
        #expect(hand.isHandComplete)

        // README: begin
        // When the hand is over, the stacks go back to the seats for the next hand's config.
        for (player, seat) in seats.enumerated() {
            stacksBySeat[seat] = hand.stacks[player]
        }
        stacksBySeat = stacksBySeat.filter { $0.value > 0 }    // a stack of 0 is refused: rebuy or leave
        // README: end
        #expect(stacksBySeat == [2: 300, 5: 150, 7: 199, 9: 121])
        #expect(HandConfig.playerOrder(occupiedSeats: Array(stacksBySeat.keys), buttonSeat: 7) == [9, 2, 5, 7])

        // What the config refuses when the table changes.
        #expect(throws: ConfigError.nonPositiveStartingStack(player: 1)) {
            try HandConfig(mode: .cashGame, startingStacks: [100, 0, 100], blindsOrStraddles: [1, 2], minBet: 2)
        }
        #expect(throws: ConfigError.playerCountOutOfRange(1)) {
            try HandConfig(mode: .cashGame, startingStacks: [300], blindsOrStraddles: [1, 2], minBet: 2)
        }
        #expect(throws: ConfigError.tooManyBlindsOrStraddles(3)) {
            try HandConfig(mode: .cashGame, startingStacks: [100, 100], blindsOrStraddles: [1, 2, 4], minBet: 2)
        }

        // Heads-up the seat that is not the button is player 0, the big blind. An empty button seat is dead.
        #expect(HandConfig.playerOrder(occupiedSeats: [3, 8], buttonSeat: 8) == [3, 8])
        #expect(HandConfig.playerOrder(occupiedSeats: [2, 5, 7, 9], buttonSeat: 4) == [5, 7, 9, 2])
    }

    @Test("the README's forced bets post what it says")
    func forcedBets() throws {
        func posted(_ blinds: [Int], antes: [Int] = [], trimming: Bool = false, players: Int) throws -> [Int] {
            let hand = HandState(config: try HandConfig(
                mode: .cashGame, startingStacks: Array(repeating: 100, count: players), antes: antes,
                anteTrimming: trimming, blindsOrStraddles: blinds, minBet: 2
            ))
            return hand.stacks.map { 100 - $0 }
        }
        #expect(try posted([1, 2], players: 6) == [1, 2, 0, 0, 0, 0])
        #expect(try posted([1, 2], players: 2) == [2, 1])
        #expect(try posted([1, 2, 4], players: 6) == [1, 2, 4, 0, 0, 0])
        #expect(try posted([1, 2, 0, 0, 0, 4], players: 6) == [1, 2, 0, 0, 0, 4])
        #expect(try posted([1, 2, -2], players: 6) == [1, 2, 2, 0, 0, 0])
        #expect(try posted([2], players: 5) == [2, 0, 0, 0, 0])
        #expect(try posted([1, 2, 0, -2], antes: [0, 0, 0, 1], players: 4) == [1, 2, 0, 3])
        #expect(try posted([1, 2], antes: [1, 1, 1, 1, 1, 1], trimming: true, players: 6) == [2, 3, 1, 1, 1, 1])
        #expect(try posted([1, 2], antes: [0, 2], players: 6) == [1, 4, 0, 0, 0, 0])
        #expect(try posted([1, 2], antes: [0, 0, 0, 0, 0, 2], players: 6) == [1, 2, 0, 0, 0, 2])
        #expect(throws: ConfigError.anteTrimmingRequiresUniformAntes) {
            try HandConfig(
                mode: .cashGame, startingStacks: Array(repeating: 100, count: 6), antes: [1], anteTrimming: true,
                blindsOrStraddles: [1, 2], minBet: 2
            )
        }
    }

    @Test("the log's rows for a fold-out and for a scoop hold what the README says")
    func settlementRows() throws {
        // Everyone folds to player 2's bet of 10, so it is neither collected nor returned, and only the pull has it.
        let foldOut = try HandState.replay(
            config: Self.threeHanded, operations: Self.toTheShowdown.prefix(15) + [.fold(player: 1)]
        ).log.map(\.event)
        #expect(foldOut.contains(.betsCollected(collected: [0, 0, 0], returned: [0, 0, 0])))
        #expect(foldOut.contains(.chipsPushed(pot: 0, runout: nil, amounts: [0, 0, 13])))
        #expect(foldOut.contains(.chipsPulled(player: 2, amount: 23)))

        // Two runs and one winner: the beaten hand is killed first, so the push names no run.
        var scoop = try HandState.replay(
            config: Self.headsUp(),
            operations: [
                .dealHole(player: 0, card: .known(.ace, .spades)), .dealHole(player: 1, card: .known(.king, .spades)),
                .dealHole(player: 0, card: .known(.ace, .hearts)), .dealHole(player: 1, card: .known(.king, .hearts)),
                .betOrRaise(player: 1, to: 100), .checkOrCall(player: 0),
                .selectRunoutCount(player: 0, count: 2), .selectRunoutCount(player: 1, count: 2),
                .showHoleCards(player: 1), .showHoleCards(player: 0),
            ]
        )
        var board = try Card.parse("2c3d7h8sJc2d3h7s8cJd")[...]
        while let pending = scoop.pendingOperation {
            if case .burnCard = pending {
                scoop = try scoop.apply(.burnCard(.unknown))
            } else {
                let card = board.popFirst()
                scoop = try scoop.apply(.dealBoard(try #require(card)))
            }
        }
        #expect(scoop.boards.count == 2)
        #expect(scoop.log.contains { $0.event == .chipsPushed(pot: 0, runout: nil, amounts: [200, 0]) })
    }

    @Test("pots left with the same players are paid as one, so a tie across them has one remainder")
    func mergedPots() throws {
        var hand = HandState(config: try HandConfig(
            mode: .cashGame, startingStacks: [100, 4, 100, 100, 100], blindsOrStraddles: [1, 2], minBet: 2
        ))
        for (index, card) in try Card.parse("7h2cAsAdQc2d3cKdKhQd").enumerated() {
            hand = try hand.apply(.dealHole(player: index % 5, card: card))
        }
        for operation: HandOperation in [
            .betOrRaise(player: 2, to: 7), .checkOrCall(player: 3), .checkOrCall(player: 4), .fold(player: 0),
            .checkOrCall(player: 1),                 // all in for 4
            .burnCard(.unknown), .dealBoard(.known(.ace, .hearts)), .dealBoard(.known(.king, .spades)),
            .dealBoard(.known(.seven, .diamonds)),
            .betOrRaise(player: 2, to: 10), .checkOrCall(player: 3), .fold(player: 4),
            .burnCard(.unknown), .dealBoard(.known(.nine, .clubs)), .checkOrCall(player: 2), .checkOrCall(player: 3),
            .burnCard(.unknown), .dealBoard(.known(.jack, .spades)), .checkOrCall(player: 2), .checkOrCall(player: 3),
        ] {
            hand = try hand.apply(operation)
        }
        #expect(hand.pots.map(\.amount) == [17, 29])
        #expect(hand.pots.map(\.eligiblePlayers) == [[1, 2, 3], [2, 3]])

        for player in [2, 3, 1] {
            hand = try hand.apply(.showHoleCards(player: player))
        }

        // Players 2 and 3 tie, and player 1 is beaten. Pot by pot the chips would come to 24 and 22.
        #expect(hand.statuses[1] == .killed)
        #expect(hand.results?.map(\.won) == [0, 0, 23, 23, 0])
        let pushes = hand.log.filter { if case .chipsPushed = $0.event { true } else { false } }
        #expect(pushes.map(\.event) == [.chipsPushed(pot: 0, runout: 0, amounts: [0, 0, 23, 23, 0])])
    }

    @Test("on several runs a merged pot splits across the runs first, and each run has its own remainder")
    func mergedPotsOnTwoRuns() throws {
        var hand = HandState(config: try HandConfig(
            mode: .cashGame, startingStacks: [100, 4, 17, 17, 100], blindsOrStraddles: [1, 2], minBet: 2
        ))
        for (index, card) in try Card.parse("7h5cAsAdQc2h4cKsKdQd").enumerated() {
            hand = try hand.apply(.dealHole(player: index % 5, card: card))
        }
        for operation: HandOperation in [
            .betOrRaise(player: 2, to: 7), .checkOrCall(player: 3), .checkOrCall(player: 4), .fold(player: 0),
            .checkOrCall(player: 1),                 // all in for 4
            .burnCard(.unknown), .dealBoard(.known(.nine, .spades)), .dealBoard(.known(.nine, .diamonds)),
            .dealBoard(.known(.seven, .clubs)),
            .betOrRaise(player: 2, to: 10), .checkOrCall(player: 3), .fold(player: 4),
        ] {
            hand = try hand.apply(operation)
        }
        #expect(hand.pots.map(\.amount) == [17, 29])

        for player in [1, 2, 3] {
            hand = try hand.apply(.selectRunoutCount(player: player, count: 2))
        }
        for player in [2, 3, 1] {
            hand = try hand.apply(.showHoleCards(player: player))
        }
        for card in try Card.parse("2c3hJh8h") {
            hand = try hand.apply(.burnCard(.unknown))
            hand = try hand.apply(.dealBoard(card))
        }

        // Each run pays 23 and splits it 12 and 11, so the 24 and 22 here come from two odd chips, not from two pots.
        #expect(hand.statuses[1] == .killed)
        #expect(hand.results?.map(\.won) == [0, 0, 24, 22, 0])
        let pushes = hand.log.filter { if case .chipsPushed = $0.event { true } else { false } }
        #expect(pushes.map(\.event) == [
            .chipsPushed(pot: 0, runout: 0, amounts: [0, 0, 12, 11, 0]),
            .chipsPushed(pot: 0, runout: 1, amounts: [0, 0, 12, 11, 0]),
        ])
    }

    @Test("Pot-Limit Omaha deals four hole cards, stops raises at the pot, and makes hands from two hole cards")
    func omaha() throws {
        // README: begin
        let omaha = try HandConfig(
            variant: .potLimitOmahaHoldem, mode: .cashGame, startingStacks: [200, 200, 200],
            blindsOrStraddles: [1, 2], minBet: 2
        )
        var hand = HandState(config: omaha)

        // 1. Four hole cards each, still one card per operation.
        for card in try Card.parse("AsKsQsAhKhQhAdKdQdAcKcQc") {
            guard case let .dealHoleCard(player, _)? = hand.pendingOperation else { break }
            hand = try hand.apply(.dealHole(player: player, card: card))
        }
        #expect(hand.holeCards.map(\.count) == [4, 4, 4])

        // 2. No bet or raise above the pot. The button may call 2 and raise by the 5 then in the pot, to 7.
        #expect(hand.legalActions?.betOrRaise == .raise(4...7))
        hand = try hand.apply(.betOrRaise(player: 2, to: 7))
        #expect(hand.legalActions?.betOrRaise == .raise(12...23))
        // README: end

        // 3. Four aces make one pair, and their one spade makes no flush on four spades. Nothing is face up yet, so
        // there is no face-up hand either.
        func played(_ streets: String...) throws -> HandState {
            var played = try hand.applying(.checkOrCall(player: 0), .checkOrCall(player: 1))
            for street in streets {
                played = try played.apply(.burnCard(.unknown))
                for card in try Card.parse(street) {
                    played = try played.apply(.dealBoard(card))
                }
                while let actor = played.actor {
                    played = try played.apply(.checkOrCall(player: actor))
                }
            }
            return played
        }
        let river = try played("2s7s9s", "Ts", "3h")
        #expect(river.hand(of: 0)?.description == "One pair (AsAh7s9sTs)")
        #expect(river.dealtHand(of: 0)?.description == "One pair (AsAh7s9sTs)")
        #expect(river.hand(of: 0, faceUpOnly: true) == nil)

        // On the river a kept hand is forgotten and has none. After two Keeps the last player may neither keep nor
        // muck, as nobody would hold a hand, nor show one card, and a show of two cards wins.
        #expect(river.pendingOperation == .showdown(runoutSelectors: [], showOrder: [0, 1, 2]))
        let kept = try river.apply(.showHoleCards(player: 0, cards: []))
        #expect(kept.hand(of: 0) == nil)
        let twoKept = try kept.apply(.showHoleCards(player: 1, cards: []))
        #expect(!twoKept.canApply(.showHoleCards(player: 2, cards: [])))
        #expect(!twoKept.canApply(.muckHoleCards(player: 2)))
        #expect(throws: EngineError.wouldAbandonPot(player: 2, pot: 0)) {
            try twoKept.apply(.showHoleCards(player: 2, cards: [.known(.queen, .spades)]))
        }
        let shown = try twoKept.apply(
            .showHoleCards(player: 2, cards: [.known(.queen, .spades), .known(.queen, .hearts)])
        )
        #expect(shown.results?.map(\.net) == [-7, -7, 14])

        // Heads-up, the other player may instead muck and let the kept hand take the pot unseen.
        let headsUp = try HandConfig(
            variant: .potLimitOmahaHoldem, mode: .cashGame, startingStacks: [100, 100], blindsOrStraddles: [1, 2],
            minBet: 2
        )
        var duel = HandState(config: headsUp)
        for (index, card) in try Card.parse("AsKsAhKhAdKdAcKc").enumerated() {
            duel = try duel.apply(.dealHole(player: index % 2, card: card))
        }
        for street in ["", "2d7h9s", "Th", "3d"] {
            if !street.isEmpty {
                duel = try duel.apply(.burnCard(.unknown))
                for card in try Card.parse(street) {
                    duel = try duel.apply(.dealBoard(card))
                }
            }
            while let actor = duel.actor {
                duel = try duel.apply(.checkOrCall(player: actor))
            }
        }
        let duelKept = try duel.apply(.showHoleCards(player: 0, cards: []))
        #expect(!duelKept.canApply(.showHoleCards(player: 1, cards: [])))
        #expect(try duelKept.apply(.muckHoleCards(player: 1)).results?.map(\.net) == [2, -2])

        // Before the river a kept hand stays live: all in before the flop, it still makes a hand on the flop.
        var allIn = HandState(config: headsUp)
        for (index, card) in try Card.parse("AsKsAhKhAdKdAcKc").enumerated() {
            allIn = try allIn.apply(.dealHole(player: index % 2, card: card))
        }
        allIn = try allIn.applying(
            .betOrRaise(player: 1, to: 6), .betOrRaise(player: 0, to: 18), .betOrRaise(player: 1, to: 54),
            .betOrRaise(player: 0, to: 100), .checkOrCall(player: 1),
            .selectRunoutCount(player: 0, count: nil), .selectRunoutCount(player: 1, count: nil),
            .showHoleCards(player: 0, cards: []), .showHoleCards(player: 1),
            .burnCard(.unknown), .dealBoard(.known(.two, .diamonds)), .dealBoard(.known(.seven, .hearts)),
            .dealBoard(.known(.nine, .spades))
        )
        #expect(allIn.holeCards[0].map(\.card) == (try Card.parse("AsAhAdAc")))
        #expect(allIn.hand(of: 0)?.description == "One pair (AsAh2d7h9s)")
        #expect(allIn.hand(of: 0, faceUpOnly: true) == nil)

        // Stored as version 2 with the game named; Hold'em stays version 1. PHH calls the game PO.
        let stored = try JSONDecoder().decode([String: JSONValue].self, from: shown.json())
        #expect(stored["formatVersion"] == .int(2))
        guard case let .object(config)? = stored["config"] else {
            Issue.record("No config in the document")
            return
        }
        #expect(config["variant"] == .string("potLimitOmahaHoldem"))
        let holdem = try JSONDecoder().decode([String: JSONValue].self, from: Self.atTheShowdown().json())
        #expect(holdem["formatVersion"] == .int(1))
        #expect(try shown.phh().hasPrefix("variant = 'PO'\n"))
    }

    @Test("a misread card is corrected from its log row")
    func correctionFromTheLog() throws {
        let session = TableSession(state: try Self.atTheShowdown())
        // README: begin
        @MainActor
        func correct(_ entry: LogEntry, to card: Card, in session: TableSession) throws(ReplayError) {
            // The hand can move on during a rescan, and then the row's index is wrong or gone.
            guard let index = entry.operationIndex, session.state.log.contains(entry) else { return }
            switch entry.event {
            case let .holeCardDealt(player, _):
                try session.replaceOperation(at: index, with: .dealHole(player: player, card: card))
            case .boardCardDealt:
                try session.replaceOperation(at: index, with: .dealBoard(card))
            case .cardBurned:
                try session.replaceOperation(at: index, with: .burnCard(card))
            default:
                break
            }
        }
        // README: end

        func entry(_ matches: (HandEvent) -> Bool) throws -> LogEntry {
            try #require(session.state.log.first { matches($0.event) })
        }
        let river = try entry { if case .boardCardDealt(_, street: .river, runout: 0) = $0 { true } else { false } }
        try correct(river, to: .known(.queen, .hearts), in: session)
        #expect(session.state.boards == [try Card.parse("Jc8d3s2dQh")])

        let hole = try entry { if case .holeCardDealt(player: 2, _) = $0 { true } else { false } }
        try correct(hole, to: .known(.ace, .diamonds), in: session)
        #expect(session.state.holeCards[2].map(\.card) == (try Card.parse("AdKc")))

        let burn = try entry { if case .cardBurned(_, street: .turn, runout: 0) = $0 { true } else { false } }
        try correct(burn, to: .known(.four, .clubs), in: session)
        #expect(session.state.operations[16] == .burnCard(.known(.four, .clubs)))

        // A row with nothing to correct changes nothing.
        let before = session.state
        let automated = try entry { if case .blindOrStraddlePosted = $0 { true } else { false } }
        try correct(automated, to: .known(.four, .clubs), in: session)
        let fold = try entry { if case .folded = $0 { true } else { false } }
        try correct(fold, to: .known(.four, .clubs), in: session)
        #expect(session.state == before)

        // A row kept while undo took its operation back is stale, even once another operation has its index. Undo
        // reverses this session's corrections first, so the hand goes on in a session restored from it.
        let stale = try entry { if case .boardCardDealt(_, street: .river, runout: 0) = $0 { true } else { false } }
        let restored = TableSession(state: session.state)
        for _ in 0..<3 {
            restored.undo()
        }
        let undone = restored.state
        try correct(stale, to: .known(.four, .clubs), in: restored)
        #expect(restored.state == undone)
        try restored.apply(.dealBoard(.known(.four, .spades)))
        let redealt = restored.state
        try correct(stale, to: .known(.four, .clubs), in: restored)
        #expect(restored.state == redealt)
    }

    @Test("a correction that no longer fits names the first operation it breaks")
    func refusedCorrection() throws {
        let session = TableSession(state: try Self.atTheShowdown())
        // README: begin
        // Player 1 really folded preflop, not called (`operations[8]`). That ends the hand, so the
        // burn after it no longer fits, and nothing changes.
        let before = session.state
        let refusal = #expect(throws: ReplayError.self) {
            try session.replaceOperation(at: 8, with: .fold(player: 1))
        }
        #expect(refusal?.operationIndex == 9)
        #expect(refusal?.operation == .burnCard(.unknown))
        #expect(refusal?.error == .handComplete)
        #expect(refusal?.error.message() == "The hand is over.")
        #expect(session.state == before)

        // To go ahead, drop what came after the corrected operation.
        let kept = session.state.operations[..<8]
        try session.replaceOperations(with: kept + [.fold(player: 1)])
        #expect(session.state.isHandComplete)
        // README: end
        #expect(session.state.operations.count == 9)
        #expect(session.state.stacks == [199, 198, 203])
    }

    @Test("undo reverses a correction as one step, newest first, and a restored session has none to reverse")
    func undoAfterACorrection() throws {
        let finished = try Self.atTheShowdown().apply(.showHoleCards(player: 1)).apply(.showHoleCards(player: 2))
        let river = try #require(finished.operations.firstIndex(of: .dealBoard(.known(.nine, .hearts))))

        // A correction that dropped operations comes back whole.
        let session = TableSession(state: finished)
        try session.replaceOperations(with: finished.operations[..<8] + [.fold(player: 1)])
        #expect(session.state.operations.count == 9)
        session.undo()
        #expect(session.state == finished)

        // After a correction and two more operations, undo takes back those two, then the correction, then the
        // operations before it.
        let atRiver = try HandState.replay(config: finished.config, operations: Array(finished.operations[...river]))
        let dealing = TableSession(state: atRiver)
        try dealing.replaceOperation(at: river, with: .dealBoard(.known(.ace, .hearts)))
        let corrected = dealing.state
        try dealing.apply(.betOrRaise(player: 1, to: 20))
        try dealing.apply(.checkOrCall(player: 2))
        dealing.undo()
        dealing.undo()
        #expect(dealing.state == corrected)
        dealing.undo()
        #expect(dealing.state == atRiver)
        dealing.undo()
        #expect(dealing.state.operations == Array(atRiver.operations.dropLast()))

        // A session made with `init(state:)` holds no corrections, so its undo takes back operations.
        let restored = TableSession(state: corrected)
        restored.undo()
        #expect(restored.state.operations == Array(corrected.operations.dropLast()))
    }

    @Test("a wrong stack is corrected by replaying the hand on a corrected config")
    func correctedConfig() throws {
        let session = TableSession(state: try Self.atTheShowdown())
        // README: begin
        // Player 2 really had 260, not the 200 entered.
        let old = session.state.config
        let corrected = try HandConfig(
            mode: old.mode, startingStacks: [200, 200, 260], antes: old.antes, anteTrimming: old.anteTrimming,
            blindsOrStraddles: old.blindsOrStraddles, minBet: old.minBet, automations: old.automations
        )
        try session.replaceConfig(with: corrected)
        #expect(session.state.stacks[2] == 224)
        // README: end
        #expect(session.state.operations == Self.toTheShowdown)

        // A stack too small for a bet entered refuses the correction, and nothing changes.
        let before = session.state
        let tooSmall = try HandConfig(
            mode: .cashGame, startingStacks: [200, 200, 8], blindsOrStraddles: [1, 2], minBet: 2
        )
        let refusal = #expect(throws: ReplayError.self) { try session.replaceConfig(with: tooSmall) }
        #expect(refusal?.operationIndex == 14)
        #expect(refusal?.error == .betAboveMaximum(amount: 10, maximum: 2))
        #expect(session.state == before)

        // Undo takes the correction back.
        session.undo()
        #expect(session.state == (try Self.atTheShowdown()))

        // Operations name players by index, so a config with another player count does not fit them.
        let fourHanded = try HandConfig(
            mode: .cashGame, startingStacks: [200, 200, 200, 200], blindsOrStraddles: [1, 2], minBet: 2
        )
        let added = #expect(throws: ReplayError.self) { try session.replaceConfig(with: fourHanded) }
        #expect(added?.operationIndex == 6)       // player 3 is still owed cards
        let headsUp = try Self.headsUp()
        let removed = #expect(throws: ReplayError.self) { try session.replaceConfig(with: headsUp) }
        #expect(removed?.error == .invalidPlayer(2))
    }

    @Test("a shove entered at the old stack changes with the stack, or the correction leaves chips behind")
    func correctedConfigWithAShove() throws {
        let session = TableSession(config: try Self.headsUp())
        for (index, card) in try Card.parse("AsKsAhKh").enumerated() {
            try session.apply(.dealHole(player: index % 2, card: card))
        }
        try session.apply(.betOrRaise(player: 1, to: 100))
        #expect(session.state.stacks == [98, 0])
        let deeper = try HandConfig(
            mode: .cashGame, startingStacks: [100, 150], blindsOrStraddles: [1, 2], minBet: 2
        )

        // Replayed as entered, the shove leaves 50 behind.
        #expect(try HandState.replay(config: deeper, operations: session.state.operations).stacks == [98, 50])

        var operations = session.state.operations
        operations[4] = .betOrRaise(player: 1, to: 150)
        try session.replaceConfig(with: deeper, operations: operations)
        #expect(session.state.stacks == [98, 0])

        // A smaller stack refuses the shove as entered.
        let shallower = try HandConfig(
            mode: .cashGame, startingStacks: [100, 80], blindsOrStraddles: [1, 2], minBet: 2
        )
        let refusal = #expect(throws: ReplayError.self) { try session.replaceConfig(with: shallower) }
        #expect(refusal?.error == .betAboveMaximum(amount: 150, maximum: 80))
    }

    @Test("corrections that touch several operations are made together")
    func severalCorrections() throws {
        let session = TableSession(state: try Self.atTheShowdown())
        // README: begin
        // The 7h and the Qd were swapped. Correcting either one alone would repeat a card.
        var operations = session.state.operations
        operations[0] = .dealHole(player: 0, card: .known(.queen, .diamonds))
        operations[1] = .dealHole(player: 1, card: .known(.seven, .hearts))
        try session.replaceOperations(with: operations)
        // README: end
        #expect(session.state.holeCards[1].map(\.card) == (try Card.parse("7hJd")))
        let repeated = #expect(throws: ReplayError.self) {
            try session.replaceOperation(at: 0, with: .dealHole(player: 0, card: .known(.seven, .hearts)))
        }
        #expect(repeated?.error == .duplicateCard(.known(.seven, .hearts), location: .hole(player: 0)))

        // Back to the cards as first read, with a listed show.
        try session.replaceOperations(with: Self.toTheShowdown)
        let listed: [Card] = [.known(.queen, .diamonds), .known(.jack, .diamonds)]
        try session.apply(.showHoleCards(player: 1, cards: listed))
        let refusal = #expect(throws: ReplayError.self) {
            try session.replaceOperation(at: 4, with: .dealHole(player: 1, card: .known(.jack, .spades)))
        }
        #expect(refusal?.operationIndex == 24)
        #expect(refusal?.error == .shownCardNotDealt(player: 1, card: .known(.jack, .diamonds)))

        // A list that fails partway changes nothing either, not even the operations before the failure.
        let before = session.state
        var mistaken = before.operations
        mistaken[4] = .dealHole(player: 1, card: .known(.jack, .spades))
        #expect(throws: ReplayError.self) {
            try session.replaceOperations(with: mistaken)
        }
        #expect(session.state == before)

        // README: begin
        // Another hand: player 1 showed by listing Qd and Jd, but the Jd was really the Js.
        operations = session.state.operations
        let showIndex = operations.count - 1           // the show is the last operation here
        operations[4] = .dealHole(player: 1, card: .known(.jack, .spades))
        operations[showIndex] = .showHoleCards(
            player: 1, cards: [.known(.queen, .diamonds), .known(.jack, .spades)]
        )
        try session.replaceOperations(with: operations)
        // README: end
        #expect(session.state.holeCards[1].map(\.card) == (try Card.parse("QdJs")))
    }

    @Test("an unscanned card is revealed by a show, and an unscanned board card blocks settlement")
    func unscanned() throws {
        var operations = Self.toTheShowdown
        operations[4] = .dealHole(player: 1, card: .unknown)
        operations[21] = .dealBoard(.unknown)
        var hand = try HandState.replay(config: Self.threeHanded, operations: operations)
        // README: begin
        // Player 1's second card and the river were entered as `.unknown`.
        #expect(!hand.canApply(.showHoleCards(player: 1)))     // the second card is unknown
        #expect(hand.hand(of: 1) == nil)                       // the river is unknown

        // A show that lists the cards reveals the unscanned one.
        hand = try hand.apply(.showHoleCards(
            player: 1, cards: [.known(.queen, .diamonds), .known(.jack, .diamonds)]
        ))

        // The last show would settle the hand, so it is refused, and the state stays as it was.
        // Muck needs no board, so it is the only button left, and it gives the pot away.
        #expect(!hand.canApply(.showHoleCards(player: 2)))
        #expect(hand.canApply(.muckHoleCards(player: 2)))
        #expect(throws: EngineError.unknownBoardCard(runout: 0, position: 4)) {
            try hand.apply(.showHoleCards(player: 2))
        }

        // Correct the river, and enter the show again.
        let river = try #require(hand.operations.firstIndex(of: .dealBoard(.unknown)))
        hand = try hand.replacingOperation(at: river, with: .dealBoard(.known(.nine, .hearts)))
        hand = try hand.apply(.showHoleCards(player: 2))
        #expect(hand.isHandComplete)
        // README: end
        #expect(hand.stacks == [199, 237, 164])
    }

    @Test("a card nobody scanned is ?? in a stored document, even on a board")
    func unscannedInTheDocument() throws {
        struct Dealt: Decodable { let card: String? }
        struct HoleCards: Decodable { let holeCards: [Dealt] }
        struct Document: Decodable {
            let operations: [Dealt]
            let boards: [[String]]
            let results: [HoleCards]
        }

        var operations = Array(Self.toTheShowdown.prefix(15)) + [.fold(player: 1)]
        operations[5] = .dealHole(player: 2, card: .unknown)
        operations[10] = .dealBoard(.unknown)
        let hand = try HandState.replay(config: Self.threeHanded, operations: operations)
        #expect(hand.isHandComplete)

        let document = try JSONDecoder().decode(Document.self, from: try hand.json())
        #expect(document.operations[5].card == "??")
        #expect(document.operations[10].card == "??")
        #expect(document.boards == [["??", "8d", "3s"]])
        #expect(document.results[2].holeCards.map(\.card) == ["As", "??"])
    }

    @Test("a hand survives being stored as text and read back")
    func storing() throws {
        let hand = try Self.atTheShowdown()
        // README: begin
        // `json()` works at any point in the hand, so the same document saves a hand under way.
        let document = String(decoding: try hand.json(), as: UTF8.self)

        // After a crash: read it back and carry on. Undo reaches back through the whole hand.
        let session = TableSession(state: try HandState(json: Data(document.utf8)))
        #expect(session.state == hand)
        #expect(session.canUndo)
        // README: end
        session.undo()
        #expect(session.state.operations == Array(hand.operations.dropLast()))

        // README: begin
        struct HandRow: Codable {
            let id: UUID
            let document: String                       // the text from `json()`, not a `HandState`
        }
        // README: end
        let row = HandRow(id: UUID(), document: document)
        let read = try JSONDecoder().decode(HandRow.self, from: try JSONEncoder().encode(row))
        #expect(try HandState(json: Data(read.document.utf8)) == hand)

        // README: begin
        let history = try hand.phh()
        #expect(history.hasPrefix("variant = 'NT'\n"))
        // README: end
    }

    @Test("before the flop the seat after the largest post acts first, and a live post does not count")
    func firstToAct() throws {
        func dealt(_ blinds: [Int]) throws -> HandState {
            try Self.dealt(HandConfig(
                mode: .cashGame, startingStacks: Array(repeating: 200, count: 6), blindsOrStraddles: blinds, minBet: 2
            ))
        }
        func order(_ blinds: [Int]) throws -> [Int] {
            var hand = try dealt(blinds)
            var order = [Int]()
            while let actor = hand.actor {
                order.append(actor)
                hand = try hand.apply(.checkOrCall(player: actor))
            }
            return order
        }
        #expect(try order([1, 2]) == [2, 3, 4, 5, 0, 1])
        #expect(try order([1, 2, 4]) == [3, 4, 5, 0, 1, 2])
        #expect(try order([1, 2, 0, 0, 0, 4]) == [0, 1, 2, 3, 4, 5])
        #expect(try order([1, 2, 4, 8]) == [4, 5, 0, 1, 2, 3])
        #expect(try order([1, 2, 2]) == [3, 4, 5, 0, 1, 2])
        #expect(try order([1, 2, -2]) == [2, 3, 4, 5, 0, 1])

        // A room that starts left of the big blind cannot be entered: the small blind must go first.
        #expect(throws: EngineError.notYourTurn(player: 2, actor: 0)) {
            try dealt([1, 2, 0, 0, 0, 4]).apply(.checkOrCall(player: 2))
        }
    }

    @Test("a street's first bet counts as a full raise even when it is all in for less than minBet")
    func shortOpeningBet() throws {
        // After a check, an all-in bet of 20 lets the player who checked raise, to 120.
        let short = try Self.limpedFlop(stacks: [5000, 5000, 120, 5000], then: [
            .checkOrCall(player: 0), .checkOrCall(player: 1), .betOrRaise(player: 2, to: 20), .checkOrCall(player: 3),
        ])
        #expect(short.actor == 0)
        #expect(short.toCall == 20)
        #expect(short.legalActions?.betOrRaise == .raise(120...4900))

        // The same 20 as a raise over a full bet closes the action for the bettor.
        let full = try Self.limpedFlop(stacks: [5000, 5000, 220, 5000], then: [
            .betOrRaise(player: 0, to: 100), .checkOrCall(player: 1), .betOrRaise(player: 2, to: 120),
            .checkOrCall(player: 3),
        ])
        #expect(full.actor == 0)
        #expect(full.toCall == 20)
        #expect(full.legalActions?.betOrRaise == .unavailable(.actionNotReopened))
    }

    @Test("a full raise is measured against the street's largest increase, which can be less than minBet")
    func fullRaiseBelowMinBet() throws {
        var hand = try Self.dealt(HandConfig(
            mode: .cashGame, startingStacks: [500, 500, 500, 13, 500, 16, 500], blindsOrStraddles: [5, 10], minBet: 10
        ))
        for operation: HandOperation in [
            .checkOrCall(player: 2), .betOrRaise(player: 3, to: 13), .checkOrCall(player: 4),
            .betOrRaise(player: 5, to: 16), .checkOrCall(player: 6), .checkOrCall(player: 0), .checkOrCall(player: 1),
        ] {
            hand = try hand.apply(operation)
        }

        // Each all-in raised by 3, so the second was a full raise, though a raise from here must still add 10.
        #expect(hand.actor == 2)
        #expect(hand.legalActions?.betOrRaise == .raise(26...500))
        hand = try hand.apply(.checkOrCall(player: 2))
        #expect(hand.actor == 4)
        #expect(hand.toCall == 3)
        #expect(hand.legalActions?.betOrRaise == .raise(26...500))

        // The measure is the increase, not the total: after 100 and a raise to 300 it is 200, so all in to 550 reopens.
        let reopened = try Self.limpedFlop(stacks: [5000, 5000, 650, 5000], then: [
            .betOrRaise(player: 0, to: 100), .betOrRaise(player: 1, to: 300), .betOrRaise(player: 2, to: 550),
            .checkOrCall(player: 3), .checkOrCall(player: 0),
        ])
        #expect(reopened.actor == 1)
        #expect(reopened.toCall == 250)
        #expect(reopened.legalActions?.betOrRaise == .raise(800...4900))

        // After a raise to 350 it is 250, so an all-in that adds 240 does not.
        let closed = try Self.limpedFlop(stacks: [5000, 5000, 690, 5000], then: [
            .betOrRaise(player: 0, to: 100), .betOrRaise(player: 1, to: 350), .betOrRaise(player: 2, to: 590),
            .checkOrCall(player: 3), .checkOrCall(player: 0),
        ])
        #expect(closed.actor == 1)
        #expect(closed.toCall == 240)
        #expect(closed.legalActions?.betOrRaise == .unavailable(.actionNotReopened))

        // After a short first bet of 20, an all-in to 40 is a full raise, though `minBet` is 100.
        let afterShortBet = try Self.limpedFlop(stacks: [120, 5000, 140, 5000], then: [
            .betOrRaise(player: 0, to: 20), .checkOrCall(player: 1), .betOrRaise(player: 2, to: 40),
            .checkOrCall(player: 3),
        ])
        #expect(afterShortBet.actor == 1)
        #expect(afterShortBet.toCall == 20)
        #expect(afterShortBet.legalActions?.betOrRaise == .raise(140...4900))
    }

    @Test("a player answers each showdown once, though a show is accepted again once paying out begins")
    func oneAnswer() throws {
        let answered = try Self.atTheShowdown().apply(.showHoleCards(player: 1, cards: [.known(.queen, .diamonds)]))
        for second: HandOperation in [
            .showHoleCards(player: 1), .showHoleCards(player: 1, cards: []), .muckHoleCards(player: 1),
        ] {
            #expect(throws: EngineError.noShowdownExpected(player: 1)) { try answered.apply(second) }
        }

        let finished = try answered.apply(.showHoleCards(player: 2))
        #expect(finished.isHandComplete)
        #expect(finished.canApply(.showHoleCards(player: 2)))

        // A player out of the hand is refused for that reason, and for this one once nothing is left to answer.
        let mucked = try Self.atTheShowdown().apply(.muckHoleCards(player: 1))
        #expect(throws: EngineError.playerNotInHand(player: 1)) { try mucked.apply(.muckHoleCards(player: 1)) }

        // With pushes entered by hand, the pending push is where paying out begins, before any chips have moved.
        let push = try HandState.replay(
            config: Self.threeHanded(without: [.chipsPushing]),
            operations: Self.toTheShowdown + [.showHoleCards(player: 1), .showHoleCards(player: 2)]
        )
        #expect(push.pendingOperation == .pushChips(pot: 0, runout: nil))
        #expect(push.canApply(.showHoleCards(player: 1)))
        #expect(throws: EngineError.mustShowAllCards(player: 1)) { try push.apply(.muckHoleCards(player: 1)) }
    }

    @Test("a mucked hand stays mucked, and bringing it back means replacing a Keep it takes chips from too")
    func muckedHandBroughtBack() throws {
        var river = try Self.headsUpRiver()
        for operation: HandOperation in [
            .checkOrCall(player: 0), .betOrRaise(player: 1, to: 10), .checkOrCall(player: 0),
        ] {
            river = try river.apply(operation)
        }
        #expect(river.pendingOperation == .showdown(runoutSelectors: [], showOrder: [1, 0]))

        // Player 1 bet and mucked. Player 0 holds the better hand and cannot muck, so takes the pot with Keep.
        let session = TableSession(state: river)
        try session.apply(.muckHoleCards(player: 1))
        #expect(throws: EngineError.playerNotInHand(player: 1)) { try session.apply(.showHoleCards(player: 1)) }
        try session.apply(.showHoleCards(player: 0, cards: []))
        let kept = session.state
        #expect(kept.results?.map(\.won) == [24, 0])
        #expect(kept.results?[1].status == .mucked)
        #expect(kept.results?[1].holeCards.contains(where: \.isFaceUp) == false)
        #expect(throws: EngineError.playerNotInHand(player: 1)) { try kept.apply(.showHoleCards(player: 1)) }

        // Replacing only the muck pays the worse hand, because the kept hand plays the board.
        let muck = river.operations.count
        try session.replaceOperation(at: muck, with: .showHoleCards(player: 1))
        #expect(session.state.results?.map(\.won) == [0, 24])
        try session.replaceOperation(at: muck + 1, with: .showHoleCards(player: 0))
        #expect(session.state.results?.map(\.won) == [24, 0])

        // Undo gets to the same hand, and takes the Keep back on the way.
        let undone = TableSession(state: kept)
        undone.undo()
        undone.undo()
        try undone.apply(.showHoleCards(player: 1))
        try undone.apply(.showHoleCards(player: 0))
        #expect(undone.state == session.state)
    }

    @Test("the answer that kept the card is replaced, whether it came before the muck or left only one card down")
    func winnersAnswerBeforeTheMuck() throws {
        let river = try Self.headsUpRiver().apply(.checkOrCall(player: 0)).apply(.checkOrCall(player: 1))
        #expect(river.pendingOperation == .showdown(runoutSelectors: [], showOrder: [0, 1]))
        let first = river.operations.count

        // Nothing is entered after the muck, but the Keep before it still plays the board.
        let session = TableSession(state: river)
        try session.apply(.showHoleCards(player: 0, cards: []))
        try session.apply(.muckHoleCards(player: 1))
        let kept = session.state
        #expect(kept.results?.map(\.won) == [4, 0])
        try session.replaceOperation(at: first + 1, with: .showHoleCards(player: 1))
        #expect(session.state.results?.map(\.won) == [0, 4])
        try session.replaceOperation(at: first, with: .showHoleCards(player: 0))
        #expect(session.state.results?.map(\.won) == [4, 0])

        // One undo leaves that Keep in place, and undo back past both answers matches replacing both.
        let undone = TableSession(state: kept)
        undone.undo()
        try undone.apply(.showHoleCards(player: 1))
        #expect(undone.state.results?.map(\.won) == [0, 4])
        undone.undo()
        undone.undo()
        try undone.apply(.showHoleCards(player: 0))
        try undone.apply(.showHoleCards(player: 1))
        #expect(undone.state == session.state)

        // A card left down by a partial show is lost the same way.
        let partial = TableSession(state: river)
        try partial.apply(.muckHoleCards(player: 1))
        try partial.apply(.showHoleCards(player: 0, cards: [.known(.king, .spades)]))
        #expect(partial.state.results?.map(\.won) == [4, 0])
        try partial.replaceOperation(at: first, with: .showHoleCards(player: 1))
        #expect(partial.state.results?.map(\.won) == [0, 4])
        try partial.replaceOperation(at: first + 1, with: .showHoleCards(player: 0))
        #expect(partial.state.results?.map(\.won) == [4, 0])
    }

    @Test("a Keep that had already lost stays as it was, and is killed with its cards still face down")
    func beatenKeepStays() throws {
        var river = HandState(config: Self.threeHanded)
        for (index, card) in try Card.parse("Ah7c4cKh7d4d").enumerated() {
            river = try river.apply(.dealHole(player: index % 3, card: card))
        }
        for operation: HandOperation in [
            .checkOrCall(player: 2), .checkOrCall(player: 0), .checkOrCall(player: 1),
            .burnCard(.unknown), .dealBoard(.known(.queen, .hearts)), .dealBoard(.known(.nine, .hearts)),
            .dealBoard(.known(.five, .hearts)),
            .checkOrCall(player: 0), .checkOrCall(player: 1), .checkOrCall(player: 2),
            .burnCard(.unknown), .dealBoard(.known(.three, .hearts)),
            .checkOrCall(player: 0), .checkOrCall(player: 1), .checkOrCall(player: 2),
            .burnCard(.unknown), .dealBoard(.known(.three, .clubs)),
            .checkOrCall(player: 0), .checkOrCall(player: 1), .checkOrCall(player: 2),
        ] {
            river = try river.apply(operation)
        }
        let first = river.operations.count

        // Player 0 kept a flush and lost to the fours, so player 0 was not the winner.
        let session = TableSession(state: river)
        try session.apply(.showHoleCards(player: 0, cards: []))
        try session.apply(.muckHoleCards(player: 1))
        try session.apply(.showHoleCards(player: 2))
        #expect(session.state.results?.map(\.won) == [0, 0, 6])
        #expect(session.state.results?[0].status == .killed)
        #expect(session.state.results?[0].holeCards.contains(where: \.isFaceUp) == false)

        // The hand brought back beats the winner. Replacing the beaten Keep as well would pay the flush.
        try session.replaceOperation(at: first + 1, with: .showHoleCards(player: 1))
        #expect(session.state.results?.map(\.won) == [0, 6, 0])
        try session.replaceOperation(at: first, with: .showHoleCards(player: 0))
        #expect(session.state.results?.map(\.won) == [6, 0, 0])
    }

    @Test("at an all-in a kept hand answers every ask, so only its last answer can become a show")
    func lastAnswerAtAnAllIn() throws {
        func kept(_ player: Int) -> HandOperation { .showHoleCards(player: player, cards: []) }
        let start = try Self.allInOnTheFlop()
        let config = start.config

        // Player 0 mucks kings, and the other two keep at the flop, turn and river, so they chop on the board.
        let muck = start.operations.count
        let flopAsk = muck + 1
        let turnAsk = flopAsk + 4
        let riverAsk = turnAsk + 4
        var operations = start.operations + [.muckHoleCards(player: 0), kept(1), kept(2)]
        operations += [.burnCard(.unknown), .dealBoard(.known(.ten, .clubs)), kept(1), kept(2)]
        operations += [.burnCard(.unknown), .dealBoard(.known(.three, .spades)), kept(1), kept(2)]
        let hand = try HandState.replay(config: config, operations: operations)
        #expect(hand.results?.map(\.won) == [0, 150, 150])

        // The kings brought back beat two kept hands, though player 2 holds aces.
        var corrected = operations
        corrected[muck] = .showHoleCards(player: 0)
        #expect(try HandState.replay(config: config, operations: corrected).results?.map(\.won) == [300, 0, 0])

        // A shown hand is not asked again, so a show at the first ask leaves the later answers with nothing to answer.
        var everyAnswer = corrected
        for ask in [flopAsk, turnAsk, riverAsk] {
            everyAnswer[ask] = .showHoleCards(player: 1)
            everyAnswer[ask + 1] = .showHoleCards(player: 2)
        }
        let refusal = #expect(throws: ReplayError.self) {
            try HandState.replay(config: config, operations: everyAnswer)
        }
        #expect(refusal?.operationIndex == turnAsk)
        #expect(refusal?.error == .noShowdownExpected(player: 1))

        // Only the last answers change, and the aces take the pot.
        corrected[riverAsk] = .showHoleCards(player: 1)
        corrected[riverAsk + 1] = .showHoleCards(player: 2)
        #expect(try HandState.replay(config: config, operations: corrected).results?.map(\.won) == [0, 0, 300])
    }

    @Test("a Keep that no replacement takes chips from stays, even for a winner of another pot")
    func keptWinnerOfAnotherPot() throws {
        var river = HandState(config: try HandConfig(
            mode: .cashGame, startingStacks: [200, 40, 40, 200], blindsOrStraddles: [1, 2], minBet: 2
        ))
        for (index, card) in try Card.parse("AsKcTs8d5dQc4s6d").enumerated() {
            river = try river.apply(.dealHole(player: index % 4, card: card))
        }
        for operation: HandOperation in [
            .betOrRaise(player: 2, to: 40), .checkOrCall(player: 3), .checkOrCall(player: 0), .checkOrCall(player: 1),
            .burnCard(.unknown), .dealBoard(.known(.two, .hearts)), .dealBoard(.known(.seven, .clubs)),
            .dealBoard(.known(.nine, .clubs)), .betOrRaise(player: 0, to: 20), .checkOrCall(player: 3),
            .burnCard(.unknown), .dealBoard(.known(.jack, .diamonds)), .checkOrCall(player: 0), .checkOrCall(player: 3),
            .burnCard(.unknown), .dealBoard(.known(.three, .spades)), .betOrRaise(player: 0, to: 20), .fold(player: 3),
        ] {
            river = try river.apply(operation)
        }
        #expect(throws: EngineError.wouldAbandonPot(player: 0, pot: 1)) { try river.apply(.muckHoleCards(player: 0)) }
        let first = river.operations.count

        let session = TableSession(state: river)
        try session.apply(.showHoleCards(player: 0, cards: []))
        try session.apply(.showHoleCards(player: 1))
        try session.apply(.muckHoleCards(player: 2))
        #expect(session.state.results?.map(\.won) == [40, 160, 0, 0])
        try session.replaceOperation(at: first + 2, with: .showHoleCards(player: 2))
        #expect(session.state.results?.map(\.won) == [40, 160, 0, 0])

        // Player 0 is paid the side pot the hand brought back cannot reach, and the Keep stays. Replacing it would
        // take the main pot from player 1, whose hand beat the one brought back.
        try session.replaceOperation(at: first, with: .showHoleCards(player: 0))
        #expect(session.state.results?.map(\.won) == [200, 0, 0, 0])
    }

    @Test("a replaced answer can take chips from another hand with a card down, and that answer is replaced too")
    func replacementTakesFromAnotherKeep() throws {
        var river = HandState(config: try HandConfig(
            mode: .cashGame, startingStacks: [200, 40, 200], blindsOrStraddles: [1, 2], minBet: 2
        ))
        for (index, card) in try Card.parse("8hThQd8sKsTc").enumerated() {
            river = try river.apply(.dealHole(player: index % 3, card: card))
        }
        for operation: HandOperation in [
            .betOrRaise(player: 2, to: 40), .checkOrCall(player: 0), .checkOrCall(player: 1),
            .burnCard(.unknown), .dealBoard(.known(.two, .hearts)), .dealBoard(.known(.nine, .spades)),
            .dealBoard(.known(.ten, .diamonds)), .betOrRaise(player: 0, to: 40), .checkOrCall(player: 2),
            .burnCard(.unknown), .dealBoard(.known(.three, .diamonds)),
            .checkOrCall(player: 0), .checkOrCall(player: 2),
            .burnCard(.unknown), .dealBoard(.known(.five, .spades)), .checkOrCall(player: 0), .checkOrCall(player: 2),
        ] {
            river = try river.apply(operation)
        }
        let first = river.operations.count

        // Player 1 shows only the ten. Player 2 cannot muck the side pot, so keeps both cards down.
        let session = TableSession(state: river)
        try session.apply(.muckHoleCards(player: 0))
        try session.apply(.showHoleCards(player: 1, cards: [.known(.ten, .hearts)]))
        try session.apply(.showHoleCards(player: 2, cards: []))
        #expect(session.state.results?.map(\.won) == [0, 120, 80])

        // The eights take the side pot from the Keep, and the tens with a queen then take the main pot from the
        // partial show, whose king is still down. Each replacement that takes chips calls for the next.
        try session.replaceOperation(at: first, with: .showHoleCards(player: 0))
        #expect(session.state.results?.map(\.won) == [80, 120, 0])
        try session.replaceOperation(at: first + 2, with: .showHoleCards(player: 2))
        #expect(session.state.results?.map(\.won) == [0, 0, 200])
        try session.replaceOperation(at: first + 1, with: .showHoleCards(player: 1))
        #expect(session.state.results?.map(\.won) == [0, 120, 80])
    }

    @Test("a show after the hand does not undo the Keep, so the Keep is the answer to replace")
    func showAfterTheKeep() throws {
        func keeps() -> [HandOperation] { (0..<3).map { .showHoleCards(player: $0, cards: []) } }
        var operations: [HandOperation] = try Card.parse("5sTs9h3d2d2c").enumerated().map { index, card in
            .dealHole(player: index % 3, card: card)
        }
        operations += [.betOrRaise(player: 2, to: 295), .checkOrCall(player: 0), .checkOrCall(player: 1)]
        operations += (0..<3).map { .selectRunoutCount(player: $0, count: nil) }
        operations += keeps()
        operations += [
            .burnCard(.unknown), .dealBoard(.known(.nine, .clubs)), .dealBoard(.known(.six, .clubs)),
            .dealBoard(.known(.six, .spades)),
        ]
        operations += keeps()
        operations += [.burnCard(.unknown), .dealBoard(.known(.nine, .diamonds))]
        operations += keeps()
        operations += [.burnCard(.unknown), .dealBoard(.known(.two, .spades))]
        let muck = operations.count
        let keep = muck + 2
        operations += [
            .muckHoleCards(player: 0), .muckHoleCards(player: 1), .showHoleCards(player: 2, cards: []),
            .showHoleCards(player: 2, cards: try Card.parse("9h2c")),
        ]
        let session = TableSession(state: try HandState.replay(
            config: HandConfig(
                mode: .cashGame, startingStacks: [182, 430, 295], blindsOrStraddles: [1, 2], minBet: 2
            ),
            operations: operations
        ))
        #expect(session.state.results?.map(\.won) == [0, 0, 772])
        #expect(session.state.results?[2].shown == true)

        // The show after the hand changes no chips, so the two pair beat the Keep, though the full house is face up.
        try session.replaceOperation(at: muck, with: .showHoleCards(player: 0))
        #expect(session.state.results?.map(\.won) == [546, 0, 226])
        #expect(session.state.results?[2].shown == true)
        try session.replaceOperation(at: keep, with: .showHoleCards(player: 2))
        #expect(session.state.results?.map(\.won) == [0, 0, 772])
    }

    @Test("a mucked hand keeps the isFaceUp it had, so a card shown before the muck stays up")
    func cardShownBeforeTheMuck() throws {
        var hand = try Self.allInOnTheFlop().apply(.showHoleCards(player: 0, cards: [.known(.king, .spades)]))
        for operation: HandOperation in [
            .showHoleCards(player: 1), .showHoleCards(player: 2),
            .burnCard(.unknown), .dealBoard(.known(.ten, .clubs)),
            .muckHoleCards(player: 0),
            .burnCard(.unknown), .dealBoard(.known(.three, .spades)),
        ] {
            hand = try hand.apply(operation)
        }
        #expect(hand.results?[0].status == .mucked)
        #expect(hand.results?[0].shown == false)
        #expect(hand.results?[0].holeCards.map(\.isFaceUp) == [true, false])
    }

    @Test("a fold pays the small blind and any antes to the big blind")
    func foldPaysTheBigBlind() throws {
        let hand = try Self.dealt(HandConfig(
            mode: .cashGame, startingStacks: [200, 200, 200, 200], antes: [1, 1, 1, 1], anteTrimming: true,
            blindsOrStraddles: [1, 2], minBet: 2
        )).apply(.fold(player: 2)).apply(.fold(player: 3)).apply(.fold(player: 0))
        #expect(hand.results?.map(\.won) == [0, 5, 0, 0])
        #expect(hand.results?.map(\.net) == [-2, 4, -1, -1])
    }

    @Test("a wrong stack or forced bet is corrected by replaying the operations on a corrected config")
    func wrongConfig() throws {
        // The app has 150 for a player with 170, so the all-in tops out short and is refused at the real amount.
        let low = try HandConfig(
            mode: .cashGame, startingStacks: [100, 150, 100], blindsOrStraddles: [1, 2], minBet: 2
        )
        var entered = try Self.dealt(low)
        entered = try entered.apply(.fold(player: 2)).apply(.checkOrCall(player: 0))
        #expect(entered.legalActions?.betOrRaise == .raise(4...150))
        #expect(throws: EngineError.betAboveMaximum(amount: 170, maximum: 150)) {
            try entered.apply(.betOrRaise(player: 1, to: 170))
        }

        // Neither tool reaches the config: undo reverses that correction, then takes back the call.
        let session = TableSession(state: entered)
        try session.replaceOperations(with: session.state.operations)
        #expect(session.state.config == low)
        session.undo()
        session.undo()
        #expect(session.state.config == low)
        try session.apply(.checkOrCall(player: 0))

        // A replay on a corrected config does, and undo and corrections carry on from it.
        let corrected = try HandConfig(
            mode: .cashGame, startingStacks: [100, 170, 100], blindsOrStraddles: [1, 2], minBet: 2
        )
        let replayed = TableSession(
            state: try HandState.replay(config: corrected, operations: session.state.operations)
        )
        try replayed.apply(.betOrRaise(player: 1, to: 170))
        #expect(replayed.state.bets == [2, 170, 0])
        replayed.undo()
        #expect(replayed.state.config == corrected)
        try replayed.replaceOperation(at: 7, with: .fold(player: 0))
        #expect(replayed.state.config == corrected)
        #expect(replayed.state.stacks == [99, 171, 100])

        // A straddle found after the deal fits. Found after the first action it throws like any correction.
        let straddled = try HandConfig(
            mode: .cashGame, startingStacks: [100, 100, 100, 100], blindsOrStraddles: [1, 2, 4], minBet: 2
        )
        let deal = try Self.dealt(HandConfig(
            mode: .cashGame, startingStacks: [100, 100, 100, 100], blindsOrStraddles: [1, 2], minBet: 2
        ))
        let late = try HandState.replay(config: straddled, operations: deal.operations)
        #expect(late.bets == [1, 2, 4, 0])
        #expect(late.actor == 3)
        #expect(late.toCall == 4)
        let tooLate = #expect(throws: ReplayError.self) {
            try HandState.replay(
                config: straddled, operations: deal.apply(.checkOrCall(player: 2)).operations
            )
        }
        #expect(tooLate?.error == .notYourTurn(player: 2, actor: 3))

        // A `to:` entered at the old stack stays as entered, so 20 of the loser's chips stay in front of them.
        var capped = HandState(config: try HandConfig(
            mode: .cashGame, startingStacks: [300, 150], blindsOrStraddles: [1, 2], minBet: 2
        ))
        for (index, card) in try Card.parse("AsKhKsQd").enumerated() {
            capped = try capped.apply(.dealHole(player: index % 2, card: card))
        }
        for operation: HandOperation in [
            .checkOrCall(player: 1), .checkOrCall(player: 0),
            .burnCard(.unknown), .dealBoard(.known(.two, .clubs)), .dealBoard(.known(.seven, .diamonds)),
            .dealBoard(.known(.nine, .hearts)), .checkOrCall(player: 0), .checkOrCall(player: 1),
            .burnCard(.unknown), .dealBoard(.known(.three, .hearts)),
            .checkOrCall(player: 0), .checkOrCall(player: 1),
            .burnCard(.unknown), .dealBoard(.known(.four, .diamonds)),
            .checkOrCall(player: 0), .betOrRaise(player: 1, to: 148), .checkOrCall(player: 0),
            .showHoleCards(player: 1), .showHoleCards(player: 0),
        ] {
            capped = try capped.apply(operation)
        }
        #expect(capped.stacks == [450, 0])
        let bigger = try HandConfig(
            mode: .cashGame, startingStacks: [300, 170], blindsOrStraddles: [1, 2], minBet: 2
        )
        let stale = try HandState.replay(config: bigger, operations: capped.operations)
        #expect(stale.stacks == [450, 20])
        var operations = capped.operations
        let allIn = try #require(operations.firstIndex(of: .betOrRaise(player: 1, to: 148)))
        operations[allIn] = .betOrRaise(player: 1, to: 168)
        #expect(try HandState.replay(config: bigger, operations: operations).stacks == [470, 0])
    }

    @Test("a correction after the stacks were carried adds the change in final stack, as copying again loses chips")
    func correctionAfterCarrying() throws {
        var hand = HandState(config: try HandConfig(
            mode: .cashGame, startingStacks: [100, 100], blindsOrStraddles: [1, 2], minBet: 2
        ))
        let seats = HandConfig.playerOrder(occupiedSeats: [3, 8], buttonSeat: 8)
        let misread = HandOperation.dealHole(player: 1, card: .known(.three, .diamonds))
        let operations: [HandOperation] = [
            .dealHole(player: 0, card: .known(.ace, .spades)), .dealHole(player: 1, card: .known(.ace, .diamonds)),
            .dealHole(player: 0, card: .known(.king, .spades)), misread,
            .checkOrCall(player: 1), .checkOrCall(player: 0),
            .burnCard(.unknown), .dealBoard(.known(.two, .clubs)), .dealBoard(.known(.seven, .diamonds)),
            .dealBoard(.known(.nine, .hearts)), .betOrRaise(player: 0, to: 20), .checkOrCall(player: 1),
            .burnCard(.unknown), .dealBoard(.known(.three, .hearts)), .checkOrCall(player: 0), .checkOrCall(player: 1),
            .burnCard(.unknown), .dealBoard(.known(.four, .diamonds)), .checkOrCall(player: 0), .checkOrCall(player: 1),
            .showHoleCards(player: 0), .showHoleCards(player: 1),
        ]
        for operation in operations {
            hand = try hand.apply(operation)
        }

        // The hand was carried to the seats, and a player then bought in for 50 more.
        var stacksBySeat = [Int: Int]()
        for (player, seat) in seats.enumerated() {
            stacksBySeat[seat] = hand.stacks[player]
        }
        stacksBySeat[3, default: 0] += 50

        // The correction changes who won.
        let index = try #require(operations.firstIndex(of: misread))
        let corrected = try hand.replacingOperation(
            at: index, with: .dealHole(player: 1, card: .known(.king, .clubs))
        )
        #expect(corrected.results?.map(\.net) == [0, 0])

        // Copying the stacks again loses the 50. Adding the change keeps it.
        var copied = stacksBySeat
        var added = stacksBySeat
        for (player, seat) in seats.enumerated() {
            copied[seat] = corrected.stacks[player]
            added[seat, default: 0] += corrected.stacks[player] - hand.stacks[player]
        }
        #expect(copied == [3: 100, 8: 100])
        #expect(added == [3: 150, 8: 100])

        // A later hand can leave a player less than the change takes away, and a config refuses what is left.
        for stack in [0, -22] {
            #expect(throws: ConfigError.nonPositiveStartingStack(player: 0)) {
                try HandConfig(mode: .cashGame, startingStacks: [stack, 100], blindsOrStraddles: [1, 2], minBet: 2)
            }
        }

        // A corrected config moves the final stack but not `net`, so a change in `net` would miss the 20.
        let short = try Self.dealt(HandConfig(
            mode: .cashGame, startingStacks: [100, 150, 100], blindsOrStraddles: [1, 2], minBet: 2
        )).apply(.fold(player: 2)).apply(.fold(player: 0))
        let full = try HandState.replay(
            config: HandConfig(mode: .cashGame, startingStacks: [100, 170, 100], blindsOrStraddles: [1, 2], minBet: 2),
            operations: short.operations
        )
        #expect(full.results?.map(\.net) == short.results?.map(\.net))
        #expect(zip(full.stacks, short.stacks).map(-) == [0, 20, 0])
    }

    @Test("a correction works a call out again but not a to:, so an all-in can stop being all in")
    func staleAllIn() throws {
        func played(allInOn street: Street) throws -> TableSession {
            let session = TableSession(config: try Self.headsUp())
            for (index, card) in try Card.parse("AsKsAdKd").enumerated() {
                try session.apply(.dealHole(player: index % 2, card: card))
            }
            try session.apply(.checkOrCall(player: 1))
            try session.apply(.checkOrCall(player: 0))
            try session.apply(.burnCard(.unknown))
            for card in try Card.parse("2c3c4c") {
                try session.apply(.dealBoard(card))
            }
            try session.apply(.betOrRaise(player: 0, to: 30))
            try session.apply(.checkOrCall(player: 1))
            try session.apply(.burnCard(.unknown))
            try session.apply(.dealBoard(.known(.five, .diamonds)))
            if street == .turn {
                try session.apply(.betOrRaise(player: 0, to: try #require(session.state.maxRaiseTo)))
                try session.apply(.checkOrCall(player: 1))
                try session.apply(.selectRunoutCount(player: 0, count: nil))
                try session.apply(.selectRunoutCount(player: 1, count: nil))
                try session.apply(.showHoleCards(player: 0))
                try session.apply(.showHoleCards(player: 1))
                try session.apply(.burnCard(.unknown))
                try session.apply(.dealBoard(.known(.nine, .hearts)))
            } else {
                try session.apply(.checkOrCall(player: 0))
                try session.apply(.checkOrCall(player: 1))
                try session.apply(.burnCard(.unknown))
                try session.apply(.dealBoard(.known(.nine, .hearts)))
                try session.apply(.betOrRaise(player: 0, to: try #require(session.state.maxRaiseTo)))
                try session.apply(.checkOrCall(player: 1))
                try session.apply(.showHoleCards(player: 0))
                try session.apply(.muckHoleCards(player: 1))
            }
            return session
        }

        // The flop bet was entered as 30 and was really 20, and the river all-in was the player's last 68.
        let session = try played(allInOn: .river)
        #expect(session.state.stacks == [200, 0])
        let flopBet = try #require(session.state.operations.firstIndex(of: .betOrRaise(player: 0, to: 30)))
        let allIn = try #require(session.state.operations.firstIndex(of: .betOrRaise(player: 0, to: 68)))
        try session.replaceOperation(at: flopBet, with: .betOrRaise(player: 0, to: 20))
        #expect(session.state.isHandComplete)
        #expect(session.state.stacks == [190, 10])
        try session.replaceOperation(at: allIn, with: .betOrRaise(player: 0, to: 78))
        #expect(session.state.stacks == [200, 0])

        // Before the river a finished hand's later entries stop fitting, so the same stale number is refused.
        let turn = try played(allInOn: .turn)
        let turnBet = try #require(turn.state.operations.firstIndex(of: .betOrRaise(player: 0, to: 30)))
        let refusal = #expect(throws: ReplayError.self) {
            try turn.replaceOperation(at: turnBet, with: .betOrRaise(player: 0, to: 20))
        }
        #expect(refusal?.error == .noRunoutSelectionExpected(player: 0))

        // With nothing entered after it, nothing refuses it, and the hand deals on with chips behind.
        let call = try #require(turn.state.operations.firstIndex(of: .selectRunoutCount(player: 0, count: nil)))
        try turn.replaceOperations(with: Array(turn.state.operations[..<call]))
        #expect(turn.state.pendingOperation == .showdown(runoutSelectors: [0, 1], showOrder: [0, 1]))
        try turn.replaceOperation(at: turnBet, with: .betOrRaise(player: 0, to: 20))
        #expect(turn.state.pendingOperation == .burnCard(street: .river, runout: 0))
        #expect(turn.state.stacks == [10, 10])
    }
}
