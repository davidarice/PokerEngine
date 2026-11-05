import PokerEngine
import SwiftUI

/// One card. Nil, or a card nobody knows, is drawn face down.
struct CardView: View {
    let card: Card?
    let width: CGFloat

    private static let ranks = ["2", "3", "4", "5", "6", "7", "8", "9", "10", "J", "Q", "K", "A"]
    private static let suits = ["♣", "♦", "♥", "♠"]

    var body: some View {
        RoundedRectangle(cornerRadius: width / 7)
            .fill(isFaceUp ? Color.white : Color(red: 0.13, green: 0.25, blue: 0.55))
            .overlay { face }
            .overlay {
                RoundedRectangle(cornerRadius: width / 7).stroke(.black.opacity(0.3), lineWidth: 0.5)
            }
            .frame(width: width, height: width * 1.4)
    }

    /// Where a board card has yet to come.
    static func emptySlot(width: CGFloat) -> some View {
        RoundedRectangle(cornerRadius: width / 7)
            .stroke(.white.opacity(0.2), lineWidth: 1)
            .frame(width: width, height: width * 1.4)
    }

    private var isFaceUp: Bool {
        if case .known = card { true } else { false }
    }

    @ViewBuilder private var face: some View {
        if case let .known(rank, suit) = card {
            VStack(spacing: -width / 12) {
                Text(Self.ranks[rank.rawValue]).font(.system(size: width * 0.42, weight: .bold))
                Text(Self.suits[suit.rawValue]).font(.system(size: width * 0.46))
            }
            .foregroundStyle(suit == .hearts || suit == .diamonds ? Color.red : Color.black)
        }
    }
}
