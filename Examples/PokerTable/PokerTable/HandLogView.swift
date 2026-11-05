import PokerEngine
import SwiftUI

/// The engine's log of the hand.
struct HandLogView: View {
    let game: Game
    @Environment(\.dismiss) private var dismiss

    private var hand: HandState? { game.session?.state }

    var body: some View {
        NavigationStack {
            List {
                let hands = game.finalHands
                if !hands.isEmpty {
                    Section("Hands") {
                        ForEach(hands, id: \.self) { Text($0).font(.footnote) }
                    }
                }
                Section("Log") {
                    ForEach(Array((hand?.log ?? []).enumerated()), id: \.offset) { _, entry in
                        Text(text(for: entry.event))
                            .font(.footnote)
                            .foregroundStyle(entry.isAutomated ? .secondary : .primary)
                    }
                }
            }
            .navigationTitle("Hand \(game.handNumber)")
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    ShareLink("Share the hand as JSON", item: json)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }

    private var json: String {
        guard let data = try? hand?.json() else { return "" }
        return String(decoding: data, as: UTF8.self)
    }

    private func name(_ player: Int) -> String { game.name(of: player) }

    private func text(for event: HandEvent) -> String {
        switch event {
        case let .antePosted(player, amount):
            "\(name(player)): ante \(amount)"
        case let .blindOrStraddlePosted(player, amount):
            "\(name(player)): post \(amount)"
        case let .betsCollected(collected, returned):
            "Bets collected: \(collected.reduce(0, +)), uncalled returned: \(returned.reduce(0, +))"
        case let .cardBurned(card, street, runout):
            "Burn \(card) for the \(street), run \(runout + 1)"
        case let .holeCardDealt(player, card):
            "\(name(player)): dealt \(card)"
        case let .boardCardDealt(card, street, runout):
            "\(street.rawValue.capitalized), run \(runout + 1): \(card)"
        case let .folded(player):
            "\(name(player)): fold"
        case let .checkedOrCalled(player, amount):
            "\(name(player)): \(amount == 0 ? "check" : "call \(amount)")"
        case let .betOrRaised(player, to):
            "\(name(player)): bet or raise to \(to)"
        case let .runoutCountSelected(player, count):
            "\(name(player)): run \(count.map(String.init) ?? "no preference")"
        case let .holeCardsShown(player, cards):
            "\(name(player)): show \(cards.map(\.description).joined(separator: " "))"
        case let .holeCardsMucked(player):
            "\(name(player)): muck"
        case let .handKilled(player):
            "\(name(player)): beaten"
        case let .chipsPushed(pot, runout, amounts):
            "Pot \(pot + 1)\(runout.map { ", run \($0 + 1)" } ?? ""): \(payouts(amounts))"
        case let .chipsPulled(player, amount):
            "\(name(player)): takes \(amount)"
        case let .blindsChopped(returned):
            "The blinds chop: \(payouts(returned)) back"
        case .handVoided:
            "Hand voided: every stack back where it started"
        }
    }

    private func payouts(_ amounts: [Int]) -> String {
        amounts.enumerated()
            .filter { $0.element > 0 }
            .map { "\(name($0.offset)) \($0.element)" }
            .joined(separator: ", ")
    }
}
