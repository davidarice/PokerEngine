# Decisions

PokerEngine ports PokerKit v0.7.7's state machine for No-Limit Texas Hold'em and Pot-Limit Omaha. The default is to do
exactly what PokerKit does. This file records four things:

- where PokerKit's rules differ from common house rules (the engine follows PokerKit);
- where the engine deliberately differs from PokerKit, and why;
- the API and packaging choices that a reader would not guess;
- which PokerKit refusal each engine error stands for.

**Evidence.** Entries cite probes in `tools/oracle/quirks.json`. Each probe runs a scenario against real PokerKit
0.7.7 and records what happened. Regenerate the file with `uv run tools/oracle/generate.py quirks --out
tools/oracle/quirks.json`. Line numbers refer to `pokerkit/state.py` at v0.7.7.

**Status.** The milestone in brackets is when the behaviour lands. M1 (cards and evaluation), M2 (config, forced
bets, dealing and betting), M3 (showdown, pots and payouts), M4 (running the board more than once) and M5 (JSON, PHH
and `TableSession`) are implemented, so a hand plays to completion on as many runouts as the cards can fill, up to
`maximumRunoutCount` (B1, B5), and can be stored, exported and undone. Partial shows, reveals, river forgetting,
re-asks and B4 were planned for M4 but landed in M3, because they live in the same PokerKit functions as showing,
mucking and hand killing. Version 0.1.1 adds `dealtHand(of:)` (C17) and `TableSession.replaceConfig(with:operations:)`
(C18). Version 0.2.0 adds a chop and a void (B12), lets the player left at a tournament showdown keep the cards face
down (B13), refuses an unknown card in a listed show (B14), and makes `TableSession.undo()` reverse a correction (C19).
Version 0.2.1 adds Pot-Limit Omaha (C20). Version 0.2.2 adds `TableState`, the table between hands, and 0.2.3 lets the
dealer change seats and move the button between hands (C21). Version 0.2.5 adds `redactingHiddenCards(keeping:)`, a copy
of the hand without the cards the table never saw (C22).

## A. PokerKit rules that differ from common house rules (followed as PokerKit has them)

1. **Minimum raise over a straddle.** It is `minBet + straddle`, not twice the straddle. Blinds and straddles
   never set the raise increment, so facing 1/2/4 with `minBet` 2 the minimum raise is to 6, not 8.
   *Evidence:* `betting_oq1` (actor 3, minimum raise-to 6). [M2]
2. **The first bet of a street, or before the flop the first raise, always counts as a full raise.** The increment
   tracker starts each street at 0, so even a short all-in reopens the action. Example: two limps, then the small
   blind's 3-chip all-in over a 2-chip big blind; the big blind *and* the limpers may still raise. TDA would not
   reopen the action for the limpers. After the flop an all-in bet below `minBet` counts the same way, so a player
   who checked may raise it. TDA 2026 Rule 49-A and Robert's Rules of Poker (section 14, rule 3) would not allow
   that raise.
   *Evidence:* `betting_oq2` (BB can raise, minimum 5; after the BB calls, the limper can raise); oracle scenario
   `short-all-ins-reopen-below-min-bet` (step 28: player 0 checked, faces 14, minimum raise-to 34). [M2]
3. **When a short all-in reopens the action.** "Full" means an increment of at least the largest increment so
   far this street; `minBet` plays no part. A player who has acted since the last full raise may re-raise only
   if the all-in raises since then add up to a full raise. Once they do, one more short all-in blocks those
   players again, even though they now face more than a full raise in total.
   *Evidence:* `betting_oq4` (actor faces 800 and cannot raise); `extra_a_corrected_betting_oq3` (1-chip
   increments count as full: to call 1, can raise, minimum 22). [M2]
4. **Short big blind.** Callers match only what was actually posted, and the minimum raise-to is `minBet` plus
   the posted amount.
   *Evidence:* `betting_oq5` (bets [1, 1, 0], to call 1, minimum raise-to 3). [M2]
5. **Big-blind ante with a short big blind.** The ante is taken before the blind, and the blind gets what is
   left. TDA recommended the ante first in 2019 (RP-11) and moved to the blind first at its 2024 summit. "What is
   left" is the starting stack minus the full ante, even when trimmed antes hand part of that ante back: a player
   who starts with 6 chips posts an ante of 5, gets 2 back, and posts a blind of 1, not 2.
   *Evidence:* `betting_oq6`; oracle scenario `blind-after-trimmed-ante-refund`. [M2]
6. **Heads-up positions.** Player 0 is the big blind and player 1 is the button/small blind. Ante and blind
   arrays are written small-blind first and read reversed. With equal blinds, the big blind acts first preflop.
   *Evidence:* `betting_oq7`. [M2]
7. **Folding when checking is free.** It is an error in tournaments. Cash games allow it (PokerKit only warns),
   except where the fold would abandon a pot (see B2).
   *Evidence:* `betting_oq12`. [M2]
8. **Uncalled bets.** These come back when bets are collected. When everyone folds, the winner's own last bet
   is never collected; it comes back through the pull alone and is not counted in `won`. [M2/M3]
9. **The table waits for the showdown after an all-in.** No further card can be dealt until every player has
   shown or mucked. In cash games, when the all-in comes before the river, every active player must also choose
   a runout count first. A cash player who kept cards face down is asked again after each runout street,
   starting from player 0. Here and in A10, A11 and A15, *the all-in* is the betting round that ends with two or more
   active players, at most one of them holding chips. That can be later than the bet that put a player all in: while
   two active players hold chips, betting and dealing go on with no showdown and no runout choice.
   *Evidence:* `betting_oq10`, `cards_oq6`; oracle scenario `reask-after-each-all-in-street`. [M3]
10. **Runout consensus.**
    - Abstaining counts as agreeing, and any disagreement means one run, even if a later player matches the first
      count.
    - Covering players and players who muck still choose, even after mucking, and a mucked player's count still
      counts.
    - The choice is offered once per hand, only in cash games, and only when the all-in comes before the river.
    - The count takes effect when that first showdown ends.

    *Evidence:* `betting_oq9`, `cards_oq2`, `pots_oq10`; oracle scenarios `disagreement-runs-once`,
    `mucked-player-sets-the-count`, `count-takes-effect-when-the-first-showdown-ends`. [M3/M4]
11. **Running the board again.** Each run repeats the streets after the all-in, and the cards dealt before it are
    shared. A burn is required before every flop, turn and river of every runout. There is no burn before the hole
    cards. A run's river has no showdown unless it is the last: the street goes back, so a hand kept face down is
    asked again at the street of the all-in and after each street of the next run, and only the last river forgets
    cards (A13).
    *Evidence:* oracle scenarios `reask-through-two-runs`, `run-it-three-times-from-the-turn`,
    `hellmuth-wiggins-four-runs`. [M2/M4]
