"""Translate between PokerEngine's terms and PokerKit 0.7.7.

PokerEngine's operations are its JSON v1 objects, such as
``{"type": "dealHole", "player": 0, "card": "As"}``. Snapshots describe a
PokerKit state with PokerEngine's field names, so the Swift harness compares
like with like.
"""

import copy
import warnings
from collections.abc import Iterable

from pokerkit import (
    AntePosting,
    Automation,
    BetCollection,
    BlindOrStraddlePosting,
    BoardDealing,
    Card,
    CardBurning,
    CheckingOrCalling,
    ChipsPulling,
    ChipsPushing,
    CompletionBettingOrRaisingTo,
    Folding,
    HandHistory,
    HandKilling,
    HoleCardsShowingOrMucking,
    HoleDealing,
    Mode,
    NoLimitTexasHoldem,
    OmahaHoldemHand,
    PotLimitOmahaHoldem,
    RunoutCountSelection,
    State,
)

AUTOMATIONS = {
    'antePosting': Automation.ANTE_POSTING,
    'betCollection': Automation.BET_COLLECTION,
    'blindOrStraddlePosting': Automation.BLIND_OR_STRADDLE_POSTING,
    'runoutCountSelection': Automation.RUNOUT_COUNT_SELECTION,
    'handKilling': Automation.HAND_KILLING,
    'chipsPushing': Automation.CHIPS_PUSHING,
    'chipsPulling': Automation.CHIPS_PULLING,
}
STREETS = ('preflop', 'flop', 'turn', 'river')
SHORT_ALL_IN = 'Short all-in cannot be raised.'
ALREADY_ACTED = (
    'The player already acted and hence cannot raise in face of a non-full'
    ' all-in wager'
)
NO_REASON = 'There is no reason to complete, bet, or raise'
REAL_GET_EFFECTIVE_STACK = State.get_effective_stack
REAL_BEGIN_HAND_KILLING = State._begin_hand_killing
REAL_VERIFY_SHOWING = State.verify_hole_cards_showing_or_mucking


def get_effective_stack(self: State, player_index: int) -> int:
    """B3: after a concession the last player has nobody to bet against.

    PokerKit asserts here when that player still has chips.
    """
    if sum(self.statuses) < 2:
        return 0

    return REAL_GET_EFFECTIVE_STACK(self, player_index)


def select_runout_count(
        self: State,
        runout_count: int | None = None,
        player_index: int | None = None,
        *,
        commentary: str | None = None,
) -> RunoutCountSelection:
    """B5: PokerKit's method, with the verification it meant to call.

    PokerKit passes the player as the count, which ignores the player named
    and lets a count of 0 or less through.
    """
    player_index = self.verify_runout_count_selection(
        runout_count,
        player_index,
    )

    assert self.runout_count_selector_statuses[player_index]

    self.runout_count_selector_statuses[player_index] = False

    if runout_count is not None:
        if self.runout_count is None:
            self.runout_count = runout_count
        elif self.runout_count != runout_count:
            self.runout_count = 1

        assert self.runout_count == runout_count or self.runout_count == 1

    operation = RunoutCountSelection(
        player_index,
        runout_count,
        commentary=commentary,
    )

    self._update_showdown(operation)

    return operation


def begin_hand_killing(self: State) -> None:
    """B4: a lone survivor is paid without evaluating any hand.

    PokerKit evaluates even then, stopping at the first board that player can
    win. It raises ``KeyError`` if the first board holds an unknown card, and
    a known first board never kills that player, so nothing else changes.
    """
    if sum(self.statuses) == 1:
        self._update_hand_killing()
    else:
        REAL_BEGIN_HAND_KILLING(self)


