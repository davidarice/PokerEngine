import Foundation
import Testing
@testable import PokerEngine

@Suite("Cards")
struct CardTests {
    @Test("parses PokerKit's card grammar")
    func parsesPokerKitGrammar() throws {
        let aceOfSpades = Card(.ace, .spades)
        let kingOfSpades = Card(.king, .spades)
        #expect(try Card.parse("As") == [aceOfSpades])
        #expect(try Card.parse("AsKs") == [aceOfSpades, kingOfSpades])
        #expect(try Card.parse("As Ks") == [aceOfSpades, kingOfSpades])
        #expect(try Card.parse("2c, 8d, 5s, Kh") == [Card(.two, .clubs), Card(.eight, .diamonds), Card(.five, .spades), Card(.king, .hearts)])
        // Commas are dropped wherever they are, even inside a card.
        #expect(try Card.parse("A,s") == [aceOfSpades])
        #expect(try Card.parse("10h") == [Card(.ten, .hearts)])
        #expect(try Card.parse("??As") == [.unknown, aceOfSpades])
        #expect(try Card.parse("") == [])
    }

    @Test("rejects malformed card strings, case-sensitively like PokerKit")
    func rejectsMalformedStrings() {
        #expect(throws: CardParseError.oddLength("AsK")) { try Card.parse("AsK") }
        #expect(throws: CardParseError.invalidRank("1")) { try Card.parse("1s") }
        #expect(throws: CardParseError.invalidSuit("x")) { try Card.parse("Ax") }
        #expect(throws: CardParseError.invalidRank("a")) { try Card.parse("as") }
        #expect(throws: CardParseError.invalidSuit("S")) { try Card.parse("AS") }
        // The rank is checked before the suit.
        #expect(throws: CardParseError.invalidRank("x")) { try Card.parse("xy") }
    }

    @Test("parses code points like Python, so look-alike characters are not cards")
    func parsesCodePointsLikePython() throws {
        // U+212A KELVIN SIGN is canonically equivalent to "K" as a Swift Character, but PokerKit rejects it.
        #expect(throws: CardParseError.invalidRank("\u{212A}")) { try Card.parse("\u{212A}s") }
        // Cards split on Python's whitespace, which adds U+001C…U+001F to Unicode's.
        for separator in ["\t", "\n", "\r", "\u{0B}", "\u{0C}", "\u{1C}", "\u{1D}", "\u{1E}", "\u{1F}", "\u{85}", "\u{A0}"] {
            #expect(try Card.parse("As\(separator)Ks") == [Card(.ace, .spades), Card(.king, .spades)], "\(separator.debugDescription)")
        }
        // A combining mark is a code point of its own, so the token has odd length.
        #expect(throws: CardParseError.oddLength("A\u{301}s")) { try Card.parse("A\u{301}s") }
    }

    @Test("rejects partially unknown cards, which PokerKit accepts (DECISIONS.md deviation 7)")
    func rejectsPartiallyUnknownCards() {
        #expect(throws: CardParseError.partiallyUnknown("A?")) { try Card.parse("A?") }
        #expect(throws: CardParseError.partiallyUnknown("?s")) { try Card.parse("Ks?s") }
    }

    @Test("prints every card as PokerKit's repr and parses it back")
    func roundTripsDescriptions() {
        for card in Card.standardDeck + [.unknown] {
            #expect(Card(card.description) == card)
        }
        #expect(Card(.ten, .diamonds).description == "Td")
        #expect(Card.unknown.description == "??")
        #expect(Card("AsKs") == nil)
        #expect(Card("") == nil)
    }

    @Test("standard deck matches PokerKit's Deck.STANDARD order")
    func standardDeckOrder() {
        let names = Card.standardDeck.map(\.description)
        #expect(names.count == 52)
        #expect(Set(names).count == 52)
        #expect(names.prefix(6).joined() == "2c2d2h2s3c3d")
        #expect(names.last == "As")
    }

    @Test("exposes rank and suit only for known cards")
    func rankAndSuit() {
        #expect(Card(.queen, .hearts).rank == .queen)
        #expect(Card(.queen, .hearts).suit == .hearts)
        #expect(Card.unknown.rank == nil)
        #expect(Card.unknown.suit == nil)
        #expect(Rank.allCases.map(\.symbol) == Array("23456789TJQKA"))
        #expect(Suit.allCases.map(\.symbol) == Array("cdhs"))
        #expect(Rank.two < Rank.ace)
    }

    @Test("encodes as a JSON string")
    func codesAsJSONString() throws {
        let cards: [Card] = [Card(.ace, .spades), .unknown]
        let data = try JSONEncoder().encode(cards)
        #expect(String(decoding: data, as: UTF8.self) == #"["As","??"]"#)
        #expect(try JSONDecoder().decode([Card].self, from: data) == cards)
        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode([Card].self, from: Data(#"["A?"]"#.utf8))
        }
    }

    @Test("decodes only the canonical two-character JSON form, passing on why a card does not parse")
    func decodesCanonicalFormOnly() throws {
        for text in ["10h", " As", "A,s", "As\n"] {
            let data = try JSONEncoder().encode([text])
            #expect(throws: DecodingError.self, "\(text.debugDescription)") {
                try JSONDecoder().decode([Card].self, from: data)
            }
        }
        let error = #expect(throws: DecodingError.self) { try JSONDecoder().decode([Card].self, from: Data(#"["A?"]"#.utf8)) }
        guard case let .dataCorrupted(context)? = error else {
            Issue.record("Expected a dataCorrupted error, got \(String(describing: error))")
            return
        }
        #expect(context.underlyingError as? CardParseError == .partiallyUnknown("A?"))
    }
}
