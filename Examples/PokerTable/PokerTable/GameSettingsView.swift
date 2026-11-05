import PokerEngine
import SwiftUI

struct GameSettingsView: View {
    @Bindable var game: Game
    @Environment(\.dismiss) private var dismiss
    /// Why the hand could not take the last stack correction.
    @State private var refusal: String?

    var body: some View {
        NavigationStack {
            Form {
                if let hand = game.session?.state, !hand.isHandComplete {
                    Section {
                        ForEach(hand.config.startingStacks.indices, id: \.self) { player in
                            Stepper(
                                "\(game.name(of: player)) started with \(hand.config.startingStacks[player])",
                                value: startingStack(of: player), in: 1...100_000, step: 10
                            )
                        }
                    } header: {
                        Text("This hand")
                    } footer: {
                        Text(refusal ?? "Correct a stack entered wrong, and the hand is replayed on it.")
                            .foregroundStyle(refusal == nil ? Color.secondary : Color.red)
                    }
                }
                Section("Next hand") {
                    Picker("Game", selection: $game.variant) {
                        Text("No-Limit Hold'em").tag(HandConfig.Variant.noLimitTexasHoldem)
                        Text("Pot-Limit Omaha").tag(HandConfig.Variant.potLimitOmahaHoldem)
                    }
                    .pickerStyle(.segmented)
                    Stepper("Big blind: \(game.bigBlind)", value: $game.bigBlind, in: 2...100, step: 2)
                    Stepper("Buy-in: \(game.startingStack)", value: $game.startingStack, in: 20...2000, step: 20)
                    Button("Reset every stack to the buy-in") { game.resetStacks() }
                        .disabled(!game.isBetweenHands)
                }
                Section {
                    Button("Void this hand", role: .destructive) {
                        game.enter(.voidHand)
                        dismiss()
                    }
                    .disabled(game.isBetweenHands)
                } footer: {
                    Text("For a misdeal or a fouled deck: every chip goes back, and the redeal keeps the button.")
                }
            }
            .formStyle(.grouped)
            .navigationTitle("Settings")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }

    private func startingStack(of player: Int) -> Binding<Int> {
        Binding {
            game.session?.state.config.startingStacks[player] ?? 0
        } set: { stack in
            refusal = game.correctStartingStack(of: player, to: stack)
        }
    }
}
