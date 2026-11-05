"""Hands played on PokerKit and recorded step by step for the Swift harness.

Each hand is one JSON line: the config, then one step per operation, then
PokerKit's PHH text for the state the hand ended in (null with more than one
runout). A step holds the operation, the events it produced, and the snapshot
fields that changed; the first step is ``HandState.init`` and has the full
snapshot.

A rejected step is never played on PokerKit. ``"rejected"`` says why:

- ``"pokerkit"``: PokerKit refuses it, in the step's ``"message"``;
- ``"B1"``: it repeats a known card, which PokerKit lets through;
- ``"B2"``, ``"B4"``, ``"B5"``, ``"B6"``, ``"B9"``, ``"B14"``: PokerEngine
  refuses it by that deviation. The step's ``"error"`` is the exact
  ``EngineError``, as its synthesized ``Codable`` JSON.

Every hand is played to completion, and sometimes on through post-hand shows.
The one exception is B4: PokerKit cannot get past an unknown board card, so a
hand ends right after that rejection.
"""

import copy
import random
import warnings
from collections import Counter

from pokerkit import (
    BetCollection,
    CardBurning,
    ChipsPushing,
    Deck,
    HandKilling,
    HoleCardsShowingOrMucking,
    RunoutCountSelection,
    State,
)

import bridge

STAGES = ('full',)
SAMPLE_FEATURES = (
    'heads-up', 'short-handed', 'full-ring', 'cash', 'tournament', 'omaha',
    'rejected-B2-dead-hand',
    'uniform-antes', 'trimmed-antes', 'bb-ante', 'button-ante', 'no-blinds',
    'equal-blinds', 'utg-straddle', 'double-straddle', 'button-straddle',
    'irregular-blinds', 'live-post', 'two-live-posts', 'manual-antes',
    'manual-blinds', 'manual-collection', 'unknown-card',
    'off-order-hole-deal', 'short-all-in-raise', 'sub-minimum-full-raise',
    'uncalled-return', 'free-fold', 'fold-out', 'fold-out-before-push',
    'all-in-preflop', 'all-in-postflop', 'river-showdown',
    'river-showdown-contested', 'all-in-runout', 're-ask', 'runout-selection',
    'runout-automation', 'partial-show', 'river-forget', 'reveal', 'muck',
    'concession', 'kill', 'manual-kill', 'manual-push', 'manual-pull',
    'single-survivor-push', 'split-pot', 'odd-chip', 'side-pot-win',
    'post-hand-show', 'rejected-pokerkit', 'rejected-B1', 'rejected-B2',
    'rejected-B4', 'rejected-B5', 'rejected-B6', 'rejected-B9',
    'rejected-B14',
    # B13: about 13 hands in 10,000, so the committed hands usually fall
    # short; scenarios.py covers it.
    'tournament-keep',
    'short-stack-forced-bet', 'multiple-runouts', 'three-or-more-runouts',
    'runouts-from-flop', 'runouts-from-turn', 'runouts-from-river',
    'runout-disagreement', 'reask-between-runouts', 'runouts-split-a-pot',
    'runout-remainder', 'runout-scoop', 'runout-concession', 'unequal-boards',
    'rejected-B4-later-runout',
    # Random play rarely gets here (about 1 hand in 30,000, 7 in 10,000 and
    # 8 in 10,000), so the committed hands usually fall short; scenarios.py
    # covers all three.
    'already-acted-refusal', 'refund-to-folded', 'rejected-B2-fold',
)
MANUAL_SETTLEMENT = {
    'killHand': 'manual-kill',
    'pushChips': 'manual-push',
    'pullChips': 'manual-pull',
}
SETTLING_PHASES = ('handKilling', 'chipsPushing', 'chipsPulling', 'complete')
UNKNOWN_CARD_RATE = 0.08
# B4 ends a hand, so board cards are unknown far less often than the rest.
UNKNOWN_BOARD_CARD_RATE = 0.015
# ``HandState.maximumRunoutCount`` (B5).
MAXIMUM_RUNOUT_COUNT = 52


