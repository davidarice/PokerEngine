"""Probes that settle the research reports' open questions on PokerKit 0.7.7.

Each probe transcribes one "Open questions" snippet from the betting, cards or
pots report (same config, same operations), or checks one extra fact the plan
relies on. A probe writes what it reads into ``seen`` as it goes, so values
read before an exception are kept. ``run_probes`` runs every probe under
``random.seed(0)`` (automated dealing draws from PokerKit's shuffled deck),
with every warning recorded, and under an alarm of 10 seconds unless the probe
asks for longer (after a runout count of 0, PokerKit asks for more runouts
forever).

Short value names: ``to_call`` is ``checking_or_calling_amount``,
``min_raise_to`` is ``min_completion_betting_or_raising_to_amount`` and
``can_raise`` is ``can_complete_bet_or_raise_to()``.
"""

import json
import random
import signal
import traceback
import warnings
from collections.abc import Callable, Iterable
from dataclasses import dataclass, fields
from hashlib import md5
from itertools import combinations
from pathlib import Path

from pokerkit import (
    Automation as A,
    Card,
    ChipsPushing,
    Deck,
    HandHistory,
    Label,
    Mode,
    NoLimitTexasHoldem as NL,
    StandardHighHand,
    StandardLookup,
    State,
    rake,
)

TIMEOUT_SECONDS = 10
FREE_FOLD_WARNING = 'There is no reason for this player to fold.'
TEST_LOOKUPS_MD5 = '488cdd27873395ba75205cd02fb9d6b2'
"""What StandardLookupTestCase.test_get_entry in test_lookups.py asserts."""

ALL = tuple(A)
"""The betting report's ``tuple(A)``: dealing is automated too."""
POSTING = (A.ANTE_POSTING, A.BET_COLLECTION, A.BLIND_OR_STRADDLE_POSTING)
"""The betting report's ``B`` and the cards report's ``A``."""
BOOKKEEPING = POSTING + (A.HAND_KILLING, A.CHIPS_PUSHING, A.CHIPS_PULLING)
"""The plan's default: no dealing, runout-selection or show/muck automation."""
NO_DEALING_OR_RUNOUTS = POSTING + (
    A.CARD_BURNING,
    A.HOLE_CARDS_SHOWING_OR_MUCKING,
    A.HAND_KILLING,
    A.CHIPS_PUSHING,
    A.CHIPS_PULLING,
)
"""The automations of pots OQ2 and OQ13."""

LOOKUP_ORDER_RULE = (
    'Number the 52 cards of Deck.STANDARD by deck position 4 * rank + suit,'
    ' with rank 0 (deuce) to 12 (ace) and suit 0 to 3 for c, d, h, s, so the'
    ' deck runs 2c 2d 2h 2s 3c ... Ah As. Take all C(52,5) = 2,598,960'
    ' five-card combinations in lexicographic order of positions'
    ' (itertools.combinations order: 0 1 2 3 4, then 0 1 2 3 5, ...).'
    ' Stable-sort them by StandardLookup entry index ascending, weakest first,'
    ' so hands of equal strength keep that enumeration order. Write each hand'
    ' as its five cards in ascending position, each card as its rank character'
    ' (2-9, T, J, Q, K, A) followed by its suit character (c, d, h, s), with'
    ' no separators, so a royal flush in spades is TsJsQsKsAs. Join the hands'
    ' with a single LF (0x0A) and no trailing newline, encode as UTF-8 (all'
    ' ASCII) and take the MD5 as lowercase hex.'
)


ProbeFunction = Callable[[dict], None]


@dataclass(frozen=True)
class Probe:
    source: str
    question: str
    prediction: str
    expected: dict | None
    run: ProbeFunction
    timeout_seconds: int


PROBES: list[Probe] = []


def probe(
        source: str,
        question: str,
        prediction: str,
        expected: dict | None = None,
        timeout_seconds: int = TIMEOUT_SECONDS,
) -> Callable[[ProbeFunction], ProbeFunction]:
    """Register a probe.

    ``expected`` holds the machine-checkable part of the prediction, shaped
    like the observation: ``values`` (keys the probe records), ``exception``
    (fields of the described exception) and ``warnings`` (messages). Leaving
    out ``exception`` predicts that nothing is raised.
    """
    def register(function: ProbeFunction) -> ProbeFunction:
        PROBES.append(
            Probe(
                source,
                question,
                prediction,
                expected,
                function,
                timeout_seconds,
            ),
        )
        return function

    return register


def run_probes() -> list[dict]:
    signal.signal(signal.SIGALRM, raise_timeout)

    return list(map(run_probe, PROBES))


def raise_timeout(signum: int, frame: object) -> None:
    raise TimeoutError('The probe ran past its time limit.')


def run_probe(probe: Probe) -> dict:
    seen: dict = {}
    random.seed(0)

    with warnings.catch_warnings(record=True) as caught:
        warnings.simplefilter('always')
        signal.alarm(probe.timeout_seconds)

        try:
            probe.run(seen)
        except Exception as error:  # PokerKit's failures are the observation
            exception = describe_exception(error)
        else:
            exception = None
        finally:
            signal.alarm(0)

    observed = {
        'values': seen,
        'exception': exception,
        'warnings': [str(warning.message) for warning in caught],
    }

    if probe.expected is None:
        matches = None
    else:
        matches = is_subset({'exception': None, **probe.expected}, observed)

    return {
        'id': probe.run.__name__,
        'source': probe.source,
        'question': probe.question,
        'prediction': {'text': probe.prediction, 'expected': probe.expected},
        'observed': observed,
        'matches': matches,
    }


def describe_exception(error: Exception) -> dict:
    """Describe an exception by its frames below this module (PokerKit's)."""
    frames = [
        frame
        for frame in traceback.extract_tb(error.__traceback__)
        if frame.filename != __file__
    ]

    if not frames:
        raise error  # raised by the probe's own code: a probe bug

    raising = frames[-1]

    return {
        'type': type(error).__name__,
        'message': str(error),
        'function': raising.name,
        'location': f'{Path(raising.filename).name}:{raising.lineno}',
        'statement': raising.line,
        'call_chain': [frame.name for frame in frames],
    }


