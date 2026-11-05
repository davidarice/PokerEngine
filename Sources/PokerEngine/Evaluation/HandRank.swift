/// The category of a five-card high hand, weakest first. The synthesized `Codable` form (the raw integer) is not
/// part of the stored hand format.
public enum HandCategory: Int, Sendable, Hashable, CaseIterable, Comparable, Codable {
    case highCard, onePair, twoPair, threeOfAKind, straight, flush, fullHouse, fourOfAKind, straightFlush

    public static func < (lhs: HandCategory, rhs: HandCategory) -> Bool { lhs.rawValue < rhs.rawValue }

    /// PokerKit's label text (`pokerkit.lookups.Label`), e.g. "Three of a kind".
    public var label: String {
        switch self {
        case .highCard: "High card"
        case .onePair: "One pair"
        case .twoPair: "Two pair"
        case .threeOfAKind: "Three of a kind"
        case .straight: "Straight"
        case .flush: "Flush"
        case .fullHouse: "Full house"
        case .fourOfAKind: "Four of a kind"
        case .straightFlush: "Straight flush"
        }
    }

    /// Category boundaries from PokerHandEvaluator's rank.c, applied to its class number (7462 − strength).
    init(strength: Int) {
        switch Evaluator.classCount - strength {
        case 6186...: self = .highCard
        case 3326...: self = .onePair
        case 2468...: self = .twoPair
        case 1610...: self = .threeOfAKind
        case 1600...: self = .straight
        case 323...: self = .flush
        case 167...: self = .fullHouse
        case 11...: self = .fourOfAKind
        default: self = .straightFlush
        }
    }
}

/// The best five-card high hand a player holds. Ranks compare by strength alone, so a stronger hand is
/// greater and suits never break ties, as with PokerKit's `Hand`. Ranks are derived data: the `Codable` form
/// (the category and five cards) is not part of the stored hand format.
public struct HandRank: Sendable, Hashable, Comparable, Codable, CustomStringConvertible {
    public let category: HandCategory
    /// The five cards making the hand, in the order PokerKit's `Hand.cards` reports them.
    public let cards: [Card]
    /// 0 (seven-high) … 7461 (royal flush): PokerKit's `StandardLookup` entry index.
    let strength: Int

    init(strength: Int, cards: [Card]) {
        self.category = HandCategory(strength: strength)
        self.cards = cards
        self.strength = strength
    }

    public static func == (lhs: HandRank, rhs: HandRank) -> Bool { lhs.strength == rhs.strength }

    public static func < (lhs: HandRank, rhs: HandRank) -> Bool { lhs.strength < rhs.strength }

    public func hash(into hasher: inout Hasher) { hasher.combine(strength) }

    /// PokerKit's `str(hand)`, e.g. "Three of a kind (KsKhKdJc8d)".
    public var description: String { "\(category.label) (\(cards.map(\.description).joined()))" }
}

extension HandRank {
    private enum CodingKeys: String, CodingKey { case category, cards }

    /// Rebuilds the rank from its five cards, so a decoded value can never disagree with them.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let cards = try container.decode([Card].self, forKey: .cards)
        let category = try container.decode(HandCategory.self, forKey: .category)
        // Evaluator.bestHand traps on repeated cards, so distinctness is checked first.
        guard cards.count == 5, Set(cards).count == 5, let rank = Evaluator.bestHand(cards), rank.category == category else {
            throw DecodingError.dataCorruptedError(forKey: .cards, in: container,
                                                   debugDescription: "Not five distinct known cards of the stated category")
        }
        self = rank
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(category, forKey: .category)
        try container.encode(cards, forKey: .cards)
    }
}
