/// Why `HandState.phh()` cannot export a hand. The synthesized `Codable` form is not part of the stored hand format.
public enum PHHExportError: Error, Sendable, Hashable, Codable {
    /// PHH has no way to write more than one runout.
    case multipleRunouts(count: Int)
    /// PHH has no way to write a hand that ended in a chop or a void.
    case blindsChopped
    case handVoided
}

extension HandState {
    /// The hand in PHH, PokerKit's hand-history text, as it stands: byte for byte what PokerKit's
    /// `HandHistory.from_game_state(...).dumps()` gives, with the true `ante_trimming_status`, `finishing_stacks` as
    /// the current stacks and `winnings` as the chips pushed so far (DECISIONS.md C15).
    public func phh() throws(PHHExportError) -> String {
        switch log.last?.event {
        case .blindsChopped: throw .blindsChopped
        case .handVoided: throw .handVoided
        default: break
        }
        guard runoutCount == 1 else { throw .multipleRunouts(count: runoutCount) }
        func list(_ values: [Int]) -> String {
            "[" + values.map(String.init).joined(separator: ", ") + "]"
        }
        let variant = switch config.variant {
        case .noLimitTexasHoldem: "NT"
        case .potLimitOmahaHoldem: "PO"
        }
        return [
            "variant = '\(variant)'",
            "ante_trimming_status = \(config.anteTrimming)",
            "antes = \(list(config.antes))",
            "blinds_or_straddles = \(list(config.blindsOrStraddles))",
            "min_bet = \(config.minBet)",
            "starting_stacks = \(list(config.startingStacks))",
            "actions = [" + phhActions.map { "'\($0)'" }.joined(separator: ", ") + "]",
            "finishing_stacks = \(list(stacks))",
            "winnings = \(list(chipsWon))",
        ].joined(separator: "\n")
    }

    /// PokerKit writes deals when something else comes next: one line per player in player order, then the board.
    /// The whole log is read for that, because a burn, a collection, a kill or a push, which have no line, also end
    /// a run of deals.
    private var phhActions: [String] {
        var actions = [String]()
        var holeCards = [Int: [Card]]()
        var boardCards = [Card]()
        func text(_ cards: [Card]) -> String {
            cards.map(\.description).joined()
        }
        func writeDeals() {
            for (player, cards) in holeCards.sorted(by: { $0.key < $1.key }) {
                actions.append("d dh p\(player + 1) \(text(cards))")
            }
            if !boardCards.isEmpty {
                actions.append("d db \(text(boardCards))")
            }
            holeCards = [:]
            boardCards = []
        }
        for entry in log {
            switch entry.event {
            case let .holeCardDealt(player, card):
                holeCards[player, default: []].append(card)
                continue
            case let .boardCardDealt(card, _, _):
                boardCards.append(card)
                continue
            default:
                writeDeals()
            }
            switch entry.event {
            case let .folded(player):
                actions.append("p\(player + 1) f")
            case let .checkedOrCalled(player, _):
                actions.append("p\(player + 1) cc")
            case let .betOrRaised(player, to):
                actions.append("p\(player + 1) cbr \(to)")
            case let .holeCardsShown(player, cards):
                actions.append("p\(player + 1) sm \(text(cards))")
            case let .holeCardsMucked(player):
                actions.append("p\(player + 1) sm")
            default:
                break
            }
        }
        writeDeals()
        return actions
    }
}