def is_subset(expected: object, observed: object) -> bool:
    """Whether every key of ``expected`` is in ``observed``, equally valued.

    Leaves compare as JSON text, so ``True`` and ``1`` differ as they do in
    quirks.json.
    """
    if isinstance(expected, dict):
        return isinstance(observed, dict) and all(
            key in observed and is_subset(value, observed[key])
            for key, value in expected.items()
        )

    return (
        json.dumps(expected, sort_keys=True)
        == json.dumps(observed, sort_keys=True)
    )


def cards(values: Iterable[Card]) -> list[str]:
    return [repr(card) for card in values]


def operation(op: object) -> str:
    """The operation's repr without its commentary, which is always None."""
    arguments = ', '.join(
        f'{field.name}={getattr(op, field.name)!r}'
        for field in fields(op)
        if field.name != 'commentary'
    )

    return f'{type(op).__name__}({arguments})'


def lookup_order_bytes() -> bytes:
    """The bytes test_lookups.py hashes for StandardLookup.

    The test sorts ``combinations(Deck.STANDARD, 5)`` by ``lookup.get_entry``
    and joins each hand's card reprs. Entries compare by index alone and the
    sort is stable, so sorting by the int index and joining precomputed reprs
    gives the same bytes in about 5 seconds rather than the test form's 9,
    which keeps the probe inside its alarm.
    """
    lookup = StandardLookup()
    hands = zip(
        combinations(Deck.STANDARD, 5),
        combinations(map(repr, Deck.STANDARD), 5),
    )
    ordered = sorted(hands, key=lambda hand: lookup.get_entry(hand[0]).index)

    return '\n'.join(''.join(names) for _, names in ordered).encode()


# Betting report, section 12


@probe(
    'betting OQ1',
    'What is the minimum raise-to facing a 1/2/4 UTG straddle with min bet 2?',
    'Minimum raise after a straddle (expected: actor 3, minimum 6, not 8)',
    {'values': {'actor_index': 3, 'min_raise_to': 6}},
)
def betting_oq1(seen: dict) -> None:
    s = NL.create_state(
        ALL, True, 0, (1, 2, 4), 2, 200, 6, mode=Mode.CASH_GAME,
    )
    seen['actor_index'] = s.actor_index
    seen['min_raise_to'] = s.min_completion_betting_or_raising_to_amount


@probe(
    'betting OQ2',
    'Does a short SB all-in over two limpers reopen raising for the BB and the'
    ' limpers?',
    "Limpers reopened by the SB's short all-in (expected: `1 True 5`, then"
    ' `2 True`)',
    {
        'values': {
            'actor_index': 1,
            'can_raise': True,
            'min_raise_to': 5,
            'actor_index_after_call': 2,
            'can_raise_after_call': True,
        },
    },
)
def betting_oq2(seen: dict) -> None:
    s = NL.create_state(
        ALL, True, 0, (1, 2), 2, (3, 200, 200, 200), 4, mode=Mode.CASH_GAME,
    )
    s.check_or_call()
    s.check_or_call()
    s.complete_bet_or_raise_to(3)
    seen['actor_index'] = s.actor_index
    seen['can_raise'] = s.can_complete_bet_or_raise_to()
    seen['min_raise_to'] = s.min_completion_betting_or_raising_to_amount
    s.check_or_call()
    seen['actor_index_after_call'] = s.actor_index
    seen['can_raise_after_call'] = s.can_complete_bet_or_raise_to()


@probe(
    'betting OQ3',
    'After all-ins for 3 and then 4 and two folds, may the caller of the 3'
    ' re-raise?',
    'A short raise over a short raise counts as full (expected: `3 1 True`)',
    {'values': {'actor_index': 3, 'to_call': 1, 'can_raise': True}},
)
def betting_oq3(seen: dict) -> None:
    s = NL.create_state(
        ALL, True, 0, (1, 2), 2, (200, 200, 3, 200, 4), 5, mode=Mode.CASH_GAME,
    )
    s.complete_bet_or_raise_to(3)
    s.check_or_call()
    s.complete_bet_or_raise_to(4)
    s.fold()
    s.fold()
    seen['actor_index'] = s.actor_index
    seen['to_call'] = s.checking_or_calling_amount
    seen['can_raise'] = s.can_complete_bet_or_raise_to()

    # Not in the prediction: PokerKit's reason when raising is refused.
    try:
        s.verify_completion_betting_or_raising_to()
    except ValueError as error:
        seen['raise_refusal'] = str(error)


@probe(
    'betting OQ4',
    'Once short all-ins add up to a full raise, may a player who already acted'
    ' re-raise after one more short all-in?',
    'A full cumulative raise followed by another short all-in (expected:'
    ' `1 800 False`)',
    {'values': {'actor_index': 1, 'to_call': 800, 'can_raise': False}},
)
def betting_oq4(seen: dict) -> None:
    s = NL.create_state(
        ALL, True, 1, 0, 1, (20001, 20001, 20001, 1301, 1701, 1801), 6,
    )
    s.complete_bet_or_raise_to(500)
    s.complete_bet_or_raise_to(1000)
    s.check_or_call()

    for a in (1300, 1700, 1800):
        s.complete_bet_or_raise_to(a)

    s.check_or_call()
    seen['actor_index'] = s.actor_index
    seen['to_call'] = s.checking_or_calling_amount
    seen['can_raise'] = s.can_complete_bet_or_raise_to()


@probe(
    'betting OQ5',
    'With a 1-chip big blind, what do callers owe and what is the minimum'
    ' raise-to?',
    'Short big blind (expected: `[1, 1, 0] 2 1 3`)',
    {
        'values': {
            'bets': [1, 1, 0],
            'actor_index': 2,
            'to_call': 1,
            'min_raise_to': 3,
        },
    },
)
def betting_oq5(seen: dict) -> None:
    s = NL.create_state(
        ALL, True, 0, (1, 2), 2, (200, 1, 200), 3, mode=Mode.CASH_GAME,
    )
    seen['bets'] = list(s.bets)
    seen['actor_index'] = s.actor_index
    seen['to_call'] = s.checking_or_calling_amount
    seen['min_raise_to'] = s.min_completion_betting_or_raising_to_amount


