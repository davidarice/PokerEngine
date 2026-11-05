@testable import PokerEngine

/// Shorthand for a scanned card in tests: `card("As")`.
func card(_ text: String) -> Card {
    guard let card = Card(text) else { preconditionFailure("Not a card: \(text)") }
    return card
}

/// Cards as a show lists them: `cards("As??")`.
func cards(_ text: String) -> [Card] {
    guard let cards = try? Card.parse(text) else { preconditionFailure("Not cards: \(text)") }
    return cards
}

func up(_ text: String) -> HoleCard { HoleCard(card: card(text), isFaceUp: true) }
func down(_ text: String) -> HoleCard { HoleCard(card: card(text), isFaceUp: false) }

extension HandConfig {
    /// A config for tests; mirrors PokerKit's `NoLimitTexasHoldem.create_state` argument order.
    static func test(
        _ mode: Mode = .cashGame,
        variant: Variant = .noLimitTexasHoldem,
        stacks: [Int],
        antes: [Int] = [],
        anteTrimming: Bool = false,
        blinds: [Int] = [1, 2],
        minBet: Int = 2,
        automations: Set<Automation> = .bookkeeping
    ) -> HandConfig {
        do {
            return try HandConfig(
                variant: variant, mode: mode, startingStacks: stacks, antes: antes, anteTrimming: anteTrimming,
                blindsOrStraddles: blinds, minBet: minBet, automations: automations
            )
        } catch {
            preconditionFailure("Invalid test config: \(error)")
        }
    }
}

extension HandState {
    /// Applies operations in order.
    func applying(_ operations: HandOperation...) throws(EngineError) -> HandState {
        try applying(operations)
    }

    func applying(_ operations: [HandOperation]) throws(EngineError) -> HandState {
        var state = self
        for operation in operations {
            state = try state.apply(operation)
        }
        return state
    }

    /// Deals hole cards as PokerKit suggests, one card to each player in turn: `"AsKs QdQh"` gives player 0 the
    /// As and Qd, and player 1 the Ks and Qh, when two players are dealt in.
    func dealingHoles(_ text: String) throws -> HandState {
        var state = self
        for card in try Card.parse(text) {
            guard case let .dealHoleCard(player, _)? = state.pendingOperation else {
                preconditionFailure("No hole card is pending")
            }
            state = try state.apply(.dealHole(player: player, card: card))
        }
        return state
    }

    /// Deals each player's hole cards in turn, one operation per card, as a ported test's `deal_hole` calls do.
    func dealing(_ holes: String...) throws -> HandState {
        var state = self
        for (player, cards) in holes.enumerated() {
            for card in try Card.parse(cards) {
                state = try state.apply(.dealHole(player: player, card: card))
            }
        }
        return state
    }

    /// Burns an unknown card and deals the board cards of the next street.
    func dealingStreet(_ text: String) throws -> HandState {
        var state = try apply(.burnCard(.unknown))
        for card in try Card.parse(text) {
            state = try state.apply(.dealBoard(card))
        }
        return state
    }

    /// Checks or calls until the betting round is over.
    func checkingDown() throws -> HandState {
        var state = self
        while let actor = state.actor {
            state = try state.apply(.checkOrCall(player: actor))
        }
        return state
    }

    var events: [HandEvent] { log.map(\.event) }

    var checksAndCalls: [HandEvent] {
        events.filter { if case .checkedOrCalled = $0 { true } else { false } }
    }
}
