import Foundation
import Testing
@testable import PokerEngine

/// Redacting a hand for phones that mustn't learn its hidden cards: other players' copies of a game.
@Suite("Redacting hidden cards")
struct RedactionTests {
    /// Three players check to the river with known burns. Player 0 shows aces and wins; players 1 (kings) and 2
    /// (queens) muck.
    private func showdown() throws -> HandState {
        try HandState(config: .test(stacks: [200, 200, 200]))
            .dealingHoles("AsKsQsAhKhQh").checkingDown()
            .applying(.burnCard(card("8c")), .dealBoard(card("2c")), .dealBoard(card("7d")), .dealBoard(card("9h")))
            .checkingDown()
            .applying(.burnCard(card("8d")), .dealBoard(card("Ts"))).checkingDown()
            .applying(.burnCard(card("8h")), .dealBoard(card("3s"))).checkingDown()
            .applying(.showHoleCards(player: 0), .muckHoleCards(player: 1), .muckHoleCards(player: 2))
    }

    @Test("a showdown keeps the hand shown and hides the hands mucked and the burned cards")
    func showdownHidesWhatTheTableDidNotSee() throws {
        let hand = try showdown()
        let redacted = try hand.redactingHiddenCards()
        #expect(redacted.dealtHoleCards[0].map(\.card) == cards("AsAh"))
        #expect(redacted.dealtHoleCards[1].map(\.card) == [.unknown, .unknown])
        #expect(redacted.dealtHoleCards[2].map(\.card) == [.unknown, .unknown])
        #expect(redacted.burnCards == [.unknown, .unknown, .unknown])
        #expect(redacted.boards == hand.boards)
        #expect(redacted.stacks == hand.stacks)

        let stored = String(decoding: try JSONEncoder().encode(hand), as: UTF8.self)
        let shared = String(decoding: try JSONEncoder().encode(redacted), as: UTF8.self)
        #expect(stored.contains("\"Kh\"") && stored.contains("\"8c\""), "the full hand names the kings and the burns")
        #expect(!shared.contains("\"Kh\"") && !shared.contains("\"8c\""), "the shared copy names neither")
    }

    @Test("a player's own copy keeps their cards and hides everyone else's")
    func ownCopyKeepsOwnCards() throws {
        let kings = try showdown().redactingHiddenCards(keeping: [1])
        #expect(kings.dealtHoleCards[1].map(\.card) == cards("KsKh"))
        #expect(kings.dealtHoleCards[2].map(\.card) == [.unknown, .unknown])
        #expect(kings.dealtHoleCards[0].map(\.card) == cards("AsAh"))
    }

    @Test("a hand won without a showdown shares no hole card")
    func handWonWithoutAShowdown() throws {
        var hand = try HandState(config: .test(stacks: [200, 200])).dealingHoles("AsKsAhKh")
        let opener = try #require(hand.actor)
        hand = try hand.applying(.betOrRaise(player: opener, to: 10))
        let other = try #require(hand.actor)
        hand = try hand.applying(.fold(player: other))
        #expect(hand.isHandComplete)

        let redacted = try hand.redactingHiddenCards()
        #expect(redacted.dealtHoleCards.joined().allSatisfy { $0.card == .unknown })
        #expect(redacted.stacks == hand.stacks)
    }

    @Test("a hand that its own operations don't rebuild is refused, not shared")
    func handThatDisagreesWithItsOperations() throws {
        var hand = try showdown()
        hand.stacks[0] += 1
        #expect(throws: RedactionError.outcomeChanged) { try hand.redactingHiddenCards() }

        var unplayable = try showdown()
        unplayable.operations.append(.fold(player: 0))
        #expect {
            try unplayable.redactingHiddenCards()
        } throws: { error in
            guard case let .replayFailed(failure) = error as? RedactionError else { return false }
            return failure.operationIndex == unplayable.operations.count - 1
        }
    }

    @Test("every random hand, after every operation, hides what the table didn't see and changes nothing it did",
          arguments: try OracleHand.committed("random"))
    func randomHands(_ hand: OracleHand) {
        Self.checkEveryStep(of: hand)
    }

    @Test("every scenario hand, after every operation, hides what the table didn't see and changes nothing it did",
          arguments: try OracleHand.committed("scenarios"))
    func scenarioHands(_ hand: OracleHand) {
        Self.checkEveryStep(of: hand)
    }

    /// Redacts the hand after each operation, as a phone following the game would get it, through to the end.
    private static func checkEveryStep(of hand: OracleHand) {
        var state = HandState(config: hand.config)
        for (index, step) in hand.steps.enumerated() {
            guard step.rejected == nil, let operation = step.op, let next = try? state.apply(operation) else { continue }
            state = next
            check(state, "\(hand.name) step \(index)")
        }
    }

    private static func check(_ hand: HandState, _ context: String) {
        let redacted: HandState
        do {
            redacted = try hand.redactingHiddenCards()
        } catch {
            Issue.record("\(context): \(error)")
            return
        }
        let hidden = hiddenCards(of: hand)
        let leaked = redacted.operations.flatMap(\.namedCards).filter(hidden.contains)
        #expect(leaked.isEmpty, "\(context): \(leaked) still in the operations")
        for (form, text) in writtenForms(of: redacted, context) {
            let named = hidden.filter { text.contains($0.description) }
            #expect(named.isEmpty, "\(context): \(named) still in the \(form)")
        }
        #expect(redacted.stacks == hand.stacks, "\(context): stacks differ")
        #expect(redacted.bets == hand.bets, "\(context): bets differ")
        #expect(redacted.statuses == hand.statuses, "\(context): statuses differ")
        #expect(redacted.boards == hand.boards, "\(context): boards differ")
        #expect(faceUpCards(of: redacted) == faceUpCards(of: hand), "\(context): shown cards differ")
    }

    /// The hand as text, as it is stored, logged and exported. A hand history exists only for a hand on one board
    /// that was neither chopped nor voided. A card is written as its rank and then its suit, and no rank follows a
    /// suit, so a card's text appears only where that card is written.
    private static func writtenForms(of hand: HandState, _ context: String) -> [(String, String)] {
        var forms = [(String, String)]()
        do {
            forms.append(("stored hand", String(decoding: try hand.json(), as: UTF8.self)))
            forms.append(("log", String(decoding: try JSONEncoder().encode(hand.log), as: UTF8.self)))
        } catch {
            Issue.record("\(context): the redacted hand doesn't encode: \(error)")
        }
        if let history = try? hand.phh() {
            forms.append(("hand history", history))
        }
        return forms
    }

    /// What the table never saw: hole cards never face up, and burned cards.
    private static func hiddenCards(of hand: HandState) -> Set<Card> {
        let dealt = hand.dealtHoleCards.joined().map(\.card) + hand.burnCards
        return Set(dealt)
            .subtracting(faceUpCards(of: hand).joined())
            .subtracting(hand.boards.joined())
            .subtracting([.unknown])
    }

    private static func faceUpCards(of hand: HandState) -> [[Card]] {
        hand.dealtHoleCards.map { $0.filter(\.isFaceUp).map(\.card) }
    }
}

private extension HandOperation {
    /// The cards an operation names.
    var namedCards: [Card] {
        switch self {
        case let .burnCard(card), let .dealBoard(card), let .dealHole(_, card): [card]
        case let .showHoleCards(_, cards): cards ?? []
        default: []
        }
    }
}