@probe(
    'betting OQ6',
    'When a 3-chip big blind owes a 2-chip BB ante, is the ante or the blind'
    ' taken first?',
    'BB ante versus blind when the BB is short (expected: `AntePosting(1, 2)`,'
    ' `BetCollection((0, 2, 0))`, `BlindOrStraddlePosting(0, 1)`,'
    ' `BlindOrStraddlePosting(1, 1)`)',
    {
        'values': {
            'operations': [
                'AntePosting(player_index=1, amount=2)',
                'BetCollection(bets=(0, 2, 0))',
                'BlindOrStraddlePosting(player_index=0, amount=1)',
                'BlindOrStraddlePosting(player_index=1, amount=1)',
            ],
        },
    },
)
def betting_oq6(seen: dict) -> None:
    s = NL.create_state(POSTING, False, {1: 2}, (1, 2), 2, (200, 3, 200), 3)
    seen['operations'] = list(map(operation, s.operations))


@probe(
    'betting OQ7',
    'Heads-up, who pays a button ante, and who acts first preflop with equal'
    ' blinds?',
    'Heads-up button ante and equal blinds (expected: `(0, 5) 5 0`, then `0`)',
    {
        'values': {
            'antes': [0, 5],
            'effective_ante_0': 5,
            'effective_ante_1': 0,
            'actor_index_equal_blinds': 0,
        },
    },
)
def betting_oq7(seen: dict) -> None:
    s = NL.create_state((), False, {-1: 5}, (1, 2), 2, 200, 2)
    seen['antes'] = list(s.antes)
    seen['effective_ante_0'] = s.get_effective_ante(0)
    seen['effective_ante_1'] = s.get_effective_ante(1)
    seen['actor_index_equal_blinds'] = NL.create_state(
        ALL, True, 0, (2, 2), 2, 200, 2,
    ).actor_index


def betting_oq8_all_in() -> State:
    """Betting OQ8's hand up to the BB's call of the SB's all-in."""
    s = NL.create_state(
        POSTING, True, 0, (1, 2), 2, (50, 200, 200), 3, mode=Mode.CASH_GAME,
    )

    for c in ('AsAd', 'KsKd', 'QsQd'):
        s.deal_hole(c)

    s.fold()
    s.complete_bet_or_raise_to(50)
    s.check_or_call()

    return s


@probe(
    'betting OQ8',
    'Can the board be dealt before the all-in showdown ends, and what happens'
    ' when the all-in player mucks and the caller has chips behind?',
    'Mucking at the all-in showdown, then dealing (expected: AssertionError at'
    ' `get_effective_stack` 2502). The same setup with `can_burn_card()`'
    ' checked before any show/muck should give False, which confirms the'
    ' "showdown before dealing" gate.',
    {
        'values': {'can_burn_card_before_show_or_muck': False},
        'exception': {
            'type': 'AssertionError',
            'function': 'get_effective_stack',
            'statement': 'assert len(effective_stacks) > 1',
        },
    },
)
def betting_oq8(seen: dict) -> None:
    s = betting_oq8_all_in()
    s.select_runout_count()
    s.select_runout_count()
    seen['can_burn_card_before_show_or_muck'] = s.can_burn_card()
    s.show_or_muck_hole_cards(False)
    s.show_or_muck_hole_cards(True)
    s.burn_card('??')
    s.deal_board('2c3c4c')


@probe(
    'betting OQ9',
    'Does select_runout_count(runout_count, player_index) credit the named'
    ' player and validate the count?',
    '`select_runout_count` argument bug. Run this right after the all-in in'
    ' OQ8, before any runout selection is made. Expected: the first call'
    ' records `RunoutCountSelection(player_index=0, runout_count=2)`, not'
    " player 1; the second call raises `ValueError('The runout count 0 is not"
    " positive.')`.",
    {
        'values': {
            'last_operation':
                'RunoutCountSelection(player_index=0, runout_count=2)',
        },
        'exception': {
            'type': 'ValueError',
            'message': 'The runout count 0 is not positive.',
        },
    },
)
def betting_oq9(seen: dict) -> None:
    s = betting_oq8_all_in()
    s.select_runout_count(2, 1)
    seen['last_operation'] = operation(s.operations[-1])
    s.select_runout_count(None, 0)


@probe(
    'betting OQ10',
    'After a heads-up preflop all-in without show automation, is dealing'
    ' blocked until runout selection and shows are done?',
    'A preflop all-in without show automation blocks dealing (expected:'
    ' `False [True, True] [1, 0]`)',
    {
        'values': {
            'can_burn_card': False,
            'runout_count_selector_statuses': [True, True],
            'showdown_indices': [1, 0],
        },
    },
)
def betting_oq10(seen: dict) -> None:
    s = NL.create_state(
        POSTING, True, 0, (1, 2), 2, 100, 2, mode=Mode.CASH_GAME,
    )
    s.deal_hole('AsAd')
    s.deal_hole('KsKd')
    s.complete_bet_or_raise_to(100)
    s.check_or_call()
    seen['can_burn_card'] = s.can_burn_card()
    seen['runout_count_selector_statuses'] = list(
        s.runout_count_selector_statuses,
    )
    seen['showdown_indices'] = list(s.showdown_indices)


@probe(
    'betting OQ11',
    'If both side-pot players fold for free after a short all-in, what happens'
    ' to the side pot nobody is eligible for?',
    'Both side-pot players fold for free, leaving one all-in player. Expected:'
    ' AssertionError `len(pot.player_indices) == 1` in `push_chips` (6167) for'
    ' the 80-chip side pot that no one is eligible for. With `-O`, an'
    ' IndexError instead.',
    {
        'exception': {
            'type': 'AssertionError',
            'function': 'push_chips',
            'statement': 'assert len(pot.player_indices) == 1',
        },
    },
)
def betting_oq11(seen: dict) -> None:
    s = NL.create_state(
        ALL, True, 0, (1, 2), 2, (10, 200, 200), 3, mode=Mode.CASH_GAME,
    )
    s.complete_bet_or_raise_to(50)
    s.check_or_call()
    s.check_or_call()
    s.fold()
    s.fold()


