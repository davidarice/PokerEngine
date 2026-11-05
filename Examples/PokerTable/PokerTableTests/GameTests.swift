import PokerEngine
import Testing
@testable import PokerTable

/// SplitMix64, so that a failing hand comes back on the next run.
private struct SeededGenerator: RandomNumberGenerator {
    var state: UInt64

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var mixed = state
        mixed = (mixed ^ (mixed >> 30)) &* 0xBF58_476D_1CE4_E5B9
        mixed = (mixed ^ (mixed >> 27)) &* 0x94D0_49BB_1331_11EB
        return mixed ^ (mixed >> 31)
    }
}

/// What a dealer might enter next, from the buttons the action bar would offer. Empty would strand the dealer.
private func dealerChoices(in hand: HandState, deck: Deck) -> [HandOperation] {
    switch hand.pendingOperation {
    case .act:
        guard let actions = hand.legalActions else { return [] }
        let player = actions.player
        var choices: [HandOperation] = [.checkOrCall(player: player)]
        if actions.canFold, actions.toCall > 0 {
            choices.append(.fold(player: player))
        }
        if let amounts = actions.betOrRaise.amounts {
            choices.append(.betOrRaise(player: player, to: amounts.lowerBound))
            choices.append(.betOrRaise(player: player, to: amounts.upperBound))
        }
        return choices
    case let .showdown(selectors, _) where !selectors.isEmpty:
        return deck.runCounts(for: hand).map { .selectRunoutCount(player: selectors[0], count: $0) }
    case let .showdown(_, order):
        let player = order[0]
        let keep = hand.holeCards[player].filter(\.isFaceUp).map(\.card)
        return [
            HandOperation.showHoleCards(player: player), .showHoleCards(player: player, cards: keep),
            .muckHoleCards(player: player),
        ].filter(hand.canApply)
    default:
        return []
    }
}

@Suite("The deck")
struct DeckTests {
    @Test("it holds every card once, and a card the camera missed comes after that")
    func everyCardOnce() {
        var generator = SeededGenerator(state: 1)
        var deck = Deck(using: &generator)
        let cards = (0..<52).map { _ in deck.next() }
        #expect(Set(cards).count == 52)
        #expect(!cards.contains(.unknown))
        #expect(deck.next() == .unknown)
    }

    @Test("it enters only cards, so every decision is the dealer's, and no hand strands the dealer",
          arguments: HandConfig.Variant.allCases)
    func onlyCards(variant: HandConfig.Variant) throws {
        var generator = SeededGenerator(state: 2)
        var (allIns, sidePots, secondRuns) = (0, 0, 0)
        for _ in 0..<3000 {
            let count = Int.random(in: 2...10, using: &generator)
            let config = try HandConfig(
                variant: variant,
                mode: .cashGame,
                startingStacks: (0..<count).map { _ in Int.random(in: 1...300, using: &generator) },
                blindsOrStraddles: [1, 2],
                minBet: 2
            )
            var deck = Deck(using: &generator)
            var hand = HandState(config: config)
            var mostPots = 0
            while !hand.isHandComplete {
                if let card = deck.nextCard(for: hand) {
                    switch card {
                    case .burnCard, .dealHole, .dealBoard: break
                    default: Issue.record("The deck entered \(card)")
                    }
                    hand = try hand.apply(card)
                } else {
                    let choice = try #require(dealerChoices(in: hand, deck: deck).randomElement(using: &generator))
                    hand = try hand.apply(choice)
                }
                mostPots = max(mostPots, hand.pots.count)
            }
            #expect(hand.stacks.reduce(0, +) == config.startingStacks.reduce(0, +))
            #expect(!hand.boards.joined().contains(.unknown))
            allIns += hand.stacks.contains(0) ? 1 : 0
            sidePots += mostPots > 1 ? 1 : 0
            secondRuns += hand.runoutCount > 1 ? 1 : 0
        }
        #expect(allIns > 100)
        #expect(sidePots > 100)
        #expect(secondRuns > 10)
    }
}

