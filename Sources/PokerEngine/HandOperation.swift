/// One event at the table, entered by the dealer. `HandState.apply(_:)` takes one operation at a time.
///
/// Every player-scoped operation names its player, by player index (see `HandConfig`). Dealing operations carry
/// one card each, so a misread card is corrected by editing one operation, plus any listed show that repeats it
/// (see `replacingOperation(at:with:)`); `.unknown` deals a card that was never scanned. `pendingOperation` says
/// which operation the hand is waiting for.
///
/// `Codable` is the stored hand format (JSON v1 and v2): a flat object with a `type` tag, such as
/// `{"type":"dealHole","player":0,"card":"As"}`. Optional fields are omitted when nil.
public enum HandOperation: Sendable, Hashable {
    /// Posting is only entered by the dealer when that step is not automated.
    case postAnte(player: Int)
    case collectBets
    case postBlindOrStraddle(player: Int)

    /// Burns before every flop, turn and river, including those of extra runouts. Dealing is never automated.
    case burnCard(Card)
    case dealHole(player: Int, card: Card)
    case dealBoard(Card)

    case fold(player: Int)
    case checkOrCall(player: Int)
    /// `to` is the player's total bet on this street, not the increment.
    case betOrRaise(player: Int, to: Int)

    /// How many times to run the board after an all-in, in cash games, from 1 to `HandState.maximumRunoutCount`.
    /// `nil` means no preference.
    case selectRunoutCount(player: Int, count: Int?)
    /// `nil` turns every hole card face up, and is refused while any is unknown (list the cards to reveal them).
    /// Listed cards are shown in that order, must match the scanned cards, and can reveal cards dealt as `.unknown`;
    /// a list may not hold `.unknown` itself. In cash games, and for the player left at a tournament showdown with
    /// nobody all in, a subset, or `[]`, keeps the other cards face down.
    case showHoleCards(player: Int, cards: [Card]? = nil)
    case muckHoleCards(player: Int)

    /// Settlement steps, entered by the dealer only when not automated.
    case killHand(player: Int)
    case pushChips
    case pullChips(player: Int)

    /// Never pending: offer them when `canApply(_:)` allows. Each ends the hand with every stack back where it started.
    /// `chopBlinds` is the blinds taking their blinds back, in a cash game, before the flop, once everyone else has
    /// folded with nothing in the pot but the blinds' own chips. `voidHand` is a misdeal or a fouled deck, at any
    /// point, even once the hand is over.
    case chopBlinds
    case voidHand
}

extension HandOperation {
    /// The player the operation names, if any.
    var player: Int? {
        switch self {
        case let .postAnte(player), let .postBlindOrStraddle(player), let .dealHole(player, _), let .fold(player),
             let .checkOrCall(player), let .betOrRaise(player, _), let .selectRunoutCount(player, _),
             let .showHoleCards(player, _), let .muckHoleCards(player), let .killHand(player), let .pullChips(player):
            player
        case .collectBets, .burnCard, .dealBoard, .pushChips, .chopBlinds, .voidHand:
            nil
        }
    }
}

extension HandOperation: Codable {
    private enum CodingKeys: String, CodingKey {
        case type, player, card, to, count, cards
    }

    private enum Kind: String, Codable {
        case postAnte, collectBets, postBlindOrStraddle, burnCard, dealHole, dealBoard, fold, checkOrCall, betOrRaise
        case selectRunoutCount, showHoleCards, muckHoleCards, killHand, pushChips, pullChips, chopBlinds, voidHand
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        func player() throws -> Int { try container.decode(Int.self, forKey: .player) }
        func card() throws -> Card { try container.decode(Card.self, forKey: .card) }
        self = switch try container.decode(Kind.self, forKey: .type) {
        case .postAnte: .postAnte(player: try player())
        case .collectBets: .collectBets
        case .postBlindOrStraddle: .postBlindOrStraddle(player: try player())
        case .burnCard: .burnCard(try card())
        case .dealHole: .dealHole(player: try player(), card: try card())
        case .dealBoard: .dealBoard(try card())
        case .fold: .fold(player: try player())
        case .checkOrCall: .checkOrCall(player: try player())
        case .betOrRaise: .betOrRaise(player: try player(), to: try container.decode(Int.self, forKey: .to))
        case .selectRunoutCount:
            .selectRunoutCount(player: try player(), count: try container.decodeIfPresent(Int.self, forKey: .count))
        case .showHoleCards:
            .showHoleCards(player: try player(), cards: try container.decodeIfPresent([Card].self, forKey: .cards))
        case .muckHoleCards: .muckHoleCards(player: try player())
        case .killHand: .killHand(player: try player())
        case .pushChips: .pushChips
        case .pullChips: .pullChips(player: try player())
        case .chopBlinds: .chopBlinds
        case .voidHand: .voidHand
        }
    }

    public func encode(to encoder: any Encoder) throws {
        let kind: Kind
        var player: Int?, card: Card?, to: Int?, count: Int?, cards: [Card]?
        switch self {
        case let .postAnte(p): (kind, player) = (.postAnte, p)
        case .collectBets: kind = .collectBets
        case let .postBlindOrStraddle(p): (kind, player) = (.postBlindOrStraddle, p)
        case let .burnCard(c): (kind, card) = (.burnCard, c)
        case let .dealHole(p, c): (kind, player, card) = (.dealHole, p, c)
        case let .dealBoard(c): (kind, card) = (.dealBoard, c)
        case let .fold(p): (kind, player) = (.fold, p)
        case let .checkOrCall(p): (kind, player) = (.checkOrCall, p)
        case let .betOrRaise(p, amount): (kind, player, to) = (.betOrRaise, p, amount)
        case let .selectRunoutCount(p, n): (kind, player, count) = (.selectRunoutCount, p, n)
        case let .showHoleCards(p, shown): (kind, player, cards) = (.showHoleCards, p, shown)
        case let .muckHoleCards(p): (kind, player) = (.muckHoleCards, p)
        case let .killHand(p): (kind, player) = (.killHand, p)
        case .pushChips: kind = .pushChips
        case let .pullChips(p): (kind, player) = (.pullChips, p)
        case .chopBlinds: kind = .chopBlinds
        case .voidHand: kind = .voidHand
        }
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(kind, forKey: .type)
        try container.encodeIfPresent(player, forKey: .player)
        try container.encodeIfPresent(card, forKey: .card)
        try container.encodeIfPresent(to, forKey: .to)
        try container.encodeIfPresent(count, forKey: .count)
        try container.encodeIfPresent(cards, forKey: .cards)
    }
}