@probe(
    'betting OQ12',
    'In cash-game mode, may a player fold when checking is free, and does it'
    ' warn?',
    '`can_fold` in cash-game mode with a free check (expected: `True [\'There'
    " is no reason for this player to fold.']`)",
    {
        'values': {
            'can_fold': True,
            'warnings_during_can_fold': [FREE_FOLD_WARNING],
        },
    },
)
def betting_oq12(seen: dict) -> None:
    s = NL.create_state(ALL, True, 0, (1, 2), 2, 200, 3, mode=Mode.CASH_GAME)
    s.check_or_call()
    s.check_or_call()

    with warnings.catch_warnings(record=True) as w:
        warnings.simplefilter('always')
        seen['can_fold'] = s.can_fold()
        seen['warnings_during_can_fold'] = [str(x.message) for x in w]


# Cards report, section 13


def cards_oq1_all_in() -> State:
    """Cards OQ1's three-way preflop all-in, before any runout selection."""
    s = NL.create_state(
        POSTING, True, 0, (1, 2), 2, 100, 3, mode=Mode.CASH_GAME,
    )

    for c in ('AsAh', 'KsKh', 'QsQh'):
        s.deal_hole(c)

    s.complete_bet_or_raise_to(100)
    s.check_or_call()
    s.check_or_call()

    return s


@probe(
    'cards OQ1',
    'Is can_select_runout_count(2, 0) refused, and whom does'
    ' select_runout_count(2, 2) credit?',
    'The runout-selection argument bug: `[0,1,2] False`, then'
    ' `player_index=0 ?`',
    {
        'values': {
            'runout_count_selector_indices': [0, 1, 2],
            'can_select_runout_count_2_0': False,
            'selection_player_index': 0,
        },
    },
)
def cards_oq1(seen: dict) -> None:
    s = cards_oq1_all_in()
    seen['runout_count_selector_indices'] = list(
        s.runout_count_selector_indices,
    )
    seen['can_select_runout_count_2_0'] = s.can_select_runout_count(2, 0)
    selection = s.select_runout_count(2, 2)
    seen['selection'] = operation(selection)
    seen['selection_player_index'] = selection.player_index


@probe(
    'cards OQ2',
    'What state does a runout count of 0 leave behind?',
    '`runout_count = 0` loops forever. On a fresh copy of the state above:'
    ' `0 1 -1 0 ?` (runout_count, street_return_index, street_return_count,'
    ' board_count)',
    {
        'values': {
            'runout_count': 0,
            'street_return_index': 1,
            'street_return_count': -1,
            'board_count': 0,
        },
    },
)
def cards_oq2(seen: dict) -> None:
    s = cards_oq1_all_in()
    s.select_runout_count(0)
    s.select_runout_count()
    s.select_runout_count()
    seen['runout_count'] = s.runout_count
    seen['street_return_index'] = s.street_return_index
    seen['street_return_count'] = s.street_return_count
    seen['board_count'] = s.board_count
    # Not in the prediction: the street_return fields are only set once
    # every pending show or muck is done.
    seen['showdown_indices'] = list(s.showdown_indices)


@probe(
    'cards OQ3',
    'Where does the KeyError from an unknown board card surface?',
    'Where the `KeyError` from an unknown board card surfaces: `get_hand`'
    ' gives `None ?` after the `??` flop, and the final shows raise'
    ' `KeyError ?`',
    {'values': {'get_hand': None}, 'exception': {'type': 'KeyError'}},
)
def cards_oq3(seen: dict) -> None:
    s = NL.create_state(POSTING, True, 0, (1, 2), 2, 200, 2)
    s.deal_hole('AsAh')
    s.deal_hole('KsKh')
    s.check_or_call()
    s.check_or_call()
    s.burn_card('??')
    s.deal_board('2c3d??')
    hand = s.get_hand(0, 0, 0)
    seen['get_hand'] = None if hand is None else str(hand)

    for b in ('4h', '5s'):
        s.check_or_call()
        s.check_or_call()
        s.burn_card('??')
        s.deal_board(b)

    s.check_or_call()
    s.check_or_call()
    seen['first_show'] = operation(s.show_or_muck_hole_cards(True))
    s.show_or_muck_hole_cards(True)


@probe(
    'cards OQ4',
    "Is a duplicate card inside one deal_hole call ('AsAs') detected?",
    'No duplicate check inside one call: `True [As, As] False ?`',
    {
        'values': {
            'can_deal_hole_AsAs': True,
            'hole_cards_0': ['As', 'As'],
            'can_deal_hole_As': False,
        },
    },
)
def cards_oq4(seen: dict) -> None:
    warnings.simplefilter('error')  # run_probe's catch_warnings restores it
    s = NL.create_state(POSTING, True, 0, (1, 2), 2, 200, 2)
    seen['can_deal_hole_AsAs'] = s.can_deal_hole('AsAs')
    s.deal_hole('AsAs')
    seen['hole_cards_0'] = cards(s.hole_cards[0])
    seen['can_deal_hole_As'] = s.can_deal_hole('As')


@probe(
    'cards OQ5',
    'If the all-in player concedes and the winner has chips behind, does'
    ' dealing the flop crash?',
    'A concession at the all-in, with the winner holding chips behind:'
    ' `AssertionError in get_effective_stack ?`',
    {
        'exception': {
            'type': 'AssertionError',
            'function': 'get_effective_stack',
        },
    },
)
def cards_oq5(seen: dict) -> None:
    s = NL.create_state(
        POSTING, True, 0, (1, 2), 2, (300, 100), 2, mode=Mode.CASH_GAME,
    )
    s.deal_hole('AsAh')
    s.deal_hole('KsKh')
    s.complete_bet_or_raise_to(100)
    s.check_or_call()
    s.show_or_muck_hole_cards(False)
    s.show_or_muck_hole_cards(True)
    s.select_runout_count()
    s.select_runout_count()
    s.burn_card('??')
    s.deal_board('2c3d4h')


