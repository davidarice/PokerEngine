import PokerEngine
import SwiftUI

/// The bottom of the screen: whose decision it is, and the buttons to enter it.
struct ActionBar: View {
    let game: Game

    var body: some View {
        VStack(spacing: 10) {
            Text(status)
                .font(.subheadline)
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
            controls
        }
        .padding()
        .frame(maxWidth: .infinity, minHeight: 176)
        .background(.black.opacity(0.35))
    }

    private var status: String {
        guard let hand = game.session?.state else { return "Add bots if you like, then deal." }
        if let summary = game.summary { return summary }
        guard let player = game.playerToAnswer else { return "" }
        let name = game.name(of: player)
        if case let .showdown(selectors, _) = hand.pendingOperation {
            return selectors.isEmpty ? "\(name): show, keep or muck?" : "\(name): how many runs?"
        }
        return "\(name) to act"
    }

    @ViewBuilder private var controls: some View {
        if game.isBetweenHands {
            betweenHands
        } else if let hand = game.session?.state, let player = game.playerToAnswer {
            switch hand.pendingOperation {
            case .act:
                if let actions = hand.legalActions {
                    BettingControls(game: game, hand: hand, actions: actions).id(actions)
                }
            case let .showdown(selectors, _) where !selectors.isEmpty:
                runCountButtons(player)
            case .showdown:
                ShowdownButtons(game: game, hand: hand, player: player)
            default:
                EmptyView()
            }
        }
    }

    private var betweenHands: some View {
        HStack {
            Button("Add bot", systemImage: "plus") { game.addBot() }
                .frame(maxWidth: .infinity)
                .buttonStyle(.bordered)
                .disabled(game.seats.count == Game.maximumSeats)

            Button(game.handNumber == 0 ? "Deal" : "Next hand") { game.deal() }
                .frame(maxWidth: .infinity)
                .buttonStyle(.borderedProminent)
        }
        .controlSize(.large)
    }

    /// Any disagreement means one run, and "Any" agrees with whatever the others say. Only counts the deck can deal
    /// are offered.
    private func runCountButtons(_ player: Int) -> some View {
        HStack {
            ForEach(game.runCounts, id: \.self) { (count: Int?) in
                Button(count.map { "\($0)×" } ?? "Any") {
                    game.enter(.selectRunoutCount(player: player, count: count))
                }
                .buttonStyle(.bordered)
            }
        }
        .controlSize(.large)
    }
}

private struct BettingControls: View {
    let game: Game
    let hand: HandState
    let actions: LegalActions
    @State private var amount: Int

    init(game: Game, hand: HandState, actions: LegalActions) {
        self.game = game
        self.hand = hand
        self.actions = actions
        _amount = State(initialValue: actions.betOrRaise.amounts?.lowerBound ?? 0)
    }

    var body: some View {
        VStack(spacing: 10) {
            if let amounts = actions.betOrRaise.amounts, amounts.count > 1 {
                HStack {
                    preset("Min", amounts.lowerBound)
                    preset("½ pot", potSized(0.5, within: amounts))
                    preset("Pot", potSized(1, within: amounts))
                    // In pot-limit the top is the pot, not the stack.
                    let allIn = amounts.upperBound == hand.stacks[actions.player] + hand.bets[actions.player]
                    preset(allIn ? "All in" : "Max", amounts.upperBound)
                }
                Slider(
                    value: Binding { Double(amount) } set: { amount = Int($0) },
                    in: Double(amounts.lowerBound)...Double(amounts.upperBound),
                    step: 1
                )
            }
            HStack {
                if actions.canFold {
                    Button("Fold") { game.enter(.fold(player: actions.player)) }
                        .frame(maxWidth: .infinity)
                        .tint(.red)
                }
                Button(actions.toCall == 0 ? "Check" : "Call \(actions.toCall)") {
                    game.enter(.checkOrCall(player: actions.player))
                }
                .frame(maxWidth: .infinity)
                if actions.betOrRaise.amounts != nil {
                    Button("\(betLabel) \(amount)") { game.enter(.betOrRaise(player: actions.player, to: amount)) }
                        .frame(maxWidth: .infinity)
                }
                // Everyone else folded to the blinds, who may agree to take their blinds back.
                if hand.canApply(.chopBlinds) {
                    Button("Chop") { game.enter(.chopBlinds) }
                        .frame(maxWidth: .infinity)
                }
            }
            .buttonStyle(.bordered)
            .controlSize(.large)
        }
    }

    private var betLabel: String {
        if case .raise = actions.betOrRaise { "Raise to" } else { "Bet" }
    }

    /// The legal street total nearest to a bet of `fraction` of the pot, counting the call.
    private func potSized(_ fraction: Double, within amounts: ClosedRange<Int>) -> Int {
        let wanted = (hand.bets.max() ?? 0) + Int(Double(hand.totalPot + actions.toCall) * fraction)
        return min(max(wanted, amounts.lowerBound), amounts.upperBound)
    }

    private func preset(_ title: String, _ value: Int) -> some View {
        Button(title) { amount = value }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .frame(maxWidth: .infinity)
    }
}

private struct ShowdownButtons: View {
    let game: Game
    let hand: HandState
    let player: Int

    /// Each list replaces the last, so Keep lists any card already up.
    private var keep: HandOperation {
        .showHoleCards(player: player, cards: hand.holeCards[player].filter(\.isFaceUp).map(\.card))
    }

    var body: some View {
        HStack {
            answer("Show", .showHoleCards(player: player))
            answer("Keep face down", keep)
            answer("Muck", .muckHoleCards(player: player))
        }
        .controlSize(.large)
    }

    private func answer(_ title: String, _ operation: HandOperation) -> some View {
        Button(title) { game.enter(operation) }
            .buttonStyle(.bordered)
            .disabled(!hand.canApply(operation))
    }
}

extension BetOrRaise {
    /// The street totals allowed, whichever kind of bet this is.
    var amounts: ClosedRange<Int>? {
        switch self {
        case let .bet(amounts), let .raise(amounts): amounts
        case .unavailable: nil
        }
    }
}