def verify_hole_cards_showing_or_mucking(
        self: State,
        status_or_hole_cards: bool | str | None = None,
        player_index: int | None = None,
) -> tuple:
    """B13: the player left at a tournament showdown with nobody all in may
    keep cards face down, as in a cash game.

    The tournament check is the only one here that reads the mode. After the
    hand PokerKit's own refusal stands, and the engine's B9 gives the same.
    """
    if (
            self.mode == Mode.TOURNAMENT
            and self.street is not None
            and sum(self.statuses) == 1
            and not self.all_in_status
    ):
        self.mode = Mode.CASH_GAME

        try:
            return REAL_VERIFY_SHOWING(
                self, status_or_hole_cards, player_index,
            )
        finally:
            self.mode = Mode.TOURNAMENT

    return REAL_VERIFY_SHOWING(self, status_or_hole_cards, player_index)


def emulate_deviations() -> None:
    """Make PokerKit go on where PokerEngine deliberately does (B3, B4, B5,
    B13).

    These are the only patches, and they are never applied at import:
    ``generate.py quirks`` probes real PokerKit, so its B3 and B5 evidence
    would silently vanish. Every other deviation is classified without being
    played.
    """
    State.get_effective_stack = get_effective_stack
    State.select_runout_count = select_runout_count
    State._begin_hand_killing = begin_hand_killing
    State.verify_hole_cards_showing_or_mucking = (
        verify_hole_cards_showing_or_mucking
    )


VARIANTS = {
    'noLimitTexasHoldem': NoLimitTexasHoldem,
    'potLimitOmahaHoldem': PotLimitOmahaHoldem,
}


def create_game(config: dict) -> NoLimitTexasHoldem | PotLimitOmahaHoldem:
    """A PokerKit game for a PokerEngine ``HandConfig`` (stored form).

    ``variant`` is only there for a game other than Texas hold'em.
    """
    if config['mode'] == 'cashGame':
        mode = Mode.CASH_GAME
    else:
        mode = Mode.TOURNAMENT

    return VARIANTS[config.get('variant', 'noLimitTexasHoldem')](
        tuple(AUTOMATIONS[name] for name in config['automations']),
        config['anteTrimming'],
        tuple(config['antes']),
        tuple(config['blindsOrStraddles']),
        config['minBet'],
        mode=mode,
    )


def create_state(config: dict) -> State:
    return create_game(config)(
        tuple(config['startingStacks']),
        len(config['startingStacks']),
    )


def apply(state: State, operation: dict) -> None:
    """Apply one PokerEngine operation; ValueError if PokerKit refuses it."""
    kind = operation['type']
    player = operation.get('player')

    with warnings.catch_warnings():
        # PokerKit warns about free folds in cash games and about cards
        # outside the deck; neither is an error.
        warnings.simplefilter('ignore')

        if kind == 'postAnte':
            state.post_ante(player)
        elif kind == 'collectBets':
            state.collect_bets()
        elif kind == 'postBlindOrStraddle':
            state.post_blind_or_straddle(player)
        elif kind == 'burnCard':
            state.burn_card(operation['card'])
        elif kind == 'dealHole':
            state.deal_hole(operation['card'], player)
        elif kind == 'dealBoard':
            state.deal_board(operation['card'])
        elif kind in ('fold', 'checkOrCall', 'betOrRaise'):
            # PokerKit's betting actions take no player; it always acts for
            # the actor (and says so when nobody is to act).
            if state.actor_index not in (None, player):
                raise ValueError(f'Player {player} is not the actor')
            elif kind == 'fold':
                state.fold()
            elif kind == 'checkOrCall':
                state.check_or_call()
            else:
                state.complete_bet_or_raise_to(operation['to'])
        elif kind == 'selectRunoutCount':
            state.select_runout_count(operation.get('count'), player)
        elif kind in ('showHoleCards', 'muckHoleCards'):
            state.show_or_muck_hole_cards(show_argument(operation), player)
        elif kind == 'killHand':
            state.kill_hand(player)
        elif kind == 'pushChips':
            state.push_chips()
        elif kind == 'pullChips':
            state.pull_chips(player)
        else:
            raise NotImplementedError(kind)


