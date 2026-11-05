import PokerEngine
import SwiftUI

/// One player at the table: cards, name, chips, and what they did last.
struct SeatView: View {
    static let width: CGFloat = 88
    static let height: CGFloat = 92

    let game: Game
    let seat: Game.Seat

    private var hand: HandState? { game.session?.state }
    private var player: Int? { game.players.firstIndex(of: seat.id) }

    var body: some View {
        VStack(spacing: 1) {
            HStack(spacing: 2) {
                ForEach(Array(cards.enumerated()), id: \.offset) { _, card in
                    // Four Omaha cards fit the seat at a narrower width.
                    CardView(card: card, width: cards.count > 2 ? 19 : 26)
                }
            }
            .frame(height: 37)
            HStack(spacing: 3) {
                Text(seat.name).fontWeight(.semibold)
                if isButton {
                    Text("D")
                        .font(.system(size: 9, weight: .heavy))
                        .foregroundStyle(.black)
                        .frame(width: 13, height: 13)
                        .background(.white, in: Circle())
                }
            }
            Text("\(stack)").monospacedDigit().foregroundStyle(.yellow)
            Text(detail.text).foregroundStyle(detail.color)
        }
        .font(.system(size: 11))
        .lineLimit(1)
        .minimumScaleFactor(0.8)
        .padding(.vertical, 4)
        .frame(width: Self.width, height: Self.height)
        .background(.black.opacity(0.55), in: RoundedRectangle(cornerRadius: 9))
        .overlay {
            if isActing {
                RoundedRectangle(cornerRadius: 9).stroke(.yellow, lineWidth: 2)
            }
        }
        .overlay(alignment: .topTrailing) {
            if game.isBetweenHands, game.seats.count > 2 {
                Button("Remove \(seat.name)", systemImage: "xmark.circle.fill") { game.remove(seat) }
                    .labelStyle(.iconOnly)
                    .buttonStyle(.plain)
                    .foregroundStyle(.white.opacity(0.7))
                    .padding(3)
            }
        }
        .opacity(isOut ? 0.55 : 1)
    }

    private var stack: Int {
        guard let hand, let player, !hand.isHandComplete else { return seat.stack }
        return hand.stacks[player]
    }

    private var isButton: Bool { game.players.last == seat.id }

    private var isActing: Bool {
        player != nil && player == game.playerToAnswer
    }

    private var isOut: Bool {
        guard let hand, let player else { return false }
        return !hand.isHandComplete && hand.statuses[player] != .active
    }

    /// The dealer sees every card, as the camera would.
    private var cards: [Card] {
        guard let hand, let player else { return [] }
        return (hand.results?[player].holeCards ?? hand.holeCards[player]).map(\.card)
    }

    private var detail: (text: String, color: Color) {
        guard let hand, let player else { return ("", .secondary) }
        if let result = hand.results?[player] {
            if result.net > 0 { return ("+\(result.net)", .green) }
            if result.net < 0 { return ("\(result.net)", .red) }
            return ("Even", .secondary)
        }
        switch hand.statuses[player] {
        case .folded: return ("Folded", .secondary)
        case .mucked: return ("Mucked", .secondary)
        case .killed: return ("Beaten", .secondary)
        case .active: break
        }
        if !cards.isEmpty, hand.holeCards[player].allSatisfy(\.isFaceUp) { return ("Shown", .white) }
        if hand.stacks[player] == 0 { return ("All in", .orange) }
        return (lastAction(of: player, in: hand) ?? (hand.bets[player] > 0 ? "Blind \(hand.bets[player])" : ""), .white)
    }

    /// What the player last did on this street.
    private func lastAction(of player: Int, in hand: HandState) -> String? {
        for entry in hand.log.reversed() {
            switch entry.event {
            case .boardCardDealt:
                return nil
            case let .checkedOrCalled(actor, amount) where actor == player:
                return amount == 0 ? "Check" : "Call \(amount)"
            case let .betOrRaised(actor, to) where actor == player:
                return "Bet \(to)"
            default:
                continue
            }
        }
        return nil
    }
}