@Suite("The table")
@MainActor
struct GameTests {
    /// Every player bets their whole stack or calls, and shows.
    private func playAllIn(_ game: Game) {
        while let player = game.playerToAnswer, let hand = game.session?.state {
            switch hand.pendingOperation {
            case .act:
                if let top = hand.legalActions?.betOrRaise.amounts?.upperBound {
                    game.enter(.betOrRaise(player: player, to: top))
                } else {
                    game.enter(.checkOrCall(player: player))
                }
            case let .showdown(selectors, _) where !selectors.isEmpty:
                game.enter(.selectRunoutCount(player: player, count: nil))
            default:
                game.enter(.showHoleCards(player: player))
            }
        }
    }

    @Test("a deal stops at the first decision, and later cards arrive by themselves")
    func cardsArriveByThemselves() throws {
        let game = Game()
        game.deal()
        let session = try #require(game.session)
        #expect(session.state.operations.count == 6)
        #expect(session.state.pendingOperation == .act(player: 2))
        #expect(game.playerToAnswer == 2)

        game.enter(.checkOrCall(player: 2))
        game.enter(.checkOrCall(player: 0))
        #expect(session.state.boards[0].isEmpty)
        game.enter(.checkOrCall(player: 1))
        #expect(session.state.boards[0].count == 3)
        #expect(session.state.pendingOperation == .act(player: 0))
    }

    @Test("a refused entry changes nothing and says why")
    func refusal() throws {
        let game = Game()
        game.deal()
        let session = try #require(game.session)
        let before = session.state
        game.enter(.fold(player: 0))
        #expect(session.state == before)
        #expect(game.alert == EngineError.notYourTurn(player: 0, actor: 2).message(naming: game.name(of:)))
    }

    @Test("bots fill the table up to ten seats, and at least two stay")
    func addingAndRemoving() {
        let game = Game()
        #expect(game.seats.map(\.id) == [0, 1, 2])
        for _ in 0..<20 {
            game.addBot()
        }
        #expect(game.seats.map(\.id) == Array(0..<10))

        game.remove(game.seats[4])
        #expect(game.seats.map(\.id) == [0, 1, 2, 3, 5, 6, 7, 8, 9])
        game.addBot()
        #expect(game.seats[4].id == 4)

        for _ in 0..<20 {
            game.remove(game.seats[0])
        }
        #expect(game.seats.count == 2)
    }

    @Test("seats cannot change during a hand")
    func seatsAreFixedInAHand() {
        let game = Game()
        game.deal()
        game.addBot()
        game.remove(game.seats[1])
        #expect(game.seats.count == 3)

        game.enter(.voidHand)
        game.addBot()
        #expect(game.seats.count == 4)
    }

    @Test("the button moves round the occupied seats, after a chop too")
    func button() {
        let game = Game()
        var buttons = [Int?]()
        for _ in 0..<4 {
            game.deal()
            buttons.append(game.players.last)
            // The button acts first, three-handed, and folds to the blinds, who chop.
            game.enter(.fold(player: 2))
            game.enter(.chopBlinds)
            #expect(game.summary == "The blinds chopped.")
        }
        #expect(buttons == [0, 1, 2, 0])
        #expect(game.handNumber == 4)
        #expect(game.seats.map(\.stack) == [200, 200, 200])
    }

    @Test("a void gives every chip back, and the redeal keeps the button")
    func voiding() {
        let game = Game()
        game.deal()
        game.enter(.fold(player: 2))
        game.enter(.chopBlinds)
        game.deal()
        #expect(game.players.last == 1)
        game.enter(.checkOrCall(player: 2))
        #expect(game.session?.state.totalPot == 5)
        game.enter(.voidHand)
        #expect(game.isBetweenHands)
        #expect(game.summary == "Hand voided: every chip went back.")
        #expect(game.seats.map(\.stack) == [200, 200, 200])
        game.deal()
        #expect(game.players.last == 1)
    }

    @Test("a finished hand's stacks go back to the seats, and a player out of chips buys back in")
    func stacksAndRebuys() {
        let game = Game()
        while !game.seats.contains(where: { $0.stack == 0 }) {
            game.deal()
            playAllIn(game)
            #expect(game.isBetweenHands)
            #expect(game.seats.map(\.stack).reduce(0, +) == 600)
        }
        game.deal()
        #expect(game.seats.allSatisfy { $0.stack > 0 })
    }

