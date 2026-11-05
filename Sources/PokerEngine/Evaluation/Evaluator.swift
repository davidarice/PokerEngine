internal import CHandEvaluator

/// High-hand evaluation on top of the vendored PokerHandEvaluator (PHE). The only file that sees C.
///
/// PokerKit's `StandardHighHand.from_game` takes the best five of all the cards it is given; PHE's six- and
/// seven-card functions compute exactly that class, so one call replaces PokerKit's combination loop. Omaha's
/// `OmahaHoldemHand.from_game` ranks every pair of hole cards with every three board cards, at most 60 five-card
/// hands, which the five-card function ranks without PHE's 130 MB of Omaha tables.
enum Evaluator {
    /// Number of distinct five-card high-hand classes. PHE numbers them 1 (best) … 7462 (worst).
    static let classCount = 7_462

    /// PHE's card id, rank * 4 + suit. This is also the card's index in PokerKit's `Deck.STANDARD`.
    static func id(_ rank: Rank, _ suit: Suit) -> Int32 {
        Int32(rank.rawValue * 4 + suit.rawValue)
    }

    /// Strength of five distinct card ids, 0 (weakest) … 7461, equal to PokerKit's lookup entry index.
    static func strength(_ a: Int32, _ b: Int32, _ c: Int32, _ d: Int32, _ e: Int32) -> Int {
        classCount - Int(evaluate_5cards(a, b, c, d, e))
    }

    /// The best five-card hand among five to seven distinct known cards, or nil when there are fewer than five
    /// cards or any is unknown (PokerKit cannot evaluate an unknown card either).
    ///
    /// Ties keep the first combination in `itertools.combinations` order, as PokerKit's `from_game` does, so
    /// `HandRank.cards` matches PokerKit's `Hand.cards`.
    static func bestHand(_ cards: [Card]) -> HandRank? {
        guard cards.count >= 5 else { return nil }
        var ids = [Int32]()
        for card in cards {
            guard case let .known(rank, suit) = card else { return nil }
            ids.append(id(rank, suit))
        }
        // PHE reads past its tables for repeated cards; callers reject duplicates before evaluating.
        precondition(Set(ids).count == ids.count, "duplicate cards cannot be evaluated")

        let best: Int
        switch ids.count {
        case 5: best = strength(ids[0], ids[1], ids[2], ids[3], ids[4])
        case 6: best = classCount - Int(evaluate_6cards(ids[0], ids[1], ids[2], ids[3], ids[4], ids[5]))
        case 7: best = classCount - Int(evaluate_7cards(ids[0], ids[1], ids[2], ids[3], ids[4], ids[5], ids[6]))
        default: preconditionFailure("a hold'em hand has at most seven cards")
        }
        return HandRank(strength: best, cards: firstFiveCardCombination(of: cards, ids: ids, strength: best))
    }

    /// The best Omaha hand: exactly two of `hole` with exactly three of `board`. Nil with fewer than two hole cards or
    /// three board cards, or when any card is unknown (callers leave out unknown hole cards, as PokerKit does).
    ///
    /// Pairs of hole cards go in the outer loop and board triples in the inner one, each in `itertools.combinations`
    /// order, and a tie keeps the first, so `HandRank.cards` matches PokerKit's `Hand.cards`: the two hole cards, then
    /// the three board cards.
    static func bestOmahaHand(hole: [Card], board: [Card]) -> HandRank? {
        guard hole.count >= 2, board.count >= 3, let holeIDs = ids(of: hole), let boardIDs = ids(of: board) else {
            return nil
        }
        precondition(Set(holeIDs + boardIDs).count == hole.count + board.count, "duplicate cards cannot be evaluated")
        var best: (strength: Int, cards: [Card])?
        for a in holeIDs.indices { for b in (a + 1)..<holeIDs.count {
            for c in boardIDs.indices { for d in (c + 1)..<boardIDs.count { for e in (d + 1)..<boardIDs.count {
                let value = strength(holeIDs[a], holeIDs[b], boardIDs[c], boardIDs[d], boardIDs[e])
                if value > best?.strength ?? -1 {
                    best = (value, [hole[a], hole[b], board[c], board[d], board[e]])
                }
            } } }
        } }
        return best.map { HandRank(strength: $0.strength, cards: $0.cards) }
    }

    /// PHE's ids for the cards, or nil if any is unknown.
    private static func ids(of cards: [Card]) -> [Int32]? {
        var ids = [Int32]()
        for card in cards {
            guard case let .known(rank, suit) = card else { return nil }
            ids.append(id(rank, suit))
        }
        return ids
    }

    private static func firstFiveCardCombination(of cards: [Card], ids: [Int32], strength best: Int) -> [Card] {
        let count = ids.count
        for a in 0..<count { for b in (a + 1)..<count { for c in (b + 1)..<count { for d in (c + 1)..<count {
            for e in (d + 1)..<count where strength(ids[a], ids[b], ids[c], ids[d], ids[e]) == best {
                return [cards[a], cards[b], cards[c], cards[d], cards[e]]
            }
        } } } }
        preconditionFailure("the best class always comes from some five-card combination")
    }
}