@probe(
    'cards OQ6',
    'In a cash game, is a player who kept cards face down asked to show or'
    ' muck again after a runout street?',
    'A face-down player is asked again after a runout street: `0 False ?`'
    ' (showdown_index, card_burning_status)',
    {'values': {'showdown_index': 0, 'card_burning_status': False}},
)
def cards_oq6(seen: dict) -> None:
    s = NL.create_state(
        POSTING, True, 0, (1, 2), 2, 200, 2, mode=Mode.CASH_GAME,
    )
    s.deal_hole('AsAh')
    s.deal_hole('KsKh')
    s.check_or_call()
    s.check_or_call()
    s.burn_card('??')
    s.deal_board('2c3d4h')
    s.complete_bet_or_raise_to(198)
    s.check_or_call()
    s.select_runout_count()
    s.select_runout_count()
    s.show_or_muck_hole_cards(())
    s.show_or_muck_hole_cards(True)
    s.burn_card('??')
    s.deal_board('9c')
    seen['showdown_index'] = s.showdown_index
    seen['card_burning_status'] = s.card_burning_status


@probe(
    'cards OQ7',
    'Does a partial show on the river turn the unshown card into ?? and return'
    ' it to the deck?',
    'A partial show on the river returns the unshown card to the deck:'
    ' `(As, ??) [As, ??] True ?`',
    {
        'values': {
            'shown_hole_cards': ['As', '??'],
            'hole_cards_0': ['As', '??'],
            'Ks_in_deck_cards': True,
        },
    },
)
def cards_oq7(seen: dict) -> None:
    s = NL.create_state(
        POSTING, True, 0, (1, 2), 2, 200, 2, mode=Mode.CASH_GAME,
    )
    s.deal_hole('AsKs')
    s.deal_hole('QhQd')
    s.check_or_call()
    s.check_or_call()

    for b in ('2c3d4h', '9c', 'Td'):
        s.burn_card('??')
        s.deal_board(b)
        s.check_or_call()
        s.check_or_call()

    shown = s.show_or_muck_hole_cards('As')
    seen['shown_hole_cards'] = cards(shown.hole_cards)
    seen['hole_cards_0'] = cards(s.hole_cards[0])
    seen['Ks_in_deck_cards'] = next(Card.parse('Ks')) in s.deck_cards


@probe(
    'cards OQ8',
    'Does dealing a ?? board card erase a burned ?? from burn_cards?',
    "A burned `'??'` is erased by a `'??'` board card: `[] ?`",
    {'values': {'burn_cards': []}},
)
def cards_oq8(seen: dict) -> None:
    s = NL.create_state(POSTING, True, 0, (1, 2), 2, 200, 2)
    s.deal_hole('????')
    s.deal_hole('????')
    s.check_or_call()
    s.check_or_call()
    s.burn_card('??')
    s.deal_board('??2c3d')
    seen['burn_cards'] = cards(s.burn_cards)


@probe(
    'cards OQ9',
    'Does rake() round a 10% rake half to even?',
    'Rake rounding (round half to even on a double): `(0,5) (2,13) (2,23) ?`',
    {'values': {'rake_5': [0, 5], 'rake_15': [2, 13], 'rake_25': [2, 23]}},
)
def cards_oq9(seen: dict) -> None:
    seen['rake_5'] = list(rake(5, percentage=0.1))
    seen['rake_15'] = list(rake(15, percentage=0.1))
    seen['rake_25'] = list(rake(25, percentage=0.1))


@probe(
    'cards OQ10',
    'How many distinct entry indices does StandardLookup hold?',
    'Size of the evaluator table: `7462 ?`',
    {'values': {'distinct_indices': 7462}},
)
def cards_oq10(seen: dict) -> None:
    seen['distinct_indices'] = len(
        {e.index for e in StandardLookup()._Lookup__entries.values()},
    )


@probe(
    'cards OQ11',
    'At a tournament all-in, may a player muck, and may they show only one'
    ' card?',
    'A tournament all-in allows mucking but refuses partial shows:'
    ' `True False ?`',
    {'values': {'can_muck': True, 'can_show_As': False}},
)
def cards_oq11(seen: dict) -> None:
    s = NL.create_state(POSTING, True, 0, (1, 2), 2, 200, 2)
    s.deal_hole('AsAh')
    s.deal_hole('KsKh')
    s.complete_bet_or_raise_to(200)
    s.check_or_call()
    seen['can_muck'] = s.can_show_or_muck_hole_cards(False)
    seen['can_show_As'] = s.can_show_or_muck_hole_cards('As')


@probe(
    'cards OQ12',
    'Does deal_hole accept a negative player index?',
    'A negative dealee index is accepted: `2 ?`',
    {'values': {'player_index': 2}},
)
def cards_oq12(seen: dict) -> None:
    s = NL.create_state(POSTING, True, 0, (1, 2), 2, 200, 3)
    seen['player_index'] = s.deal_hole('As', -1).player_index
    # Not in the prediction: whose hand the card landed in.
    seen['hole_cards'] = list(map(cards, s.hole_cards))


@probe(
    'cards OQ13',
    'Does a post-hand partial show in tournament mode raise a bare'
    ' AssertionError?',
    'A post-hand partial show in tournament mode raises a bare'
    ' `AssertionError`: `AssertionError propagates ?`',
    {'exception': {'type': 'AssertionError'}},
)
def cards_oq13(seen: dict) -> None:
    s = NL.create_state(POSTING, True, 0, (1, 2), 2, 200, 3)

    for c in ('AsAh', 'KsKh', 'QsQh'):
        s.deal_hole(c)

    s.fold()
    s.fold()
    seen['can_show_Ks'] = s.can_show_or_muck_hole_cards('Ks', 1)


# Pots report, section 12


