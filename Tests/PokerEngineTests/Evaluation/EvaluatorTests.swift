import CryptoKit
import Foundation
import Testing
@testable import PokerEngine

@Suite("Hand evaluation")
struct EvaluatorTests {
    /// Card ids in PokerKit's `Deck.STANDARD` order, which is also PHE's id order.
    private static let ids = (0..<52).map(Int32.init)

    /// Calls `body` for every five-card combination in `itertools.combinations` order.
    private static func forEachFiveCardHand(_ body: (Int32, Int32, Int32, Int32, Int32) -> Void) {
        for a in 0..<48 { for b in (a + 1)..<49 { for c in (b + 1)..<50 { for d in (c + 1)..<51 { for e in (d + 1)..<52 {
            body(ids[a], ids[b], ids[c], ids[d], ids[e])
        } } } } }
    }

    @Test("every five-card hand lands in its standard category, and all 7462 classes occur")
    func exhaustiveFiveCardCounts() {
        var hands = [HandCategory: Int]()
        var strengths = Set<Int>()
        Self.forEachFiveCardHand { a, b, c, d, e in
            let strength = Evaluator.strength(a, b, c, d, e)
            hands[HandCategory(strength: strength), default: 0] += 1
            strengths.insert(strength)
        }
        #expect(hands == [
            .straightFlush: 40, .fourOfAKind: 624, .fullHouse: 3_744, .flush: 5_108, .straight: 10_200,
            .threeOfAKind: 54_912, .twoPair: 123_552, .onePair: 1_098_240, .highCard: 1_302_540,
        ])
        #expect(strengths == Set(0..<7_462))
    }

    /// Port of pokerkit/tests/test_lookups.py `StandardLookupTestCase.test_get_entry`: a stable sort of all
    /// combinations by lookup entry, serialized as card reprs joined by newlines, has a fixed MD5. That pins the
    /// order of every five-card hand. The sort alone cannot see where one class ends and the next begins, so the
    /// number of hands in each class is pinned too (digest computed with PokerKit 0.7.7); together they prove
    /// `strength` equals PokerKit's entry index for every hand.
    @Test("orders all 2,598,960 five-card hands exactly as PokerKit's StandardLookup")
    func matchesPokerKitLookupOrder() {
        var strengths = [Int]()
        strengths.reserveCapacity(2_598_960)
        var bucketSizes = [Int](repeating: 0, count: 7_462)
        Self.forEachFiveCardHand { a, b, c, d, e in
            let strength = Evaluator.strength(a, b, c, d, e)
            strengths.append(strength)
            bucketSizes[strength] += 1
        }

        // Counting sort keeps each bucket in enumeration order, as Python's stable sort does.
        var nextSlot = [Int](repeating: 0, count: 7_462)
        for strength in 1..<7_462 { nextSlot[strength] = nextSlot[strength - 1] + bucketSizes[strength - 1] }
        let names = Card.standardDeck.map { Array($0.description.utf8) }
        let lineLength = 11
        var text = [UInt8](repeating: UInt8(ascii: "\n"), count: strengths.count * lineLength)
        var handIndex = 0
        Self.forEachFiveCardHand { a, b, c, d, e in
            var offset = nextSlot[strengths[handIndex]] * lineLength
            nextSlot[strengths[handIndex]] += 1
            handIndex += 1
            for id in [a, b, c, d, e] {
                text[offset] = names[Int(id)][0]
                text[offset + 1] = names[Int(id)][1]
                offset += 2
            }
        }
        text.removeLast()   // the serialization has no trailing newline

        #expect(md5(text) == "488cdd27873395ba75205cd02fb9d6b2")
        #expect(md5(Array(bucketSizes.map(String.init).joined(separator: ",").utf8)) == "b1222f6e56bc13a622a7ffe3a06fc37a")
    }

    private func md5(_ bytes: [UInt8]) -> String {
        Insecure.MD5.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
    }

    @Test("six- and seven-card hands rank as their best five-card subset")
    func ranksBestFiveCardSubset() throws {
        var generator = SplitMix64(seed: 2026)
        for _ in 0..<5_000 {
            for count in [6, 7] {
                let cards = Array(Card.standardDeck.shuffled(using: &generator).prefix(count))
                let rank = try #require(Evaluator.bestHand(cards))
                let subsets = fiveCardSubsets(of: cards)
                let subsetStrengths = subsets.compactMap { Evaluator.bestHand($0)?.strength }
                #expect(subsetStrengths.count == subsets.count)
                #expect(rank.strength == subsetStrengths.max())
                // PokerKit keeps the first best combination, in its own order.
                #expect(rank.cards == subsets.first { Evaluator.bestHand($0)?.strength == rank.strength })
            }
        }
    }

    @Test("agrees with PokerKit's StandardHighHand on sampled 5-, 6- and 7-card hands")
    func matchesPokerKitSamples() throws {
        struct Samples: Decodable {
            struct Sample: Decodable { let cards: String; let strength: Int; let label: String; let best: String }
            let pokerkit: String
            let samples: [Sample]
        }
        let fixture = try JSONDecoder().decode(Samples.self, from: Fixtures.data("evaluator/pokerkit-samples.json"))
        #expect(fixture.pokerkit == "0.7.7")
        #expect(fixture.samples.count >= 3_000)
        for sample in fixture.samples {
            let rank = try #require(Evaluator.bestHand(try Card.parse(sample.cards)))
            #expect(rank.strength == sample.strength, "\(sample.cards)")
            #expect(rank.category.label == sample.label, "\(sample.cards)")
            #expect(rank.cards.map(\.description).joined() == sample.best, "\(sample.cards)")
        }
    }

    @Test("hands with fewer than five cards or an unknown card have no rank")
    func incompleteHandsHaveNoRank() throws {
        #expect(Evaluator.bestHand(try Card.parse("AsKsQsJs")) == nil)
        #expect(Evaluator.bestHand(try Card.parse("AsKsQsJs??")) == nil)
        #expect(Evaluator.bestHand([]) == nil)
    }

    @Test("ranks compare by strength and describe themselves with PokerKit's label and chosen cards")
    func comparesAndDescribes() throws {
        let trips = try #require(Evaluator.bestHand(try Card.parse("KsKhKdJc8d4c2s")))
        #expect(trips.description == "Three of a kind (KsKhKdJc8d)")
        let royal = try #require(Evaluator.bestHand(try Card.parse("2c3dAsKsQsJsTs")))
        #expect(royal.description == "Straight flush (AsKsQsJsTs)")
        #expect(royal.strength == 7_461)
        let worst = try #require(Evaluator.bestHand(try Card.parse("7c5d4h3s2c")))
        #expect(worst.category == .highCard)
        #expect(worst.strength == 0)
        let wheel = try #require(Evaluator.bestHand(try Card.parse("5c4d3h2sAc")))
        let sixHighStraight = try #require(Evaluator.bestHand(try Card.parse("6c5d4h3s2c")))
        #expect(wheel.category == .straight)
        #expect(wheel < sixHighStraight)
        #expect(worst < trips && trips < royal)
        // Suits never break ties, so equal-strength hands are equal ranks: they hash alike, and neither is less.
        let otherTrips = try #require(Evaluator.bestHand(try Card.parse("KcKhKdJs8h")))
        #expect(trips == otherTrips)
        #expect(trips.hashValue == otherTrips.hashValue)
        #expect(!(trips < otherTrips) && !(otherTrips < trips))
    }

    @Test("keeps PokerKit's chosen five cards, in combination order, when several combinations tie")
    func keepsFirstBestCombination() throws {
        // PokerKit's own Hand.cards doctest, and two hands with more than one best combination.
        let expectations = [
            "AsAcKh3sAdAh": "Four of a kind (AsAcKhAdAh)",
            "5c5d6h7s8c9d": "Straight (5c6h7s8c9d)",
            "AcAdKhKsQcQdJh": "Two pair (AcAdKhKsQc)",
        ]
        for (cards, description) in expectations {
            #expect(Evaluator.bestHand(try Card.parse(cards))?.description == description)
        }
    }

    // MARK: Omaha

    @Test("agrees with PokerKit's OmahaHoldemHand on sampled deals, with no hand below two hole cards")
    func matchesPokerKitOmahaSamples() throws {
        struct Samples: Decodable {
            struct Sample: Decodable { let hole: String; let board: String; let strength: Int?; let best: String? }
            let omahaSamples: [Sample]
        }
        let fixture = try JSONDecoder().decode(Samples.self, from: Fixtures.data("evaluator/pokerkit-samples.json"))
        #expect(fixture.omahaSamples.count >= 2_000)
        #expect(fixture.omahaSamples.contains { $0.best == nil })
        for sample in fixture.omahaSamples {
            let rank = Evaluator.bestOmahaHand(hole: try Card.parse(sample.hole), board: try Card.parse(sample.board))
            #expect(rank?.strength == sample.strength, "\(sample.hole) on \(sample.board)")
            #expect(rank?.description == sample.best, "\(sample.hole) on \(sample.board)")
        }
    }

    @Test("an Omaha hand is exactly two hole cards and three board cards, the first best in PokerKit's order")
    func omahaUsesTwoAndThree() throws {
        // Each answer is PokerKit's OmahaHoldemHand.from_game. Four aces make one pair, one spade makes no flush, and
        // trips on the board still need two hole cards; the last four are PokerKit's own doctests.
        let expectations = [
            ("AsAhAdAc", "2s7s9sTs3h", "One pair (AsAh7s9sTs)"),
            ("AsKd8c2h", "Qs7s9sTs3h", "High card (AsKdQs9sTs)"),
            ("AsKs8c2h", "Qs7s9sTd3h", "Flush (AsKsQs7s9s)"),
            ("2c3d4h5s", "KsKhKdQc7d", "Three of a kind (4h5sKsKhKd)"),
            ("6c7c8c9c", "8s9sTc", "Straight (6c7c8s9sTc)"),
            ("6c7c8s9s", "8c9cTc", "Straight flush (6c7c8c9cTc)"),
            ("6c7c8c9c", "8s9sTc9hKs", "Full house (8c9c8s9s9h)"),
            ("6c7c8sAh", "As9cTc2sKs", "One pair (8sAhAsTcKs)"),
        ]
        for (hole, board, description) in expectations {
            #expect(Evaluator.bestOmahaHand(hole: try Card.parse(hole), board: try Card.parse(board))?.description
                == description)
        }
    }

    @Test("an Omaha hand needs two known hole cards, three board cards and no unknown board card")
    func incompleteOmahaHandsHaveNoRank() throws {
        #expect(Evaluator.bestOmahaHand(hole: try Card.parse("As"), board: try Card.parse("2c7d9hTd3s")) == nil)
        #expect(Evaluator.bestOmahaHand(hole: try Card.parse("AsAhKsKh"), board: try Card.parse("2c7d")) == nil)
        #expect(Evaluator.bestOmahaHand(hole: try Card.parse("AsAhKsKh"), board: try Card.parse("2c7d??Td3s")) == nil)
        #expect(Evaluator.bestOmahaHand(hole: try Card.parse("AsAh"), board: try Card.parse("2c7d9h"))?.description
            == "One pair (AsAh2c7d9h)")
    }

    @Test("encodes a rank as its category and cards, and rejects JSON that does not describe a real hand")
    func codesRankFromItsCards() throws {
        let trips = try #require(Evaluator.bestHand(try Card.parse("KsKhKdJc8d")))
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        let data = try encoder.encode(trips)
        #expect(String(decoding: data, as: UTF8.self) == #"{"cards":["Ks","Kh","Kd","Jc","8d"],"category":3}"#)
        let decoded = try JSONDecoder().decode(HandRank.self, from: data)
        #expect(decoded == trips)
        #expect(decoded.cards == trips.cards)
        let forgeries = [
            #"{"category":8,"cards":[]}"#,
            #"{"category":0,"cards":["Ks","Kh","Kd","Jc","8d"]}"#,
            #"{"category":3,"cards":["Ks","Ks","Kd","Jc","8d"]}"#,
            #"{"category":3,"cards":["??","Kh","Kd","Jc","8d"]}"#,
            #"{"category":3,"cards":["Ks","Kh","Kd","Jc","8d","2c"]}"#,
        ]
        for forgery in forgeries {
            #expect(throws: DecodingError.self, "\(forgery)") {
                try JSONDecoder().decode(HandRank.self, from: Data(forgery.utf8))
            }
        }
    }

    private func fiveCardSubsets(of cards: [Card]) -> [[Card]] {
        var subsets = [[Card]]()
        func extend(_ start: Int, _ chosen: [Card]) {
            if chosen.count == 5 { subsets.append(chosen); return }
            for index in start..<cards.count { extend(index + 1, chosen + [cards[index]]) }
        }
        extend(0, [])
        return subsets
    }
}