def show_argument(operation: dict) -> bool | str:
    """``show_or_muck_hole_cards``'s first argument for a show or a muck."""
    if operation['type'] == 'muckHoleCards':
        return False

    cards_shown = operation.get('cards')

    return True if cards_shown is None else ''.join(cards_shown)


def phase(state: State) -> str:
    """The phase of PokerKit's pending structures (it has no phase field)."""
    if any(state.ante_posting_statuses):
        return 'antePosting'
    elif state.bet_collection_status:
        return 'betCollection'
    elif any(state.blind_or_straddle_posting_statuses):
        return 'blindOrStraddlePosting'
    elif (
            state.card_burning_status
            or any(state.hole_dealing_statuses)
            or any(state.board_dealing_counts)
    ):
        return 'dealing'
    elif state.actor_indices:
        return 'betting'
    elif (
            any(state.runout_count_selector_statuses)
            or state.showdown_indices
    ):
        return 'showdown'
    elif any(state.hand_killing_statuses):
        return 'handKilling'
    elif state._sub_pots:
        return 'chipsPushing'
    elif any(state.chips_pulling_statuses):
        return 'chipsPulling'
    else:
        return 'complete'


def dealing_runout(state: State) -> int:
    """The runout being dealt, from PokerKit's countdown of those still due.

    PokerKit's records do not say, and nothing is counted down until the first
    showdown ends: every card before that belongs to the shared board.
    """
    if state.street_return_index is None:
        return 0

    return state.runout_count - state.street_return_count - 1


def event(
        record: object,
        street: str | None,
        runout: int = 0,
        returned: list[int] | None = None,
) -> dict:
    """A PokerKit record as a ``HandEvent``."""
    match record:
        case AntePosting(player_index=p, amount=a):
            return {'type': 'antePosted', 'player': p, 'amount': a}
        case BlindOrStraddlePosting(player_index=p, amount=a):
            return {'type': 'blindOrStraddlePosted', 'player': p, 'amount': a}
        case BetCollection(bets=bets):
            return {
                'type': 'betsCollected',
                'collected': list(bets),
                'returned': returned,
            }
        case CardBurning(card=card):
            return {
                'type': 'cardBurned',
                'card': repr(card),
                'street': street,
                'runout': runout,
            }
        case HoleDealing(player_index=p, cards=(card,)):
            return {'type': 'holeCardDealt', 'player': p, 'card': repr(card)}
        case BoardDealing(cards=(card,)):
            return {
                'type': 'boardCardDealt',
                'card': repr(card),
                'street': street,
                'runout': runout,
            }
        case Folding(player_index=p):
            return {'type': 'folded', 'player': p}
        case CheckingOrCalling(player_index=p, amount=a):
            return {'type': 'checkedOrCalled', 'player': p, 'amount': a}
        case CompletionBettingOrRaisingTo(player_index=p, amount=a):
            return {'type': 'betOrRaised', 'player': p, 'to': a}
        case RunoutCountSelection(player_index=p, runout_count=count):
            return {'type': 'runoutCountSelected', 'player': p, 'count': count}
        case HoleCardsShowingOrMucking(player_index=p, hole_cards=()):
            return {'type': 'holeCardsMucked', 'player': p}
        case HoleCardsShowingOrMucking(player_index=p, hole_cards=shown):
            return {
                'type': 'holeCardsShown',
                'player': p,
                'cards': cards(shown),
            }
        case HandKilling(player_index=p):
            return {'type': 'handKilled', 'player': p}
        case ChipsPushing(amounts=amounts, pot_index=pot, board_index=board):
            return {
                'type': 'chipsPushed',
                'pot': pot,
                'runout': board,
                'amounts': list(amounts),
            }
        case ChipsPulling(player_index=p, amount=a):
            return {'type': 'chipsPulled', 'player': p, 'amount': a}
        case _:
            raise NotImplementedError(repr(record))