class Recorder:
    """Applies operations to a PokerKit state and records the steps."""

    def __init__(self, config: dict) -> None:
        self.config = config
        self.state = bridge.create_state(config)
        self.previous = bridge.snapshot(self.state)
        self.steps = [
            {
                'events': bridge.events(
                    self.state, 0, None, 0, [0] * self.state.player_count,
                ),
                'state': self.previous,
            },
        ]
        self.stopped = False
        self.features = config_features(config) | short_forced_bets(self.state)
        self.bets_before_collection = list(self.state.bets)
        self.pushes = {}

    @property
    def done(self) -> bool:
        return self.stopped or not self.state.status

    def street(self) -> str | None:
        if self.state.street_index is None:
            return None

        return bridge.STREETS[self.state.street_index]

    def play(self, operation: dict) -> dict | None:
        """Records ``operation`` as the classifier rules; returns its verdict.

        ``apply`` mutates the state, so every operation is classified first.
        """
        verdict = classify(self.state, operation)

        if verdict is None:
            self.apply(operation)
        else:
            self.reject(operation, verdict)

        return verdict

    def reject(self, operation: dict, verdict: dict) -> None:
        self.steps.append({'op': operation} | verdict)
        self.features.add(f'rejected-{verdict["rejected"]}')

        if verdict['rejected'] == 'B4':
            self.stopped = True

            if verdict['error']['unknownBoardCard']['runout']:
                self.features.add('rejected-B4-later-runout')
        elif verdict['rejected'] == 'B2' and operation['type'] == 'fold':
            self.features.add('rejected-B2-fold')
        elif verdict['rejected'] == 'B2' and 'cards' in operation:
            # Only an Omaha hand that keeps cards face down can abandon a pot.
            self.features.add('rejected-B2-dead-hand')

    def note_features(self, operation: dict) -> None:
        """Features visible before ``operation``, and the bets it leaves."""
        state = self.state
        kind = operation['type']
        actor = state.actor_index
        self.bets_before_collection = list(state.bets)

        if operation.get('card') == '??':
            self.features.add('unknown-card')
        suggested = state.hole_dealee_index

        if kind == 'dealHole' and operation['player'] != suggested:
            self.features.add('off-order-hole-deal')
        if kind == 'fold' and state.checking_or_calling_amount == 0:
            self.features.add('free-fold')
        if actor is not None and (
                bridge.raise_refusal(state) == bridge.ALREADY_ACTED
        ):
            self.features.add('already-acted-refusal')
        if kind == 'checkOrCall':
            self.bets_before_collection[actor] += (
                state.checking_or_calling_amount
            )
        if kind == 'betOrRaise':
            self.bets_before_collection[actor] = operation['to']
            increment = operation['to'] - max(state.bets)
            largest = state.completion_betting_or_raising_amount
            minimum = state.street.min_completion_betting_or_raising_amount

            # A3: only the largest increment so far decides a full raise.
            if increment < largest:
                self.features.add('short-all-in-raise')
            elif increment < minimum:
                self.features.add('sub-minimum-full-raise')
        if kind == 'dealBoard' and state.all_in_status:
            self.features.add('all-in-runout')
        if kind == 'showHoleCards':
            self.note_show(operation)
        if kind in MANUAL_SETTLEMENT:
            self.features.add(MANUAL_SETTLEMENT[kind])

    def note_show(self, operation: dict) -> None:
        state = self.state

        if state.street is None:
            self.features.add('post-hand-show')

        if operation.get('cards') is None:
            return

        shown = [card for card in operation['cards'] if card != '??']
        dealt = [
            card
            for card, _ in bridge.dealt_hole_cards(state)[operation['player']]
        ]

        if len(shown) < len(dealt):
            self.features.add('partial-show')

            # Accepted, so the player left with nobody all in (B13).
            if self.config['mode'] == 'tournament':
                self.features.add('tournament-keep')
        if any(card not in dealt for card in shown):
            self.features.add('reveal')
        if state.street is state.streets[-1] and any(
                card != '??' and card not in shown for card in dealt
        ):
            self.features.add('river-forget')

    def note_settled_features(self, start: int, street: str | None) -> None:
        """Features of the cascade since ``start`` and of how betting ends.

        ``street`` is the street before the operation; antes are collected
        before there is one.
        """
        state = self.state
        survivor = None
        settling = sum(state.statuses)

        if settling == 1:
            survivor = state.statuses.index(True)

        for record in state.operations[start:]:
            match record:
                case BetCollection(bets=bets) if street is not None:
                    self.note_collection(bets, survivor)
                case RunoutCountSelection():
                    self.features.add(
                        'runout-selection' if record is state.operations[start]
                        else 'runout-automation',
                    )
                case HoleCardsShowingOrMucking(hole_cards=()):
                    self.features.add('muck')
                case HandKilling():
                    self.features.add('kill')
                    settling += 1
                case ChipsPushing():
                    self.note_push(record)

        self.note_runouts()
        phase = bridge.phase(state)

        if state.folded_status:
            if 'mucked' in bridge.player_statuses(state):
                self.features.add('concession')
            else:
                self.features.add('fold-out')

                if phase == 'chipsPushing':
                    self.features.add('fold-out-before-push')
        elif phase == 'showdown' and not state.runout_count_selection_flag:
            if state.street_index == len(state.streets) - 1:
                self.features.add('river-showdown')
            elif state.street_index == 0:
                self.features.add('all-in-preflop')
            else:
                self.features.add('all-in-postflop')
        elif phase == 'showdown' and state.showdown_indices:
            self.features.add('re-ask')
        elif (
                phase in SETTLING_PHASES
                and street == bridge.STREETS[-1]
                and settling > 1
                and not state.all_in_status
        ):
            # Not read off the push: a loser's hand is killed first, so one
            # winner is paid as a single survivor.
            self.features.add('river-showdown-contested')

    def note_collection(
            self,
            bets: tuple[int, ...],
            survivor: int | None,
    ) -> None:
        for i, collected in enumerate(bets):
            bet = self.bets_before_collection[i]

            if i != survivor and bet > collected:
                self.features.add('uncalled-return')

                if not self.state.statuses[i]:
                    self.features.add('refund-to-folded')

    def note_push(self, record: ChipsPushing) -> None:
        winners = [amount for amount in record.amounts if amount]
        pushes = self.pushes.setdefault(record.pot_index, [])
        pushes.append(record.amounts)

        if record.board_index is None:
            self.features.add('single-survivor-push')

            if self.state.board_count > 1 and not self.state.folded_status:
                self.features.add('runout-scoop')
        if len(winners) > 1:
            self.features.add('split-pot')
        if len(set(winners)) > 1:
            self.features.add('odd-chip')
        if record.pot_index:
            self.features.add('side-pot-win')
        if len({tuple(map(bool, amounts)) for amounts in pushes}) > 1:
            self.features.add('runouts-split-a-pot')
        if len({sum(amounts) for amounts in pushes}) > 1:
            self.features.add('runout-remainder')

    def note_runouts(self) -> None:
        """Features of the table's choice and of running the board again."""
        state = self.state
        counts = {
            record.runout_count
            for record in state.operations
            if isinstance(record, RunoutCountSelection)
        }

        if len(counts - {None}) > 1:
            self.features.add('runout-disagreement')
        if state.board_count == 1:
            return

        first_street = bridge.STREETS[state.street_return_index]
        self.features |= {'multiple-runouts', f'runouts-from-{first_street}'}

        if state.board_count > 2:
            self.features.add('three-or-more-runouts')
        if bridge.phase(state) == 'showdown' and bridge.dealing_runout(state):
            self.features.add('reask-between-runouts')
        if state.folded_status:
            self.features.add('runout-concession')

        lengths = {
            len(list(state.get_board_cards(i))) for i in state.board_indices
        }

        if bridge.phase(state) in SETTLING_PHASES and len(lengths) > 1:
            self.features.add('unequal-boards')

    def apply(self, operation: dict) -> None:
        start = len(self.state.operations)
        street = self.street()
        runout = bridge.dealing_runout(self.state)
        bets = list(self.state.bets)
        self.note_features(operation)
        bridge.apply(self.state, operation)
        self.note_settled_features(start, street)
        snapshot = bridge.snapshot(self.state)
        self.steps.append(
            {
                'op': operation,
                'events': bridge.events(
                    self.state, start, street, runout, bets,
                ),
                'state': {
                    key: value
                    for key, value in snapshot.items()
                    if self.previous[key] != value
                },
            },
        )
        self.previous = snapshot

    def hand(self, name: str, stage: str) -> dict:
        return {
            'name': name,
            'stage': stage,
            'features': sorted(self.features),
            'config': self.config,
            'steps': self.steps,
            'phh': bridge.phh(self.state, self.config),
        }


