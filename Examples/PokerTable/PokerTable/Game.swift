import Observation
import PokerEngine
import PokerEngineObservation

/// The table and the hand in play. `TableState` keeps who sits where, the chips, the stakes and the button; the deck
/// enters the cards, and the dealer enters everything else.
@MainActor
@Observable
final class Game {
    struct Seat: Identifiable, Hashable {
        /// The seat's number, counting clockwise.
        let id: Int
        var stack: Int

        var name: String { "Bot \(id + 1)" }
    }

    static let maximumSeats = TableState.seatCount
    private static let buyIn = 200

    private(set) var table = Game.openingTable()
    /// The hand in play, or the last one until the next deal.
    private(set) var session: TableSession?
    var startingStack = Game.buyIn
    /// Why the engine or the table refused something.
    var alert: String?

    @ObservationIgnored private var deck: Deck?

    var seats: [Seat] {
        table.stacks.map { Seat(id: $0.key, stack: $0.value) }.sorted { $0.id < $1.id }
    }
    /// `players[i]` is the seat of player i in the hand in play, or in the last one until the next deal.
    var players: [Int] { table.hand?.seats ?? [] }
    var handNumber: Int { table.hand?.number ?? 0 }
    var isBetweenHands: Bool { !table.isHandInPlay }

    /// The big blind from the next hand. The small blind is half of it, and the minimum bet follows it.
    var bigBlind: Int {
        get { table.stakes.bigBlind }
        set {
            table.stakes.bigBlind = newValue
            table.stakes.smallBlind = newValue / 2
        }
    }
    /// The game of the next hand.
    var variant: HandConfig.Variant {
        get { table.stakes.variant }
        set { table.stakes.variant = newValue }
    }

    /// The run counts the dealer may choose: those the cards left in the deck can deal.
    var runCounts: [Int?] {
        guard let hand = session?.state, let deck else { return [nil] }
        return deck.runCounts(for: hand)
    }

    /// The player whose decision the dealer has to enter next.
    var playerToAnswer: Int? {
        switch session?.state.pendingOperation {
        case let .act(player): player
        case let .showdown(runoutSelectors, showOrder): runoutSelectors.first ?? showOrder.first
        default: nil
        }
    }

    func name(of player: Int) -> String {
        Seat(id: players[player], stack: 0).name
    }

    /// Who came out ahead, once the hand is over.
    var summary: String? {
        guard let hand = session?.state, let results = hand.results else { return nil }
        switch hand.operations.last {
        case .chopBlinds: return "The blinds chopped."
        case .voidHand: return "Hand voided: every chip went back."
        default: break
        }
        let winners = results.filter { $0.net > 0 }.sorted { $0.net > $1.net }
        guard !winners.isEmpty else { return "No chips changed hands." }
        return winners.map { winner in
            let shown = winner.shown && hand.runoutCount == 1
            let rank = shown ? hand.hand(of: winner.player, faceUpOnly: true)?.category.label : nil
            return "\(name(of: winner.player)) +\(winner.net)" + (rank.map { " with \($0)" } ?? "")
        }.joined(separator: ", ")
    }

    /// Seats a bot in the first empty seat. The table refuses it during a hand.
    func addBot() {
        guard let seat = (0..<Self.maximumSeats).first(where: { table.stacks[$0] == nil }) else { return }
        change { try $0.sit(seat, stack: startingStack) }
    }

    /// Empties the seat, keeping two bots to deal to. The table refuses it during a hand.
    func remove(_ seat: Seat) {
        guard seats.count > 2 else { return }
        change { try $0.stand(seat.id) }
    }

    func resetStacks() {
        change { table in
            for seat in table.stacks.keys {
                try table.setStack(of: seat, to: startingStack)
            }
        }
    }

    /// Starts the next hand and deals it. Anyone out of chips buys back in first, and the table moves the button on,
    /// or keeps it for the redeal after a void.
    func deal() {
        do throws(TableError) {
            for (seat, stack) in table.stacks where stack == 0 {
                try table.setStack(of: seat, to: startingStack)
            }
            session = TableSession(config: try table.nextHand().config)
        } catch {
            alert = "The hand could not start: \(error)"
            return
        }
        var generator = SystemRandomNumberGenerator()
        deck = Deck(using: &generator)
        enterCards()
    }

    /// Enters what the dealer decided for a player, then any cards that brings.
    func enter(_ operation: HandOperation) {
        if apply(operation) {
            enterCards()
        }
    }

    /// Corrects a starting stack entered wrong in the hand in play, and replays the hand on it. Returns why the hand
    /// cannot take it, or nil once it is corrected. Does nothing between hands.
    func correctStartingStack(of player: Int, to stack: Int) -> String? {
        guard let session, !session.state.isHandComplete else { return nil }
        let old = session.state.config
        var stacks = old.startingStacks
        stacks[player] = stack
        do {
            let config = try HandConfig(
                variant: old.variant, mode: old.mode, startingStacks: stacks, antes: old.antes,
                anteTrimming: old.anteTrimming, blindsOrStraddles: old.blindsOrStraddles, minBet: old.minBet,
                automations: old.automations
            )
            try session.replaceConfig(with: config)
        } catch let error as ReplayError {
            return error.error.message(naming: name(of:))
        } catch {
            return "\(name(of: player)) cannot start with \(stack)."
        }
        finishIfComplete()
        enterCards()
        return nil
    }

    /// Each hand still in at the end, ranked from the cards dealt on every board, with what became of it.
    var finalHands: [String] {
        guard let hand = session?.state, let results = hand.results else { return [] }
        return results.filter { $0.status != .folded }.compactMap { result in
            let ranks = (0..<hand.runoutCount).compactMap { hand.dealtHand(of: result.player, board: $0) }
            guard !ranks.isEmpty else { return nil }
            let outcome = switch result.status {
            case .killed: "beaten"
            case .mucked: "mucked"
            default: result.net > 0 ? "+\(result.net)" : result.net < 0 ? "\(result.net)" : "even"
            }
            let ranked = ranks.map(\.description).joined(separator: " / ")
            return "\(name(of: result.player)): \(ranked) · \(result.shown ? "shown" : "not shown") · \(outcome)"
        }
    }

    /// Three bots with the buy-in and the button on the first seat, which no table refuses.
    private static func openingTable() -> TableState {
        var table = try! TableState(stakes: .init(mode: .cashGame, smallBlind: 1, bigBlind: 2))
        for seat in 0..<3 {
            try! table.sit(seat, stack: buyIn)
        }
        return table
    }

    private func enterCards() {
        while let hand = session?.state, let card = deck?.nextCard(for: hand), apply(card) {}
    }

    private func apply(_ operation: HandOperation) -> Bool {
        guard let session else { return false }
        do throws(EngineError) {
            try session.apply(operation)
        } catch {
            alert = error.message(naming: name(of:))
            return false
        }
        finishIfComplete()
        return true
    }

    /// Gives a finished hand's chips back to the table. After a change to the hand, only the difference moves.
    private func finishIfComplete() {
        guard let hand = session?.state, hand.isHandComplete, let deal = table.hand else { return }
        change { try $0.finish(hand, of: deal) }
    }

    /// Changes the table, or says why it refused.
    private func change(_ body: (inout TableState) throws -> Void) {
        do {
            try body(&table)
        } catch {
            alert = "The table refused: \(error)"
        }
    }
}