def pending(state: State) -> dict | None:
    """PokerEngine's ``pendingOperation``."""
    match phase(state):
        case 'antePosting':
            return {
                'type': 'postAnte',
                'forcedBets': [
                    [i, state.get_effective_ante(i)]
                    for i in state.ante_poster_indices
                ],
            }
        case 'betCollection':
            return {'type': 'collectBets'}
        case 'blindOrStraddlePosting':
            return {
                'type': 'postBlindOrStraddle',
                'forcedBets': [
                    [i, state.get_effective_blind_or_straddle(i)]
                    for i in state.blind_or_straddle_poster_indices
                ],
            }
        case 'dealing':
            street = STREETS[state.street_index]
            runout = dealing_runout(state)

            if state.card_burning_status:
                return {'type': 'burnCard', 'street': street, 'runout': runout}
            elif state.hole_dealee_index is not None:
                dealee = state.hole_dealee_index

                return {
                    'type': 'dealHoleCard',
                    'player': dealee,
                    'cardIndex': len(state.hole_cards[dealee]),
                }
            else:
                count = state.street.board_dealing_count

                return {
                    'type': 'dealBoardCard',
                    'street': street,
                    'runout': runout,
                    'cardIndex': count - state.board_dealing_count,
                    'cardCount': count,
                }
        case 'betting':
            return {'type': 'act', 'player': state.actor_index}
        case 'showdown':
            return {
                'type': 'showdown',
                'runoutSelectors': [
                    i for i in state.player_indices
                    if state.runout_count_selector_statuses[i]
                ],
                'showOrder': list(state.showdown_indices),
            }
        case 'handKilling':
            return {
                'type': 'killHand',
                'players': list(state.hand_killing_indices),
            }
        case 'chipsPushing':
            _, pot, runout, _ = state._sub_pots[0]

            return {'type': 'pushChips', 'pot': pot, 'runout': runout}
        case 'chipsPulling':
            return {
                'type': 'pullChips',
                'players': list(state.chips_pulling_indices),
            }
        case _:
            return None


def can_fold(state: State) -> bool | None:
    """``LegalActions.canFold``: PokerKit's answer, less what B2 refuses."""
    if state.actor_index is None:
        return None

    with warnings.catch_warnings():
        warnings.simplefilter('ignore')

        return (
            state.can_fold()
            and abandoned_pot(state, state.actor_index) is None
        )


def abandoned_pot(state: State, player: int) -> int | None:
    """The pot a fold or muck by ``player`` leaves with nobody eligible (B2).

    A fold is played out on a copy: everyone still to act owes the largest
    bet, a folded player's included, so a pot is lost only if it stays
    without a winner once they have called. The index is into the pots as
    they would then stand. A muck comes after every bet is collected.
    """
    if state.actor_index is None:
        probe = copy.copy(state)
        probe.statuses = list(state.statuses)
        probe.statuses[player] = False
    else:
        probe = copy.deepcopy(state)
        # Without automations the copy stops before ``push_chips`` can assert.
        probe.automations = ()

        with warnings.catch_warnings():
            warnings.simplefilter('ignore')
            probe.fold()

        # PokerKit clears the queue when one player is left.
        while probe.actor_index is not None:
            probe.check_or_call()

        if probe.can_collect_bets():
            probe.collect_bets()

    for index, pot in enumerate(probe.pots):
        if not pot.player_indices:
            return index

    return None


def dead_hand_pot(state: State, operation: dict) -> int | None:
    """B2 in Omaha: the pot nobody could win once ``operation`` answers the
    river's showdown, as an index into the pots as they would then stand.

    There a card kept face down is forgotten and an Omaha hand needs two hole
    cards, so a player who has answered without two known cards cannot win,
    and PokerKit loses the pot without a word. A lone survivor is paid
    without a look at the cards. Shows the classifier has already refused,
    such as one listing ``??``, never get here.
    """
    if (
            OmahaHoldemHand not in state.hand_types
            or state.street is not state.streets[-1]
    ):
        return None

    player = operation['player']
    probe = copy.copy(state)
    probe.statuses = list(state.statuses)
    known = [sum(map(bool, cards)) for cards in state.hole_cards]

    if operation['type'] == 'muckHoleCards':
        probe.statuses[player] = False
    elif operation.get('cards') is not None:
        known[player] = len(operation['cards'])

    if sum(probe.statuses) < 2:
        return None

    for index, pot in enumerate(probe.pots):
        if all(
                (i == player or i not in state.showdown_indices)
                and known[i] < 2
                for i in pot.player_indices
        ):
            return index

    return None