12. **Odd chips and push order.**
    - Each pot is split across runouts, with the remainder to runout 0. A pot smaller than the run count therefore
      pays nothing on the last runs, whoever wins them.
    - On a tie, the whole remainder goes to the lowest-index winner (the first seat left of the button).
    - When only one player is left after mucks or kills, each pot goes to that player whole, with no per-runout
      split. A run-it-twice scoop is the common case.
    - Pots left with the same eligible players after mucks and kills merge before they are split, so a tie across
      them has one remainder on each run, not one per pot, and a push's `pot` counts the merged pots. House rules
      usually split each side pot on its own (TDA 2026 Rule 23).
    - Pots are pushed main pot first.

    *Evidence:* `pots_oq1` (pushes (5, 3, 3)), `pots_oq13` (single push with no board); oracle scenarios
    `remainder-goes-to-the-first-run`, `one-chip-pot-on-two-runs`, `scoop-is-paid-as-a-single-survivor`; oracle hand
    `random-1-00001` (pots of 21, 180 and 468 become one of 669, split 335/334). [M3/M4]
13. **Pots are awarded on face-up cards plus the board.** An unshown cash hand plays the board. After a partial
    show on the last river, the cards left face down become `??` in the live state, even a card shown at an earlier
    street if a river re-ask leaves it out. The log's deal rows and `results` keep the scanned cards. Hands are
    evaluated at each push, so a post-hand show during a manual push can change who wins the next one. PokerKit takes
    `??` in a listed show as that card not being shown; the engine refuses it (B14). An Omaha hand must use two hole
    cards, so there a hand with fewer than two face up has no hand to play and cannot win (C20).
    *Evidence:* `cards_oq7`, `pots_oq11` (no shows, so the pot is chopped); oracle scenarios
    `river-reask-forgets-a-shown-card`, `post-hand-show-changes-the-next-push`. [M3]
14. **Showdown order.** The last bettor or raiser of the round before the showdown shows first, and a short
    all-in raiser counts. If nobody bet or raised in that round, the order starts before the flop at the seat
    after the largest blind or straddle actually posted (a live post does not count, and a tie goes to the later
    seat), and on later streets at player 0. Players out of the hand are skipped but all-in players are not, so
    an all-in player can show first without having acted in that round. There is no rule that side-pot players
    show first. [M3]
15. **Conceding at an all-in.** A muck at a pre-river all-in still requires the next street to be dealt; the
    pot is then awarded as if everyone else had folded. With more than one run nothing else is dealt, so `boards` can
    end up uneven, and `runoutCount` stays at the count chosen.
    *Evidence:* `pots_oq10`; oracle scenarios `concession-before-the-first-run`,
    `concession-on-the-last-street-of-a-run`, `concession-between-runs`. [M3/M4]
16. **Smaller rules.**
    - Forced bets may be posted in any order.
    - An undersized raise that is not all-in is an error.
    - There is no out-of-turn action. [M2]
17. **Who acts first before the flop.** The seat after the largest blind or straddle actually posted, with a tie
    going to the later seat as in A14. Whoever posted it acts last if nobody raises, so with a button straddle the small
    blind acts first, then the big blind, and the button last. A live post does not count, and the poster keeps their
    usual turn. A straddle too short to be the largest post changes nothing. Some rooms start left of the big blind
    and still give the straddler last action, and no config does that. TDA has no straddle rule, and Robert's Rules of
    Poker (section 14, rule 15) allows one straddle, on the big blind's left, so those orders are room practice:
    Wikipedia, "Betting in poker", and Bart Hanson, Card Player, 21 March 2018.
    *Evidence:* oracle scenarios `button-straddle`, `short-button-straddle`, `utg-straddle`, `live-post`. [M2]
18. **An answer at a showdown stands, and a mucked hand stays mucked.** A player answers each showdown once: a second
    answer is refused, though a show is accepted again once chips pushing begins. Only a hand with a card face down is
    asked again, after an all-in (A9). A mucked or killed hand can never be shown, so the engine has no way to ask to
    see one. Robert's Rules of Poker (The Showdown, rule 5) lets a player ask to see a hand that was eligible for the
    showdown: if anyone but the winner asks, a folded hand is dead, and if the winner asks, both hands are live and the
    best hand wins. TDA 2026 Rule 15 lets a player change their mind until the dealer kills the cards. An app records a
    dead hand as mucked. A hand ruled live is a correction: replace the muck with a show and, if any replacement takes
    chips from a player who kept a card face down, the last answer that kept it, before or after the muck, because only
    face-up cards count (A13). `undo()` back past those answers does the same. A player no replacement takes chips from
    stays as entered. A hand turned over counts in every pot it is in, even one it had given up by keeping its cards
    face down, because cards speak (Robert's Rules of Poker, The Showdown, rule 2). No rule book shows a hand for one
    pot only, so there is no per-pot show.
    *Evidence:* oracle scenarios `reask-after-each-all-in-street` (step 20), `muck-refused-for-its-timing-before-b2`
    (step 12), `show-refused-outside-the-order` (step 31). [M3]
19. **The player left at a tournament showdown after an all-in must show.** A tournament refuses a list that leaves a
    card down, and a muck would abandon the pot (B2), so that player can only be entered as a show, and `results` marks
    the cards face up. TDA 2026 Rule 17 tables every hand once a player is all in. With nobody all in the engine
    departs from PokerKit (B13).
    *Evidence:* oracle scenarios `tournament-partial-show-refused-at-an-all-in`,
    `tournament-last-player-must-show-after-a-river-all-in`, `last-muck-would-abandon-the-pot`. [M3]
20. **A fold to the big blind.** When everyone else has folded, a fold pays the small blind and any antes to the big
    blind. PokerKit has no chop, and the engine adds one (B12). [M2]

## B. Deliberate deviations from PokerKit

1. **Duplicate cards are errors.** A known card that is already in a hand, on any board, burned, mucked, or
   repeated within one operation throws `.duplicateCard`, whether it is dealt or revealed by a show. PokerKit only
   warns, or says nothing when the repeat is inside one call, which is how `AsAs` is accepted. A card the river
   forgot (A13) still counts as in that hand, or in the muck once its holder is out: PokerKit has it back in the
   deck and says nothing when another player reveals it. There is no reshuffle when the deck runs out; burn `??` if
   a runout needs more cards. PokerKit shuffles its burns and muck back into an empty deck, but here a scanned card
   stays where it went. A count the remaining cards cannot fill therefore leaves `??` on a board, and B4 refuses to
   settle it until the hand is replayed with a smaller count and without the operations of the runs that go.
   Two real copies of a card are a fouled deck: TDA 2026 Rule 37-E and Robert's Rules of Poker (Irregularities, rule
   4) void the hand and return every bet. The engine cannot tell that from a misread, so the dealer enters the void
   (B12).
   *Evidence:* `cards_oq4`, `cards_oq7`, `cards_oq11`; oracle scenarios `forgotten-card-revealed-by-another-player`,
   `forgotten-card-revealed-after-its-holder-is-killed`, `shown-card-forgotten-then-revealed-by-another-player`,
   `duplicate-from-another-run`, `deck-runs-out-during-runs`. [M2/M3/M4]