@probe(
    'pots OQ1',
    'With a three-way tie after a 1-chip rake, where do the odd chips go?',
    'Odd chips with a three-way tie. Predicted amounts `(5, 3, 3)`: remainder'
    ' 2 all to index 0',
    {'values': {'amounts': [5, 3, 3]}},
)
def pots_oq1(seen: dict) -> None:
    s = NL.create_state(
        POSTING + (
            A.CARD_BURNING,
            A.HOLE_CARDS_SHOWING_OR_MUCKING,
            A.HAND_KILLING,
            A.CHIPS_PULLING,
        ),
        True, 0, (1, 2), 2, 100, 3,
        rake=lambda a, st: (1, a - 1),
    )

    for h in ('2c3c', '2d3d', '2h3h'):
        s.deal_hole(h)

    s.complete_bet_or_raise_to(4)
    s.check_or_call()
    s.check_or_call()

    for b in ('AsKsQs', 'Js', 'Ts'):
        s.deal_board(b)

        while s.actor_index is not None:
            s.check_or_call()

    push = s.push_chips()
    seen['push'] = operation(push)
    seen['amounts'] = list(push.amounts)


def pots_oq2_flop_all_in() -> tuple[NL, State]:
    """Pots OQ2's game and its state just after the call of the flop all-in."""
    g = NL(NO_DEALING_OR_RUNOUTS, True, 0, (1, 2), 2, mode=Mode.CASH_GAME)
    s = g(100, 2)
    s.deal_hole('AcAd')
    s.deal_hole('KcKd')
    s.check_or_call()
    s.check_or_call()
    s.deal_board('2c3d4h')
    s.complete_bet_or_raise_to(98)
    s.check_or_call()

    return g, s


@probe(
    'pots OQ2',
    'Can a run-it-twice hand round-trip through PHH?',
    'Run-it-twice cannot round-trip through PHH. Predicted: four `d db` lines'
    ' after the two `sm` lines, then a `ValueError` on replay (expect'
    " ValueError('Unable to repair the hand history'))",
    {
        'values': {
            'last_six_action_kinds': ['sm', 'sm', 'db', 'db', 'db', 'db'],
        },
        'exception': {
            'type': 'ValueError',
            'message': 'Unable to repair the hand history',
        },
    },
)
def pots_oq2(seen: dict) -> None:
    g, s = pots_oq2_flop_all_in()
    s.select_runout_count(2)
    s.select_runout_count(2)

    for b in ('5s', '9h', '6s', 'Th'):
        s.deal_board(b)

    hh = HandHistory.from_game_state(g, s)
    seen['actions'] = list(hh.actions)
    seen['last_six_action_kinds'] = [
        action.split()[1] for action in hh.actions[-6:]
    ]
    list(HandHistory.loads(hh.dumps()))


@probe(
    'pots OQ3',
    'Is can_select_runout_count(2, 0) refused although player 0 may select,'
    ' and whom does select_runout_count(3, 1) credit?',
    '`player_index` is ignored and 0 is mis-validated. Use the state from'
    ' question 2, stopped just after the flop call: expect False although'
    ' player 0 may select; expect 0, not 1',
    {
        'values': {
            'can_select_runout_count_2_0': False,
            'selection_player_index': 0,
        },
    },
)
def pots_oq3(seen: dict) -> None:
    _, s = pots_oq2_flop_all_in()
    seen['can_select_runout_count_2_0'] = s.can_select_runout_count(2, 0)
    seen['selection_player_index'] = s.select_runout_count(3, 1).player_index


@probe(
    'pots OQ4',
    'Is a runout count of 0 accepted, and what does it leave behind?',
    'A count of 0 is accepted. Use a fresh state from question 2, stopped at'
    ' the flop all-in: expect `0 -1 0` (runout_count, street_return_count,'
    ' board_count)',
    {
        'values': {
            'runout_count': 0,
            'street_return_count': -1,
            'board_count': 0,
        },
    },
)
def pots_oq4(seen: dict) -> None:
    _, s = pots_oq2_flop_all_in()
    s.select_runout_count(0)
    s.select_runout_count(None)
    seen['runout_count'] = s.runout_count
    seen['street_return_count'] = s.street_return_count
    seen['board_count'] = s.board_count


@probe(
    'pots OQ5',
    'In tournament mode, may the all-in player muck at the all-in showdown?',
    'Tournament all-in muck is accepted. Predicted: tournament mode, `True`,'
    ' `1`, `True` (expect TOURNAMENT True 1 True)',
    {
        'values': {
            'mode': 'TOURNAMENT',
            'all_in_status': True,
            'showdown_index': 1,
            'can_muck': True,
        },
    },
)
def pots_oq5(seen: dict) -> None:
    s = NL.create_state(
        POSTING + (A.CARD_BURNING,), True, 0, (1, 2), 2, 100, 2,
    )
    s.deal_hole('AcAd')
    s.deal_hole('KcKd')
    s.complete_bet_or_raise_to(100)
    s.check_or_call()
    seen['mode'] = s.mode.name
    seen['all_in_status'] = s.all_in_status
    seen['showdown_index'] = s.showdown_index
    seen['can_muck'] = s.can_show_or_muck_hole_cards(False)


@probe(
    'pots OQ6',
    'Does a tournament partial show after a fold-out raise AssertionError?',
    'Tournament partial show after a fold-out raises `AssertionError`: expect'
    " AssertionError (cash game: False, 'Non-standard showdown must show all"
    " cards.')",
    {'exception': {'type': 'AssertionError'}},
)
def pots_oq6(seen: dict) -> None:
    s = NL.create_state(
        POSTING + (A.CHIPS_PUSHING, A.CHIPS_PULLING),
        True, 0, (1, 2), 2, 100, 2,
    )
    s.deal_hole('AcAd')
    s.deal_hole('KcKd')
    s.fold()
    seen['can_show_Ac??'] = s.can_show_or_muck_hole_cards('Ac??', 0)


def pots_oq7_preflop(mode: Mode) -> State:
    """Pots OQ7's hand through the preflop calls of the 50-chip raise."""
    s = NL.create_state(
        POSTING + (
            A.CARD_BURNING,
            A.HAND_KILLING,
            A.CHIPS_PUSHING,
            A.CHIPS_PULLING,
        ),
        True, 0, (1, 2), 2, (10, 100, 100), 3,
        mode=mode,
    )

    for h in ('AcAd', 'KcKd', 'QcQd'):
        s.deal_hole(h)

    s.complete_bet_or_raise_to(50)
    s.check_or_call()
    s.check_or_call()

    return s