def raise_refusal(state: State) -> str | None:
    """PokerKit's reason for refusing any bet or raise by the actor."""
    try:
        state.verify_completion_betting_or_raising_to()
    except ValueError as error:
        return str(error)

    return None


def bet_or_raise(state: State) -> str | None:
    """PokerEngine's ``LegalActions.betOrRaise``: ``bet`` or ``raise``, or
    the ``RaiseUnavailableReason`` for PokerKit's refusal.

    PokerKit checks short all-ins and acted players before coverage; the
    engine names coverage first (DECISIONS.md D).
    """
    actor = state.actor_index

    if actor is None:
        return None

    refusal = raise_refusal(state)

    if refusal is None:
        return 'bet' if max(state.bets) == 0 else 'raise'
    elif state.stacks[actor] <= max(state.bets) - state.bets[actor]:
        return 'playerIsCovered'
    elif refusal in (SHORT_ALL_IN, ALREADY_ACTED):
        return 'actionNotReopened'
    elif refusal.startswith(NO_REASON):
        return 'noOpponentCanRespond'

    raise NotImplementedError(refusal)


def board_hands(
        state: State,
        board: int,
) -> tuple[list[str | None], list[str | None]]:
    """Each player's best hand on ``board``, then from shown cards alone."""
    hands = []
    up_hands = []

    for i in state.player_indices:
        hand = state.get_hand(i, board, 0)
        hands.append(None if hand is None else str(hand))

        # Unlike ``get_hand``, this lets an unknown board card's KeyError out.
        try:
            hand = state.get_up_hand(i, board, 0)
        except KeyError:
            hand = None

        up_hands.append(None if hand is None else str(hand))

    return hands, up_hands


def snapshot(state: State) -> dict:
    """The fields the Swift harness compares after each step."""
    hands, up_hands = zip(
        *(board_hands(state, board) for board in state.board_indices),
    )

    return {
        'stacks': list(state.stacks),
        'bets': list(state.bets),
        'statuses': player_statuses(state),
        'street': (
            None if state.street_index is None
            else STREETS[state.street_index]
        ),
        'actor': state.actor_index,
        'toCall': state.checking_or_calling_amount,
        'canFold': can_fold(state),
        'betOrRaise': bet_or_raise(state),
        'minRaiseTo': state.min_completion_betting_or_raising_to_amount,
        'maxRaiseTo': state.max_completion_betting_or_raising_to_amount,
        'pots': [
            {
                'amount': pot.amount,
                'eligiblePlayers': list(pot.player_indices),
            }
            for pot in state.pots
        ],
        'totalPot': state.total_pot_amount,
        'boards': [
            cards(state.get_board_cards(i)) for i in state.board_indices
        ],
        'runoutCount': state.board_count,
        'holeCards': [cards(hole) for hole in state.hole_cards],
        'faceUp': [list(statuses) for statuses in state.hole_card_statuses],
        'hands': list(hands),
        'upHands': list(up_hands),
        'pending': pending(state),
        'complete': not state.status,
        'results': results(state),
    }


def cards(values: Iterable[Card]) -> list[str]:
    return [repr(card) for card in values]


def player_statuses(state: State) -> list[str]:
    """``PlayerStatus``: how each player left, unlike ``state.statuses``."""
    statuses = ['active'] * state.player_count

    for record in state.operations:
        match record:
            case Folding(player_index=p):
                statuses[p] = 'folded'
            case HoleCardsShowingOrMucking(player_index=p, hole_cards=()):
                statuses[p] = 'mucked'
            case HandKilling(player_index=p):
                statuses[p] = 'killed'

    return statuses


