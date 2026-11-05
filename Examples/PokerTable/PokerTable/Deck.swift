import PokerEngine

/// Stands in for the camera: a shuffled deck that supplies each card as the hand asks for it.
struct Deck {
    private var cards: [Card]

    init(using generator: inout some RandomNumberGenerator) {
        cards = Rank.allCases
            .flatMap { rank in Suit.allCases.map { Card.known(rank, $0) } }
            .shuffled(using: &generator)
    }

    /// `.unknown`, a card the camera missed, only once the deck is empty, which `runCounts(for:)` keeps from
    /// happening.
    mutating func next() -> Card {
        cards.popLast() ?? .unknown
    }

    /// The run counts the cards left can deal, from no preference up to three runs. Each run takes a burn and the board
    /// cards of every street still to come, up to eight cards, and ten Omaha players leave only four after one run.
    func runCounts(for hand: HandState) -> [Int?] {
        let boardCards = hand.boards[0].count
        let cardsPerRun = 5 - boardCards + [0: 3, 3: 2, 4: 1][boardCards, default: 0]
        return [nil, 1, 2, 3].filter { ($0 ?? 1) * cardsPerRun <= cards.count }
    }

    /// The card `hand` is waiting for, as the operation the camera would enter. Nil when it is waiting for the dealer.
    mutating func nextCard(for hand: HandState) -> HandOperation? {
        switch hand.pendingOperation {
        case .burnCard:
            .burnCard(next())
        case let .dealHoleCard(player, _):
            .dealHole(player: player, card: next())
        case .dealBoardCard:
            .dealBoard(next())
        default:
            nil
        }
    }
}