2. **(User's decision) A pot can never be left without a winner.** A fold or muck that would leave a pot with
   nobody eligible throws `.wouldAbandonPot`, and `LegalActions.canFold` reflects it. PokerKit has three
   outcomes here:
   - with 2+ players active, it burns the chips with a warning;
   - with one player active, it asserts in `push_chips`;
   - when everyone mucks, the chips vanish silently. This is PokerKit's tested behaviour (`test_unknown_showdown`),
     and the port's version of that test expects the rejection instead.

   Bets not yet collected count. The M2 soak found a free fold that strands only live bets: everyone folds to a
   straddler whose one remaining opponent is all in for less than the blinds, and the straddler folds instead of
   checking the option. Once collected, the folded players' blinds form a side pot nobody can win, and PokerKit
   asserts while pushing it.

   Players still to act count too, unless the fold leaves one player, which ends the round at once. Otherwise a
   fold is refused only if a pot would stay without anyone eligible after everyone still to act has called, capped
   by their stacks. While such a player could still call into the pot the fold stands, as in PokerKit. The fold that
   makes the loss certain is the one refused, free or not, and that player must then check, call or raise. So the
   refusal can land on a later player: with blinds `[1, 2, -3, -3]`, once both live posts have folded the small blind
   may not fold, because the round would end and the big blind would get no chance to call into the top layer. That
   holds even if the small blind is too short to reach the layer itself: its call is what gives the big blind a turn.
   In the oracle's runs a refusal that did not end the round took two or more live posts in a cash game.
   `.wouldAbandonPot`'s `pot` is an index into the pots as they would stand if the fold or muck went through, so it
   need not exist in the current `pots`.

   Omaha adds a fourth way to lose a pot (0.2.1). There a hand must use two hole cards, and on the river a card kept
   face down is forgotten (A13), so a player who answers the river's showdown with fewer than two cards face up has
   no hand: PokerKit kills it, and when every player eligible for a pot is killed the pot is lost without a word. So
   in Omaha an answer at the river's showdown, a Keep, a short list or a muck, is refused with `.wouldAbandonPot`
   when it leaves a pot whose eligible players have all answered and none holds two known hole cards. With one player
   left nobody compares hands, so that player is paid as always, a Keep included. The refusal lands on the answer that
   makes the loss certain, even with a player still to answer for another pot, and that player then has to show. A
   real table would give an uncontested side pot to its last player unseen; here that player shows two cards.
   *Evidence:* `betting_oq11`, `pots_oq7`, `pots_oq8`; oracle scenarios `b2-two-equal-live-posts`,
   `b2-mid-round-refusal`, `b2-short-blinds-below-two-live-posts`, `b2-straddler-free-fold`,
   `omaha-kept-hands-cannot-abandon-the-pot`, `omaha-muck-refused-after-two-dead-hands`,
   `omaha-dead-hands-in-a-side-pot`. [M3, 0.2.1]
3. **Conceding with chips behind.** PokerKit's flow in A15 is kept. When the remaining player still has chips,
   PokerKit asserts in `get_effective_stack` (line 2502); the engine counts that player's effective stack as 0.
   *Evidence:* `betting_oq8`, `cards_oq5`. [M3]
4. **Unknown board cards.** A `??` board card is accepted when dealt. When hand killing begins with 2+ players
   active, the operation whose cascade got there throws `.unknownBoardCard` and the state is unchanged. A contested
   push always follows hand killing, so nothing else evaluates hands. Only three operations can get there, all on
   the river and with 2+ players still active: the last board deal of an all-in whose active hands are all face up,
   and the last show or the last muck of the showdown. With more than one run that is the last run's river, and the
   error names the first unknown card run by run, a shared card on run 0. A river bet, call, check or fold or a bet
   collection stops at the show order, and a runout selection comes before the river. A `??` dealt earlier is
   corrected with `replacingOperation`. A refused operation is not recorded, so a `??` river that throws from its own
   deal is fixed by dealing the scanned card. A lone survivor is paid without evaluation. PokerKit raises `KeyError`
   only when a last show or muck on the river leaves that player, the one lone-survivor path through hand killing, and
   only if the first board holds the `??`: it stops at the first board that player can win, so a `??` on a later run
   changes nothing. A fold-out or a pre-river concession (A15) skips hand killing, so PokerKit evaluates nothing
   there; it pays, apart from the assertions in B2 and B3.
   `hand(of:)` returns nil for a board containing `??`, as PokerKit's `get_hand` does.
   *Evidence:* `cards_oq3`; oracle scenarios `unknown-board-*`, `unknown-river-after-a-concession`,
   `unknown-card-on-the-last-run`, `unknown-card-on-the-first-run`, `unknown-shared-card-before-two-runs`,
   `unknown-cards-on-two-runs`, `unknown-card-refuses-the-last-show`, `unknown-card-refuses-the-last-muck`,
   `lone-survivor-unknown-*`, `unknown-card-on-a-concession-board`. [M3/M4]
5. **Runout selection.** The named player is credited, and counts below 1 or above `HandState.maximumRunoutCount`
   (52) throw `.invalidRunoutCount`. PokerKit's `select_runout_count` passes the player index into the count
   parameter. As a result an explicit player is ignored, player 0 is rejected as "count 0", and counts of 0 or less
   run forever. PokerKit has no upper limit. The engine's keeps one mistaken or hostile count from making `boards`
   build billions of arrays, and no real hand reaches it: every run needs a card of its own.
   *Evidence:* `betting_oq9`, `cards_oq1`, `pots_oq3`, `pots_oq4`; oracle scenario
   `count-above-the-maximum-refused`. [M3/M4]
6. **(User's decision) Shown cards must match the dealt cards.** Shown cards must agree with the player's known
   dealt cards, or the engine throws `.shownCardNotDealt`. A card dealt as `??` can be revealed once; after that it
   is a known dealt card. A slot the river forgot (A13) shows `??` in the live state but belongs to its scanned card,
   so only that card fits it. PokerKit replaces known cards with whatever is shown, warning only if a shown card
   is not in its deck.
   *Evidence:* oracle scenarios `shown-card-not-dealt`, `forgetter-shows-after-the-hand`,
   `another-players-forgotten-card-not-dealt`. [M3]
7. **Cards and amounts.**
   - Only the fully unknown card `??` is supported; the parser rejects partially known cards such as `A?`, which
     PokerKit accepts.
   - Card text is parsed by code point, as Python does. Unicode look-alikes such as U+212A KELVIN SIGN are
     therefore not read as `K`.
   - Chips are `Int`; there are no infinite or decimal stacks.
   - The game mode is required, because PokerKit defaults to tournament. [M1/M2]
8. **Stricter config and input validation.**
   - 2–10 players.
   - Ante and blind arrays may not be longer than the player count. PokerKit silently truncates them, which
     drops a heads-up straddle.
   - Non-uniform antes require `anteTrimming = false`.
   - Starting stacks may add up to at most `HandConfig.maximumChips` (2^50), and no forced bet or minimum bet may
     exceed it (`.amountsTooLarge`), so no sum the engine computes can overflow `Int`. PokerKit's Python integers
     have no limit.
   - Player indices outside `0..<playerCount` are errors. PokerKit takes -1 as the last player but records -1.

   *Evidence:* `cards_oq12`. [M2]
9. **Shows with no street in play.**
   - Post-hand shows are accepted only after chips pushing has begun, and must show every card. During forced bets
     PokerKit accepts `cards: nil` and `[]`, recording an empty show; the engine throws `.noShowdownExpected`. That
     check runs last, so a muck or a non-empty list then still gets PokerKit's refusal (`.mustShowAllCards`,
     `.tooManyCardsShown`).
   - A tournament post-hand show that leaves a card unshown makes PokerKit raise a bare `AssertionError` (line 5538)
     when `all_in_status` is false. The engine throws `.mustShowAllCards` for a listed show and
     `.cannotShowUnknownCard` for `cards: nil` with an unknown card. With `all_in_status` true PokerKit refuses
     normally ("The player must show when all-in.").

   *Evidence:* `cards_oq13`, `pots_oq6`; oracle scenarios `forced-bets-shows-cash`, `forced-bets-shows-tournament`,
   `tournament-post-hand-shows`, `tournament-fold-out-survivor-holds-an-unknown-card`,
   `tournament-river-shove-then-a-fold`. [M3]
10. **API shape.** The input type is `HandOperation`, not `Operation`, because `Foundation.Operation` would make
    the bare name ambiguous in every file that imports SwiftUI. Dealing operations carry one card each (PokerKit
    allows several per call). [M2]
11. **Not ported.** The package is PokerKit's No-Limit Texas Hold'em state machine and nothing else.
    - Rake: `HandConfig` has no such option. PokerKit's `rake` argument is left out, and its default takes nothing,
      so every pot is paid in full, as at PokerKit's default.
    - Other games and options: every variant but these two (C20), multi-board games (`starting_board_count`),
      non-position openings and custom `divmod`.
    - The deck: shuffling, dealing and burning automation, show-or-muck automation and `get_dealable_cards`. The
      camera supplies every card, and the players decide.
    - Other formats: commentary, PHH import, the ACPC, Pluribus and PokerStars formats, and `analysis.py`.
12. **Voiding a hand and chopping the blinds (0.2.0).** PokerKit has neither, so these operations are the engine's
    own. Each ends the hand with every stack back at its starting stack and records an event saying what each player
    got back. Every operation after it is refused with `.handComplete`, a show after the hand included, and `results`
    gives every player a `net` and a `won` of 0. `pendingOperation` never asks for either: the app offers them where
    `canApply(_:)` allows.
    - `.voidHand` is a misdeal or a fouled deck. A misdeal can be declared only before substantial action (TDA 2026
      Rule 37-D), but a fouled deck stops play whenever it is found and every bet is returned (Rule 37-E; Robert's
      Rules of Poker, Irregularities, rule 4), and a result can be disputed until the next hand begins (Rule 24). The
      engine cannot tell which applies, so it accepts a void at any point, even once the hand is over, and the dealer
      judges. A player who had already pulled winnings hands them back, so `returned` can be negative.
    - `.chopBlinds` follows Robert's Rules of Poker, which allows the blinds to take their blinds back when all other
      players have folded, in non-tournament button games (House Policies, rule 15; rule 13 of its private-games
      edition). The engine allows it in a cash game while the first round's betting is under way, when the two blinds
      are the only players left, neither has put in more than the blind, and nobody else has put in a chip. The rule
      says nothing of antes or dead posts, so a pot holding another player's ante or post cannot be chopped; a
      big-blind ante is the big blind's own and goes back with the blind. A straddler acts after the blinds, so a
      straddled pot never reaches a chop.
    - After a chop the button moves on, and after a misdeal the redeal is an exact replay with the same button (TDA 2026
      Rule 37-C). `TableState` does both (C21); an app that builds its own configs does them itself.
    - `phh()` throws `.blindsChopped` or `.handVoided`: PHH cannot write either. JSON v1 stores them as the operations
      `{"type":"chopBlinds"}` and `{"type":"voidHand"}`, so `formatVersion` stays 1: every older document reads as
      before, and an engine older than 0.2.0 refuses a document that holds either.

    *Evidence:* `VoidAndChopTests`; the oracle checks both at every step of every hand (C9). [0.2.0]
13. **The player left at a tournament showdown with nobody all in may keep the cards face down (0.2.0).** TDA 2026
    Rule 18-B makes a showdown with nobody all in uncontested once all but one player has mucked, and the last player
    wins without tabling. PokerKit refuses that player any list that leaves a card down ("A card is not shown in final
    showdown."), and a muck would abandon the pot (B2), so before 0.2.0 the cards had to be entered as shown. The
    engine accepts from the only player left a list that leaves cards down, `[]` included, as in a cash game, unless
    a player is all in: TDA 2026 Rule 17 then tables every hand (A19). All in is PokerKit's `all_in_status`, which
    also counts a river whose betting ended with a stack at 0, so a river all-in for less counts though both callers
    have chips behind. After the hand a show must still turn up every card (B9).
    *Evidence:* oracle scenarios `tournament-last-player-keeps`, `tournament-last-player-shows-one-card`,
    `tournament-last-player-must-show-after-a-river-all-in`. [0.2.0]
14. **An unknown card in a listed show is refused (0.2.0).** PokerKit takes `??` in a list as that card not being
    shown, so a rescan that misses a card passes for a partial show and can give the pot away. A card is shown by
    listing it and kept face down by leaving it out, so `??` says nothing a list without it cannot. The engine refuses
    it with `.cannotShowUnknownCard`, in either mode. The check runs after PokerKit's own, so a list PokerKit refuses
    for another reason gets PokerKit's refusal.
    *Evidence:* oracle scenarios `listed-unknown-refused-on-the-river`, `listed-unknown-refused-at-an-all-in`.
    [0.2.0]

## C. API and packaging choices

1. **Hand evaluation (M1).**
   - The engine vendors PokerHandEvaluator's 5-, 6- and 7-card evaluators. PokerKit evaluates only a player's
     known cards, so unknown hole cards can leave 5 or 6 known cards.
   - Equivalence with PokerKit's `StandardLookup` is proven by two digests over every five-card hand, which
     together pin each hand's PokerKit entry index:
     - the lookup-order digest from `test_lookups.py`;
     - a per-class hand-count digest.
   - It is also checked against 3,500 PokerKit samples.
   - A hand's five cards are PokerKit's first best combination, kept in combination order.
2. **`HandRank` (M1).**
   - Ranks compare by strength alone, as PokerKit's `Hand` does.
   - `Codable` writes only the category and the five cards, and decoding rebuilds the rank from the cards, so a
     decoded rank cannot contradict them. Ranks are derived data, not part of the stored hand format.
   - `HandCategory.label` exposes PokerKit's label text, for example "Three of a kind".
3. **Card JSON (M1).** A card is the string `"As"` or `"??"`, and decoding accepts only that canonical form. When
   the text does not parse, the `DecodingError` carries the `CardParseError`.
4. **Vendored C symbols (M1).** The evaluator's C globals have generic names (`choose`, `dp`, `flush`, …), so
   `Package.swift` renames them to `pokerengine_phe_*` with compile-time defines. That avoids link-time clashes
   in apps, and the vendored files stay unmodified.
5. **`swift test` with only the Command Line Tools (M1).** SwiftPM 6.4's `swift test` omits Swift Testing's macro
   plugin path when the active developer directory is the Command Line Tools. The test target then passes that
   path itself. The setting applies only in that setup, and packages that depend on PokerEngine never see it.
6. **`.bookkeeping` (M2)** is a static member of `Set<HandConfig.Automation>`, not of the enum, so it works as
   the `automations:` default and in expressions such as `.bookkeeping.subtracting([.chipsPushing])`.
7. **The log (M2).** `apply(_:)` appends the dealer's own event first, then every automated event it set off, in
   PokerKit's order. `LogEntry.operationIndex` points back into `operations` (nil for the automation `init` runs).
   `betsCollected` also reports `returned`, the uncalled amounts PokerKit's record leaves implicit.
8. **Invariants (M2, M3).** Debug builds check after every operation that chips are conserved, known cards are
   unique, live cards come from the dealt cards, players out of the hand hold nothing, every queued actor can bet, at
   most one phase is pending, and none exactly when the hand is complete. A broken invariant stops the program;
   release builds skip the checks.
9. **Oracle (M2, M3, M4, M5).** `tools/oracle` plays hands on PokerKit and records, for every step, the events and the
   snapshot fields that changed; `OracleTests` replays them through the engine and stops at the first difference.
   - The snapshot covers chips, pots, player statuses, cards and which are face up, hands on every board, the runout
     count, the pending operation, completion, `results` and the actor's options: bet or raise with its range, or why
     raising is refused (labelled as in D). Every field of `LegalActions` is compared, so what the UI shows matches
     PokerKit.
   - Committed: 191 hand-written scenarios and 200 random hands, about a third of them Omaha, each played to completion
     or to a B4 refusal. The random hands are selected so every tracked feature appears in at least 3 hands of one
     committed file. The
     scenarios cover the unit-tested rules of play, every corner where a planted bug once got past the suite, and the
     rare states below. Input checks with no hand to compare stay in the unit tests: invalid configs and player
     indices (B8). `POKER_ORACLE_DIR` adds a larger set generated on demand. The fixtures are 5.3 MB, over the plan's
     estimate of 3 MB, because hands now run to completion and on several boards; coverage was kept rather than cut to
     fit. The largest hand possible, 432 pushes on 48 boards, is a unit test instead: a few hands that size would
     outweigh every fixture.
   - Each hand also records PokerKit's PHH text at the state it ended in, which `phh()` must match byte for byte, or
     nil with several runouts, where it must throw. A sample of each hand's states must replay to the same state and
     survive a JSON round trip with the same bytes. The hand must come out the same, every stored property included,
     with every automation off and each automated event entered by hand.
   - Rejected steps are compared too. One classifier decides every step, in the engine's check order: PokerKit's own
     refusal, then the checks only the port has, then the cascade. Operations PokerKit refuses must map to the error
     in D. Deviation steps are never applied to PokerKit and carry the exact expected `EngineError`, except B1, where
     any `.duplicateCard` will do. A refused raise must give the reason `LegalActions` gave, and a refused fold must
     agree with `canFold`.
   - Four patches emulate deviations PokerKit cannot get past: B3 (`get_effective_stack`), B5
     (`select_runout_count`), B4's lone survivor (`_begin_hand_killing`) and B13
     (`verify_hole_cards_showing_or_mucking`, whose tournament check runs as in a cash game for the player left with
     nobody all in). `bridge.emulate_deviations()` applies them for the `scenarios` and `hands` commands only, so
     `quirks` keeps probing real PokerKit. Everything else is unpatched. B2's expected pot comes from playing the fold
     and the calls on PokerKit itself.
   - PokerKit has no void or chop (B12), so at every step the harness checks them from the public API instead: a void
     must give every chip back, and a chop must be accepted exactly where B12's rule allows it and give every chip back
     too.
   - Scenarios list the operations that matter and are then finished by a fixed policy: burn `??`, deal the lowest
     undealt cards, check or call, abstain from runout choices, show as is when possible, otherwise reveal with the
     lowest unseen cards.
   - "Unseen" and "revealable" come from a dealt record rebuilt from PokerKit's operations, never from its deck or
     live cards, because PokerKit has a card the river forgot back in the deck, and its burns and muck too once the
     deck runs out.
   - PokerKit's burn and board records do not say which run they belong to. The bridge works that out from PokerKit's
     own countdown of runs still to come, not by counting cards as the engine does.
   - Random play rarely reaches three states, so at least 3 scenarios carry each: a player barred from raising by
     A3's closing short all-in, an uncalled bet returned to a player who folded, and a fold refused by B2.
     Mid-round B2 refusals appear only in scenarios.
10. **What `HandState(json:)` reads (M5).** `StoredJSONScanner` reads a document's bytes before `JSONDecoder` does and
    refuses anything but JSON as the engine writes it: printable ASCII with no escape, whole numbers of at most 19
    digits with no fraction or exponent, and each key once in its object, at most 32 levels deep and 1 MiB long. Layout
    and key order are free, so a document can pass through a Postgres `jsonb` column if it arrives as an object. Sent
    to that column through PostgREST as a `String`, it is stored as one JSON string: JSON operators find nothing in it,
    and read back with `::text` its escapes are refused. A key the format does not have is allowed, but the same rules
    hold under it. The format needs nothing more; free text would be a new `formatVersion`.
    The reasons:
    - Readers must agree on the hand. `JSONDecoder` keeps the first value of a repeated key, while Python, JavaScript
      and Postgres keep the last. It reads numbers through a double, so `1.9999999999999999` is a `minBet` of 2 to it
      and not to a reader of exact decimals. It matches string enums by canonical equivalence, so `handKilling` spelled
      with U+212A KELVIN SIGN turns that automation on, while Python sees an unknown name, and a reader that drops it
      replays a hand that does not finish.
    - Nothing may stall the reader. Swift normalizes strings to compare and hash them, which takes time in the square
      of a run of combining marks out of order. With such a run in a `type` value, a valid 321 KB document took over a
      minute in a release build on a Mac, and Python read it in milliseconds. A size limit alone would not help, as
      1 MiB still takes minutes. In ASCII there is nothing to normalize.
    - A document gets one answer on every OS. `JSONDecoder` also takes trailing commas, and does not look into what it
      does not read: raw control characters, invalid UTF-8, malformed escapes, numbers like `1.2.3`. Foundation's JSON
      code changed in iOS 18 and macOS 15, and iOS 17 cannot be run here, so nothing relies on what it lets through.
      The same goes for a number past an `Int`'s 19 digits under a key nothing reads: `JSONSerialization` refuses from
      about 166 digits, JavaScript reads 400 as `Infinity`, Python refuses 4,301 and Postgres 131,073. `JSONDecoder`
      also reads UTF-16 and UTF-32, which the scanner refuses: their NUL bytes and byte order marks are not in the
      format.
    - The limits bound what a document can cost. The worst document found needed about 55 MB at 1 MiB on macOS 26, over
      50 times its size, and iOS 17 was not measured. The scanner recurses. A finished hand reaches 6 levels, counting
      each value on the path, and about 32 KB at its largest in the tests. Only a hand of tens of thousands of
      operations would pass 1 MiB, and `json()` would then write a document `HandState(json:)` refuses. Text read back
      from `jsonb` is 11 to 14% longer, so such a hand can pass the limit there from about 920 KB.
    A plain `decode(HandState.self, from:)`, which includes a `Decodable` row with a `HandState` field, still replays
    and checks the summary but has none of this. Read documents from outside with `HandState(json:)`, so a row should
    hold the document as text.
11. **`showHoleCards(cards: nil)` (M3)** is PokerKit's `True`: it turns the live cards face up as they stand, and is
    refused while any is unknown. It cannot bring back a card the river forgot; the dealer lists the scanned cards
    instead. It does not mean "as dealt", because that would reorder cards a listed show has already reordered.
12. **`results` (M3).** PokerKit's live cards stop matching what each player was dealt: a show reorders them, the
    river forgets them and leaving the hand empties them. Only its operation log keeps each player's cards, and the
    oracle rebuilds them from it (C9). The engine keeps them in state as `dealtHoleCards`, so shows, mucks and
    duplicate checks need not replay its log: `PlayerResult.holeCards` is the cards as dealt with reveals filled in.
    `isFaceUp` means shown at any point, even if a river re-ask turned the card back down. The plan said "shown at
    the end", but a hand shown and then killed has no live cards at the end. A post-hand show after completion can
    change `holeCards` and `shown`, so `results` is not fixed at completion; chips never change.
13. **The muck keeps scanned cards (M3).** A fold, muck or kill moves the scanned cards to the muck, including any
    the river forgot. PokerKit's show returns those cards to its deck, which is why another player can reveal them
    with no warning (B1); its muck holds `??` for them.
14. **JSON v1 (M5).** `HandState`'s `Codable` form, written by `json()` and read by `HandState(json:)`, is the same
    document for crash recovery mid-hand and for upload.
    - Keys: `formatVersion` (1, or 2 for Omaha: C20), `config`, `operations`, then a summary for readers that do not
      run the engine:
      `complete`, `finalStacks`, `boards` (one per runout, repeating the shared cards), `runoutCount` and `results`.
      Mid-hand `finalStacks` are the stacks as they stand and `results` is `null`.
    - The hand is the config and the operations. After the check of its text (C10), decoding replays them and throws
      `DecodingError` if a key is missing, the version is not 1, the config is invalid, an operation is refused (the
      `ReplayError` is the underlying error) or the summary differs from the replay. The plan checked only
      `finalStacks`. Every field is checked because other readers go by the summary, so a document that disagrees with
      itself would be two hands.
    - A key the format does not have is ignored if its text keeps to C10, so it cannot change the hand.
    - `results` uses the synthesized forms of `PlayerResult`, `HoleCard` and `PlayerStatus`, so renaming a field of
      theirs changes the format. The documents in `Fixtures/json` pin it: any change that breaks one needs a new
      `formatVersion`.
    - `json()` sorts keys, so a hand gives the same bytes every time on one version of Foundation. iOS 18 and macOS 15
      changed the order, which swaps `anteTrimming` and `antes`, so compare hands by their contents, not their bytes,
      across systems. `Fixtures/json` is compared by contents for that reason.
15. **PHH export (M5).** `phh()` gives PokerKit's `HandHistory.from_game_state(...).dumps()` byte for byte, for a hand
    complete or under way. It throws `.multipleRunouts(count:)` once `runoutCount` is above 1. A count that disagreed
    exports normally, as does an agreed count until the first showdown ends. A concession keeps its count (A15), so it
    throws even with one run of cards dealt. PHH has no way to write a second board or the count (`pots_oq2`).
    - Burns, posts, collections, runout choices, kills, pushes and pulls leave no line. Hole cards are grouped by
      player and each street's board is one line, as PokerKit compresses them, so the order the hole cards were dealt
      in is lost. A post-hand show entered before a manual push keeps no place relative to it: `HandHistory` pushes
      first, so it can pay different players with no error (A13).
    - `from_game_state` leaves `ante_trimming_status` false (`pots_oq9`); the oracle passes the true value, as `phh()`
      writes it. `finishing_stacks` is the current stacks and `winnings` the chips pushed so far, so a fold-out
      winner's own bet is not in `winnings`.
    - For hands PokerKit cannot finish, the text is the patched oracle's (C9), and stock PokerKit raises replaying it,
      as it does playing the hand: `AssertionError` for a concession with chips behind (B3), `KeyError` when a last
      show or muck on the river leaves one player with `??` on the board (B4). A text from a hand under way is a
      snapshot: `HandHistory` plays on past its last action, so it need not end on the text's stacks.
    - There is no reading PHH back, and no metadata fields such as `players` or `event`: the engine does not have them.
16. **`TableSession` (M5)** is the only type in `PokerEngineObservation`, so `PokerEngine` needs neither Observation
    nor SwiftUI. Undo replays the operations without the last one instead of keeping a stack of states, because replay
    is deterministic. A session restored with `init(state:)` therefore undoes as far as one that played the whole
    hand. Only a correction keeps the state it replaced, so that undo can reverse it (C19). `undo()` with nothing to
    take back does nothing, so a double tap cannot crash the app.
17. **`dealtHand(of:)` (0.1.1).** `hand(of:)` follows PokerKit's `get_hand`, which ranks the live cards of a player
    still in the hand, so it has nothing to say about a beaten, mucked or folded hand, or a kept one the river forgot.
    `dealtHand(of:)` ranks the dealt record that `results` comes from (C12), for any player. The two share one
    evaluation, so wherever a player's live cards are still the dealt ones they agree, and the oracle checks that at
    every step. A folded hand is ranked with the whole board, cards dealt after the fold included, and `faceUpOnly`
    counts a card shown at any point, as `results` does; leaving those out is the app's choice. Before this, the README
    named a beaten hand by replaying without `.handKilling`, which needed the operations cut short at a show after the
    hand or a settlement step entered by hand.
18. **`replaceConfig(with:operations:)` (0.1.1)** replays the operations on a corrected config inside the session, so
    a view observing it carries on. A bet keeps the `to:` entered rather than following the new stack: an all-in at
    the old stack might have been a bet that happened to equal it, and only the dealer knows, so the corrected list is
    a parameter. Keeping the player count is the caller's job: operations name players by index, so another count
    changes who they mean, even where the replay happens to fit.
19. **Undo reverses a correction (0.2.0).** Before 0.2.0, `undo()` straight after a correction took back the hand's
    last operation, so a misread card came back only by correcting its row again, and a correction that dropped
    operations only from a list kept before it. Now each correction keeps the state it replaced, with the operation
    count just after it. While the hand is back at that count the correction is the last change, so `undo()` restores
    that state; otherwise it takes back the last operation by replay, as before. Keeping only corrections leaves undo
    as C16 describes everywhere else, so a session made with `init(state:)` still undoes through the whole hand. It
    starts with no correction to reverse.
20. **Pot-Limit Omaha (0.2.1)** is PokerKit's `PotLimitOmahaHoldem`, chosen with `HandConfig.variant`; Texas Hold'em
    is the default, so no earlier code or stored hand changes. Three things differ, and everything else, forced bets
    and straddles, showdowns, runouts, unknown cards and every deviation, is shared.
    - Each player is dealt four hole cards before the flop, one card per operation as before. Ten players use 48 of
      the 52 cards on one run, so a second run fits only from the turn on; B1 says what happens when the cards run out.
    - A hand is exactly two hole cards and three board cards, PokerKit's `OmahaHoldemHand.from_game`: the best of at
      most 60 five-card hands, each ranked by PokerHandEvaluator's five-card function. PHE's own Omaha tables, about
      130 MB, are not vendored. A tie keeps PokerKit's first combination, hole pairs outermost, so `HandRank.cards`
      lists the two hole cards, then the three board cards. Unknown hole cards are left out, as `get_hand` leaves them
      out, so fewer than two known means no hand, and a hand with fewer than two face up has no `faceUpOnly` hand. That
      is how a hand kept face down on the river can lose a pot B2 guards. Checked against 2,000 PokerKit evaluations,
      some with no hand, and at every step of every oracle hand.
    - The largest bet or raise is PokerKit's pot-sized one: a call, then a raise the size of the pot after it, that is
      `2 × the largest bet − the player's bet + totalPot`, but never below the minimum raise and never above the
      stack. The minimum raise and the reasons a raise is refused are the same as in no-limit.

    A stored Omaha hand is `formatVersion` 2, with `config.variant`. A Texas Hold'em hand is still written as version
    1, byte for byte as before, so every earlier engine reads it, while an earlier engine refuses version 2 rather than
    replay Omaha as Hold'em: one voided before the third hole card would replay. Version 1 has no `variant`, so the key
    there is ignored like any key the format does not have (C14), and version 2 must name the game.
    `HandState.formatVersion` is now the newest version, 2. `phh()` writes `variant = 'PO'`, as PokerKit does.
    *Evidence:* the `omaha-*` oracle scenarios, among them PokerKit's Antonius–Blom hand; a third of the random
    hands; `OmahaTests`. [0.2.1]
21. **`TableState` (0.2.2, 0.2.3)** keeps what lasts from hand to hand: who sits in which of ten seats, one for each
    player a hand can hold, with how many chips, the stakes and the button. It deals each hand's `HandConfig` and
    carries each finished hand's stacks back to the seats, so an app keeps no player order or stacks of its own.
    PokerKit has no table, since its `State` is one hand, so the rules are the owner's. Theirs is a home game whose
    dealer starts every hand and knows who is at the table, and whose app stands up a player who leaves, emptying the
    seat, so the rules are the simplest that fit.
    - Everyone seated with chips is dealt in. A player with none stays seated, dealt out until a rebuy, and there is
      no sitting out. Robert's Rules of Poker (private-games edition, Section 4, rules 4, 7, 9 and 11) has a new
      player post a big blind or wait for it, deals nobody in between the big blind and the button, and has missed
      blinds made up, even by a player who missed them while busted, before rebuying. None of that is adopted: nobody
      owes a missed blind, and a returning player is dealt in wherever the button is. A post or a straddle still needs
      a `HandConfig` built directly, and a negative blind, which `HandConfig` reads as a live post, is refused.
    - The button is the same section's moving button (rule 1(a)). After each hand it moves forward to the next player
      dealt in, skipping empty seats and players with no chips, and the blinds are the two players after it, so a
      player can skip a blind or pay one twice when someone leaves. Its dead button (rule 1(b)) is not offered. After a
      chop the button moves on (B12). After a void it stays, because a misdeal's redeal is the same deal again (TDA
      2026 Rule 37-C), and that includes a void entered once the hand is over. The button belongs to its seat, so a
      player who changes seats leaves it behind.
    - Between hands the dealer may change anything, as at a real table during a break, and during a hand nothing:
      until the hand in play is finished, `sit`, `stand`, `setStack`, `changeSeat`, `moveButton` and `nextHand` throw
      `.handInPlay`. `changeSeat(from:to:)` (0.2.3) moves a player with their chips, even none, or trades two players'
      seats. `moveButton(to:)` (0.2.3) puts the button on a seat for the next hand, or on the next player dealt in
      after it, as the starting seat does. It wins over a void's redeal and over any correction of the last hand, and
      after that hand the button moves on as usual. A hand ends only by being finished, so to drop one, void it and
      finish that. `stakes` is a plain property, read when the next hand is dealt, and stakes no hand can have are
      refused then, with `HandConfig`'s reason. `minBet` follows the big blind unless it is set.
    - A correction is the same hand finished again with its `Deal`, which `nextHand()` gives and numbers. Only each
      final stack's change moves, so a rebuy or top-up since stays. It is refused once the next hand is dealt, since a
      result can be disputed only until then (TDA 2026 Rule 24). It is also refused once a player of that hand has
      stood up or changed seats, because it moves each change to the seat the player had. The dealer can still set the
      stacks by hand. A hand replayed on a corrected starting stack with `replaceConfig(with:)` is finished the same
      way, and the seat gets the corrected hand's final stack.
    - Every stack stays within `HandConfig.maximumChips`, so no sum the table computes can overflow.
    - The `Codable` form saves a table between launches. Decoding refuses one that no calls could have left, as
      `HandState` refuses a document that disagrees with itself, so a damaged save cannot make a call trap or leave
      the table stuck. It is not part of the stored hand format (C14), and changing it would be a breaking release.
      0.2.3 adds whether the dealer moved the button, and a 0.2.2 save, which lacks it, reads as not moved.

    *Evidence:* `TableStateTests`, and the README's table in `ReadmeTests`. [0.2.2, 0.2.3]

22. **`redactingHiddenCards(keeping:)` (0.2.5)** gives a hand to someone who must not learn the cards the table never
    saw, such as the other players at a home game, following it on their phones. It turns each hole card never shown,
    except those of the players in `keeping`, and every burned card into `??` in the operations, then replays them.
    Everything else follows from the operations, so the log, the live cards, `results`, the document and PHH cannot
    hold a hidden card, as they could if the stored cards were edited in place. The copy ends where the hand does.
    Pots go on face-up cards (A13). Every hand with a card face down is asked again at each showdown (A9, A18), and a
    card kept face down at the last river is forgotten, so hand killing and pushes see only shown cards. Hiding a card
    never gets an operation refused, either: a hidden card is never shown later, and a `??` hole card or burn is
    accepted wherever a known one is. The redaction checks all this rather than assume it. It compares the stacks,
    bets, statuses, boards, cards shown, street, actor, `pendingOperation` and each result's chips, status and `shown`,
    and throws `RedactionError` instead of returning a copy that differs. A card shown at one street and left out of a
    river re-ask stays in the copy, since the table saw it.
    *Evidence:* `RedactionTests` redacts every oracle hand after every operation, and finds no hidden card in the
    operations, the document, the log or the hand history, and no change to what the table saw. [0.2.5]

## D. Errors

Each `EngineError` stands for a PokerKit `ValueError`, warning or crash, or, where the table says "No check", for
an input PokerKit accepts. The oracle checks the mapping on every refusal it records
(`OracleTests.matches(_:for:pokerKitMessage:)`). Checks run in this order: the hand is over, the named player does
not exist, the hand does not expect this kind of operation (PokerKit's first check), it is another player's turn, then
amounts and cards. So a dealt card scanned at the wrong moment reports the timing, not the duplicate, and a
refused raise reports why before its amount is judged, both as in PokerKit. Shows and mucks skip the first check,
because a post-hand show is still accepted after the hand, and the refusal of a show during forced bets runs last
(B9). A void skips it too, as it reaches a finished hand, and after a chop or a void every operation gets
`.handComplete` (B12). Three checks PokerKit does not have run ahead of some of its refusals, in the order above:
`.handComplete`, which stands for the operation's own refusal; `.invalidPlayer` (B8), which comes before even PokerKit's
first check; and `.notYourTurn`, which comes before the fold, raise and amount checks PokerKit makes for the actor.
Every other check only the port has runs after PokerKit's, so, with B5's call fixed, any other input PokerKit rejects
gets the error listed for that refusal.
`message(naming:)` words each error for the dealer in the engine's own terms, not PokerKit's.
A refused raise's message names only the refusal: the call can be a free check, and a tournament then refuses the
fold. Nobody being left to respond can also refuse the first bet of a street, so that message says "cannot bet or
raise".

| Engine error | PokerKit 0.7.7 |
| --- | --- |
| `handComplete` | The operation's own refusal, such as "There is no player to act." or "No card burning is pending." PokerKit still accepts a post-hand show, as the engine does (B9). After a chop or a void, no check: PokerKit has neither (B12) |
| `invalidPlayer(i)` | No check: the operation's own refusal when PokerKit's first check fires before it reads the index, otherwise an `IndexError`, or a negative index counted from the end (B8). PokerKit's betting actions take no player, and `select_runout_count` reads the index as a count (B5) |
| `noAnteExpected(p)` | "Nobody can post the ante." or "The Player *p* cannot post the ante." |
| `noBetCollectionExpected` | "The bet collection is currently prohibited." |
| `noBlindOrStraddleExpected(p)` | "Nobody can post the blind or straddle." or "The Player *p* cannot post the blind or straddle" |
| `noDealExpected(.burn)` | "No card burning is pending." |
| `noDealExpected(.holeCard(p))` | "Currently, nobody can be dealt hole cards." or "The Player *p* cannot be dealt any hole cards." |
| `noDealExpected(.boardCard)` | "No board dealing is pending." |
| `burnRequired` | "A card must be burnt before board dealing." |
| `duplicateCard(c, location:)` | A warning, or nothing when the repeat is inside one call or the card is back in its deck (B1) |
| `noActionExpected` | "There is no player to act." |
| `notYourTurn(p, actor:)` | No check: PokerKit's betting actions take no player and act for the actor |
| `cannotFoldWhenCheckIsFree(p)` | "There is no reason for this player to fold." (tournaments; cash games only warn) |
| `betBelowMinimum(x, minimum: m)` | "The amount *x* is below the minimum allowed *m*." |
| `betAboveMaximum(x, maximum: m)` | "The amount *x* is above the maximum allowed *m*." |
| `raiseNotAllowed(p, .playerIsCovered)` | "The player is already covered by a previous bet/raise. …", or one of the two messages below when PokerKit's earlier check fires first |
| `raiseNotAllowed(p, .actionNotReopened)` | "Short all-in cannot be raised." or "The player already acted and hence cannot raise in face of a non-full all-in wager" |
| `raiseNotAllowed(p, .noOpponentCanRespond)` | "There is no reason to complete, bet, or raise since every other player has either folded or gone all-in." |
| `noRunoutSelectionExpected(p)` | "Nobody can choose the number of runouts." or "The Player *p* cannot choose the number of runouts." |
| `invalidRunoutCount(c)` | "The runout count *c* is not positive." once B5's call is fixed; also a count above `maximumRunoutCount`, which PokerKit accepts (B5) |
| `noShowdownExpected(p)` | "There is no player to showdown." or "The Player *p* cannot perform a showdown."; also `cards: nil` or `[]` during forced bets, which PokerKit accepts (B9) |
| `playerNotInHand(p)` | "Player is not active." |
| `tooManyCardsShown(p, n)` | "too many cards shown" |
| `cannotShowUnknownCard(p)` | For a show with `cards: nil`: "An unknown card is shown.", "The player must show when all-in." or "A card is not shown in final showdown."; or a bare `AssertionError` (B9). For a list holding `??`, no check: PokerKit takes it as that card not being shown (B14) |
| `mustShowAllCards(p)` | For a listed show or a muck: "The player must show when all-in.", "A card is not shown in final showdown." or "Non-standard showdown must show all cards."; or a bare `AssertionError` (B9) |
| `shownCardNotDealt(p, c)` | No check: PokerKit replaces the cards, warning only if a shown card is not in its deck (B6) |
| `wouldAbandonPot(p, pot:)` | No check: a burn warning, an `AssertionError` in `push_chips`, or chips lost silently (B2) |
| `unknownBoardCard(r, position:)` | No check: a `KeyError` from the cascade (B4) |
| `noHandToKill(p)` | "Nobody can kill their hand." or "The Player *p* cannot kill their hand." |
| `noChipsToPush` | "The chip pushing is not allowed." |
| `noChipsToPull(p)` | "No one can pull chips." or "There is no chip to be pulled." |
| `cannotChopBlinds` | No check: PokerKit has no chop (B12) |

PokerKit tests a refused raise in a fixed order: the call (capped at the stack) is smaller than the largest raise
increment so far, then an acted player faces short all-ins that do not add up to a full raise, then the player is
covered, then nobody is left to respond. Whether raising is allowed is exactly PokerKit's verdict, but the reason
is labelled by meaning, coverage first. A covered player facing a short all-in therefore gets `.playerIsCovered`
where PokerKit says "Short all-in cannot be raised." The same labels appear in `LegalActions.betOrRaise`, and the
oracle checks them on every turn and requires each refused raise to give the same one.

## Research notes

`quirks.json` has 42 probes: 37 matched their predictions, and 1 is reference text (the PHH output). The other 4
"mismatches" all trace to how the research snippets were written, not to surprises in PokerKit:

- **`betting_oq3`:** the snippet folds the only other player with chips, so the "nobody can respond" rule fires.
- **`cards_oq2`:** shows were still pending, so the runout count had not taken effect yet.
- **`cards_oq12`:** PokerKit records the raw index -1.
- **`pots_oq10`:** a runout choice and a show were still pending before the burn.