def dealt_hole_cards(state: State) -> list[list[list]]:
    """Every player's ``[card, shown]`` slots, in deal order.

    These are the cards the player holds, whatever the live ``hole_cards``
    say: a show reorders those, the river forgets them and leaving the hand
    empties them. A listed card the player was not dealt fills the first
    ``??`` slot, and ``shown`` never goes back to false.
    """
    dealt = [[] for _ in state.player_indices]

    for record in state.operations:
        match record:
            case HoleDealing(player_index=p, cards=(card,)):
                dealt[p].append([repr(card), False])
            case HoleCardsShowingOrMucking(player_index=p, hole_cards=shown):
                for card in cards(filter(None, shown)):
                    slots = [slot for slot in dealt[p] if slot[0] == card]
                    slot = slots[0] if slots else next(
                        slot for slot in dealt[p] if slot[0] == '??'
                    )
                    slot[:] = [card, True]

    return dealt


def winnings(state: State) -> list[int]:
    """Chips pushed to each player, without any bet returned."""
    won = [0] * state.player_count

    for record in state.operations:
        if isinstance(record, ChipsPushing):
            won = [sum(amounts) for amounts in zip(won, record.amounts)]

    return won


def phh(state: State, config: dict) -> str | None:
    """PokerKit's own hand history, or None with several runouts: PHH cannot
    hold them, and PokerKit's text for such a hand does not replay
    (``pots_oq2``). PokerKit leaves out ``ante_trimming_status``, and the
    stacks and winnings are its optional fields."""
    if state.board_count > 1:
        return None

    return HandHistory.from_game_state(
        create_game(config),
        state,
        ante_trimming_status=config['anteTrimming'],
        finishing_stacks=list(state.stacks),
        winnings=winnings(state),
    ).dumps()


def results(state: State) -> list[dict] | None:
    """``HandState.results``: null until the hand is complete."""
    if state.status:
        return None

    statuses = player_statuses(state)
    won = winnings(state)

    return [
        {
            'player': i,
            'net': state.payoffs[i],
            'won': won[i],
            'status': statuses[i],
            'holeCards': [card for card, _ in hole],
            'faceUp': [shown for _, shown in hole],
            'shown': all(shown for _, shown in hole),
        }
        for i, hole in enumerate(dealt_hole_cards(state))
    ]


def events(
        state: State,
        start: int,
        street: str | None,
        runout: int,
        bets: list[int],
) -> list[dict]:
    """The events recorded since ``state.operations[start]``.

    ``street`` and ``runout`` are those before the operation: burns and deals
    are always the dealer's own operation, never part of an automated cascade.
    ``bets`` are the bets before the operation. PokerKit does not record the
    uncalled bets a collection returns, so they are worked out here by
    following the bets through the records.
    """
    bets = list(bets)
    recorded = []
    survivor = None

    if sum(state.statuses) == 1:
        survivor = state.statuses.index(True)

    for record in state.operations[start:]:
        returned = None

        match record:
            case AntePosting(player_index=p, amount=a):
                bets[p] = a
            case BlindOrStraddlePosting(player_index=p, amount=a):
                bets[p] = a
            case CheckingOrCalling(player_index=p, amount=a):
                bets[p] += a
            case CompletionBettingOrRaisingTo(player_index=p, amount=a):
                bets[p] = a
            case BetCollection(bets=collected):
                # The winner of a fold-out keeps the bet, neither collected
                # nor returned.
                returned = [
                    0 if i == survivor else bet - collected[i]
                    for i, bet in enumerate(bets)
                ]
                bets = [
                    bet if i == survivor else 0
                    for i, bet in enumerate(bets)
                ]

        recorded.append(event(record, street, runout, returned))

    return recorded