@probe(
    'pots OQ7',
    'If every side-pot contender mucks at a tournament showdown, what happens'
    ' to the side pot?',
    'All side-pot contenders muck: crash at L6162 (expect AssertionError)',
    {
        'exception': {
            'type': 'AssertionError',
            'function': 'push_chips',
            'statement': 'assert len(pot.player_indices) == 1',
        },
    },
)
def pots_oq7(seen: dict) -> None:
    s = pots_oq7_preflop(Mode.TOURNAMENT)

    for b in ('2c3d4h', '7s', '9h'):
        s.deal_board(b)

        while s.actor_index is not None:
            s.check_or_call()

    s.show_or_muck_hole_cards(True, 0)
    s.show_or_muck_hole_cards(False, 1)
    s.show_or_muck_hole_cards(False, 2)


@probe(
    'pots OQ8',
    'In a cash game, do two free folds that strand a side pot warn and then'
    ' crash?',
    'Cash game, two non-standard folds strand a side pot. Same setup as'
    ' question 7 with `mode=Mode.CASH_GAME`, through the pre-flop calls.'
    ' Predicted: two `UserWarning`s, then `AssertionError` at L6162.',
    {
        'warnings': [FREE_FOLD_WARNING, FREE_FOLD_WARNING],
        'exception': {
            'type': 'AssertionError',
            'function': 'push_chips',
            'statement': 'assert len(pot.player_indices) == 1',
        },
    },
)
def pots_oq8(seen: dict) -> None:
    s = pots_oq7_preflop(Mode.CASH_GAME)
    s.deal_board('2c3d4h')
    s.fold()
    s.fold()


@probe(
    'pots OQ9',
    "Does from_game_state carry the game's ante_trimming_status into the hand"
    ' history?',
    '`from_game_state` drops `ante_trimming_status`. Predicted `False`.',
    {'values': {'ante_trimming_status': False}},
)
def pots_oq9(seen: dict) -> None:
    g = NL(POSTING, True, 1, (1, 2), 2)
    seen['ante_trimming_status'] = HandHistory.from_game_state(
        g, g(100, 3),
    ).ante_trimming_status


@probe(
    'pots OQ10',
    'After the first shower mucks at a heads-up cash-game preflop all-in, is'
    ' the burn next and is the hand still running?',
    'A muck in a pre-river all-in still requires the next street. Using the'
    ' setup from question 5 in cash-game mode, run'
    ' `s.show_or_muck_hole_cards(False)` for the first player to show. Then'
    ' expect `s.can_burn_card()` to be `True` and `s.status` to stay `True`'
    ' until the flop is dealt.',
    {'values': {'can_burn_card': True, 'status': True}},
)
def pots_oq10(seen: dict) -> None:
    s = NL.create_state(
        POSTING + (A.CARD_BURNING,), True, 0, (1, 2), 2, 100, 2,
        mode=Mode.CASH_GAME,
    )
    s.deal_hole('AcAd')
    s.deal_hole('KcKd')
    s.complete_bet_or_raise_to(100)
    s.check_or_call()
    s.show_or_muck_hole_cards(False)
    seen['can_burn_card'] = s.can_burn_card()
    seen['status'] = s.status
    # Not in the prediction: what is still pending instead of the burn.
    seen['showdown_index'] = s.showdown_index
    seen['runout_count_selector_indices'] = list(
        s.runout_count_selector_indices,
    )


@probe(
    'pots OQ11',
    'When a loaded hand history has no sm lines, is the pot chopped?',
    'PHH without `sm` lines chops: expect [100, 100], not [102, 98]',
    {'values': {'final_stacks': [100, 100]}},
)
def pots_oq11(seen: dict) -> None:
    hh = HandHistory.loads(
        "variant='NT'\nantes=[0,0]\nblinds_or_straddles=[1,2]\nmin_bet=2\n"
        "starting_stacks=[100,100]\nactions=['d dh p1 AcAd','d dh p2 7c2d',"
        "'p2 cc','p1 cc','d db KsQsJh','p1 cc','p2 cc','d db 4d','p1 cc',"
        "'p2 cc','d db 3c','p1 cc','p2 cc']",
    )
    seen['final_stacks'] = list(list(hh)[-1].stacks)


@probe(
    'pots OQ12',
    'Does the automatic show/muck decision stall when the shower holds unknown'
    ' cards?',
    '`None` with unknown hole cards stalls automation: expect `0 False`',
    {'values': {'showdown_index': 0, 'can_show_or_muck': False}},
)
def pots_oq12(seen: dict) -> None:
    s = NL.create_state(
        POSTING + (A.CARD_BURNING,), True, 0, (1, 2), 2, 100, 2,
        mode=Mode.CASH_GAME,
    )
    s.deal_hole('????')
    s.deal_hole('KcKd')
    s.check_or_call()
    s.check_or_call()

    for b in ('2c3d4h', '7s', '9h'):
        s.deal_board(b)

        while s.actor_index is not None:
            s.check_or_call()

    seen['showdown_index'] = s.showdown_index
    seen['can_show_or_muck'] = s.can_show_or_muck_hole_cards()


@probe(
    'pots OQ13',
    'When hand killing leaves one player, does the push take the single-player'
    ' path?',
    'A killed loser turns the push into the single-player path. Predicted: one'
    ' push with `board_index=None` and `hand_type_index=None`.',
    {
        'values': {
            'push_count': 1,
            'board_indices': [None],
            'hand_type_indices': [None],
        },
    },
)
def pots_oq13(seen: dict) -> None:
    s = NL.create_state(NO_DEALING_OR_RUNOUTS, True, 0, (1, 2), 2, 100, 2)
    s.deal_hole('AcAd')
    s.deal_hole('KcKd')
    s.complete_bet_or_raise_to(100)
    s.check_or_call()

    for b in ('2c3d4h', '7s', '9h'):
        s.deal_board(b)

    pushes = [op for op in s.operations if isinstance(op, ChipsPushing)]
    seen['pushes'] = list(map(operation, pushes))
    seen['push_count'] = len(pushes)
    seen['board_indices'] = [push.board_index for push in pushes]
    seen['hand_type_indices'] = [push.hand_type_index for push in pushes]


