import PokerEngine
import SwiftUI

struct TableView: View {
    @State private var game = Game()
    @State private var isShowingLog = false
    @State private var isShowingSettings = false

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                felt
                ActionBar(game: game)
            }
            .background(Color(red: 0.06, green: 0.08, blue: 0.07))
            .navigationTitle(game.handNumber == 0 ? "Poker Table" : "Hand \(game.handNumber)")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button("Hand log", systemImage: "list.bullet") { isShowingLog = true }
                        .disabled(game.session == nil)
                }
                ToolbarItem(placement: .primaryAction) {
                    Button("Settings", systemImage: "gearshape") { isShowingSettings = true }
                }
            }
        }
        .sheet(isPresented: $isShowingLog) { HandLogView(game: game) }
        .sheet(isPresented: $isShowingSettings) { GameSettingsView(game: game) }
        .alert("The engine refused that", isPresented: isShowingAlert) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(game.alert ?? "")
        }
        .preferredColorScheme(.dark)
    }

    private var isShowingAlert: Binding<Bool> {
        Binding { game.alert != nil } set: { if !$0 { game.alert = nil } }
    }

    private var felt: some View {
        GeometryReader { proxy in
            let size = proxy.size
            ZStack {
                Ellipse()
                    .fill(RadialGradient(
                        colors: [Color(red: 0.1, green: 0.46, blue: 0.28), Color(red: 0.04, green: 0.27, blue: 0.16)],
                        center: .center, startRadius: 10, endRadius: size.height / 2
                    ))
                    .overlay(Ellipse().stroke(Color(red: 0.32, green: 0.2, blue: 0.1), lineWidth: 8))
                    .padding(.horizontal, 22)
                    .padding(.vertical, 40)
                centre
                ForEach(Array(game.seats.enumerated()), id: \.element.id) { index, seat in
                    SeatView(game: game, seat: seat)
                        .position(position(ofSeat: index, in: size))
                }
            }
        }
    }

    /// The first seat is at the bottom, and the rest go clockwise from it.
    private func position(ofSeat index: Int, in size: CGSize) -> CGPoint {
        let angle = 2 * Double.pi * Double(index) / Double(game.seats.count)
        let (radiusX, radiusY) = (size.width / 2 - SeatView.width / 2 - 4, size.height / 2 - SeatView.height / 2 - 4)
        return CGPoint(x: size.width / 2 - radiusX * sin(angle), y: size.height / 2 + radiusY * cos(angle))
    }

    private var centre: some View {
        VStack(spacing: 6) {
            if let hand = game.session?.state {
                let boards = hand.boards
                ForEach(Array(boards.enumerated()), id: \.offset) { _, board in
                    HStack(spacing: 3) {
                        ForEach(0..<5, id: \.self) { slot in
                            if slot < board.count {
                                CardView(card: board[slot], width: boards.count > 1 ? 30 : 36)
                            } else {
                                CardView.emptySlot(width: boards.count > 1 ? 30 : 36)
                            }
                        }
                    }
                }
                if hand.totalPot > 0 {
                    Text("Pot \(hand.totalPot)").font(.subheadline.bold().monospacedDigit())
                }
            } else {
                Text("No hand yet").font(.headline).foregroundStyle(.white.opacity(0.6))
            }
        }
    }
}

#Preview {
    TableView()
}