# Random configs


def random_config(rng: random.Random) -> dict:
    player_count = rng.choice((2, 2, 3, 4, 5, 6, 6, 7, 8, 9, 10))
    big_blind = rng.choice((2, 2, 4, 10, 20, 100))
    small_blind = rng.choice((big_blind // 2, big_blind // 2, big_blind))
    blinds = blind_structure(rng, player_count, small_blind, big_blind)
    antes, ante_trimming = ante_structure(rng, player_count, big_blind)

    if not any(blinds) and not any(antes):
        blinds = [small_blind, big_blind]

    # At a short-stacked table, forced bets and all-ins cut into each other.
    short_table = rng.random() < 0.15
    stacks = [
        random_stack(rng, big_blind, short_table)
        for _ in range(player_count)
    ]
    automations = [
        name
        for name, rate in (
            ('antePosting', 0.7), ('betCollection', 0.7),
            ('blindOrStraddlePosting', 0.7), ('runoutCountSelection', 0.2),
            ('handKilling', 0.7), ('chipsPushing', 0.7), ('chipsPulling', 0.7),
        )
        if rng.random() < rate
    ]

    # The stored config names a game only when it is not Texas hold'em.
    variant = {'variant': 'potLimitOmahaHoldem'} if rng.random() < 0.35 else {}

    return variant | {
        'mode': rng.choice(('cashGame', 'tournament')),
        'startingStacks': stacks,
        'antes': pad(antes, player_count),
        'anteTrimming': ante_trimming,
        'blindsOrStraddles': pad(blinds, player_count),
        'minBet': rng.choice(
            (
                big_blind, big_blind, max(1, big_blind // 2),
                2 * big_blind, 5 * big_blind,
            ),
        ),
        'automations': automations,
    }


def random_stack(rng: random.Random, big_blind: int, short_table: bool) -> int:
    if short_table and rng.random() < 0.75:
        return rng.randint(1, 3 * big_blind)

    return rng.choice(
        (
            rng.randint(1, 2 * big_blind),
            rng.randint(5 * big_blind, 30 * big_blind),
            rng.randint(50 * big_blind, 200 * big_blind),
            rng.randint(50 * big_blind, 200 * big_blind),
            rng.randint(1000 * big_blind, 5000 * big_blind),
        ),
    )


def blind_structure(
        rng: random.Random,
        player_count: int,
        small_blind: int,
        big_blind: int,
) -> list[int]:
    kinds = ['standard'] * 4 + ['none', 'irregular', 'live-post']

    if player_count >= 3:
        kinds.append('utg-straddle')
    if player_count >= 4:
        kinds += ['double-straddle', 'button-straddle', 'two-live-posts']

    match rng.choice(kinds):
        case 'standard':
            return [small_blind, big_blind]
        case 'none':
            return []
        case 'utg-straddle':
            return [small_blind, big_blind, 2 * big_blind]
        case 'double-straddle':
            return [small_blind, big_blind, 2 * big_blind, 4 * big_blind]
        case 'button-straddle':
            middle = [0] * (player_count - 3)

            return [small_blind, big_blind] + middle + [2 * big_blind]
        case 'irregular':
            return [
                rng.randint(0, big_blind)
                for _ in range(rng.randint(2, player_count))
            ]
        case 'two-live-posts':
            # B2's mid-round refusal needs two posts above the big blind,
            # seated before the remaining actors.
            first = rng.randint(big_blind + 1, 2 * big_blind)
            second = rng.choice((first, rng.randint(big_blind + 1, first)))

            return [small_blind, big_blind, -first, -second]
        case _:
            blinds = [small_blind, big_blind] + [0] * (player_count - 2)

            if player_count == 2:
                # Heads-up there is no other seat: one blind is posted live.
                position = rng.randint(0, 1)
                blinds[position] = -blinds[position]
            else:
                blinds[rng.randint(2, player_count - 1)] = -big_blind

            return blinds


def ante_structure(
        rng: random.Random,
        player_count: int,
        big_blind: int,
) -> tuple[list[int], bool]:
    ante = rng.choice((1, max(1, big_blind // 4), big_blind))

    match rng.choice(('none', 'none', 'uniform', 'bb', 'button')):
        case 'none':
            return [], rng.random() < 0.5
        case 'uniform':
            return [ante] * player_count, rng.random() < 0.5
        case 'bb':
            return [0, ante], False
        case _ if player_count == 2:
            # Heads-up the button is written first, as the small blind.
            return [ante, 0], False
        case _:
            return [0] * (player_count - 1) + [ante], False


def pad(values: list[int], count: int) -> list[int]:
    return values + [0] * (count - len(values))


# Cards


def deck_cards(state: State) -> list[str]:
    """The undealt cards, in standard deck order for reproducible choices."""
    order = {card: index for index, card in enumerate(Deck.STANDARD)}

    return [repr(card) for card in sorted(state.deck_cards, key=order.get)]


def dealt_known_cards(state: State) -> list[str]:
    """Every known card scanned so far, wherever it is now.

    Taken from the records: PokerKit has a card forgotten on the river back in
    its deck and ``??`` for it in the muck, and it shuffles its burns and muck
    back in when the deck runs out.
    """
    burned = [
        record.card
        for record in state.operations
        if isinstance(record, CardBurning)
    ]
    cards = burned + [card for slot in state.board_cards for card in slot]
    known = {repr(card) for card in cards if card}

    for hole in bridge.dealt_hole_cards(state):
        known.update(card for card, _ in hole if card != '??')

    return sorted(known)


def unseen_cards(state: State) -> list[str]:
    known = dealt_known_cards(state)

    return [card for card in deck_cards(state) if card not in known]


def random_card(rng: random.Random, state: State, unknown_rate: float) -> str:
    # Enough runouts use every card up: only ``??`` is left to deal then.
    if rng.random() < unknown_rate or not unseen_cards(state):
        return '??'

    return rng.choice(deck_cards(state))


# Random operations


def next_operation(rng: random.Random, state: State) -> dict:
    match bridge.phase(state):
        case 'antePosting':
            return {
                'type': 'postAnte',
                'player': rng.choice(list(state.ante_poster_indices)),
            }
        case 'betCollection':
            return {'type': 'collectBets'}
        case 'blindOrStraddlePosting':
            posters = list(state.blind_or_straddle_poster_indices)

            return {
                'type': 'postBlindOrStraddle',
                'player': rng.choice(posters),
            }
        case 'dealing':
            if state.card_burning_status:
                card = random_card(rng, state, UNKNOWN_CARD_RATE)

                return {'type': 'burnCard', 'card': card}
            elif any(state.hole_dealing_statuses):
                card = random_card(rng, state, UNKNOWN_CARD_RATE)
                owed = [
                    i for i in state.player_indices
                    if state.hole_dealing_statuses[i]
                ]
                player = (
                    state.hole_dealee_index if rng.random() < 0.8
                    else rng.choice(owed)
                )

                return {'type': 'dealHole', 'player': player, 'card': card}
            else:
                card = random_card(rng, state, UNKNOWN_BOARD_CARD_RATE)

                return {'type': 'dealBoard', 'card': card}
        case 'betting':
            return betting_operation(rng, state)
        case 'showdown':
            return showdown_operation(rng, state)
        case 'handKilling':
            player = rng.choice(list(state.hand_killing_indices))

            return {'type': 'killHand', 'player': player}
        case 'chipsPushing':
            return {'type': 'pushChips'}
        case _:
            player = rng.choice(list(state.chips_pulling_indices))

            return {'type': 'pullChips', 'player': player}


def betting_operation(rng: random.Random, state: State) -> dict:
    player = state.actor_index
    to_call = state.checking_or_calling_amount
    fold = {'type': 'fold', 'player': player}
    choices = [
        ({'type': 'checkOrCall', 'player': player}, 50),
        # Facing a bet only B2 can refuse a fold, and states where it does
        # are rare, so such folds are tried as often as any other.
        (fold, 25 if to_call else 8 if bridge.can_fold(state) else 3),
    ]
    low = state.min_completion_betting_or_raising_to_amount
    high = state.max_completion_betting_or_raising_to_amount

    if low is not None:
        # Small raises keep hands going, and leave room for short all-ins.
        amount = rng.choice(
            (
                low, low, high,
                rng.randint(low, high),
                rng.randint(low, min(high, 3 * low)),
            ),
        )
        bet = {'type': 'betOrRaise', 'player': player, 'to': amount}
        choices.append((bet, 30))

    operations, weights = zip(*choices)

    return rng.choices(operations, weights)[0]


def showdown_operation(rng: random.Random, state: State) -> dict:
    selectors = [
        i for i in state.player_indices
        if state.runout_count_selector_statuses[i]
    ]
    order = list(state.showdown_indices)

    if selectors and (not order or rng.random() < 0.5):
        selection = {
            'type': 'selectRunoutCount',
            'player': rng.choice(selectors),
        }
        count = runout_count_choice(rng, state)

        return selection if count is None else selection | {'count': count}

    player = rng.choice(order) if rng.random() < 0.25 else order[0]
    muck = {'type': 'muckHoleCards', 'player': player}
    stranded = bridge.abandoned_pot(state, player) is not None
    operations, weights = zip(
        *show_choices(rng, state, player),
        (muck, 3 if stranded else 25),
    )

    return rng.choices(operations, weights)[0]


def runout_count_choice(rng: random.Random, state: State) -> int | None:
    """A player's choice, usually going along with a count already named."""
    if state.runout_count not in (None, 1) and rng.random() < 0.8:
        return rng.choice((None, state.runout_count))

    return rng.choices(
        (None, 1, 2, 3, 4, 7, 0, -1, MAXIMUM_RUNOUT_COUNT + 1),
        (10, 4, 10, 5, 2, 1, 1, 1, 1),
    )[0]


def show_choices(
        rng: random.Random,
        state: State,
        player: int,
) -> list[tuple[dict, int]]:
    """Weighted shows by ``player``, some of them to be refused.

    Built from the dealt record, not the live cards: a live ``??`` dealt as
    a known card is not revealable, and naming it is a legal show.
    """
    dealt = [card for card, _ in bridge.dealt_hole_cards(state)[player]]
    unseen = unseen_cards(state)
    rng.shuffle(unseen)
    # With the deck used up a ``??`` slot stays unnamed.
    full = [
        unseen.pop() if card == '??' and unseen else card
        for card in dealt
    ]
    rng.shuffle(full)
    show = {'type': 'showHoleCards', 'player': player}
    live_unknown = not all(state.hole_cards[player])
    others = [card for card in dealt_known_cards(state) if card not in dealt]
    choices = [
        (show, 3 if live_unknown else 30),
        (show | {'cards': full}, 30),
        (show | {'cards': full[:1]}, 8),
        (show | {'cards': []}, 8),
        (show | {'cards': ['??', full[0]]}, 2),
        # An undealt card: a reveal, or B6 with no ``??`` slot to fill.
        (show | {'cards': full[:1] + unseen[:1]}, 2),
        (show | {'cards': full + unseen[:1]}, 1),
        (show | {'cards': full[:1] * 2}, 1),
    ]

    if others:
        # Someone else's card: B1 into a ``??`` slot, otherwise B6.
        choices.append((show | {'cards': [rng.choice(others)] + full[1:]}, 2))

    return choices


def post_hand_show(rng: random.Random, state: State) -> dict:
    """A show from chips pushing on, mostly by a player still in the hand."""
    active = [i for i in state.player_indices if state.statuses[i]]
    player = rng.randrange(state.player_count)

    if active and rng.random() < 0.9:
        player = rng.choice(active)

    operations, weights = zip(*show_choices(rng, state, player))

    return rng.choices(operations, weights)[0]


def invalid_operation(
        rng: random.Random,
        state: State,
) -> tuple[dict, dict] | None:
    """An operation out of place here, with the classifier's verdict.

    None if the one picked turns out to be accepted.
    """
    known = dealt_known_cards(state)
    player = rng.randrange(state.player_count)
    show = {'type': 'showHoleCards', 'player': player}
    candidates = [
        {'type': 'checkOrCall', 'player': player},
        {'type': 'fold', 'player': player},
        {'type': 'betOrRaise', 'player': player, 'to': rng.randint(1, 60)},
        {'type': 'postAnte', 'player': player},
        {'type': 'postBlindOrStraddle', 'player': player},
        {'type': 'collectBets'},
        {'type': 'burnCard', 'card': '??'},
        {'type': 'dealBoard', 'card': '??'},
        {'type': 'dealHole', 'player': player, 'card': '??'},
        {'type': 'selectRunoutCount', 'player': player},
        {'type': 'selectRunoutCount', 'player': player, 'count': 2},
        show,
        show | {'cards': []},
        show | {'cards': [random_card(rng, state, 0)]},
        {'type': 'muckHoleCards', 'player': player},
        {'type': 'killHand', 'player': player},
        {'type': 'pushChips'},
        {'type': 'pullChips', 'player': player},
    ]

    if known:
        # A dealt card scanned at the wrong moment: PokerKit names the timing.
        card = rng.choice(known)
        candidates += [
            {'type': 'burnCard', 'card': card},
            {'type': 'dealBoard', 'card': card},
            {'type': 'dealHole', 'player': player, 'card': card},
        ]

    if state.actor_index is not None:
        low = state.min_completion_betting_or_raising_to_amount
        high = state.max_completion_betting_or_raising_to_amount
        actor = state.actor_index

        if low is None:
            # PokerKit says why raising is refused before judging the amount.
            everything = state.stacks[actor] + state.bets[actor]
            candidates += [
                {'type': 'betOrRaise', 'player': actor, 'to': to}
                for to in (1, everything, everything + 1)
            ]
        else:
            candidates += [
                {'type': 'betOrRaise', 'player': actor, 'to': low - 1},
                {'type': 'betOrRaise', 'player': actor, 'to': high + 1},
            ]

    if known and bridge.phase(state) == 'dealing':
        operation = next_operation(rng, state)
        operation['card'] = rng.choice(known)
        candidates.append(operation)

    operation = rng.choice(candidates)
    verdict = classify(state, operation)

    return None if verdict is None else (operation, verdict)


def random_hand(rng: random.Random, name: str, stage: str) -> dict:
    recorder = Recorder(random_config(rng))
    state = recorder.state

    while not recorder.done:
        if rng.random() < 0.1:
            invalid = invalid_operation(rng, state)

            if invalid is not None:
                recorder.reject(*invalid)
        elif state._pots is not None and rng.random() < 0.2:
            recorder.play(post_hand_show(rng, state))

        if not recorder.done:
            recorder.play(next_operation(rng, state))

    while not recorder.stopped and rng.random() < 0.35:
        invalid = invalid_operation(rng, state)

        if invalid is not None and rng.random() < 0.3:
            recorder.reject(*invalid)
        else:
            recorder.play(post_hand_show(rng, state))

    return recorder.hand(name, stage)


# The classifier


def classify(state: State, operation: dict) -> dict | None:
    """How the engine must refuse ``operation`` here; None if it accepts it.

    The verdict holds a rejected step's fields. The order is the engine's:
    a deviation checked before PokerKit's own refusal would record it where
    the engine must give PokerKit's error, and a cascade only runs once the
    operation itself has passed.
    """
    return (
        pokerkit_refusal(state, operation)
        or port_refusal(state, operation)
        or cascade_refusal(state, operation)
    )


def pokerkit_refusal(state: State, operation: dict) -> dict | None:
    if operation['type'] in ('showHoleCards', 'muckHoleCards'):
        return show_refusal(state, operation)

    try:
        bridge.apply(copy.deepcopy(state), operation)
    except ValueError as error:
        return {'rejected': 'pokerkit', 'message': str(error)}
    except Exception:
        # The cascade failed, not the operation; the later checks judge that.
        pass

    return None


def show_refusal(state: State, operation: dict) -> dict | None:
    """PokerKit's verdict on a show or muck, without playing the cascade.

    That keeps the bare ``AssertionError`` of state.py:5538, which is B9,
    apart from the one ``push_chips`` raises for an abandoned pot.
    """
    player = operation['player']

    try:
        with warnings.catch_warnings():
            warnings.simplefilter('ignore')
            state.verify_hole_cards_showing_or_mucking(
                bridge.show_argument(operation),
                player,
            )
    except ValueError as error:
        return {'rejected': 'pokerkit', 'message': str(error)}
    except AssertionError:
        name = (
            'cannotShowUnknownCard' if operation.get('cards') is None
            else 'mustShowAllCards'
        )

        return {'rejected': 'B9', 'error': {name: {'player': player}}}

    return None


def port_refusal(state: State, operation: dict) -> dict | None:
    """The deviations after PokerKit's refusals (B1, B2, B5, B6, B9, B14)."""
    kind = operation['type']
    player = operation.get('player')

    if kind == 'showHoleCards':
        if state.street is None and state._pots is None:
            # PokerKit records an empty show here, which reads as a muck.
            return {
                'rejected': 'B9',
                'error': {'noShowdownExpected': {'player': player}},
            }
        elif operation.get('cards') is not None:
            refusal = listed_show_refusal(state, player, operation['cards'])

            if refusal is not None:
                return refusal

        pot = bridge.dead_hand_pot(state, operation)

        if pot is not None:
            return {
                'rejected': 'B2',
                'error': {'wouldAbandonPot': {'player': player, 'pot': pot}},
            }
    elif kind in ('burnCard', 'dealHole', 'dealBoard'):
        if operation['card'] in dealt_known_cards(state):
            return {'rejected': 'B1'}
    elif kind in ('fold', 'muckHoleCards'):
        pot = bridge.abandoned_pot(state, player)

        if pot is None and kind == 'muckHoleCards':
            pot = bridge.dead_hand_pot(state, operation)

        if pot is not None:
            return {
                'rejected': 'B2',
                'error': {'wouldAbandonPot': {'player': player, 'pot': pot}},
            }
    elif kind == 'selectRunoutCount':
        count = operation.get('count')

        if count is not None and count > MAXIMUM_RUNOUT_COUNT:
            return {
                'rejected': 'B5',
                'error': {'invalidRunoutCount': {'_0': count}},
            }

    return None


def listed_show_refusal(
        state: State,
        player: int,
        cards: list[str],
) -> dict | None:
    """A listed show checked against the dealt record, as the engine does."""
    listed = [card for card in cards if card != '??']

    if len(listed) < len(cards):
        return {
            'rejected': 'B14',
            'error': {'cannotShowUnknownCard': {'player': player}},
        }
    elif len(set(listed)) < len(listed):
        return {'rejected': 'B1'}

    dealt = [card for card, _ in bridge.dealt_hole_cards(state)[player]]
    open_slots = dealt.count('??')
    known = dealt_known_cards(state)

    for card in listed:
        if card in dealt:
            continue
        elif not open_slots:
            return {
                'rejected': 'B6',
                'error': {
                    'shownCardNotDealt': {'player': player, 'card': card},
                },
            }
        elif card in known:
            return {'rejected': 'B1'}

        open_slots -= 1

    return None


def cascade_refusal(state: State, operation: dict) -> dict | None:
    """B4: the operation is fine, but what it sets off cannot finish."""
    probe = copy.deepcopy(state)

    try:
        bridge.apply(probe, operation)
    except KeyError:
        # The operation's own card can be the unknown one, so read the probe.
        for runout in probe.board_indices:
            board = list(map(bool, probe.get_board_cards(runout)))

            if not all(board):
                error = {'runout': runout, 'position': board.index(False)}

                return {
                    'rejected': 'B4',
                    'error': {'unknownBoardCard': error},
                }

        raise

    return None


# Coverage


def config_features(config: dict) -> set[str]:
    player_count = len(config['startingStacks'])
    antes = config['antes']
    blinds = config['blindsOrStraddles']
    automations = set(config['automations'])
    found = {
        'heads-up' if player_count == 2
        else 'short-handed' if player_count <= 6
        else 'full-ring',
        'cash' if config['mode'] == 'cashGame' else 'tournament',
    }

    if config.get('variant') == 'potLimitOmahaHoldem':
        found.add('omaha')

    if len(set(antes)) == 1 and antes[0]:
        if config['anteTrimming']:
            found.add('trimmed-antes')
        else:
            found.add('uniform-antes')
    elif antes[1:2] != [0] and not any(antes[2:]) and not antes[0]:
        found.add('bb-ante')
    elif any(antes):
        found.add('button-ante')

    if not any(blinds):
        found.add('no-blinds')
    elif any(value < 0 for value in blinds):
        found.add('live-post')

        if sum(value < -blinds[1] for value in blinds) > 1:
            found.add('two-live-posts')
    elif (
            player_count > 3
            and blinds[-1] > blinds[1] > 0
            and not any(blinds[2:-1])
    ):
        found.add('button-straddle')
    elif player_count > 3 and blinds[3] > blinds[2] > blinds[1] > 0:
        found.add('double-straddle')
    elif (
            player_count > 2
            and blinds[2] > blinds[1] > 0
            and not any(blinds[3:])
    ):
        found.add('utg-straddle')
    elif blinds[0] == blinds[1] > 0 and not any(blinds[2:]):
        found.add('equal-blinds')
    elif any(blinds[2:]) or not 0 < blinds[0] < blinds[1]:
        found.add('irregular-blinds')

    if any(antes) and 'antePosting' not in automations:
        found.add('manual-antes')
    if any(blinds) and 'blindOrStraddlePosting' not in automations:
        found.add('manual-blinds')
    if 'betCollection' not in automations:
        found.add('manual-collection')

    return found


def short_forced_bets(state: State) -> set[str]:
    """Whether a stack cuts any ante or blind short, as PokerKit posts them."""
    for i in state.player_indices:
        position = 1 - i if state.player_count == 2 else i
        ante = state.antes[position]
        blind = abs(state.blinds_or_straddles[position])

        if (
                state.get_effective_ante(i) < ante
                or state.get_effective_blind_or_straddle(i) < blind
        ):
            return {'short-stack-forced-bet'}

    return set()


def select(
        hands: list[dict],
        count: int,
        minimum: int,
) -> tuple[list[dict], Counter]:
    """Up to ``count`` hands covering each feature ``minimum`` times first."""
    chosen = []
    coverage = Counter()
    rest = list(hands)

    for feature in SAMPLE_FEATURES:
        for hand in list(rest):
            if coverage[feature] >= minimum or len(chosen) >= count:
                break
            elif feature in hand['features']:
                chosen.append(hand)
                rest.remove(hand)
                coverage.update(hand['features'])

    for hand in rest[:count - len(chosen)]:
        chosen.append(hand)
        coverage.update(hand['features'])

    return chosen, coverage


def random_hands(
        seed: int,
        pool: int,
        count: int,
        stage: str,
) -> tuple[list[dict], Counter]:
    rng = random.Random(seed)
    hands = [
        random_hand(rng, f'random-{seed}-{index:05}', stage)
        for index in range(pool)
    ]

    return select(hands, count, 3)