    @Test("a starting stack entered wrong is corrected mid-hand, and any cards that brings arrive by themselves")
    func correctingAStack() throws {
        let game = Game()
        game.deal()
        let session = try #require(game.session)
        game.enter(.betOrRaise(player: 2, to: 150))
        game.enter(.checkOrCall(player: 0))
        game.enter(.checkOrCall(player: 1))
        game.enter(.checkOrCall(player: 0))
        game.enter(.checkOrCall(player: 1))
        #expect(session.state.pendingOperation == .act(player: 2))
        #expect(session.state.boards[0].count == 3)

        // Player 2 really started with 150, so the raise was all in, and the flop's betting is over.
        #expect(game.correctStartingStack(of: 2, to: 150) == nil)
        #expect(session.state.config.startingStacks == [200, 200, 150])
        #expect(session.state.stacks[2] == 0)
        #expect(session.state.boards[0].count == 4)
        #expect(session.state.pendingOperation == .act(player: 0))
    }

    @Test("a correction the hand cannot take changes nothing and says why")
    func refusedCorrection() throws {
        let game = Game()
        game.deal()
        let session = try #require(game.session)
        game.enter(.betOrRaise(player: 2, to: 150))
        let before = session.state
        let refusal = game.correctStartingStack(of: 2, to: 100)
        #expect(refusal == EngineError.betAboveMaximum(amount: 150, maximum: 100).message(naming: game.name(of:)))
        #expect(game.correctStartingStack(of: 2, to: 0) != nil)
        #expect(session.state == before)
    }

    @Test("a new big blind starts with the next hand, with half of it as the small blind and it as the minimum bet")
    func stakes() throws {
        let game = Game()
        game.deal()
        game.bigBlind = 10
        #expect(game.session?.state.config.blindsOrStraddles == [1, 2, 0])
        game.enter(.voidHand)
        game.deal()
        let config = try #require(game.session?.state.config)
        #expect(config.blindsOrStraddles == [5, 10, 0])
        #expect(config.minBet == 10)
    }

    @Test("the game setting deals Pot-Limit Omaha: four hole cards each, and no raise above the pot")
    func omaha() throws {
        let game = Game()
        game.variant = .potLimitOmahaHoldem
        game.deal()
        let hand = try #require(game.session?.state)
        #expect(hand.config.variant == .potLimitOmahaHoldem)
        #expect(hand.holeCards.map(\.count) == [4, 4, 4])
        #expect(hand.legalActions?.betOrRaise == .raise(4...7))
    }

    @Test("only run counts the deck can deal are offered: ten Omaha players all in before the flop get one run")
    func runCountsThatFit() throws {
        let game = Game()
        game.variant = .potLimitOmahaHoldem
        while game.seats.count < Game.maximumSeats {
            game.addBot()
        }
        game.deal()
        while case let .act(player)? = game.session?.state.pendingOperation {
            let top = game.session?.state.legalActions?.betOrRaise.amounts?.upperBound
            game.enter(top.map { .betOrRaise(player: player, to: $0) } ?? .checkOrCall(player: player))
        }
        let hand = try #require(game.session?.state)
        #expect(hand.stacks.allSatisfy { $0 == 0 })
        guard case let .showdown(selectors, _)? = hand.pendingOperation else {
            Issue.record("No showdown: \(String(describing: hand.pendingOperation))")
            return
        }
        #expect(selectors == Array(0..<10))
        // 40 hole cards leave 12, and each run from the flop takes 8.
        #expect(game.runCounts == [nil, 1])
    }

    @Test("the hand log ranks every hand still in at the end, a beaten one included")
    func finalHands() throws {
        let game = Game()
        var beaten: PlayerResult?
        for _ in 0..<20 where beaten == nil {
            game.deal()
            playAllIn(game)
            beaten = game.session?.state.results?.first { $0.status == .killed }
        }
        let hand = try #require(game.session?.state)
        let player = try #require(beaten).player
        let rank = try #require(hand.dealtHand(of: player))
        #expect(game.finalHands.contains("\(game.name(of: player)): \(rank) · shown · beaten"))
        #expect(game.finalHands.count == hand.results?.filter { $0.status != .folded }.count)
    }
}
