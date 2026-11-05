/// A card rank, deuce to ace. Raw values are PokerHandEvaluator's rank ids; the synthesized `Codable` form
/// (that integer) is not part of the stored hand format.
public enum Rank: Int, Sendable, Hashable, CaseIterable, Comparable, Codable {
    case two, three, four, five, six, seven, eight, nine, ten, jack, queen, king, ace

    public static func < (lhs: Rank, rhs: Rank) -> Bool { lhs.rawValue < rhs.rawValue }

    private static let symbols = Array("23456789TJQKA".unicodeScalars)

    /// PokerKit's rank character: "2"…"9", "T", "J", "Q", "K", "A".
    var symbol: Character { Character(Self.symbols[rawValue]) }

    init?(symbol: Unicode.Scalar) {
        guard let index = Self.symbols.firstIndex(of: symbol) else { return nil }
        self.init(rawValue: index)
    }
}

/// A card suit. Raw values are PokerHandEvaluator's suit ids, which is also PokerKit's deck order; the
/// synthesized `Codable` form is not part of the stored hand format.
public enum Suit: Int, Sendable, Hashable, CaseIterable, Codable {
    case clubs, diamonds, hearts, spades

    private static let symbols = Array("cdhs".unicodeScalars)

    /// PokerKit's suit character: "c", "d", "h", "s".
    var symbol: Character { Character(Self.symbols[rawValue]) }

    init?(symbol: Unicode.Scalar) {
        guard let index = Self.symbols.firstIndex(of: symbol) else { return nil }
        self.init(rawValue: index)
    }
}

/// A playing card. `.unknown` stands for a card that was dealt but never scanned (PokerKit's `??`). It also stands
/// for a scanned hole card kept face down and forgotten on the river, and for face-down padding in
/// `HandEvent.holeCardsShown`.
public enum Card: Sendable, Hashable {
    case known(Rank, Suit)
    case unknown

    init(_ rank: Rank, _ suit: Suit) {
        self = .known(rank, suit)
    }

    var rank: Rank? {
        guard case let .known(rank, _) = self else { return nil }
        return rank
    }

    var suit: Suit? {
        guard case let .known(_, suit) = self else { return nil }
        return suit
    }

    /// PokerKit's `Deck.STANDARD` order: 2c 2d 2h 2s 3c … As.
    static let standardDeck: [Card] = Rank.allCases.flatMap { rank in
        Suit.allCases.map { Card(rank, $0) }
    }
}

/// Why `Card.parse` rejected its input. Payloads are the offending text. The synthesized `Codable` form is not
/// part of the stored hand format.
public enum CardParseError: Error, Sendable, Hashable, Codable {
    /// A whitespace-separated token whose length is not a multiple of two.
    case oddLength(String)
    case invalidRank(String)
    case invalidSuit(String)
    /// A card such as "A?" with only one of rank and suit known. PokerKit accepts these; this engine does not.
    case partiallyUnknown(String)
}

extension Card {
    /// Parses cards with PokerKit's `Card.parse` grammar: concatenated two-character cards ("AsKs"), optionally
    /// separated by whitespace or commas, "10" accepted for "T", "??" for an unknown card. Case-sensitive.
    public static func parse(_ text: String) throws(CardParseError) -> [Card] {
        var cards = [Card]()
        for token in tokens(of: text) {
            guard token.count.isMultiple(of: 2) else { throw .oddLength(string(token)) }
            for index in stride(from: token.startIndex, to: token.endIndex, by: 2) {
                cards.append(try card(rank: token[index], suit: token[index + 1]))
            }
        }
        return cards
    }

    /// PokerKit's normalisation, done on code points as Python does (Swift's `Character` comparison would treat
    /// look-alikes such as U+212A KELVIN SIGN as "K"): every "10" becomes "T", commas are dropped, and the rest
    /// splits on Python's whitespace, which is Unicode White_Space plus U+001C…U+001F.
    private static func tokens(of text: String) -> [ArraySlice<Unicode.Scalar>] {
        var normalized = [Unicode.Scalar]()
        var scalars = text.unicodeScalars.makeIterator()
        var pending = scalars.next()
        while let scalar = pending {
            pending = scalars.next()
            if scalar == "1", pending == "0" {
                normalized.append("T")
                pending = scalars.next()
            } else if scalar != "," {
                normalized.append(scalar)
            }
        }
        return normalized.split { $0.properties.isWhitespace || (0x1C...0x1F).contains($0.value) }
    }

    /// Validates rank before suit, as PokerKit does, then rejects the partially unknown cards PokerKit allows.
    private static func card(rank rankSymbol: Unicode.Scalar, suit suitSymbol: Unicode.Scalar) throws(CardParseError) -> Card {
        let rank = Rank(symbol: rankSymbol)
        let suit = Suit(symbol: suitSymbol)
        if rank == nil && rankSymbol != "?" { throw .invalidRank(string([rankSymbol])) }
        if suit == nil && suitSymbol != "?" { throw .invalidSuit(string([suitSymbol])) }
        switch (rank, suit) {
        case let (rank?, suit?): return Card(rank, suit)
        case (nil, nil): return .unknown
        default: throw .partiallyUnknown(string([rankSymbol, suitSymbol]))
        }
    }

    private static func string<Scalars: Sequence<Unicode.Scalar>>(_ scalars: Scalars) -> String {
        var view = String.UnicodeScalarView()
        view.append(contentsOf: scalars)
        return String(view)
    }
}

extension Card: CustomStringConvertible, LosslessStringConvertible {
    /// PokerKit's repr: "As", "Td", or "??".
    public var description: String {
        switch self {
        case let .known(rank, suit): String([rank.symbol, suit.symbol])
        case .unknown: "??"
        }
    }

    /// Parses exactly one card.
    public init?(_ description: String) {
        guard let cards = try? Card.parse(description), cards.count == 1 else { return nil }
        self = cards[0]
    }
}

extension Card: Codable {
    /// Accepts only the canonical form ("As", "??") so every stored card re-encodes to the same text. Text that
    /// does not parse throws a `DecodingError` whose underlying error is the `CardParseError`.
    public init(from decoder: any Decoder) throws {
        let text = try decoder.singleValueContainer().decode(String.self)
        let cards: [Card]
        do {
            cards = try Card.parse(text)
        } catch {
            throw DecodingError.dataCorrupted(.init(
                codingPath: decoder.codingPath, debugDescription: "Invalid card \"\(text)\"", underlyingError: error
            ))
        }
        guard cards.count == 1, cards[0].description == text else {
            throw DecodingError.dataCorrupted(.init(
                codingPath: decoder.codingPath, debugDescription: "Not one card in canonical form: \"\(text)\""
            ))
        }
        self = cards[0]
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(description)
    }
}