# Extra facts the plan relies on


@probe(
    'extra (a)',
    'With bookkeeping automations and explicit dealing, may the caller'
    ' re-raise after all-ins to 11 and 12 when another player can still'
    ' respond?',
    'Corrected betting OQ3 (cash, blinds 5/10, min bet 10, stacks 200, 200,'
    ' 11, 200, 12; p2 raises to 11, p3 calls, p4 raises to 12, p0 calls, p1'
    ' folds): actor 3 has toCall 1, can raise, and min raise-to 22',
    {
        'values': {
            'actors': [2, 3, 4, 0, 1],
            'actor_index': 3,
            'to_call': 1,
            'can_raise': True,
            'min_raise_to': 22,
        },
    },
)
def extra_a_corrected_betting_oq3(seen: dict) -> None:
    s = NL.create_state(
        BOOKKEEPING, True, 0, (5, 10), 10, (200, 200, 11, 200, 12), 5,
        mode=Mode.CASH_GAME,
    )

    for c in ('AcAd', 'KcKd', 'QcQd', 'JcJd', 'TcTd'):
        s.deal_hole(c)

    actions = [
        s.complete_bet_or_raise_to(11),
        s.check_or_call(),
        s.complete_bet_or_raise_to(12),
        s.check_or_call(),
        s.fold(),
    ]
    seen['actors'] = [action.player_index for action in actions]
    seen['actor_index'] = s.actor_index
    seen['to_call'] = s.checking_or_calling_amount
    seen['can_raise'] = s.can_complete_bet_or_raise_to()
    seen['min_raise_to'] = s.min_completion_betting_or_raising_to_amount


@probe(
    'extra (b)',
    'What Label text does each hand category have, and are StandardLookup'
    ' entry indices dense from 0 (weakest) to 7461 (strongest)?',
    "Labels as written in lookups.py ('High card' to 'Straight flush');"
    ' indices dense and 0-based, 7-5-4-3-2 offsuit = 0, royal flush = 7461',
    {
        'values': {
            'labels': {
                'HIGH_CARD': 'High card',
                'ONE_PAIR': 'One pair',
                'TWO_PAIR': 'Two pair',
                'THREE_OF_A_KIND': 'Three of a kind',
                'STRAIGHT': 'Straight',
                'FLUSH': 'Flush',
                'FULL_HOUSE': 'Full house',
                'FOUR_OF_A_KIND': 'Four of a kind',
                'STRAIGHT_FLUSH': 'Straight flush',
            },
            'indices_dense_from_0': True,
            'weakest_index': 0,
            'strongest_index': 7461,
        },
    },
)
def extra_b_hand_labels(seen: dict) -> None:
    # Private, but PokerKit has no public way to list every entry.
    entries = StandardLookup()._Lookup__entries.values()
    indices = {entry.index for entry in entries}
    seen['labels'] = {label.name: label.value for label in Label}
    seen['index_ranges'] = {
        label.name: [
            min(entry.index for entry in entries if entry.label is label),
            max(entry.index for entry in entries if entry.label is label),
        ]
        for label in Label
    }
    seen['indices_dense_from_0'] = sorted(indices) == list(range(len(indices)))
    seen['weakest_index'] = StandardHighHand('7c5d4h3s2c').entry.index
    seen['strongest_index'] = StandardHighHand('AsKsQsJsTs').entry.index


@probe(
    'extra (c)',
    'Does the recomputed StandardLookup order digest equal the md5 that'
    ' test_lookups.py asserts?',
    f'md5 {TEST_LOOKUPS_MD5}, as StandardLookupTestCase.test_get_entry'
    ' asserts',
    {'values': {'digest': TEST_LOOKUPS_MD5}},
    # Sorting all 2,598,960 hands takes about 5 seconds; it cannot loop.
    timeout_seconds=120,
)
def extra_c_lookup_digest(seen: dict) -> None:
    text = lookup_order_bytes()
    seen['digest'] = md5(text).hexdigest()
    seen['serialization_rule'] = LOOKUP_ORDER_RULE
    seen['line_count'] = text.count(b'\n') + 1
    seen['byte_count'] = len(text)
    seen['first_line'] = text[:text.index(b'\n')].decode()
    seen['last_line'] = text[text.rindex(b'\n') + 1:].decode()


@probe(
    'extra (d)',
    'What exact text does from_game_state(...).dumps() give for a short'
    ' completed heads-up hand, as the reference for the Swift PHH exporter?',
    'Plan section 2: d dh, d db, cbr, cc, f and sm lines only (burns, posts,'
    ' collections, kills, pushes and pulls dropped), keys in dataclass field'
    ' order; the recorded text is the reference, not checked',
)
def extra_d_phh_text(seen: dict) -> None:
    game = NL(BOOKKEEPING, True, 1, (1, 2), 2, mode=Mode.CASH_GAME)
    state = game(200, 2)

    for card in ('Ac', 'Kc', 'Ad', 'Kd'):  # round-robin, one card per call
        state.deal_hole(card)

    state.complete_bet_or_raise_to(6)
    state.check_or_call()
    state.burn_card('??')

    for card in ('Jc', '8d', '2s'):
        state.deal_board(card)

    state.check_or_call()
    state.complete_bet_or_raise_to(8)
    state.check_or_call()
    state.burn_card('??')
    state.deal_board('7h')
    state.check_or_call()
    state.check_or_call()
    state.burn_card('??')
    state.deal_board('3c')
    state.complete_bet_or_raise_to(20)
    state.check_or_call()
    state.show_or_muck_hole_cards(True)
    state.show_or_muck_hole_cards(False)
    pushed = [
        op.amounts for op in state.operations if isinstance(op, ChipsPushing)
    ]
    history = HandHistory.from_game_state(
        game,
        state,
        ante_trimming_status=True,
        finishing_stacks=list(state.stacks),
        winnings=[sum(amounts) for amounts in zip(*pushed)],
    )
    seen['complete'] = not state.status
    seen['phh'] = history.dumps()
