# PokerEngine

The rules of No-Limit Texas Hold'em and Pot-Limit Omaha as a Swift package, for a dealer app at a home game. The dealer
enters every action and bet on one device, a camera identifies each card as it is dealt, and finished hands are stored
as hand histories for players to review later.

PokerEngine is the rules part of that app. It has no UI, camera, networking or persistence code, and no third-party
dependencies. The app tells it what happened at the table, and it says what is legal, what comes next and who won.

It is a port of the state machine in [PokerKit](https://github.com/uoftcprg/pokerkit) 0.7.7, checked against PokerKit
step by step. [DECISIONS.md](DECISIONS.md) records the rule choices, the differences from PokerKit and what was left
out.

This README is for the developer building the app. For a working example, [Examples/PokerTable](Examples/PokerTable)
is a small dealer app built on the engine, with a shuffled deck standing in for the camera. Open its
`PokerTable.xcodeproj` and run it on a simulator.

- [Adding the package](#adding-the-package)
- [The API at a glance](#the-api-at-a-glance)
- [A full hand](#a-full-hand)
- [Driving the UI](#driving-the-ui)
- [All-ins and running it twice](#all-ins-and-running-it-twice)
- [Seats and forced bets](#seats-and-forced-bets)
- [Pot-Limit Omaha](#pot-limit-omaha)
- [Correcting a misread](#correcting-a-misread)
- [Storing and exporting a hand](#storing-and-exporting-a-hand)
- [Rules the dealer will notice](#rules-the-dealer-will-notice)
- [Verification](#verification)

## Adding the package

PokerEngine needs iOS 17 or macOS 14. It is built and tested with Swift 6.4, in Swift 6 language mode.

In Xcode, choose **File > Add Package Dependencies**, paste `https://github.com/davidarice/PokerEngine`, and set the
dependency rule to **Up to Next Minor Version** from `0.2.4`. Add `PokerEngine` to the app target, and
`PokerEngineObservation` too if the app uses `TableSession`.

The rule stops at the next minor version because, while the version starts with 0, a minor release may change the API.
To work on the engine and the app together, add a local checkout instead, with **Add Local** in Xcode or
`.package(path: "../PokerEngine")` in a manifest.

In a manifest:

```
platforms: [.iOS(.v17), .macOS(.v14)],
dependencies: [
    .package(url: "https://github.com/davidarice/PokerEngine.git", .upToNextMinor(from: "0.2.4")),
],
targets: [
    .target(name: "DealerApp", dependencies: [
        .product(name: "PokerEngine", package: "PokerEngine"),
        .product(name: "PokerEngineObservation", package: "PokerEngine"),
    ]),
],
```

`package:` is the last part of the repository URL, or the name of the checkout folder.

| Product | What it holds |
| --- | --- |
| `PokerEngine` | The rules, as value types. It imports Foundation and nothing else from Apple. |
| `PokerEngineObservation` | `TableSession`, an `@Observable` wrapper around a hand for SwiftUI. Optional. It does not re-export `PokerEngine`, so import both. |

## The API at a glance

- **A hand is a value.** `HandState(config:)` starts a hand. `apply(_:)` returns the next state, or throws an
  `EngineError` and leaves the state as it was. `HandState` is `Sendable`, and an old state stays valid.
- **The operations are the hand.** `hand.operations` holds what the dealer entered, and replaying them on `hand.config`
  gives the same state. Undo, corrections and storage all work this way.
- **The engine keeps the books.** With the default automations the dealer never enters blinds, antes or payouts, and
  never moves bets to the pot. One `apply(_:)` can run all of that, and `hand.log` lists every step with its amounts.
- **The engine says what is legal.** `pendingOperation`, `legalActions` and `canApply(_:)` use the same checks as
  `apply(_:)`, so the UI cannot disagree with the engine on what is legal. A few choices are left to the app, such as
  checking `boards` before offering a muck, and the sections below say where.
- **Players are numbers.** Player 0 is the first seat left of the button and the last player is the button. See
  [Seats and forced bets](#seats-and-forced-bets).
- **Chips are whole numbers.** Amounts are `Int`, so make the smallest chip 1.
- **There is no rake.** Every pot is paid in full, so `stacks`, `net` and `won` ignore any rake or drop. A game that
  takes one must adjust the stacks itself between hands.

| Type | What it is |
| --- | --- |
| `HandConfig` | One hand's setup: the game, mode, stacks for 2 to 10 players, antes, blinds, minimum bet and automations. `init` throws `ConfigError`. |
| `HandState` | The hand. See the next table. |
| `HandOperation` | One thing the dealer enters. |
| `PendingOperation`, `ForcedBet` | What the hand is waiting for. |
| `LegalActions`, `BetOrRaise` | What the player to act may do. |
| `EngineError`, `ReplayError`, `RedactionError` | Why an operation, a replay or a redaction was refused. `DealKind`, `CardLocation` and `RaiseUnavailableReason` are their details. |
| `LogEntry`, `HandEvent` | One row of the hand's history. |
| `PlayerResult` | One player's outcome. |
| `Card`, `Rank`, `Suit` | `.known(.ace, .spades)`, or `.unknown` for a card nobody scanned. `Card("As")` and `Card.parse("AsKs")` read text, and the second throws `CardParseError`. |
| `HandRank`, `HandCategory` | A player's best five cards. `category.label` is text such as "Two pair". |
| `Pot`, `HoleCard`, `PlayerStatus`, `Street` | Values the queries return. |
| `TableSession` | In `PokerEngineObservation`: an observable hand with undo and corrections. |
| `TableState`, `TableError` | The table between hands: seats, chips, stakes and the button. It deals each hand and takes its chips back. |

| To show | Read from `HandState` |
| --- | --- |
| What comes next | `pendingOperation`, `actor`, `legalActions`, `isHandComplete` |
| Chips | `stacks`, `bets` (in front of each player), `pots` (collected, main pot first), `totalPot` (both) |
| Cards | `holeCards`, `boards` (one per run) |
| Players | `statuses`, `hand(of:board:faceUpOnly:)` for a player's best hand, `dealtHand(of:board:faceUpOnly:)` for anyone's, from the cards as dealt |
| Progress | `street`, `runoutCount` |
| History | `log` for display, `operations` for replay. See [Correcting a misread](#correcting-a-misread). |
| The outcome | `results`, nil until the hand is complete. See [The end of the hand](#the-end-of-the-hand-results). |

`toCall`, `minRaiseTo` and `maxRaiseTo` give the numbers in `legalActions` on their own.

## A full hand

This hand goes from the first card to the payout, one operation at a time. Every `swift` block in this README is also
part of [ReadmeTests.swift](Tests/PokerEngineTests/Readme/ReadmeTests.swift), so it compiles against the public API and
runs in `swift test`, and the test fails if the two copies differ. Read each `#expect` line as what the hand holds at
that point.

```swift
// Blinds of 1 and 2, three players with 200 each.
// Player 0 is the small blind, player 1 the big blind and player 2 the button.
let config = try HandConfig(
    mode: .cashGame, startingStacks: [200, 200, 200], blindsOrStraddles: [1, 2], minBet: 2
)

// `automations` defaults to `.bookkeeping`, so a new hand has already posted its blinds.
var hand = HandState(config: config)
#expect(hand.bets == [1, 2, 0])
#expect(hand.stacks == [199, 198, 200])
#expect(hand.pendingOperation == .dealHoleCard(player: 0, cardIndex: 0))

// Hole cards, one operation per card, starting from player 0.
hand = try hand.apply(.dealHole(player: 0, card: .known(.seven, .hearts)))
#expect(hand.pendingOperation == .dealHoleCard(player: 1, cardIndex: 0))
hand = try hand.apply(.dealHole(player: 1, card: .known(.queen, .diamonds)))
hand = try hand.apply(.dealHole(player: 2, card: .known(.ace, .spades)))
hand = try hand.apply(.dealHole(player: 0, card: .known(.two, .clubs)))
hand = try hand.apply(.dealHole(player: 1, card: .known(.jack, .diamonds)))
hand = try hand.apply(.dealHole(player: 2, card: .known(.king, .clubs)))

// Preflop. The button acts first, facing the big blind.
#expect(hand.street == .preflop)
#expect(hand.pendingOperation == .act(player: 2))
#expect(hand.legalActions?.canFold == true)
#expect(hand.legalActions?.toCall == 2)
#expect(hand.legalActions?.betOrRaise == .raise(4...200))
hand = try hand.apply(.betOrRaise(player: 2, to: 6))   // `to` is a total for the street
#expect(hand.pendingOperation == .act(player: 0))
#expect(hand.legalActions?.toCall == 5)
hand = try hand.apply(.fold(player: 0))
#expect(hand.legalActions?.toCall == 4)
hand = try hand.apply(.checkOrCall(player: 1))         // a call of 4

// Betting is over, so the bets have moved to the pot by themselves.
#expect(hand.bets == [0, 0, 0])
#expect(hand.totalPot == 13)
#expect(hand.statuses == [.folded, .active, .active])

// The flop. A burn comes first, and its card is rarely seen.
#expect(hand.pendingOperation == .burnCard(street: .flop, runout: 0))
hand = try hand.apply(.burnCard(.unknown))
#expect(hand.pendingOperation
    == .dealBoardCard(street: .flop, runout: 0, cardIndex: 0, cardCount: 3))
hand = try hand.apply(.dealBoard(.known(.jack, .clubs)))
hand = try hand.apply(.dealBoard(.known(.eight, .diamonds)))
hand = try hand.apply(.dealBoard(.known(.three, .spades)))

// Player 0 has folded, so player 1 is first to act. Nobody has bet, so `toCall` of 0 is a check.
#expect(hand.pendingOperation == .act(player: 1))
#expect(hand.legalActions?.toCall == 0)
#expect(hand.legalActions?.betOrRaise == .bet(2...194))
hand = try hand.apply(.checkOrCall(player: 1))         // a check
hand = try hand.apply(.betOrRaise(player: 2, to: 10))
hand = try hand.apply(.checkOrCall(player: 1))         // a call

// The turn.
hand = try hand.apply(.burnCard(.unknown))
hand = try hand.apply(.dealBoard(.known(.two, .diamonds)))
hand = try hand.apply(.checkOrCall(player: 1))
hand = try hand.apply(.checkOrCall(player: 2))

// The river.
hand = try hand.apply(.burnCard(.unknown))
hand = try hand.apply(.dealBoard(.known(.nine, .hearts)))
hand = try hand.apply(.betOrRaise(player: 1, to: 20))
hand = try hand.apply(.checkOrCall(player: 2))

// The showdown. The last bettor shows first, and pots go to hands shown face up.
#expect(hand.pendingOperation == .showdown(runoutSelectors: [], showOrder: [1, 2]))
#expect(hand.hand(of: 1)?.description == "One pair (QdJdJc8d9h)")
hand = try hand.apply(.showHoleCards(player: 1))
hand = try hand.apply(.muckHoleCards(player: 2))

// Nothing is left to enter: the pot was pushed and pulled by itself.
#expect(hand.isHandComplete)
#expect(hand.pendingOperation == nil)
#expect(hand.stacks == [199, 237, 164])
#expect(hand.boards == [try Card.parse("Jc8d3s2d9h")])
#expect(hand.results?.map(\.net) == [-1, 37, -36])
#expect(hand.results?.map(\.won) == [0, 73, 0])
#expect(hand.results?.map(\.status) == [.folded, .active, .mucked])
#expect(hand.results?.map(\.shown) == [false, true, false])
#expect(hand.operations.count == 26)
```

The dealer entered 26 operations. Everything else came from the engine: the blinds, moving bets to the pot, and paying
the winner.

## Driving the UI

Keep a `TableSession` in the view, draw from `session.state`, and send each thing the dealer does to
`session.apply(_:)`. In SwiftUI, hold it in `@State private var session: TableSession?` and assign
`TableSession(config:)` where each hand starts, because a property initializer cannot read a `config` from the view and
`HandConfig.init` throws. Any view that reads `session.state` redraws when it changes. `TableSession` is `@MainActor`.

```swift
let session = TableSession(config: config)
try session.apply(.dealHole(player: 0, card: .known(.seven, .hearts)))
#expect(session.state.operations.count == 1)
#expect(session.canUndo)

session.undo()
#expect(session.state == HandState(config: config))
#expect(!session.canUndo)
```

A new hand is a new `TableSession`. If you prefer not to use the wrapper, keep a `HandState` yourself: `TableSession`
adds only undo and corrections, which are short functions over `replay(config:operations:)`.

### What comes next: `pendingOperation`

`pendingOperation` is the one thing to switch on. This function turns it into a status line, and each case's comment
names the operation that answers it. The switch has no `default`, so a new case would stop it compiling. Two operations
are never pending, a chop and a void, so offer them as [A chop or a void](#a-chop-or-a-void) explains.

```swift
func prompt(for hand: HandState, naming name: (Int) -> String) -> String {
    func list(_ players: [Int]) -> String { players.map(name).joined(separator: ", ") }

    return switch hand.pendingOperation {
    // Cards. Arm the camera for the two deals, and enter a burn at once (see Burns below).
    case .burnCard:
        "Burn a card"                                // .burnCard(.unknown)
    case let .dealHoleCard(player, _):
        "Deal to \(name(player))"                    // .dealHole(player: player, card: card)
    case let .dealBoardCard(street, runout, cardIndex, cardCount):
        "Run \(runout + 1): \(street) card \(cardIndex + 1) of \(cardCount)"  // .dealBoard(card)

    // Betting. Build the action bar from `legalActions`.
    case let .act(player):
        "\(name(player)) to act"                     // .fold, .checkOrCall or .betOrRaise

    // The showdown. Everyone listed needs an operation, in any order.
    case let .showdown(runoutSelectors, showOrder):  // .selectRunoutCount for `runoutSelectors`,
        if runoutSelectors.isEmpty {                 // .showHoleCards or .muckHoleCards for `showOrder`
            "\(name(showOrder[0])) to show or muck"
        } else {
            "Runs to choose: \(list(runoutSelectors))"
        }

    // The hand is over. Read `results`.
    case nil:
        "Hand complete"

    // Reached only when the matching automation is off. `.bookkeeping` has them all on.
    case let .postAnte(owed):
        "Antes to post: \(list(owed.map(\.player)))"     // .postAnte(player:)
    case .collectBets:
        "Collect the bets"                               // .collectBets
    case let .postBlindOrStraddle(owed):
        "Blinds to post: \(list(owed.map(\.player)))"    // .postBlindOrStraddle(player:)
    case let .killHand(players):
        "Hands to kill: \(list(players))"                // .killHand(player:)
    case .pushChips:
        "Push the pot"                                   // .pushChips
    case let .pullChips(players):
        "Chips to pull: \(list(players))"                // .pullChips(player:)
    }
}
```

**Cards.** The camera supplies the card and `pendingOperation` supplies the rest. `.dealHoleCard` suggests a player,
going round one card at a time from player 0. Any player still owed a card may be dealt instead, so the dealer can
override the suggestion if a card goes to someone else.

**Burns.** A burn is required before every flop, turn and river, and it stays face down, so enter `.burnCard(.unknown)`
as soon as one is pending. If the camera does see the card, pass it: the engine then refuses to deal that card again. An
app that enters burns by itself must also take them back: after `undo()`, if `pendingOperation` is `.burnCard`, call
`undo()` again before entering anything. Otherwise the burn comes straight back and Undo never gets past it.

**The show order.** `showOrder` starts with the player who should show first, but the engine accepts the players in any
order.

### The action bar: `legalActions`

When `pendingOperation` is `.act`, `legalActions` has everything the bar needs, and it is nil at any other time.

```swift
func buttons(for actions: LegalActions) -> [String] {
    var buttons = actions.canFold ? ["Fold"] : []
    buttons.append(actions.toCall == 0 ? "Check" : "Call \(actions.toCall)")
    switch actions.betOrRaise {
    case let .bet(amounts):
        buttons.append("Bet \(amounts)")             // for example "Bet 2...194"
    case let .raise(amounts):
        buttons.append("Raise to \(amounts)")        // for example "Raise to 4...200"
    case .unavailable:
        break
    }
    return buttons
}
```

- **Amounts are street totals.** `.betOrRaise(player:to:)` takes the player's total for the street, counting what is
  already in front of them. A big blind with 2 in who adds 6 more enters `to: 8`.
- **The range includes both ends**, and any whole number in it is legal. The top is the player's whole stack, even if
  nobody can call it all: the excess comes back when bets are collected. The bottom is below the usual minimum only when
  it is the player's whole stack.
- **`toCall` is capped at the stack.** If `toCall` equals `stacks[player]`, calling puts the player all in.
- **`canFold` can be false.** That happens in a tournament when checking is free, and when the fold would leave a pot
  with nobody able to win it. A cash game does allow folding when checking is free, so `canFold && toCall == 0` is a
  good place for a confirmation.
- **`.unavailable(reason)`** means the player can only fold, check or call. `reason` says why: the player is covered,
  the all-in was not a full raise, or nobody else could call a raise.

### Optional moves: `canApply(_:)`

`pendingOperation` says what the hand is waiting for, not which answers are allowed. `canApply(_:)` answers that
exactly, because it runs `apply(_:)` on a copy, with everything the operation would set off. Use it to enable the
buttons at the showdown, after checking `boards` and `holeCards`, as the end of this section explains:

```swift
// Player 1 may show both cards, show one, keep both face down or muck.
#expect(hand.canApply(.showHoleCards(player: 1)))
#expect(hand.canApply(.showHoleCards(player: 1, cards: [.known(.queen, .diamonds)])))
#expect(hand.canApply(.showHoleCards(player: 1, cards: [])))
#expect(hand.canApply(.muckHoleCards(player: 1)))

// If player 1 mucks, player 2 may not: nobody would be left to win the pot.
hand = try hand.apply(.muckHoleCards(player: 1))
#expect(!hand.canApply(.muckHoleCards(player: 2)))

// So player 2 keeps the cards face down and takes the pot, and `results` does not count them as shown.
#expect(hand.pendingOperation == .showdown(runoutSelectors: [], showOrder: [2]))
hand = try hand.apply(.showHoleCards(player: 2, cards: []))
#expect(hand.isHandComplete)
#expect(hand.results?[2].shown == false)
```

The `cards:` argument is what separates the moves:

| Operation | Meaning |
| --- | --- |
| `.showHoleCards(player: p)` | Turn every hole card face up. Refused while one is unknown. |
| `.showHoleCards(player: p, cards: [card])` | Show these cards. In a cash game the others stay face down. In a tournament, or once the hand is over, a show must turn up every card, so a shorter list is refused with `.mustShowAllCards`, except from the player left at a tournament showdown with nobody all in. A list may not hold `.unknown`. |
| `.showHoleCards(player: p, cards: [])` | Show nothing and stay in the hand. In a cash game, or for the player left at a tournament showdown with nobody all in. |
| `.muckHoleCards(player: p)` | Give up the hand. |

When `.showdown` comes back after an all-in, each list replaces the last one: a card left out goes back face down, even
one already shown, so list those again. See [All-ins](#all-ins-and-running-it-twice).

Pots go to hands shown face up, so **a hand kept face down plays the board** and can lose to anything shown. In Omaha
it cannot play the board, as [Pot-Limit Omaha](#pot-limit-omaha) explains.

Most tables need three buttons: Show, Muck and Keep face down. The third is how a player takes the pot unseen once
everyone else has mucked: that player cannot muck, and Show would record the cards as shown, or be refused if one is
unscanned. While anyone else is still in, even all in, it means playing the board as above. A tournament allows Keep
only for the player left with nobody all in, who wins without tabling as tournament rules say. After an all-in every
hand is tabled, so there the player left must show.

**A false `canApply(_:)` gives no reason.** `apply(_:)` on the same operation throws it, if you want to show it. Two
cases need handling, both from a card the camera missed:

- **An unknown board card.** With two or more players left it refuses every operation that would settle the hand, so
  Show goes dark for the last to answer, and Muck may be the only button left, which gives the pot away. At a
  `.showdown`, check `boards` for `.unknown` first and ask for that card, as [Unscanned cards](#unscanned-cards) shows.
- **An unknown hole card.** Show goes dark for that player. If `holeCards[p]` holds `.unknown`, make Show scan the cards
  and send `.showHoleCards(player: p, cards: scanned)` with every card listed: a shorter list is a partial show, which
  a tournament refuses from anyone but the player left with nobody all in. A list holding `.unknown` is refused with
  `.cannotShowUnknownCard`, so a rescan that misses a card cannot pass for a partial show. A tournament player who
  cannot muck and may not keep has no other button. Correcting the deal also brings Show back.

### A chop or a void

`pendingOperation` never asks for these two, so offer each as a button where `canApply(_:)` allows it. Either ends the
hand with every stack back where it started, and nothing is accepted after it, not even a show.

- **Chop** (`.chopBlinds`): in a cash game, when everyone else has folded before the flop, the blinds may agree to
  take their blinds back, as Robert's Rules of Poker allows. It is refused once either blind has put in more, and when
  anyone else has a chip in the pot, such as an ante. A big-blind ante goes back to the big blind. The button moves on,
  as after any hand.
- **Void** (`.voidHand`): a misdeal, or a fouled deck such as two of one card. It is accepted at any point, even once
  the hand is over, because a fouled deck voids the hand whenever it is found, so the table's rules decide when to
  offer it. The redeal after a misdeal is an exact replay with the same button. [`TableState`](#seats-and-forced-bets)
  moves or keeps the button by itself.

```swift
// Player 2 folds, and the blinds agree to chop.
hand = try hand.apply(.fold(player: 2))
#expect(hand.canApply(.chopBlinds))
hand = try hand.apply(.chopBlinds)
#expect(hand.isHandComplete)
#expect(hand.results?.map(\.net) == [0, 0, 0])

// Another hand was paid out before two of one card turned up. A void gives every chip back.
let voided = try paid.apply(.voidHand)
#expect(voided.stacks == voided.config.startingStacks)
#expect(voided.results?.map(\.won) == [0, 0, 0])
#expect(voided.operations.last == .voidHand)
```

The log's last row is `.blindsChopped` or `.handVoided`, with what each player got back, and `operations.last` says
which ended the hand. A void after the hand changes the stacks as a correction does, so carry it over as
[Correcting a misread](#correcting-a-misread) says.

### The end of the hand: `results`

When `pendingOperation` is nil, `results` has one entry per player:

| Field | What it holds |
| --- | --- |
| `net` | The change in the player's stack. This is the number to show. |
| `won` | The chips pushed from pots, which usually include the player's own. |
| `status` | `.active`, `.folded`, `.mucked` or `.killed`. |
| `holeCards` | Every scanned card, folded and mucked hands included, as `card` and `isFaceUp`. `isFaceUp` says whether it was shown at any point, so show other players only those. |
| `shown` | Whether every hole card was shown. |

`.killed` is how a beaten hand ends: settlement takes out any hand that cannot win a pot, shown or not. `.active` only
means the hand was not folded, mucked or killed, and it can have a negative `net`, so find the winners from `won` and
`net`, not from `status`. If nobody has `won` or `net` above 0, either the hand ended in a chop or a void, which
`operations.last` says, or everyone else folded, no chips changed hands, and the winner is the only `.active` player.

`hand(of:)` counts the face-down cards `holeCards` still holds, so from the flop on it names the hidden hand of a winner
the others folded to. Cards kept face down on the last run's river are forgotten, so after that Keep it ranks only what
is left, even if that is the board alone. On anything the table sees, pass `faceUpOnly: true`, as pots are awarded.
That is nil under five face-up cards, board included, and the board's own rank if nothing was shown.

Once a player is out, `holeCards[p]` on the state is empty and `hand(of:)` is nil, even for a hand that was shown.
`dealtHand(of:)` ranks the cards `results` keeps instead, whatever became of the hand, so it names a beaten, mucked or
folded hand, and a hand kept face down after the river forgot it:

```swift
// Both players showed, and player 2 lost. The state has let go of the cards, but `dealtHand(of:)` ranks them.
#expect(hand.statuses == [.folded, .active, .killed])
#expect(hand.holeCards[2].isEmpty)
#expect(hand.hand(of: 2) == nil)
#expect(hand.dealtHand(of: 2)?.description == "High card (AsKcJc8d9h)")

// Player 0 folded before the flop and is ranked with the whole board. Nothing was shown, so face up only,
// that is the board's own rank.
#expect(hand.dealtHand(of: 0)?.description == "One pair (2cJc8d2d9h)")
#expect(hand.dealtHand(of: 0, faceUpOnly: true)?.description == "High card (Jc8d3s2d9h)")
```

It takes `board:` and `faceUpOnly:` as `hand(of:)` does, and gives the same answers on a stored hand. `faceUpOnly`
counts a card shown at any point, as `results` marks it. To show players only what the table saw, pass
`faceUpOnly: true` and leave out anyone with no card face up in `results`.

`canApply(_:)` also offers a show after the hand is over, to any player still `.active`, such as a winner the others
folded to. It changes `results` and `operations` but never the chips, so store the hand again afterwards. Offer it only
when `isHandComplete` is true: with `.chipsPushing` removed, `canApply(_:)` also accepts a show while `.pushChips` is
pending, and that show can change who is paid. A show after the hand must turn up every card. It stays allowed for a
player who has already shown, so check `shown` as well.

```swift
// The hand is over, and player 2 won it when the others folded. Offer "Show anyway".
#expect(hand.isHandComplete)
#expect(hand.canApply(.showHoleCards(player: 2)))
#expect(hand.results?[2].shown == false)
#expect(!hand.canApply(.showHoleCards(player: 1)))     // player 1 folded
```

After a card is kept face down on the last river, a later show must list the cards, and `canApply(_:)` with no list is
false, so ask it with the cards from `results`, scanning any that are still `.unknown`.

### Errors

When `apply(_:)` throws, the state has not changed. Show `error.message(naming:)` to the dealer, and pass your seat
labels so that it names seats rather than player numbers. The engine only calls that closure with valid players, so
`seats[player]` is safe.

```swift
func name(_ player: Int) -> String { "Seat \(seats[player])" }

func enter(_ operation: HandOperation) -> String? {
    do {
        try session.apply(operation)
        return nil
    } catch {
        return error.message(naming: name)     // `error` is an `EngineError` here
    }
}
```

Inside a closure, such as a SwiftUI `Button` action, Swift 6.4 types a plain `catch` as `any Error`, and
`error.message(naming:)` does not compile. Call a method like `enter`, or say the type:

```swift
let buttonAction = {
    do throws(EngineError) {
        try session.apply(.fold(player: 0))
    } catch {
        alert = error.message(naming: name)
    }
}
```

The queries above prevent most errors. These are the ones a dealer will still meet:

| Error | Cause | What to do |
| --- | --- | --- |
| `.duplicateCard` | The camera read a card that is already in play. | Rescan. If the earlier read was the wrong one, [correct it](#correcting-a-misread). If there really are two of that card, the deck is fouled, and the usual rule voids the hand and returns every bet: enter [`.voidHand`](#a-chop-or-a-void). |
| `.noDealExpected`, `.burnRequired` | A card arrived when that deal was not due. | Arm the camera only for the deal cases. |
| `.shownCardNotDealt` | A listed show does not match the scan. | Rescan, or correct the deal if the scan was wrong. |
| `.cannotShowUnknownCard` | A show of all cards, with one unscanned or kept face down on the last river, or a list holding `.unknown`. | List the cards: scan them, or take them from `results`. Leave out a card to keep it face down. |
| `.mustShowAllCards` | A partial show, in a tournament or after the hand. | Show every card. |
| `.wouldAbandonPot` | The fold or muck would leave a pot nobody can win. | After a fold, call or check instead. After a muck, show, or in a cash game keep the cards face down. |
| `.unknownBoardCard` | The hand cannot settle with an unscanned board card. | [Enter that card](#unscanned-cards), then repeat the operation. |

[DECISIONS.md](DECISIONS.md), section D, lists every `EngineError` and the PokerKit refusal it stands for. Only
`EngineError` has `message(naming:)`, so the UI words `ConfigError`, `PHHExportError` and `ReplayError` itself. A
`ReplayError` holds an `EngineError` in its `error` property, and
[ConfigError.swift](Sources/PokerEngine/Config/ConfigError.swift) lists what a config can refuse.

These calls stop the program on a bad argument, because that is a bug in the caller: `hand(of:)` and `dealtHand(of:)`
with an invalid player, `replacingOperation(at:with:)` and `replaceOperation(at:with:)` with an invalid index, and
`playerOrder(occupiedSeats:buttonSeat:)` with a repeated seat. An index kept while the dealer rescans can go stale, so
check it first, as `correct(_:to:in:)` does under [Correcting a misread](#correcting-a-misread).

## All-ins and running it twice

Once betting can no longer continue before the river, because at most one player still in the hand has chips, the rest
of the board is dealt with no more betting. Before the next card:

1. In a cash game, every player still in the hand chooses how many times to run the rest of the board, with
   `.selectRunoutCount(player:count:)`. A count of `nil` means no preference.
2. Every player shows or mucks, as at a showdown.

Both lists are in `.showdown`, and they can be entered in any order. Each run then gets its own burns and cards, and
`pendingOperation` says which run it is dealing.

```swift
let config = try HandConfig(
    mode: .cashGame, startingStacks: [100, 100, 100], blindsOrStraddles: [1, 2], minBet: 2
)
var hand = try HandState.replay(config: config, operations: [
    .dealHole(player: 0, card: .known(.seven, .hearts)),
    .dealHole(player: 1, card: .known(.ace, .spades)),
    .dealHole(player: 2, card: .known(.king, .hearts)),
    .dealHole(player: 0, card: .known(.two, .clubs)),
    .dealHole(player: 1, card: .known(.ace, .hearts)),
    .dealHole(player: 2, card: .known(.king, .clubs)),
    .checkOrCall(player: 2),                 // the button calls 2
    .fold(player: 0),                        // the small blind leaves 1 chip in the pot
    .checkOrCall(player: 1),                 // the big blind checks
    .burnCard(.unknown),
    .dealBoard(.known(.king, .spades)),
    .dealBoard(.known(.seven, .diamonds)),
    .dealBoard(.known(.two, .hearts)),
    .betOrRaise(player: 1, to: 98),          // all in
    .checkOrCall(player: 2),                 // also all in, so nobody can bet again
])

// Before any more cards, both players choose a run count and show or muck, in any order.
#expect(hand.pendingOperation == .showdown(runoutSelectors: [1, 2], showOrder: [1, 2]))
hand = try hand.apply(.selectRunoutCount(player: 1, count: 2))
hand = try hand.apply(.selectRunoutCount(player: 2, count: 2))
hand = try hand.apply(.showHoleCards(player: 1))
hand = try hand.apply(.showHoleCards(player: 2))
#expect(hand.runoutCount == 2)

// The first run.
#expect(hand.pendingOperation == .burnCard(street: .turn, runout: 0))
hand = try hand.apply(.burnCard(.unknown))
hand = try hand.apply(.dealBoard(.known(.five, .clubs)))
hand = try hand.apply(.burnCard(.unknown))
hand = try hand.apply(.dealBoard(.known(.nine, .diamonds)))

// The second run deals the same streets again, with burns of its own.
#expect(hand.pendingOperation == .burnCard(street: .turn, runout: 1))
hand = try hand.apply(.burnCard(.unknown))
hand = try hand.apply(.dealBoard(.known(.ace, .diamonds)))
hand = try hand.apply(.burnCard(.unknown))
hand = try hand.apply(.dealBoard(.known(.three, .hearts)))

// Each run has a board, and the cards dealt before the all-in are on both.
#expect(hand.isHandComplete)
#expect(hand.boards == [try Card.parse("Ks7d2h5c9d"), try Card.parse("Ks7d2hAd3h")])

// Three kings win the first run and three aces the second. The pot of 201 splits across
// the runs, and the odd chip goes to the first.
#expect(hand.results?.map(\.won) == [0, 100, 101])
#expect(hand.stacks == [99, 100, 101])

// PHH cannot write a second board.
#expect(throws: PHHExportError.multipleRunouts(count: 2)) { try hand.phh() }
```

- **The count.** Players who name the same count get it, and `nil` agrees with anything. Any disagreement means one run,
  and so does nobody naming a count. `runoutCount` changes when the first showdown ends. A player who
  mucks before choosing stays in `runoutSelectors`, and no card comes until that entry is made, so build the count
  control from that list, not from `statuses`, and enter `nil` for a player who has gone.
- **Never running it twice.** Pass `automations: .bookkeeping.union([.runoutCountSelection])`, and every player abstains
  by themselves.
- **Tournaments** have no choice of count, so `runoutSelectors` is empty, and a show must turn up every card. A muck is
  still accepted, so an app that tables every hand at an all-in must hide Muck itself.
- **A hand kept face down** is asked again after each street, so `.showdown` can come back between cards. Each answer
  replaces the last one: a card left out goes back face down and stops counting, though `results` keeps `isFaceUp` true
  for it. So send Keep as `cards: hand.holeCards[p].filter(\.isFaceUp).map(\.card)`, which is `[]` when no card is up.
  During an ask between runs, `street` goes back to the street of the all-in even with a finished board on the table,
  so label that screen from `boards`.
- **A muck can concede.** If a muck leaves one player before the river, that player still needs the next street dealt,
  and then wins as if everyone had folded. With several runs, `boards` can end up uneven.
- **The deck can run out.** There is no reshuffle. Four runs always fit, even with ten players all in before the flop,
  so offer 1 to 4. A higher count can run short of burns, and then `.burnCard(.unknown)` needs no card. A count the
  undealt cards cannot fill never settles, and `canApply(_:)` does not check for it. To free such a hand, use
  `replaceOperations(with:)`: give every player's `.selectRunoutCount` a smaller count and drop the operations of the
  runs that go.

## Seats and forced bets

A hand knows only player indices. `TableState` keeps what lasts from hand to hand: who sits in which of the 10 seats,
their chips, the stakes and the button. It deals each hand from that and takes each finished hand's chips back:

```swift
// Three players sit down, and the button starts on seat 5.
var table = try TableState(stakes: .init(mode: .cashGame, smallBlind: 1, bigBlind: 2), buttonSeat: 5)
try table.sit(2, stack: 300)
try table.sit(5, stack: 150)
try table.sit(7, stack: 200)

let deal = try table.nextHand()
#expect(deal.seats == [7, 2, 5])               // `deal.seats[i]` is the seat of player i
let session = TableSession(config: deal.config)
```

Play the hand as usual, then give it back with its deal:

```swift
// Everyone folded to the big blind, on seat 2. The chips go back to the seats, and the button moves on.
try table.finish(session.state, of: deal)
#expect(table.stacks == [2: 301, 5: 150, 7: 199])
#expect(try table.nextHand().seats.last == 7)
```

The rules are a home game's, for a dealer who decides who is at the table:

- **Anyone seated with chips is dealt in.** A player with no chips stays seated but is dealt out until a rebuy.
- **Between hands the dealer can change anything,** as at a real table:
  - `sit(_:stack:)` takes a seat, and `stand(_:)` empties it and returns the chips;
  - `setStack(of:to:)` is a rebuy, a top-up, or chips passed from one player to another;
  - `changeSeat(from:to:)` moves a player and their chips, or trades two players' seats;
  - `moveButton(to:)` puts the button on a seat for the next hand, or on the next player after it if nobody sits
    there.

  All of them wait for the hand in play to be finished. To drop a hand, void it and finish that.
- **The button moves to the next player** after every hand, a chop included, skipping empty seats and players with no
  chips. After a void it stays for the redeal. It belongs to its seat, so a player who changes seats leaves it behind.
- **Nobody owes a missed blind,** and a player who comes back is dealt in like anyone else. There are no straddles or
  live posts; for those, build the `HandConfig` yourself, as below.
- **A correction before the next deal:** finish the corrected hand again with the same deal. Only the difference moves,
  so a rebuy since is kept. It is refused once a player of that hand has stood up or changed seats, and once the next
  hand is dealt the result stands, as the rule books say.

After the next hand, everyone takes a break, and the dealer rearranges the table:

```swift
// A new player takes seat 3, seat 7 moves to seat 9, seat 2 passes seat 5 fifty chips, and the blinds go up.
try table.sit(3, stack: 200)
try table.changeSeat(from: 7, to: 9)
try table.setStack(of: 2, to: 250)
try table.setStack(of: 5, to: 201)
table.stakes.smallBlind = 2
table.stakes.bigBlind = 4
try table.moveButton(to: 9)

let afterTheBreak = try table.nextHand()
#expect(afterTheBreak.seats == [2, 3, 5, 9])
#expect(afterTheBreak.config.startingStacks == [250, 200, 201, 199])
#expect(afterTheBreak.config.blindsOrStraddles == [2, 4, 0, 0])
```

`stakes` can change between hands, and `minBet` follows the big blind unless set. `TableState` is `Codable`, so the app
can save it between launches, and decoding refuses a damaged save.

To build a hand yourself, `HandConfig.playerOrder(occupiedSeats:buttonSeat:)` gives the mapping, and `startingStacks`
follows it. Build a new `HandConfig` for each hand, because the button moves.

```swift
// Seats 2, 5, 7 and 9 are in the hand, and the button is on seat 5.
var stacksBySeat = [2: 300, 5: 150, 7: 200, 9: 120]
let seats = HandConfig.playerOrder(occupiedSeats: [2, 5, 7, 9], buttonSeat: 5)
#expect(seats == [7, 9, 2, 5])                 // `seats[i]` is the seat of player i

let config = try HandConfig(
    mode: .cashGame,
    startingStacks: seats.map { stacksBySeat[$0, default: 0] },
    blindsOrStraddles: [1, 2],
    minBet: 2
)
#expect(config.startingStacks == [200, 120, 300, 150])
```

Seats are numbered clockwise. Player 0 is the first occupied seat after the button, and the last player is the button.
If the button seat is empty, the occupied seat before it acts last.

Heads-up, player 0 is the big blind and player 1 is the button, which posts the small blind. `playerOrder` already gives
that order. `blindsOrStraddles` and `antes` are still written small blind first, and the engine reads them reversed.

`stacks` is in player order too, so map it back after the hand, and leave out anyone with no chips:

```swift
// When the hand is over, the stacks go back to the seats for the next hand's config.
for (player, seat) in seats.enumerated() {
    stacksBySeat[seat] = hand.stacks[player]
}
stacksBySeat = stacksBySeat.filter { $0.value > 0 }    // a stack of 0 is refused: rebuy or leave
```

Build the next hand's `playerOrder` from `Array(stacksBySeat.keys)`. A hand needs 2 to 10 players, so when one player is
left the game is over, and `HandConfig` would throw `.playerCountOutOfRange(1)`.

`blindsOrStraddles` and `antes` go by position, starting with the small blind. Shorter arrays are padded with 0, and
longer ones than the player count are refused.

| Game | `blindsOrStraddles` | `antes` | `anteTrimming` |
| --- | --- | --- | --- |
| Blinds of 1 and 2 | `[1, 2]` | | |
| Straddle of 4 from the seat after the big blind | `[1, 2, 4]` | | |
| Button straddle of 4, six players | `[1, 2, 0, 0, 0, 4]` | | |
| New player posting 2 live, third position | `[1, 2, -2]` | | |
| Dead small blind, when the house moves the big blind on and player 0 owes it | `[2]` | | |
| Player owing a dead 1 and posting 2 live, fourth position | `[1, 2, 0, -2]` | `[0, 0, 0, 1]` | `false` |
| Ante of 1 from everyone, six players | `[1, 2]` | `[1, 1, 1, 1, 1, 1]` | `true` |
| Big-blind ante of 2 | `[1, 2]` | `[0, 2]` | `false` |
| Button ante of 2, six players | `[1, 2]` | `[0, 0, 0, 0, 0, 2]` | `false` |

The six-player rows change with the table: the button is position `playerCount - 1` (heads-up, position 0), and an ante
from everyone needs one entry per player, for example `Array(repeating: 1, count: playerCount)`.

`mode` has no default, and `.cashGame` and `.tournament` differ in folds, runouts and shows. `minBet` is the minimum bet
and the smallest raise increment on every street, usually the big blind.

`automations` defaults to `.bookkeeping`, which is every automation except `.runoutCountSelection`. Removing one makes
that step a dealer operation, which `pendingOperation` then asks for.

## Pot-Limit Omaha

`variant` chooses the game, and its default is `.noLimitTexasHoldem`. With `.potLimitOmahaHoldem` everything above
works the same way, forced bets, all-ins, running it twice and corrections, apart from three things:

```swift
let omaha = try HandConfig(
    variant: .potLimitOmahaHoldem, mode: .cashGame, startingStacks: [200, 200, 200],
    blindsOrStraddles: [1, 2], minBet: 2
)
var hand = HandState(config: omaha)

// 1. Four hole cards each, still one card per operation.
for card in try Card.parse("AsKsQsAhKhQhAdKdQdAcKcQc") {
    guard case let .dealHoleCard(player, _)? = hand.pendingOperation else { break }
    hand = try hand.apply(.dealHole(player: player, card: card))
}
#expect(hand.holeCards.map(\.count) == [4, 4, 4])

// 2. No bet or raise above the pot. The button may call 2 and raise by the 5 then in the pot, to 7.
#expect(hand.legalActions?.betOrRaise == .raise(4...7))
hand = try hand.apply(.betOrRaise(player: 2, to: 7))
#expect(hand.legalActions?.betOrRaise == .raise(12...23))
```

3. **A hand is exactly two hole cards and three board cards.** `hand(of:)` and `dealtHand(of:)` rank it that way, so
   four aces make one pair, and one spade in the hand never makes a flush. With `faceUpOnly: true` a player needs two
   cards face up to have a hand at all.

That last rule changes Keep. Before the river a hand kept face down stays live, as in Hold'em. On the river the cards
kept face down are forgotten, and a hand cannot play the board, so a player who shows fewer than two cards has no hand
and cannot win anything while anyone else is still in. The engine refuses the answer that would leave a pot with nobody
holding a hand, with `.wouldAbandonPot`, as it refuses a fold or muck that would. Heads-up, after one Keep the other
player has to show two cards, or muck and let the first player take the pot unseen. `canApply(_:)` turns the refused
buttons off.

An Omaha hand is stored as `formatVersion` 2, with `"variant":"potLimitOmahaHoldem"` in its `config`. A Hold'em hand is
still written as version 1, so an app on an earlier version reads every Hold'em hand, and refuses an Omaha one. `phh()`
writes `variant = 'PO'`.

## Correcting a misread

There are two tools. `undo()` takes back the last thing the dealer did: an operation, with everything it set off, or a
correction. To change something earlier, replace it: the engine replays the whole hand with the change, and either gives
the corrected hand or throws and changes nothing.

Show `hand.log` as the hand's history. `isAutomated` marks the steps the engine took by itself, and the comments in
[HandEvent.swift](Sources/PokerEngine/HandEvent.swift) say what each row holds. Four rows need care:

- **A hand kept face down** still logs `.holeCardsShown`, with `.unknown` for each card left down, so word those rows
  from the cards.
- **When everyone else folds,** the winner's bet is in neither `collected` nor `returned`, so that `.betsCollected` row
  can be all zeros. The bet comes back only in `.chipsPulled`, which can be larger than the pushes.
- **When one player is left,** `.chipsPushed` has a `runout` of nil, even after a showdown on several runs.
- **When mucks and kills merge pots,** `.chipsPushed` numbers `pot` in the merged list, so it need not match the
  `pots` shown before settlement.

When the dealer taps a row with a wrong card and rescans, `operationIndex` leads to the operation to replace:

```swift
@MainActor
func correct(_ entry: LogEntry, to card: Card, in session: TableSession) throws(ReplayError) {
    // The hand can move on during a rescan, and then the row's index is wrong or gone.
    guard let index = entry.operationIndex, session.state.log.contains(entry) else { return }
    switch entry.event {
    case let .holeCardDealt(player, _):
        try session.replaceOperation(at: index, with: .dealHole(player: player, card: card))
    case .boardCardDealt:
        try session.replaceOperation(at: index, with: .dealBoard(card))
    case .cardBurned:
        try session.replaceOperation(at: index, with: .burnCard(card))
    default:
        break
    }
}
```

`operationIndex` is nil only for the steps a new hand runs by itself, before the first operation.

The operations after the change must still make sense. If they do not, `ReplayError` names the first one that no longer
fits, and why:

```swift
// Player 1 really folded preflop, not called (`operations[8]`). That ends the hand, so the
// burn after it no longer fits, and nothing changes.
let before = session.state
let refusal = #expect(throws: ReplayError.self) {
    try session.replaceOperation(at: 8, with: .fold(player: 1))
}
#expect(refusal?.operationIndex == 9)
#expect(refusal?.operation == .burnCard(.unknown))
#expect(refusal?.error == .handComplete)
#expect(refusal?.error.message() == "The hand is over.")
#expect(session.state == before)

// To go ahead, drop what came after the corrected operation.
let kept = session.state.operations[..<8]
try session.replaceOperations(with: kept + [.fold(player: 1)])
#expect(session.state.isHandComplete)
```

A correction can change who won, and it works on a finished hand. A call is worked out again on replay, but a bet's
`to:` stays the number entered, so after correcting an amount, check that every all-in bet or raise still takes the
whole stack: replay can accept one that no longer does. If the hand was already stored, store it again. With
`TableState`, finish the corrected hand again with its deal before the next hand is dealt, and only the change moves. If
you carried the stacks over yourself, do not copy them again, which would overwrite any later hand or top-up: when no
hand is under way, add the change in each player's final stack to their current stack. That can leave a stack at 0 or
below, which `HandConfig` refuses.

`undo()` reverses a correction as one step, even one that changed several operations or dropped some, and puts the hand
back as it was before. It goes newest first: after a correction and two more operations, it takes back those two, then
the correction, then the operations before it. A session made with `init(state:)`, as after a crash, holds no
corrections, so its `undo()` only takes back operations.

A wrong stack or forced bet is in `config`. The usual sign is a player with more chips than `legalActions` allows.
`replaceConfig(with:)` replays the hand's operations on a corrected `HandConfig`:

```swift
// Player 2 really had 260, not the 200 entered.
let old = session.state.config
let corrected = try HandConfig(
    mode: old.mode, startingStacks: [200, 200, 260], antes: old.antes, anteTrimming: old.anteTrimming,
    blindsOrStraddles: old.blindsOrStraddles, minBet: old.minBet, automations: old.automations
)
try session.replaceConfig(with: corrected)
#expect(session.state.stacks[2] == 224)
```

It can throw `ReplayError` like any correction. A bet's `to:` stays the number entered, so a player who went all in at
the old stack is left with chips behind, or with a bet too big for the new one. Change those bets in a copy of
`operations` and pass it too, as `replaceConfig(with:operations:)`. Operations name players by index, so a correction
cannot add or remove a player. `undo()` takes a correction back.

### When one card is in several operations

`replaceOperation(at:with:)` changes one operation. When a correction touches more than one, change a copy of
`operations` and pass the whole list to `replaceOperations(with:)`. Cards swapped between two players are the common
case:

```swift
// The 7h and the Qd were swapped. Correcting either one alone would repeat a card.
var operations = session.state.operations
operations[0] = .dealHole(player: 0, card: .known(.queen, .diamonds))
operations[1] = .dealHole(player: 1, card: .known(.seven, .hearts))
try session.replaceOperations(with: operations)
```

A show that lists its cards repeats them, so correcting the deal alone fails with `.shownCardNotDealt`:

```swift
// Another hand: player 1 showed by listing Qd and Jd, but the Jd was really the Js.
operations = session.state.operations
let showIndex = operations.count - 1           // the show is the last operation here
operations[4] = .dealHole(player: 1, card: .known(.jack, .spades))
operations[showIndex] = .showHoleCards(
    player: 1, cards: [.known(.queen, .diamonds), .known(.jack, .spades)]
)
try session.replaceOperations(with: operations)
```

If that player also has an unrevealed `.unknown` card, correcting only the deal is accepted, with the misread card left
in the hand. For a player with no unknown card, showing with `cards: nil` avoids this, because that show repeats no
card. Keep cannot use `cards: nil`: at an all-in it lists a shown card again on every ask, so change every
`.showHoleCards` of that player that lists it.

### Unscanned cards

If the camera misses a card, enter `.unknown` and carry on. A hole card can stay unknown until the player shows, and a
show that lists the card reveals it. With two or more players left, an unknown board card stops the hand settling: the
operation that would settle it throws `.unknownBoardCard` until the card is entered.

```swift
// Player 1's second card and the river were entered as `.unknown`.
#expect(!hand.canApply(.showHoleCards(player: 1)))     // the second card is unknown
#expect(hand.hand(of: 1) == nil)                       // the river is unknown

// A show that lists the cards reveals the unscanned one.
hand = try hand.apply(.showHoleCards(
    player: 1, cards: [.known(.queen, .diamonds), .known(.jack, .diamonds)]
))

// The last show would settle the hand, so it is refused, and the state stays as it was.
// Muck needs no board, so it is the only button left, and it gives the pot away.
#expect(!hand.canApply(.showHoleCards(player: 2)))
#expect(hand.canApply(.muckHoleCards(player: 2)))
#expect(throws: EngineError.unknownBoardCard(runout: 0, position: 4)) {
    try hand.apply(.showHoleCards(player: 2))
}

// Correct the river, and enter the show again.
let river = try #require(hand.operations.firstIndex(of: .dealBoard(.unknown)))
hand = try hand.replacingOperation(at: river, with: .dealBoard(.known(.nine, .hearts)))
hand = try hand.apply(.showHoleCards(player: 2))
#expect(hand.isHandComplete)
```

With an unknown card on a board and two or more players left, a deal that would settle the hand is refused and not
recorded. If the error names the card you just entered as `.unknown`, deal the scanned card. If it names an earlier
card, replace that operation first, then repeat the deal. `runout` and `position` say which card it is, and on several
runs it can be an earlier run's river.

`hand(of:board:)` and `dealtHand(of:board:)` are nil while that board holds an unknown card. With an unknown hole card
they rank only the known cards, so check `holeCards`, or `results` once the hand is over, before showing one.

## Storing and exporting a hand

`json()` writes the hand as a JSON document, and `HandState(json:)` reads it by replaying its operations. The same
document works for crash recovery and for upload. The engine saves nothing by itself, so write the document after every
operation if a crash must not lose the hand.

```swift
// `json()` works at any point in the hand, so the same document saves a hand under way.
let document = String(decoding: try hand.json(), as: UTF8.self)

// After a crash: read it back and carry on. Undo reaches back through the whole hand.
let session = TableSession(state: try HandState(json: Data(document.utf8)))
#expect(session.state == hand)
#expect(session.canUndo)
```

Keep the document as text in a `text` column of your row, and read it with `HandState(json:)`:

```swift
struct HandRow: Codable {
    let id: UUID
    let document: String                       // the text from `json()`, not a `HandState`
}
```

**Do not put a `HandState` in a `Decodable` row.** It compiles, but a plain decode skips the checks on the document's
text, so a hostile document can stall the reader for over a minute.

**Do not send this row to a `jsonb` column.** PostgREST stores a `String` in a `jsonb` column as one JSON string, not as
an object. A plain select still returns the original text, but `document->'results'` is null, and `document::text` gives
escaped text that `HandState(json:)` refuses. A `jsonb` column works if the request holds an object at `document`, for
example an `Encodable`-only row with `let document: HandState` (in SQL, `$1::jsonb`), sent by an encoder that leaves
keys as they are, and the query returns it as text (`document::text`): layout and key order do not matter to
`HandState(json:)`. A `String` and an object were each sent on PostgreSQL 16.4 (PGlite), with the SQL insert that
PostgREST generates, but not on PostgREST or Supabase themselves.

| Key | What it holds |
| --- | --- |
| `formatVersion` | 1, or 2 for [Pot-Limit Omaha](#pot-limit-omaha), whose `config` also holds `variant` |
| `config`, `operations` | The hand. An operation looks like `{"type":"dealHole","player":0,"card":"As"}`. |
| `complete` | Whether the hand is over |
| `finalStacks` | The stacks as they stand, by player index |
| `boards`, `runoutCount` | One board per run, with the shared cards on each |
| `results` | Each player's `player`, `net`, `won`, `status`, `holeCards` (each `card` and `isFaceUp`) and `shown`, or `null` mid-hand |

Everything after `operations` is a summary for readers that do not run the engine, such as a web page for players to
review their hands. `HandState(json:)` replays the operations and refuses a document whose summary disagrees with them.
[Fixtures/json](Tests/PokerEngineTests/Fixtures/json) has real documents.

A card nobody scanned is `"??"` in `operations` and `results`, and in `boards` if the hand ended without it being
entered, because a fold-out or a concession needs no such card. A page must handle it.

**The document holds every scanned card**, folded and mucked hands included, in `results` and in `operations`, and
`phh()` holds them too. To show players only what the table saw, use the cards in `results` with `isFaceUp` true, not
`shown`, which needs every card. Do not give players the whole document: a page that fetches it receives every card,
even if it hides some.

To give players a document, redact the hand first. `redactingHiddenCards(keeping:)` turns every hole card that was
never shown, and every burned card, into `.unknown`, then replays the operations, so the copy's `operations`, `log`,
`results`, `json()` and `phh()` name none of those cards. Board cards and shown cards stay, and so do the cards of the
players in `keeping`, for a player's own copy. Only face-up cards decide the pots, so the copy ends where the hand does,
with the same chips, statuses and boards, waiting for the same operation. The engine checks that, and throws
`RedactionError` rather than return a copy that differs.

```swift
// Player 1 shows and wins, and player 2 mucks. The table saw player 1's cards and the board, nothing else.
let finished = try hand.apply(.showHoleCards(player: 1)).apply(.muckHoleCards(player: 2))
let shared = try finished.redactingHiddenCards()
#expect(shared.results?[1].holeCards.map(\.card) == [.known(.queen, .diamonds), .known(.jack, .diamonds)])
#expect(shared.results?[2].holeCards.map(\.card) == [.unknown, .unknown])
#expect(shared.stacks == finished.stacks)

// Player 2's own copy keeps their cards.
let own = try finished.redactingHiddenCards(keeping: [2])
#expect(own.results?[2].holeCards.map(\.card) == [.known(.ace, .spades), .known(.king, .clubs)])
```

`HandState(json:)` throws `DecodingError`, and it reads only JSON as the engine writes it: printable ASCII with no
escapes, whole numbers of at most 19 digits, each key once, at most 32 levels deep and 1 MiB long. So keep names and
other app data in columns of their own, not in the document. A key the format does not have is ignored if its text
keeps to those rules. Any text with an accent or a quotation mark in it would not. [DECISIONS.md](DECISIONS.md), C10 and
C14, gives the reasons.

Compare stored hands by their contents, not their bytes: iOS 18 and macOS 15 changed the order of sorted keys. Only this
document is a stored format. The other types are `Codable` too, but their encoded form may change.

`phh()` exports the hand in PHH, PokerKit's hand-history text, byte for byte as PokerKit writes it. It works at any
point in the hand, and throws `PHHExportError.multipleRunouts(count:)` once `runoutCount` is above 1, because PHH cannot
write a second board. It throws `.blindsChopped` or `.handVoided` for a hand that ended that way.

```swift
let history = try hand.phh()
#expect(history.hasPrefix("variant = 'NT'\n"))
```

## Rules the dealer will notice

The engine follows PokerKit, and PokerKit differs from common house rules in the places below. The dealer may expect
something else, so these are worth surfacing in the app. [DECISIONS.md](DECISIONS.md) has each rule in full.

**Betting**

| Situation | What the engine does |
| --- | --- |
| Who acts first before the flop | The seat after the largest blind or straddle actually posted. Whoever posted it acts last if nobody raises. With a button straddle the small blind acts first, then the big blind, and the button last. Some rooms start left of the big blind instead, and the engine cannot: any other order is `.notYourTurn`. A live post does not count: the poster keeps their usual turn, so the poster in `[1, 2, -2]` acts first and the straddler in `[1, 2, 2]` acts last. |
| Minimum raise over a straddle | `minBet` plus the straddle. With blinds of 1 and 2, a straddle of 4 and `minBet` 2, the minimum raise is to 6, not 8. |
| A street's first bet, all in for less (before the flop, the first raise) | It counts as a full raise. After two limps, a small blind's all-in to 3 over a big blind of 2 lets the big blind and the limpers raise again. The rules of the Tournament Directors Association (TDA) would not reopen the action for the limpers. On the flop with `minBet` 100, after a check and an all-in bet of 20, the player who checked may raise to 120. TDA and Robert's Rules of Poker would not allow that raise. |
| Later short all-ins | A player who already acted may re-raise only if the all-ins since then add up to a full raise. That means at least the largest increase any bet or raise has made so far on this street, not counting forced bets, so after a short first bet or raise it can be less than `minBet`. One more short all-in closes it again. |
| A short big blind | Callers match what was actually posted, and the minimum raise is `minBet` above that. |
| A big-blind ante with a short big blind | The ante comes out first, and the blind gets what is left. TDA moved to the blind first in 2024. |
| Heads-up with equal blinds | The big blind acts first before the flop. |
| Folding when checking is free | Allowed in a cash game, an error in a tournament. |
| Chopping the blinds | In a cash game, once everyone else has folded before the flop, the blinds may take their blinds back with `.chopBlinds`, and the button moves on. Nobody else may have a chip in the pot, so another player's ante rules it out. Without a chop, a fold pays the small blind and any antes to the big blind. A misdeal is different: `.voidHand`, and the redeal keeps the same button. |
| An undersized raise that is not all in | An error. |
| Acting out of turn | An error. |

**All-ins**

| Situation | What the engine does |
| --- | --- |
| Once at most one player in the hand has chips | Nothing more is dealt until every player has shown, mucked or kept their cards face down and, in a cash game before the river, chosen a run count. While two players still have chips, betting and dealing go on, with no show and no run count. |
| Choosing a run count | Offered once per hand. Everyone in the hand at the all-in chooses, even a player who covers the others or has mucked, and a mucked player's count still counts. |
| Burns | Required before every flop, turn and river of every run. There is no burn before the hole cards. |
| Conceding before the river | The next street must still be dealt, and then the pot goes to the remaining player. |

**Showdown and payouts**

| Situation | What the engine does |
| --- | --- |
| Who wins | The best hand from the cards face up at settlement plus the board. A hand kept face down plays the board, and with nobody showing the pot is chopped. |
| Who shows first | The last bettor or raiser of the round before the showdown, even an all-in player. If nobody bet, the first player still in the hand, even one who is all in, counting from player 0 after the flop and from the seat after the largest blind or straddle before it. There is no rule that side-pot players show first. |
| Partial shows on the last river | Cards left face down become `.unknown` in `holeCards`. The log's deal rows and `results` keep the scanned cards. |
| Changing an answer, or asking to see a mucked hand | A player answers each showdown once, so a second answer is refused, though a show is accepted again once paying out begins. A mucked or killed hand can never be shown, so one turned up only to be looked at stays recorded as mucked or killed, and its `isFaceUp` values do not change. If the table rules it live, replace the muck with `.showHoleCards`. If a replacement takes chips from a player who kept a card face down, replace the last answer that kept it, before or after the muck, with a show too, because only face-up cards count. List the cards in either show if one was unscanned. `undo()` back past those answers does the same. |
| The player left at a tournament showdown | With nobody all in, may keep the cards face down and win without tabling, as TDA allows. After an all-in, must show: every hand is tabled, and nobody may muck the last hand. |
| Odd chips in a tie | The whole remainder goes to the first winner left of the button. |
| Odd chips across runs | Each pot splits evenly across the runs, and the remainder goes to the first run. |
| Side pots left with the same players | Mucks and kills can leave two or more pots with the same players, and those are paid as one pot, so a tie across them has one remainder on each run, not one per pot. With pots of 17 and 29 on one run, when the third player in the first pot is beaten and the other two tie, each gets 23. Splitting each pot by hand gives 24 and 22. |
| One player left after mucks or kills | That player gets each pot whole, with no split across runs. This is the usual case when one player scoops both runs. |
| Uncalled bets | They come back when bets are collected. When everyone folds, the winner's own bet comes back without counting in `won`. |

**Pot-Limit Omaha**

| Situation | What the engine does |
| --- | --- |
| The largest bet or raise | A call, then a raise the size of the pot after it, or the player's whole stack if that is less. Never less than the minimum raise. |
| Making a hand | Exactly two hole cards and three board cards: four aces make one pair. |
| Keep face down on the river | The cards are forgotten and the hand cannot play the board, so it wins only if everyone else mucks. The last answer that would leave a pot with no hand in it is refused. |

**Where the engine differs from PokerKit**

| Situation | What the engine does | PokerKit |
| --- | --- | --- |
| A card already in play | Refused with `.duplicateCard` | Warns |
| A fold or muck that would leave a pot with no possible winner | Refused with `.wouldAbandonPot` | Burns the chips, loses them or crashes |
| An unknown board card at settlement | Refused with `.unknownBoardCard` until corrected | Crashes |
| A run count below 1 or above 52 | Refused with `.invalidRunoutCount` | Accepts it, and a count below 1 runs forever |
| Shown cards that differ from the scan | Refused with `.shownCardNotDealt` | Takes the shown cards |
| `.unknown` in a list of shown cards | Refused with `.cannotShowUnknownCard` | Keeps that card face down |
| The player left at a tournament showdown, with nobody all in | May keep the cards face down | Must show them |
| A chop or a void | `.chopBlinds` and `.voidHand` | Has neither |
| In Omaha, river answers that leave a pot with no hand in it | The last one is refused with `.wouldAbandonPot` | Loses the pot |

## Verification

`swift test` needs neither Xcode nor Python. An app that imports SwiftUI does need Xcode, because `@State`'s macro ships
only with it.

```sh
swift build && swift test
```

`swift test` runs:

- unit tests for each rule area;
- the No-Limit Hold'em and Pot-Limit Omaha parts of PokerKit's own tests and doctests, ported to Swift;
- 191 scenarios and 200 random hands, a third of them Pot-Limit Omaha, generated from PokerKit 0.7.7, with the four
  patches in DECISIONS.md C9, compared with the engine at every step, including refused operations, with a void and a
  chop tried at every step too. Each hand's last state must match PokerKit's PHH, and a sample of its states must
  survive replay and a JSON round trip;
- the code in this README.

A larger comparison uses [uv](https://docs.astral.sh/uv/) to generate hands on PokerKit:

```sh
uv run tools/oracle/generate.py hands --stage full --seed 7 --pool 10000 --count 10000 \
    --out .oracle/s7/random.jsonl
POKER_ORACLE_DIR=.oracle/s7 swift test --filter Oracle
```

The commands that regenerate the committed fixtures are at the top of
[tools/oracle/generate.py](tools/oracle/generate.py). To lint those scripts:

```sh
uvx --python 3.12 flake8 tools/oracle/*.py
```

With Xcode, the first command below builds for iOS and the second runs the tests on a simulator:

```sh
xcodebuild build -scheme PokerEngine-Package -destination 'generic/platform=iOS'
xcodebuild test -scheme PokerEngine-Package -destination 'platform=iOS Simulator,name=iPhone 17'
```

**What has run.** The tests pass on macOS 26.7 and on simulators of iOS 26.5 and 27.0, built for iOS 17. They have not
run on iOS 17 or macOS 14 themselves, so those targets are only compiled for. They read their fixtures from the source
folder through `#filePath`, so they run on a Mac or a simulator, and nothing has run on a physical device.
`TableSession` is tested through Observation, not in a SwiftUI view. Supabase, PostgREST and `supabase-swift` are
untested.

PokerEngine includes part of PokerHandEvaluator and is a port of PokerKit. Their licences are in
[THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md), and an app that ships PokerEngine must include them in its
acknowledgements.
