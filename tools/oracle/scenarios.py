"""Hand-written hands for the oracle, played on PokerKit step by step.

These are the unit-tested rules of play, plus every corner where a planted
bug once got past the suite and the states random play rarely reaches. Input
checks with no hand to compare stay in the unit tests.

Every operation goes through the classifier in ``hands.py``, which decides how
it is recorded. A marked operation also states the verdict it should get, and
generation fails if it gets another. In ``SETTLEMENT_SCENARIOS``,
``RUNOUT_SCENARIOS`` and ``OMAHA_SCENARIOS`` a refusal must be marked. After
its listed operations a
hand is played out by a fixed policy, ``finishing_operation``, to completion or
to a B4 rejection.
"""

from collections.abc import Iterable

from pokerkit import Deck, State

import bridge
from hands import MAXIMUM_RUNOUT_COUNT, Recorder, unseen_cards

BOOKKEEPING = (
    'antePosting', 'betCollection', 'blindOrStraddlePosting',
    'handKilling', 'chipsPushing', 'chipsPulling',
)
MANUAL_PUSH = BOOKKEEPING[:4]
MANUAL_PULL = BOOKKEEPING[:5]
MANUAL_SETTLEMENT = BOOKKEEPING[:3]
SIX_HOLES = 'AsKsQsJsTs9sAhKhQhJhTh9h'
FOUR_HOLES = 'AsKsQsJsAhKhQhJh'
THREE_HOLES = 'AsKsQsAhKhQh'
TWO_HOLES = 'AsKsAhKh'
DEEP_SIX = [20001, 20001, 20001, 1301, 1701, 1801]
NOT_ACTIVE = 'Player is not active.'
NOBODY_SELECTS = 'Nobody can choose the number of runouts.'
NO_ORDER = 'There is no player to showdown.'
NON_STANDARD = 'Non-standard showdown must show all cards.'
ALL_IN_SHOW = 'The player must show when all-in.'
FINAL_SHOW = 'A card is not shown in final showdown.'
UNKNOWN_SHOWN = 'An unknown card is shown.'
TOO_MANY = 'too many cards shown'
NO_BURN = 'No card burning is pending.'
BURN_FIRST = 'A card must be burnt before board dealing.'


def config(
        stacks: list[int],
        mode: str = 'cashGame',
        antes: Iterable[int] = (),
        ante_trimming: bool = False,
        blinds: Iterable[int] = (1, 2),
        min_bet: int = 2,
        automations: Iterable[str] = BOOKKEEPING,
        variant: str | None = None,
) -> dict:
    count = len(stacks)
    antes, blinds = list(antes), list(blinds)
    # The stored config names a game only when it is not Texas hold'em.
    named = {} if variant is None else {'variant': variant}

    return named | {
        'mode': mode,
        'startingStacks': stacks,
        'antes': antes + [0] * (count - len(antes)),
        'anteTrimming': ante_trimming,
        'blindsOrStraddles': blinds + [0] * (count - len(blinds)),
        'minBet': min_bet,
        'automations': list(automations),
    }


def split(cards: str) -> list[str]:
    return [cards[i:i + 2] for i in range(0, len(cards), 2)]


def holes(cards: str, players: int) -> list[dict]:
    """Hole cards one to each player in turn from player 0, as suggested."""
    return [
        deal_hole(i % players, card) for i, card in enumerate(split(cards))
    ]


def street(cards: str, burn_card: str = '??') -> list[dict]:
    return [burn(burn_card)] + [deal_board(card) for card in split(cards)]


def check_down(players: Iterable[int], *streets: str) -> list[dict]:
    """The streets dealt and checked through, by default flop to river."""
    operations = []

    for cards in streets or ('2c7d9h', 'Td', '3s'):
        operations += street(cards) + [call(player) for player in players]

    return operations


def post_ante(player: int) -> dict:
    return {'type': 'postAnte', 'player': player}


def post_blind(player: int) -> dict:
    return {'type': 'postBlindOrStraddle', 'player': player}


def collect() -> dict:
    return {'type': 'collectBets'}


def burn(card: str) -> dict:
    return {'type': 'burnCard', 'card': card}


def deal_hole(player: int, card: str) -> dict:
    return {'type': 'dealHole', 'player': player, 'card': card}


def deal_board(card: str) -> dict:
    return {'type': 'dealBoard', 'card': card}


def call(player: int) -> dict:
    return {'type': 'checkOrCall', 'player': player}


def fold(player: int) -> dict:
    return {'type': 'fold', 'player': player}


def raise_to(player: int, amount: int) -> dict:
    return {'type': 'betOrRaise', 'player': player, 'to': amount}


def select_runouts(player: int, count: int | None = None) -> dict:
    selection = {'type': 'selectRunoutCount', 'player': player}

    return selection if count is None else selection | {'count': count}


def show(player: int, cards: str | None = None) -> dict:
    """A show as is, or of the listed cards; ``''`` lists none."""
    operation = {'type': 'showHoleCards', 'player': player}

    return operation if cards is None else operation | {'cards': split(cards)}


def muck(player: int) -> dict:
    return {'type': 'muckHoleCards', 'player': player}


def kill(player: int) -> dict:
    return {'type': 'killHand', 'player': player}


def push() -> dict:
    return {'type': 'pushChips'}


def pull(player: int) -> dict:
    return {'type': 'pullChips', 'player': player}


def refused(operation: dict, message: str) -> dict:
    return {
        **operation,
        'expect': {'rejected': 'pokerkit', 'message': message},
    }


def duplicate(operation: dict) -> dict:
    return {**operation, 'expect': {'rejected': 'B1'}}


def abandons(operation: dict, pot: int) -> dict:
    player = operation['player']
    error = {'wouldAbandonPot': {'player': player, 'pot': pot}}

    return {**operation, 'expect': {'rejected': 'B2', 'error': error}}


def unknown_board(operation: dict, position: int, runout: int = 0) -> dict:
    error = {'unknownBoardCard': {'runout': runout, 'position': position}}

    return {**operation, 'expect': {'rejected': 'B4', 'error': error}}


def too_many_runouts(operation: dict) -> dict:
    error = {'invalidRunoutCount': {'_0': operation['count']}}

    return {**operation, 'expect': {'rejected': 'B5', 'error': error}}


def not_dealt(operation: dict, card: str) -> dict:
    player = operation['player']
    error = {'shownCardNotDealt': {'player': player, 'card': card}}

    return {**operation, 'expect': {'rejected': 'B6', 'error': error}}


def b9_refusal(operation: dict, name: str) -> dict:
    error = {name: {'player': operation['player']}}

    return {**operation, 'expect': {'rejected': 'B9', 'error': error}}


def unknown_listed(operation: dict) -> dict:
    error = {'cannotShowUnknownCard': {'player': operation['player']}}

    return {**operation, 'expect': {'rejected': 'B14', 'error': error}}


def forced_bet_shows(player: int) -> list[dict]:
    """Every show and muck with no street in play and no cards dealt (B9)."""
    return [
        b9_refusal(show(player), 'noShowdownExpected'),
        b9_refusal(show(player, ''), 'noShowdownExpected'),
        refused(show(player, 'As'), TOO_MANY),
        refused(muck(player), NON_STANDARD),
    ]


def forced_bets_config(mode: str) -> dict:
    return config(
        [200] * 3, mode=mode, antes=[1] * 3, ante_trimming=True,
        automations=(),
    )


FORCED_BETS_SHOWS = (
    forced_bet_shows(1)
    + [post_ante(0), post_ante(1), post_ante(2)]
    + forced_bet_shows(2)
    + [collect()]
    + forced_bet_shows(0)
    + [post_blind(1), post_blind(0)]
)
SCENARIOS = {
    'three-handed': (
        config([200, 200, 200]),
        holes('AsKhQdAcKdQc', 3)
        + [raise_to(2, 6), call(0), call(1), deal_board('2h')]
        + street('2h7s9d')
        + [call(0), raise_to(1, 10), raise_to(2, 30), fold(0), call(1)]
        + street('Tc', burn_card='3c')
        + [call(1), raise_to(2, 50), fold(1)],
    ),
    'heads-up-ante-reversal': (
        config([200, 200], mode='tournament', antes=[0, 5]),
        holes('AsKsAhKh', 2)
        + [call(0), call(1), call(0)]
        + street('2c7d9h')
        + [call(0), raise_to(1, 20), call(0)]
        + street('Td')
        + [raise_to(0, 40), raise_to(1, 120), fold(0)],
    ),
    'heads-up-equal-blinds': (
        config([200, 200], blinds=[2, 2]),
        holes('AsKsAhKh', 2) + [call(1), call(0), call(1)],
    ),
    'heads-up-big-blind-only': (
        config([200, 200], blinds=[0, 2]),
        holes('AsKsAhKh', 2)
        + [call(1), raise_to(0, 6), call(1)]
        + street('2c7d9h')
        + [call(0), call(1)],
    ),
    'heads-up-live-post': (
        config([200, 200], blinds=[-2, 2]),
        holes('AsKsAhKh', 2)
        + [raise_to(1, 6), call(0)]
        + street('2c7d9h')
        + [call(0), raise_to(1, 10), call(0)],
    ),
    'heads-up-ante-not-capped-by-other-stack': (
        config([200, 3], mode='tournament', antes=[0, 5]),
        holes('AsKsAhKh', 2) + [call(1)],
    ),
    'heads-up-big-blind-all-in-from-blind': (
        config([2, 200]),
        holes('AsKsAhKh', 2) + [call(1)],
    ),
    # The big blind already covers everything the small blind has, so only
    # the small blind acts.
    'heads-up-short-small-blind-covered': (
        config([200, 3], mode='tournament', blinds=[2, 4], min_bet=4),
        holes('AsKsAhKh', 2) + [call(1)],
    ),
    'short-big-blind': (
        config([200, 1, 200]),
        holes('AsKsQsAhKhQh', 3)
        + [raise_to(2, 2), call(2), call(0)]
        + street('2c7d9h')
        + [call(0), call(2)]
        + street('Td')
        + [raise_to(0, 10), call(2)],
    ),
    'big-blind-ante-short-big-blind': (
        config([200, 3, 200], mode='tournament', antes=[0, 2]),
        holes('AsKsQsAhKhQh', 3) + [call(2), call(0)] + street('2c7d9h'),
    ),
    # The dead ante does not make its short payer eligible for the raise.
    'big-blind-ante-all-in-side-pot': (
        config([200, 3, 200], antes=[0, 2]),
        holes('AsKsQsAhKhQh', 3)
        + [raise_to(2, 3), call(0)]
        + street('2c7d9h')
        + [call(0), call(2)],
    ),
    'trimmed-antes-short-stacks': (
        config(
            [3, 3, 200], mode='tournament', antes=[5, 5, 5],
            ante_trimming=True, blinds=[],
        ),
        holes('AsKsQsAhKhQh', 3) + [call(2)],
    ),
    'blind-after-trimmed-ante-refund': (
        config(
            [3, 6, 3], mode='tournament', antes=[5, 5, 5], ante_trimming=True,
        ),
        holes('AsKsQsAhKhQh', 3),
    ),
    'utg-straddle': (
        config([200] * 6, blinds=[1, 2, 4]),
        holes(SIX_HOLES, 6)
        + [raise_to(3, 5), raise_to(3, 6), call(4), fold(5), fold(0)]
        + [call(1), raise_to(2, 20), call(3), fold(4), call(1)],
    ),
    'button-straddle': (
        config([200] * 6, blinds=[1, 2, 0, 0, 0, 4]),
        holes(SIX_HOLES, 6)
        + [call(0), fold(1), fold(2), raise_to(3, 12), fold(4), call(5)]
        + [call(0)],
    ),
    # The straddler posts 1 of 4, so the big blind's 2 decides the opener.
    'short-button-straddle': (
        config([200, 200, 200, 200, 200, 1], blinds=[1, 2, 0, 0, 0, 4]),
        holes(SIX_HOLES, 6) + [call(2), call(3), call(4), call(0), call(1)],
    ),
    # Nobody can match the straddle, so the straddler is never asked.
    'straddle-covers-short-blinds': (
        config([10, 10, 200], blinds=[1, 2, 50]),
        holes('AsKsQsAhKhQh', 3) + [call(0), call(1)],
    ),
    'live-post': (
        config([200] * 4, blinds=[1, 2, 0, -2]),
        holes('AsKsQsJsAhKhQhJh', 4)
        + [call(2), call(3), call(0), call(1)]
        + street('2c7d9h'),
    ),
    'first-raise-counts-full': (
        config([3, 200, 200, 200]),
        holes('AsKsQsJsAhKhQhJh', 4)
        + [call(2), call(3), raise_to(0, 3), call(1), raise_to(2, 8)]
        + [call(3), call(1)],
    ),
    'cumulative-short-all-ins-reopen': (
        config(
            DEEP_SIX, mode='tournament', antes=[1] * 6, ante_trimming=True,
            blinds=[], min_bet=1,
        ),
        holes(SIX_HOLES, 6)
        + [raise_to(0, 500), raise_to(1, 1000), call(2), raise_to(3, 1300)]
        + [raise_to(4, 1700), fold(5), call(0)]
        + [raise_to(1, 2200), call(2), call(0)],
    ),
    'cumulative-short-all-ins-closed-again': (
        config(
            DEEP_SIX, mode='tournament', antes=[1] * 6, ante_trimming=True,
            blinds=[], min_bet=1,
        ),
        holes(SIX_HOLES, 6)
        + [raise_to(0, 500), raise_to(1, 1000), call(2), raise_to(3, 1300)]
        + [raise_to(4, 1700), raise_to(5, 1800), call(0)]
        + [raise_to(1, 2600), call(1), call(2)],
    ),
    'all-in-below-min-bet-is-a-full-bet': (
        config([200, 15, 18, 200], blinds=[5, 10], min_bet=10),
        holes('AsKsQsJsAhKhQhJh', 4)
        + [call(2), call(3), call(0), call(1)]
        + street('2c7d9h')
        + [call(0), raise_to(1, 5), raise_to(2, 8), call(3), call(0)],
    ),
    'short-all-ins-reopen-below-min-bet': (
        config([300, 26, 300, 29, 32, 34], blinds=[10, 20], min_bet=20),
        holes(SIX_HOLES, 6)
        + [call(2), call(3), call(4), call(5), call(0), call(1)]
        + street('2c7d8h')
        + [call(0), raise_to(1, 6), call(2), raise_to(3, 9)]
        + [raise_to(4, 12), raise_to(5, 14), call(0), call(2)],
    ),
    # A3 at exact equality, after a bet that is not all in: 4 + 6 make the
    # 10-chip increment and reopen the action; the 5-chip all-in closes it.
    'short-all-ins-add-up-exactly-then-close': (
        config([200, 200, 16, 22, 27, 200]),
        holes(SIX_HOLES, 6)
        + [call(2), call(3), call(4), call(5), call(0), call(1)]
        + street('2c7d3h')
        + [raise_to(0, 10), call(1), raise_to(2, 14), raise_to(3, 20)]
        + [raise_to(4, 25), call(5), raise_to(0, 100), call(0)]
        + [raise_to(1, 100), call(1)],
    ),
    # test_short_all_ins: 50 + 50 make a full raise, which reopens the bettor,
    # but the caller in between faces only the second 50.
    'short-all-ins-reopen-the-bettor-not-the-caller': (
        config([1002, 152, 1002, 202], mode='tournament', ante_trimming=True),
        holes(FOUR_HOLES, 4)
        + [call(2), call(3), call(0), call(1)]
        + street('2c3c4c')
        + [raise_to(0, 100), raise_to(1, 150), call(2), raise_to(3, 200)]
        + [call(0), raise_to(2, 300), call(2)],
    ),
    'full-all-in-clears-short-all-ins': (
        config([1002, 152, 302, 1002, 402, 502, 602]),
        holes('AsKsQsJsTs9s8sAhKhQhJhTh9h8h', 7)
        + [call(2), call(3), call(4), call(5), call(6), call(0), call(1)]
        + street('2c7d3h')
        + [raise_to(0, 100), raise_to(1, 150), raise_to(2, 300), call(3)]
        + [raise_to(4, 400), raise_to(5, 500), raise_to(6, 600), call(0)]
        + [call(3)],
    ),
    # A3 after a full raise that is not all in: it forgets the 4-chip all-in,
    # so 6 + 5 alone make the 10-chip increment and reopen the action.
    'full-raise-clears-short-all-ins': (
        config([200, 16, 200, 32, 37]),
        holes('AcKcQcJcTcAdKdQdJdTd', 5)
        + [call(2), call(3), call(4), call(0), call(1)]
        + street('2c7d3h')
        + [raise_to(0, 10), raise_to(1, 14), raise_to(2, 24), raise_to(3, 30)]
        + [raise_to(4, 35), call(0), raise_to(2, 100), call(0)],
    ),
    # One more short all-in closes the action again, for the same reason.
    'short-all-ins-after-a-full-raise-close-again': (
        config([200, 16, 200, 32, 37, 43]),
        holes(SIX_HOLES, 6)
        + [call(2), call(3), call(4), call(5), call(0), call(1)]
        + street('2c7d3h')
        + [raise_to(0, 10), raise_to(1, 14), raise_to(2, 24), raise_to(3, 30)]
        + [raise_to(4, 35), raise_to(5, 41), call(0), raise_to(2, 100)]
        + [call(2)],
    ),
    'raise-over-short-all-ins': (
        config([200, 200, 11, 200, 12], blinds=[5, 10], min_bet=10),
        holes('AcKcQcJcTcAdKdQdJdTd', 5)
        + [raise_to(2, 11), call(3), raise_to(4, 12), call(0), fold(1)]
        + [raise_to(3, 21), raise_to(3, 22), call(0)],
    ),
    'short-all-in-not-reopened': (
        config([200, 200, 150]),
        holes('AsKsQsAhKhQh', 3)
        + [call(2), call(0), call(1)]
        + street('2c7d9h')
        + [raise_to(0, 100), call(1), raise_to(2, 148), raise_to(0, 198)]
        + [call(0), call(1)],
    ),
    'covered-player': (
        config([200, 200, 60]),
        holes('AsKsQsAhKhQh', 3)
        + [call(2), call(0), call(1)]
        + street('2c7d9h')
        + [raise_to(0, 100), call(1), raise_to(2, 58), call(2)],
    ),
    'raise-refused-before-its-amount-is-judged': (
        config([200, 200, 60]),
        holes('AsKsQsAhKhQh', 3)
        + [call(2), call(0), call(1)]
        + street('2c7d9h')
        + [raise_to(0, 100), call(1), raise_to(2, 1000), raise_to(2, 1)]
        + [call(2)],
    ),
    'no-opponent-can-respond': (
        config([200, 50]),
        holes('AsKsAhKh', 2) + [raise_to(1, 50), raise_to(0, 100), call(0)],
    ),
    'covered-opponents-cannot-respond': (
        config([200, 30, 100]),
        holes('AsKsQsAhKhQh', 3) + [raise_to(2, 100), call(0), call(1)],
    ),
    'folded-opponent-cannot-respond': (
        config([200, 200, 50]),
        holes('AsKsQsAhKhQh', 3)
        + [raise_to(2, 50), fold(0), raise_to(1, 100), call(1)],
    ),
    'short-all-in-with-nobody-to-respond': (
        config([300, 122]),
        holes('AsKsAhKh', 2)
        + [call(1), call(0)]
        + street('2c7d9h')
        + [raise_to(0, 100), raise_to(1, 120), raise_to(0, 298)]
        + [raise_to(0, 1), call(0)],
    ),
    # The big blind's option is a free check that may neither raise nor fold.
    'tournament-option-with-nobody-to-respond': (
        config([2, 100, 100], mode='tournament'),
        holes('AsKsQsAhKhQh', 3)
        + [fold(2), call(0), raise_to(1, 4), fold(1), call(1)],
    ),
    # A free fold leaves nobody to respond before anyone has bet the flop.
    'free-fold-leaves-nobody-to-bet-against': (
        config([200, 200, 3]),
        holes('AsKsQsAhKhQh', 3)
        + [raise_to(2, 3), call(0), call(1)]
        + street('2c7d9h')
        + [fold(0), raise_to(1, 10), call(1)],
    ),
    'all-in-for-less': (
        config([200, 200, 3], mode='tournament'),
        holes('AsKsQsAhKhQh', 3)
        + [raise_to(2, 3), raise_to(0, 8), call(1), call(0)],
    ),
    'uncalled-bet-returned': (
        config([200, 30]),
        holes('AsKsAhKh', 2)
        + [call(1), call(0)]
        + street('2c7d9h')
        + [raise_to(0, 50), call(1)],
    ),
    'refund-to-folded-straddler': (
        config([1, 2, 200, 200], blinds=[1, 2, 4]),
        holes('AsKsQsJsAhKhQhJh', 4) + [fold(3), fold(2)],
    ),
    # The big blind folds its option to a 1-chip all-in, which wins.
    'refund-to-folded-big-blind': (
        config([200, 200, 200, 1]),
        holes('AsKsQsJsAhKhQhJh', 4) + [fold(2), call(3), fold(0), fold(1)],
    ),
    'refund-to-folded-double-straddle': (
        config([200, 200, 3, 200, 200], blinds=[1, 2, 4, 8]),
        holes('AsKsQsJsTsAhKhQhJhTh', 5)
        + [fold(4), fold(0), fold(1), fold(3)],
    ),
    'side-pots': (
        config([10, 30, 60, 200]),
        holes('AsKsQsJsAhKhQhJh', 4)
        + [raise_to(2, 60), call(3), call(0), call(1)],
    ),
    'fold-out-before-push': (
        config(
            [200, 200, 200], antes=[0, 5],
            automations=BOOKKEEPING[:3],
        ),
        holes('AsKsQsAhKhQh', 3) + [raise_to(2, 6), fold(0), fold(1)],
    ),
    'fold-out-before-pull': (
        config(
            [200, 200, 200], antes=[0, 5],
            automations=BOOKKEEPING[:5],
        ),
        holes('AsKsQsAhKhQh', 3) + [raise_to(2, 6), fold(0), fold(1)],
    ),
    # Only the winner's own blind is out, so there is no pot to push.
    'fold-out-with-nothing-to-push': (
        config([200, 200], blinds=[0, 2], automations=BOOKKEEPING[:5]),
        holes('AsKsAhKh', 2) + [fold(1)],
    ),
    'free-fold-cash': (
        config([200, 200, 200]),
        holes('AsKsQsAhKhQh', 3)
        + [call(2), call(0), fold(1)]
        + street('2c7d9h')
        + [fold(0)],
    ),
    'free-fold-tournament': (
        config([200, 200, 200], mode='tournament'),
        holes('AsKsQsAhKhQh', 3)
        + [call(2), call(0), fold(1), call(1)]
        + street('2c7d9h'),
    ),
    # A fold before dealing ends, or out of turn, is refused for that, even
    # by a player who could check.
    'tournament-fold-out-of-turn': (
        config([200, 200, 200], mode='tournament'),
        [deal_hole(0, 'As'), fold(1), deal_hole(1, 'Ks'), deal_hole(2, 'Qs')]
        + [deal_hole(0, 'Ah'), deal_hole(1, 'Kh'), deal_hole(2, 'Qh')]
        + [fold(1), call(2), call(0), fold(1), call(1)]
        + street('2c7d9h')
        + [fold(2), call(0)],
    ),
    # The turn is judged before the amount and before whether the player could
    # raise at all, between streets too, where the last raise is still on file.
    'raises-out-of-turn': (
        config([200, 40, 200]),
        [refused(raise_to(1, 1), 'There is no player to act.')]
        + holes(THREE_HOLES, 3)
        + [refused(raise_to(1, 1), 'Player 1 is not the actor')]
        + [raise_to(2, 100)]
        + [refused(raise_to(1, 40), 'Player 1 is not the actor')]
        + [call(0), call(1)]
        + [refused(raise_to(0, 20), 'There is no player to act.')],
    ),
    'manual-posting': (
        config([200] * 3, antes=[1] * 3, ante_trimming=True, automations=[]),
        [post_ante(2), post_ante(2), post_ante(0), collect(), post_ante(1)]
        + [post_blind(1), collect(), post_blind(1), post_blind(0)]
        + holes('AsKsQsAhKhQh', 3)
        + [raise_to(2, 6), call(0), call(1), collect()]
        + street('2c7d9h')
        + [raise_to(0, 10), fold(1), fold(2), collect()],
    ),
    'manual-short-ante': (
        config(
            [3, 200], mode='tournament', antes=[0, 5],
            automations=('betCollection', 'blindOrStraddlePosting'),
        ),
        [post_ante(0)] + holes('AsKsAhKh', 2),
    ),
    'manual-short-blind': (
        config([200, 1, 200], automations=('antePosting', 'betCollection')),
        [post_blind(1), post_blind(0)]
        + holes('AsKsQsAhKhQh', 3)
        + [call(2), call(0)],
    ),
    'dealing-order-and-cards': (
        config([200, 200, 200]),
        [deal_hole(2, 'As'), deal_hole(2, 'Ks'), deal_hole(2, 'Qs')]
        + [duplicate(deal_hole(1, 'As')), deal_hole(1, '??')]
        + [deal_hole(0, 'Js'), deal_hole(0, 'Ts'), deal_board('2c')]
        + [deal_hole(1, '9s'), fold(2), call(0), call(1), deal_board('2c')]
        + [duplicate(burn('Ks')), burn('2c'), duplicate(deal_board('2c'))]
        + [deal_board('??'), deal_board('3c'), deal_board('Ah')]
        + [call(0), call(1)]
        + street('??')
        + [call(0), call(1), duplicate(burn('3c'))],
    ),
    # Hands use only the known cards of players still in: a folded player has
    # none on the river, and an unknown hole card leaves five known cards.
    'river-after-a-fold': (
        config([200, 200, 200]),
        holes('AsKsQsAhKhQh', 3)
        + [call(2), fold(0), call(1)]
        + street('2c7d9h')
        + [call(1), call(2)]
        + street('Td')
        + [call(1), call(2)]
        + street('3s'),
    ),
    'unknown-hole-card-on-the-turn': (
        config([200, 200]),
        [deal_hole(0, 'As'), deal_hole(1, 'Ks'), deal_hole(0, '??')]
        + [deal_hole(1, 'Kh'), call(1), call(0)]
        + street('2c7d9h')
        + [call(0), call(1)]
        + street('Td'),
    ),
    # A dealt card scanned at the wrong moment: PokerKit refuses it for the
    # timing, so the engine must report that rather than the duplicate.
    'burn-of-dealt-card-at-wrong-moment': (
        config([200, 200]),
        [deal_hole(0, 'As'), deal_hole(1, 'Ks'), burn('As')]
        + [deal_hole(0, 'Ah'), deal_hole(1, 'Kh'), burn('Kh')]
        + [call(1), call(0)]
        + street('3c4c5c', burn_card='2c')
        + [burn('3c'), call(0), raise_to(1, 20), fold(0)],
    ),
    'hole-deal-of-dealt-card-at-wrong-moment': (
        config([200, 200, 200]),
        [deal_hole(0, 'As'), deal_hole(0, 'Ks'), deal_hole(0, 'Qs')]
        + [deal_hole(1, 'Ah'), deal_hole(2, 'Kh'), deal_hole(1, 'Qh')]
        + [deal_hole(2, 'Jh'), deal_hole(2, 'As')]
        + [call(2), call(0), call(1), deal_hole(1, 'Kh')]
        + street('3c4c5c', burn_card='2c')
        + [deal_hole(0, '3c'), raise_to(0, 10), fold(1), fold(2)],
    ),
    'board-deal-of-dealt-card-before-burn': (
        config([200, 200]),
        holes('AsKsAhKh', 2)
        + [call(1), call(0), deal_board('As')]
        + street('2c7d9h')
        + [call(0), call(1), deal_board('2c')]
        + street('4d', burn_card='3d'),
    ),
}
SETTLEMENT_SCENARIOS = {
    # A14. The order is only a suggestion: anyone in it may go first.
    'showdown-order-last-aggressor': (
        config([200] * 4),
        holes(FOUR_HOLES, 4)
        + [call(2), call(3), call(0), call(1)]
        + check_down([0, 1, 2, 3], '2c7d9h', 'Td')
        + street('3s')
        + [call(0), raise_to(1, 20), call(2), call(3), call(0)]
        + [show(3), show(1), show(2), show(0)],
    ),
    # A short all-in raise makes its player the opener all the same.
    'showdown-order-short-all-in-raiser': (
        config([200, 17, 200]),
        holes(THREE_HOLES, 3)
        + [call(2), call(0), call(1)]
        + check_down([0, 1, 2], '2c7d9h', 'Td')
        + street('3s')
        + [raise_to(0, 10), raise_to(1, 15), call(2), call(0)],
    ),
    # With no raise the order starts at the round's first to act.
    'showdown-order-preflop-no-raise': (
        config([2, 2, 2]),
        holes(THREE_HOLES, 3) + [call(2), call(0)],
    ),
    # A9: nothing is dealt until every choice and every show is in.
    'all-in-shows-before-next-card': (
        config([100, 100, 100]),
        holes(THREE_HOLES, 3)
        + [raise_to(2, 100), call(0), call(1)]
        + [refused(burn('2c'), 'No card burning is pending.')]
        + [select_runouts(0), select_runouts(1), select_runouts(2)]
        + [refused(burn('2c'), 'No card burning is pending.')]
        + [show(2), show(0)]
        + [refused(deal_board('2c'), 'No board dealing is pending.')]
        + [show(1)]
        + street('2c7d9h'),
    ),
    # B5: PokerKit passes the player as the count, so it credits player 0
    # and takes any count.
    'runout-selection-credits-the-named-player': (
        config([100, 100, 100]),
        holes(THREE_HOLES, 3)
        + [raise_to(2, 100), call(0), call(1)]
        + [select_runouts(2, 1)]
        + [
            refused(
                select_runouts(2),
                'The Player 2 cannot choose the number of runouts.',
            ),
            refused(
                select_runouts(2, 0),
                'The Player 2 cannot choose the number of runouts.',
            ),
            refused(
                select_runouts(0, 0),
                'The runout count 0 is not positive.',
            ),
            refused(
                select_runouts(0, -1),
                'The runout count -1 is not positive.',
            ),
        ]
        + [show(2), select_runouts(1), show(1), select_runouts(0, 1), show(0)]
        + [refused(select_runouts(0), NOBODY_SELECTS)],
    ),
    'runout-selection-automated': (
        config(
            [100, 100, 100],
            automations=BOOKKEEPING + ('runoutCountSelection',),
        ),
        holes(THREE_HOLES, 3)
        + [raise_to(2, 100), call(0), call(1)]
        + [refused(select_runouts(0), NOBODY_SELECTS)],
    ),
    # A10: the choice stands apart from the show, in any order, and a covering
    # player and a player who mucks still have to make it.
    'runout-selection-by-covering-and-mucked-players': (
        config([300, 100, 100]),
        holes(THREE_HOLES, 3)
        + [raise_to(2, 100), call(0), call(1)]
        + [muck(1), show(2), show(0)]
        + [select_runouts(2), select_runouts(1), select_runouts(0, 1)],
    ),
    'runout-selection-not-offered-on-the-river': (
        config([100, 100]),
        holes(TWO_HOLES, 2)
        + [call(1), call(0)]
        + check_down([0, 1], '2c7d9h', 'Td')
        + street('3s')
        + [raise_to(0, 98), call(1)]
        + [refused(select_runouts(0), NOBODY_SELECTS)],
    ),
    'runout-selection-not-offered-in-tournaments': (
        config([100, 100], mode='tournament'),
        holes(TWO_HOLES, 2)
        + [raise_to(1, 100), call(0)]
        + [refused(select_runouts(0), NOBODY_SELECTS)],
    ),
    # A9: after each runout street the order restarts at player 0 and skips
    # whoever is fully face up. The runout choice is not offered again.
    'reask-after-each-all-in-street': (
        config([50, 50, 50]),
        holes(THREE_HOLES, 3)
        + [raise_to(2, 50), call(0), call(1)]
        + [select_runouts(0), select_runouts(1), select_runouts(2)]
        + [show(2, ''), show(0), show(1, 'Kh')]
        + street('2c7d9h')
        + [refused(show(0), 'The Player 0 cannot perform a showdown.')]
        + [refused(select_runouts(1), NOBODY_SELECTS)]
        + [show(1, ''), show(2, 'Qs')]
        + street('Td')
        + [show(2), show(1, 'Ks')]
        + street('3s')
        + [show(1)],
    ),
    # A show of none turns a card shown earlier face down, and on the river
    # forgets it, but the card still counts as shown in the results.
    'river-reask-forgets-a-shown-card': (
        config([50, 50]),
        holes(TWO_HOLES, 2)
        + [raise_to(1, 50), call(0)]
        + [select_runouts(1), select_runouts(0), show(1), show(0, 'As')]
        + street('2c7d9h')
        + [show(0, 'As')]
        + street('Td')
        + [show(0, 'As')]
        + street('3s')
        + [show(0, '')],
    ),
    # A listed show puts the shown cards first; the rest stay face down.
    'cash-partial-show-at-a-flop-all-in': (
        config([100, 100]),
        holes(TWO_HOLES, 2)
        + [call(1), call(0)]
        + street('2c7d9h')
        + [raise_to(0, 98), call(1)]
        + [select_runouts(0), select_runouts(1)]
        + [show(1, 'Kh'), show(0, '')]
        + street('Td')
        + [show(1), show(0, 'AhAs')],
    ),
    # A13: on the river a card kept face down is forgotten.
    'river-partial-show-forgets': (
        config([100, 100]),
        holes(TWO_HOLES, 2)
        + [call(1), call(0)]
        + check_down([0, 1])
        + [show(0, 'Ah'), show(1)],
    ),
    # B14: a card is shown or left out of the list, so an unknown entry is
    # refused wherever it stands, at an all-in and on the river.
    'listed-unknown-refused-on-the-river': (
        config([100, 100]),
        holes(TWO_HOLES, 2)
        + [call(1), call(0)]
        + check_down([0, 1])
        + [unknown_listed(show(0, '??As')), unknown_listed(show(1, 'Kh??'))]
        + [show(0, 'As'), show(1, 'Kh')],
    ),
    'listed-unknown-refused-at-an-all-in': (
        config([100, 100]),
        holes(TWO_HOLES, 2)
        + [raise_to(1, 100), call(0), select_runouts(0), select_runouts(1)]
        + [unknown_listed(show(0, '????')), show(0, '')]
        + [unknown_listed(show(1, '??Kh')), show(1)],
    ),
    'unshown-hands-play-the-board': (
        config([100, 100]),
        holes('AcKsAdQd', 2)
        + [call(1), call(0)]
        + check_down([0, 1], 'KdQsJh', '4d', '3c')
        + [show(0, ''), show(1, '')],
    ),
    'reveal-unknown-hole-cards': (
        config([100, 100]),
        [deal_hole(0, '??'), deal_hole(1, 'Ks')]
        + [deal_hole(0, 'Ah'), deal_hole(1, '??')]
        + [call(1), call(0)]
        + check_down([0, 1])
        + [refused(show(0), UNKNOWN_SHOWN)]
        + [show(0, 'AhAd'), show(1, 'QdKs')],
    ),
    'reveal-after-a-partial-show': (
        config([100, 100]),
        [deal_hole(0, '??'), deal_hole(1, 'Ks')]
        + [deal_hole(0, '??'), deal_hole(1, 'Kh')]
        + [raise_to(1, 100), call(0)]
        + [select_runouts(0), select_runouts(1), show(1), show(0, 'Ad')]
        + street('2c7d9h')
        + [refused(show(0), UNKNOWN_SHOWN), show(0, 'AdAc')],
    ),
    'tournament-show-as-is-with-an-unknown-card': (
        config([100, 100], mode='tournament'),
        [deal_hole(0, '??'), deal_hole(1, 'Ks')]
        + [deal_hole(0, 'Ah'), deal_hole(1, 'Kh')]
        + [raise_to(1, 100), call(0)]
        + [refused(show(0), ALL_IN_SHOW)]
        + [show(1), show(0, 'AdAh')],
    ),
    'tournament-river-show-as-is-with-an-unknown-card': (
        config([100, 100], mode='tournament'),
        [deal_hole(0, '??'), deal_hole(1, 'Ks')]
        + [deal_hole(0, 'Ah'), deal_hole(1, 'Kh')]
        + [call(1), call(0)]
        + check_down([0, 1])
        + [refused(show(0), FINAL_SHOW)]
        + [show(0, 'AhAd'), show(1)],
    ),
    # An all-in muck is allowed even though a partial show is not.
    'tournament-partial-show-refused-at-an-all-in': (
        config([100, 100], mode='tournament'),
        holes(TWO_HOLES, 2)
        + [raise_to(1, 100), call(0)]
        + [refused(show(1, 'Ks'), ALL_IN_SHOW)]
        + [refused(show(1, ''), ALL_IN_SHOW)]
        + [muck(1), refused(show(0, ''), ALL_IN_SHOW), show(0)],
    ),
    'tournament-partial-show-refused-on-the-river': (
        config([100, 100], mode='tournament'),
        holes(TWO_HOLES, 2)
        + [call(1), call(0)]
        + check_down([0, 1])
        + [refused(show(0, 'As'), FINAL_SHOW)]
        + [show(0), muck(1)],
    ),
    # B13: the player left at a tournament showdown with nobody all in wins
    # without tabling, so may keep the cards face down, as in a cash game.
    'tournament-last-player-keeps': (
        config([200, 200, 200], mode='tournament'),
        holes(THREE_HOLES, 3)
        + [call(2), call(0), call(1)]
        + check_down([0, 1, 2])
        + [refused(show(0, ''), FINAL_SHOW), muck(0), muck(1)]
        + [show(2, '')],
    ),
    'tournament-last-player-shows-one-card': (
        config([200, 200, 200], mode='tournament'),
        [deal_hole(0, 'As'), deal_hole(1, 'Ks'), deal_hole(2, '??')]
        + [deal_hole(0, 'Ah'), deal_hole(1, 'Kh'), deal_hole(2, 'Qh')]
        + [call(2), call(0), call(1)]
        + check_down([0, 1, 2])
        + [muck(0), muck(1), refused(show(2), UNKNOWN_SHOWN)]
        + [unknown_listed(show(2, '??Qh')), show(2, 'Qh')],
    ),
    # A river all-in for less is an all-in, though both callers have chips
    # behind: PokerKit counts any stack at 0 when the river's betting ends.
    'tournament-last-player-must-show-after-a-river-all-in': (
        config([50, 200, 200], mode='tournament'),
        holes(THREE_HOLES, 3)
        + [call(2), call(0), call(1)]
        + check_down([0, 1, 2], '2c7d9h', 'Td')
        + street('3s')
        + [raise_to(0, 48), call(1), call(2), muck(1), muck(2)]
        + [refused(show(0, ''), ALL_IN_SHOW), show(0)],
    ),
    'show-refused-outside-the-order': (
        config([200, 200, 200]),
        holes(THREE_HOLES, 3)
        + [refused(show(2), NO_ORDER), refused(muck(2), NO_ORDER)]
        + [fold(2), call(0), call(1)]
        + check_down([0, 1])
        + [refused(show(2), NOT_ACTIVE), refused(muck(2), NOT_ACTIVE)]
        + [refused(show(0, 'AsAhKd'), TOO_MANY)]
        + [refused(show(0, 'As????'), TOO_MANY)]
        + [muck(1), refused(show(1), NOT_ACTIVE), show(0)],
    ),
    # B6: known cards must match, B1 comes first for a repeat inside the list.
    'shown-card-not-dealt': (
        config([100, 100]),
        holes(TWO_HOLES, 2)
        + [call(1), call(0)]
        + check_down([0, 1])
        + [not_dealt(show(0, 'AsQd'), 'Qd')]
        + [not_dealt(show(0, 'Qd'), 'Qd')]
        + [not_dealt(show(0, 'QdAs'), 'Qd')]
        + [not_dealt(show(0, 'Ks'), 'Ks')]
        + [duplicate(show(0, 'AsAs')), duplicate(show(0, 'QdQd'))]
        + [show(0), show(1)],
    ),
    # A reveal may not name a card scanned anywhere else (B1).
    'reveal-of-a-scanned-card': (
        config([100, 100, 100]),
        [deal_hole(0, '??'), deal_hole(1, 'Ks'), deal_hole(2, 'Qs')]
        + [deal_hole(0, 'Ah'), deal_hole(1, 'Kh'), deal_hole(2, 'Qh')]
        + [call(2), call(0), call(1)]
        + street('2c7d9h', burn_card='Jd')
        + [call(0), call(1), call(2)]
        + check_down([0, 1, 2], 'Td', '3s')
        + [muck(2)]
        + [duplicate(show(0, 'KsAh')), duplicate(show(0, '2cAh'))]
        + [duplicate(show(0, 'JdAh')), duplicate(show(0, 'QsAh'))]
        + [duplicate(show(0, 'AhAh')), show(0, 'AdAh'), show(1)],
    ),
    'forgotten-card-revealed-by-another-player': (
        config([200, 200, 200]),
        [deal_hole(0, 'As'), deal_hole(1, '??'), deal_hole(2, 'Qs')]
        + [deal_hole(0, 'Ah'), deal_hole(1, 'Kh'), deal_hole(2, 'Qh')]
        + [call(2), call(0), call(1)]
        + check_down([0, 1, 2])
        + [show(0, 'As')]
        + [duplicate(show(1, 'AhKh'))]
        + [show(1, 'JdKh'), show(2)],
    ),
    'forgotten-card-revealed-after-its-holder-is-killed': (
        config([200, 200]),
        [deal_hole(0, 'As'), deal_hole(1, '??')]
        + [deal_hole(0, 'Ah'), deal_hole(1, 'Kh')]
        + [call(1), call(0)]
        + check_down([0, 1], '2c7d9h', 'Kd', 'Kc')
        + [show(0, 'As'), show(1, 'Kh')]
        + [duplicate(show(1, 'AhKh')), show(1, 'JdKh')],
    ),
    # The show that reveals the card also kills its holder, so the card is in
    # the muck by the time the winner reveals a card of their own.
    'revealed-card-in-the-muck-after-its-holder-is-killed': (
        config([200, 200]),
        holes('????2dAs', 2)
        + [call(1), call(0)]
        + check_down([0, 1], '7c9dJh', 'Qs', '4h')
        + [show(1, 'As'), show(0, '3c2d'), duplicate(show(1, '3cAs'))]
        + [show(1, '5cAs')],
    ),
    'shown-card-forgotten-then-revealed-by-another-player': (
        config([50, 50, 50]),
        [deal_hole(0, 'As'), deal_hole(1, '??'), deal_hole(2, 'Qs')]
        + [deal_hole(0, 'Ah'), deal_hole(1, 'Kh'), deal_hole(2, 'Qh')]
        + [raise_to(2, 50), call(0), call(1)]
        + [select_runouts(0), select_runouts(1), select_runouts(2)]
        + [show(2), show(0, 'As'), show(1, 'Kh')]
        + street('2c7d9h')
        + [show(0, 'As'), show(1, 'Kh')]
        + street('Td')
        + [show(0, 'As'), show(1, 'Kh')]
        + street('3s')
        + [show(0, '')]
        + [duplicate(show(1, 'AsKh'))]
        + [show(1, 'JdKh')],
    ),
    # A forgotten slot refills only with its scanned card.
    'forgetter-shows-after-the-hand': (
        config([200, 200]),
        holes(TWO_HOLES, 2)
        + [call(1), call(0)]
        + check_down([0, 1])
        + [show(0, 'As'), show(1, '')]
        + [refused(show(0), UNKNOWN_SHOWN)]
        + [refused(show(0, 'As'), NON_STANDARD)]
        + [not_dealt(show(0, 'AsKd'), 'Kd'), show(0, 'AhAs')],
    ),
    'another-players-forgotten-card-not-dealt': (
        config([200, 200]),
        holes('KsAsAhKh', 2)
        + [call(1), call(0)]
        + check_down([0, 1])
        + [show(0, 'Ks'), show(1, 'As')]
        + [not_dealt(show(1, 'AsAh'), 'Ah'), show(1, 'AsKh')],
    ),
    # B9: a hand shows only from pushing on, and in full. The show does not
    # touch the chips but does change the results.
    'post-hand-shows-after-completion': (
        config([200, 200, 200]),
        holes(THREE_HOLES, 3)
        + [raise_to(2, 6), fold(0), fold(1)]
        + [refused(show(2, 'Qs'), NON_STANDARD)]
        + [refused(show(2, ''), NON_STANDARD)]
        + [refused(muck(2), NON_STANDARD)]
        + [refused(show(0), NOT_ACTIVE), refused(muck(0), NOT_ACTIVE)]
        + [not_dealt(show(2, 'QsJd'), 'Jd')]
        + [show(2, 'QhQs'), show(2)],
    ),
    'tournament-post-hand-shows': (
        config([200, 200, 200], mode='tournament'),
        holes(THREE_HOLES, 3)
        + [raise_to(2, 6), fold(0), fold(1)]
        + [b9_refusal(show(2, 'Qs'), 'mustShowAllCards')]
        + [b9_refusal(show(2, ''), 'mustShowAllCards')]
        + [refused(muck(2), NON_STANDARD)]
        + [show(2)],
    ),
    # The bare AssertionError of state.py:5538, at every point from pushing on.
    'tournament-fold-out-survivor-holds-an-unknown-card': (
        config([200, 200, 200], mode='tournament', automations=MANUAL_PUSH),
        [deal_hole(0, 'As'), deal_hole(1, 'Ks'), deal_hole(2, '??')]
        + [deal_hole(0, 'Ah'), deal_hole(1, 'Kh'), deal_hole(2, 'Qh')]
        + [raise_to(2, 6), fold(0), fold(1)]
        + [b9_refusal(show(2), 'cannotShowUnknownCard')]
        + [b9_refusal(show(2, 'Qh'), 'mustShowAllCards')]
        + [push()]
        + [b9_refusal(show(2), 'cannotShowUnknownCard')]
        + [pull(2)]
        + [b9_refusal(show(2), 'cannotShowUnknownCard')]
        + [show(2, 'QhQd')],
    ),
    'cash-fold-out-survivor-holds-an-unknown-card': (
        config([200, 200, 200], automations=MANUAL_PUSH),
        [deal_hole(0, 'As'), deal_hole(1, 'Ks'), deal_hole(2, '??')]
        + [deal_hole(0, 'Ah'), deal_hole(1, 'Kh'), deal_hole(2, 'Qh')]
        + [raise_to(2, 6), fold(0), fold(1)]
        + [refused(show(2), UNKNOWN_SHOWN)]
        + [refused(show(2, 'Qh'), NON_STANDARD)]
        + [push(), refused(show(2), UNKNOWN_SHOWN), pull(2)]
        + [refused(show(2), UNKNOWN_SHOWN), show(2, 'QhQd')],
    ),
    # A river shove sets the all-in status, so this one is PokerKit's message.
    'tournament-river-shove-then-a-fold': (
        config([100, 100], mode='tournament'),
        [deal_hole(0, '??'), deal_hole(1, 'Ks')]
        + [deal_hole(0, 'Ah'), deal_hole(1, 'Kh')]
        + [call(1), call(0)]
        + check_down([0, 1], '2c7d9h', 'Td')
        + street('3s')
        + [raise_to(0, 98), fold(1)]
        + [refused(show(0), ALL_IN_SHOW), refused(show(0, 'Ah'), ALL_IN_SHOW)]
        + [show(0, 'AhAd')],
    ),
    'forced-bets-shows-cash': (
        forced_bets_config('cashGame'),
        FORCED_BETS_SHOWS,
    ),
    'forced-bets-shows-tournament': (
        forced_bets_config('tournament'),
        FORCED_BETS_SHOWS,
    ),
    # PokerKit evaluates inside push_chips, so a show between two pushes
    # decides the second.
    'post-hand-show-changes-the-next-push': (
        config([50, 100, 100], automations=MANUAL_PUSH),
        holes(THREE_HOLES, 3)
        + [raise_to(2, 50), call(0), call(1)]
        + street('2c7d9h')
        + [raise_to(1, 10), call(2)]
        + check_down([1, 2], 'Td', '3s')
        + [show(0, ''), show(1, ''), show(2, '')]
        + [push(), refused(show(1), UNKNOWN_SHOWN), show(1, 'KsKh'), push()],
    ),
    'manual-kill-push-pull': (
        config([200, 200, 200], automations=MANUAL_SETTLEMENT),
        holes(THREE_HOLES, 3)
        + [call(2), call(0), call(1)]
        + check_down([0, 1, 2])
        + [refused(kill(0), 'Nobody can kill their hand.')]
        + [refused(push(), 'The chip pushing is not allowed.')]
        + [refused(pull(0), 'No one can pull chips.')]
        + [show(0), show(1), show(2)]
        + [refused(show(0), NO_ORDER), refused(muck(1), NO_ORDER)]
        + [refused(kill(0), 'The Player 0 cannot kill their hand.')]
        + [kill(2), kill(1)]
        + [refused(kill(1), 'Nobody can kill their hand.')]
        + [refused(show(1), NOT_ACTIVE)]
        + [refused(pull(0), 'No one can pull chips.')]
        + [push()]
        + [refused(push(), 'The chip pushing is not allowed.')]
        + [refused(pull(1), 'There is no chip to be pulled.')]
        + [pull(0)],
    ),
    'split-pot-pulled-in-any-order': (
        config([200, 200, 200], automations=MANUAL_PULL),
        holes('2c3c2d3d2h3h', 3)
        + [call(2), call(0), call(1)]
        + check_down([0, 1, 2], 'AsKsQs', 'Js', 'Ts')
        + [show(0), show(1), show(2)]
        + [pull(2), pull(0), pull(1)],
    ),
    # A12: the remainder of 7 chips over 3 goes to the lowest index.
    'odd-chip-to-the-lowest-index-winner': (
        config([200] * 4),
        holes('2c2d2h4c3c3d3h4d', 4)
        + [call(2), call(3), fold(0), call(1)]
        + check_down([1, 2, 3], 'AsKsQs', 'Js', 'Ts')
        + [show(1), show(2), show(3)],
    ),
    # A12: the whole remainder of 8 chips over 3 goes to the lowest index.
    'whole-remainder-to-the-lowest-index-winner': (
        config([200] * 4),
        holes(FOUR_HOLES, 4)
        + [call(2), call(3), call(0), fold(1)]
        + check_down([0, 2, 3], 'TdJdQd', 'Kd', 'Ad')
        + [show(0), show(2), show(3)],
    ),
    # Antes that no blind can call are dead money, and folded chips stay in.
    'folded-chips-and-dead-antes-in-the-pot': (
        config([200] * 4, antes=[0, 5]),
        holes(FOUR_HOLES, 4)
        + [raise_to(2, 6), fold(3), call(0), fold(1)]
        + check_down([0, 2])
        + [show(0), show(2)],
    ),
    # A12: the last player left is paid with no runout and no evaluation. Every
    # layer then has the same eligible player, so the side pot has merged.
    'single-survivor-takes-the-merged-pot': (
        config([50, 200, 200], automations=MANUAL_PUSH),
        holes(THREE_HOLES, 3)
        + [raise_to(2, 50), call(0), call(1)]
        + street('2c7d9h')
        + [raise_to(1, 10), call(2)]
        + check_down([1, 2], 'Td', '3s')
        + [muck(0), muck(1), abandons(muck(2), 0), show(2)]
        + [push(), refused(push(), 'The chip pushing is not allowed.')]
        + [pull(2)],
    ),
    # B2 as test_unknown_showdown: PokerKit lets the third muck lose the pot.
    'last-muck-would-abandon-the-pot': (
        config([200] * 3),
        holes('??' * 6, 3)
        + [call(2), call(0), call(1)]
        + check_down([0, 1, 2], 'TsJsQs', 'Ks', 'As')
        + [muck(0), muck(1), abandons(muck(2), 0), show(2, '2c3c')],
    ),
    # Mucks lose eligibility at once, and the side pot's last player may not
    # muck although another player still contests the main pot.
    'muck-would-abandon-a-side-pot': (
        config([50, 200, 200]),
        holes(THREE_HOLES, 3)
        + [raise_to(2, 50), call(0), call(1)]
        + street('2c7d9h')
        + [raise_to(1, 10), call(2)]
        + check_down([1, 2], 'Td', '3s')
        + [muck(1), abandons(muck(2), 1), show(2), show(0)],
    ),
    # D: B2 comes after PokerKit's refusals. Only player 0 can win the side
    # pot, so a muck would abandon it, but one is refused out of the order
    # and again once the order is empty.
    'muck-refused-for-its-timing-before-b2': (
        config([100, 20, 100]),
        holes(THREE_HOLES, 3)
        + [raise_to(2, 100), call(0), call(1), muck(2), show(0)]
        + [refused(muck(0), 'The Player 0 cannot perform a showdown.')]
        + [show(1), refused(muck(0), NO_ORDER)],
    ),
    # B2 comes after the refusal with no street as well.
    'muck-refused-during-forced-bets-before-b2': (
        config(
            [200, 200, 200], antes=[0, 2], blinds=[9, 2],
            automations=(
                'antePosting', 'betCollection', 'handKilling',
                'chipsPushing', 'chipsPulling',
            ),
        ),
        [post_blind(1), refused(muck(1), NON_STANDARD), post_blind(0)],
    ),
    # Folded posts stay in play, so the last fold that leaves them behind is
    # refused, and the refusal can land on a later player.
    'b2-two-equal-live-posts': (
        config([200] * 4, blinds=[1, 2, -3, -3]),
        holes(FOUR_HOLES, 4)
        + [fold(2), fold(3), abandons(fold(0), 1), call(0), call(1)],
    ),
    'b2-two-unequal-live-posts': (
        config([200] * 4, blinds=[1, 2, -4, -3]),
        holes(FOUR_HOLES, 4)
        + [fold(2), fold(3), abandons(fold(0), 1), call(0), call(1)],
    ),
    'b2-fold-accepted-at-a-large-call': (
        config([200, 200, 200, 100], blinds=[1, 2, -150, -3]),
        holes(FOUR_HOLES, 4)
        + [fold(2), fold(3), abandons(fold(0), 1), call(0), call(1)],
    ),
    'b2-short-blinds-below-two-live-posts': (
        config([2, 2, 200, 200], blinds=[1, 2, -3, -3]),
        holes(FOUR_HOLES, 4)
        + [fold(2), abandons(fold(3), 1), call(3), call(0)],
    ),
    # Unlike the two posts above, a lone folded post's top comes back, so the
    # fold stands. The folder is not one of the callers: only its own chips
    # could have matched the post, and counting them would strand that layer.
    'b2-fold-below-a-folded-live-post': (
        config([2, 2, 200, 200], blinds=[1, 2, -10]),
        holes(FOUR_HOLES, 4)
        + [fold(2), fold(3), call(0)],
    ),
    # The refused player could never reach the layer: its call is what gives
    # the big blind a turn.
    'b2-refused-player-too-short-for-the-layer': (
        config([2, 200, 200, 200], blinds=[1, 2, -3, -3]),
        holes(FOUR_HOLES, 4)
        + [fold(2), fold(3), abandons(fold(0), 1), call(0), call(1)],
    ),
    # The last player's bet stays out, below every collected bet, so the bottom
    # layer holds no chips and is no pot: the one left behind is the main pot.
    'b2-pot-index-with-a-player-who-bet-nothing': (
        config([200] * 4, blinds=[0, 2, -5, -5]),
        holes(FOUR_HOLES, 4)
        + [fold(2), fold(3), abandons(fold(0), 0), call(0), call(1)],
    ),
    # Manual pushing shows the single pot, with the winner's 5 uncollected.
    'b2-refusal-then-a-fold-out': (
        config([100] * 5, blinds=[1, 2, -5, -4, 0], automations=MANUAL_PUSH),
        holes('AsKsQsJsTsAhKhQhJhTh', 5)
        + [fold(2), fold(3), fold(4), abandons(fold(0), 1)]
        + [call(0), fold(1)],
    ),
    'b2-mid-round-refusal': (
        config([3, 3, 100, 100, 3], blinds=[1, 2, -5, -4, 0]),
        holes('AsKsQsJsTsAhKhQhJhTh', 5)
        + [fold(2), abandons(fold(3), 1), call(3)],
    ),
    'b2-straddler-free-fold': (
        config([100, 100, 100, 3], blinds=[2, 4, 8]),
        holes(FOUR_HOLES, 4)
        + [call(3), fold(0), fold(1), abandons(fold(2), 1), call(2)],
    ),
    # A tournament refuses a free fold first, whatever pot it would abandon.
    'b2-tournament-free-fold-refused-first': (
        config([100, 100, 100, 3], mode='tournament', blinds=[2, 4, 8]),
        holes(FOUR_HOLES, 4)
        + [call(3), fold(0), fold(1)]
        + [refused(fold(2), 'There is no reason for this player to fold.')]
        + [call(2)],
    ),
    # A15 and B3: the survivor's chips behind would make PokerKit assert when
    # the next street's betting begins.
    'concession-with-chips-behind': (
        config([100, 300]),
        holes(TWO_HOLES, 2)
        + [raise_to(1, 100), call(0)]
        + [select_runouts(1), select_runouts(0), muck(0)]
        + [abandons(muck(1), 0), show(1)]
        + street('2c7d9h'),
    ),
    # B4: the operation whose cascade reaches evaluation is the one refused,
    # whatever its own card is.
    'unknown-board-final-river-deal': (
        config([100, 100]),
        holes(TWO_HOLES, 2)
        + [raise_to(1, 100), call(0)]
        + [select_runouts(0), select_runouts(1), show(1), show(0)]
        + [burn('??'), deal_board('2c'), deal_board('??'), deal_board('9h')]
        + street('Td')
        + [burn('??'), unknown_board(deal_board('3s'), 1)],
    ),
    'unknown-board-river-deal-itself': (
        config([100, 100]),
        holes(TWO_HOLES, 2)
        + [raise_to(1, 100), call(0)]
        + [select_runouts(0), select_runouts(1), show(1), show(0)]
        + street('2c7d9h')
        + street('Td')
        + [burn('??'), unknown_board(deal_board('??'), 4)],
    ),
    'unknown-board-last-river-show': (
        config([100, 100]),
        holes(TWO_HOLES, 2)
        + [call(1), call(0)]
        + check_down([0, 1], '??7d9h', 'Td', '3s')
        + [show(0), unknown_board(show(1), 0)],
    ),
    'unknown-board-last-partial-show': (
        config([100, 100]),
        holes(TWO_HOLES, 2)
        + [call(1), call(0)]
        + check_down([0, 1], '2c7d9h', 'Td', '??')
        + [show(0), unknown_board(show(1, 'Ks'), 4)],
    ),
    'unknown-board-last-empty-show': (
        config([100, 100]),
        holes(TWO_HOLES, 2)
        + [call(1), call(0)]
        + check_down([0, 1], '2c??9h', 'Td', '3s')
        + [show(0), unknown_board(show(1, ''), 1)],
    ),
    'unknown-board-last-muck-of-three': (
        config([100, 100, 100]),
        holes(THREE_HOLES, 3)
        + [call(2), call(0), call(1)]
        + check_down([0, 1, 2], '??7d9h', 'Td', '3s')
        + [show(0), show(1), unknown_board(muck(2), 0)],
    ),
    # A hand kept face down is asked again on the river, so that deal is fine
    # and the last show takes the refusal.
    'unknown-board-river-reask': (
        config([100, 100]),
        holes(TWO_HOLES, 2)
        + [raise_to(1, 100), call(0)]
        + [select_runouts(0), select_runouts(1), show(1), show(0, '')]
        + street('??7d9h')
        + [show(0, '')]
        + street('Td')
        + [show(0, '')]
        + street('3s')
        + [unknown_board(show(0), 0)],
    ),
    # Betting and collection only reach the show order.
    'unknown-board-river-call-and-collection': (
        config(
            [100, 100],
            automations=('antePosting', 'blindOrStraddlePosting')
            + BOOKKEEPING[3:],
        ),
        holes(TWO_HOLES, 2)
        + [call(1), call(0), collect()]
        + check_down([0, 1], '??7d9h', 'Td')
        + street('3s')
        + [raise_to(0, 10), call(1), collect()]
        + [show(0), unknown_board(show(1), 0)],
    ),
    # Before the river the last selection and the last show just move on.
    'unknown-board-last-selection-moves-on': (
        config([100, 100]),
        holes(TWO_HOLES, 2)
        + [call(1), call(0)]
        + check_down([0, 1], '2c??9h')
        + street('Td')
        + [raise_to(0, 98), call(1)]
        + [show(0), show(1), select_runouts(0), select_runouts(1)]
        + [burn('??'), unknown_board(deal_board('3s'), 1)],
    ),
    'unknown-board-last-show-moves-on': (
        config([100, 100]),
        holes(TWO_HOLES, 2)
        + [call(1), call(0)]
        + check_down([0, 1], '2c??9h')
        + street('Td')
        + [raise_to(0, 98), call(1)]
        + [select_runouts(0), select_runouts(1), show(0), show(1)]
        + [burn('??'), unknown_board(deal_board('3s'), 1)],
    ),
    # A lone survivor is paid without evaluation, so B4 never fires.
    'unknown-board-last-show-leaves-one-player': (
        config([100, 100]),
        holes(TWO_HOLES, 2)
        + [call(1), call(0)]
        + check_down([0, 1], '??7d9h', 'Td', '3s')
        + [muck(0), show(1)],
    ),
    'unknown-board-last-muck-leaves-one-player': (
        config([100, 100]),
        holes(TWO_HOLES, 2)
        + [call(1), call(0)]
        + check_down([0, 1], '??7d9h', 'Td', '3s')
        + [show(1), muck(0)],
    ),
    'unknown-river-after-a-concession': (
        config([100, 100]),
        holes(TWO_HOLES, 2)
        + [call(1), call(0)]
        + check_down([0, 1], '2c7d9h')
        + street('Td')
        + [raise_to(0, 98), call(1)]
        + [select_runouts(0), select_runouts(1), muck(1), show(0)]
        + [burn('??'), deal_board('??')],
    ),
    'unknown-board-river-fold-out': (
        config([100, 100]),
        holes(TWO_HOLES, 2)
        + [call(1), call(0)]
        + check_down([0, 1], '??7d9h', 'Td')
        + street('3s')
        + [raise_to(0, 10), fold(1)],
    ),
    'everything-but-a-show-refused-after-completion': (
        config([200, 200]),
        holes(TWO_HOLES, 2)
        + [fold(1)]
        + [refused(post_ante(0), 'Nobody can post the ante.')]
        + [refused(collect(), 'The bet collection is currently prohibited.')]
        + [refused(post_blind(0), 'Nobody can post the blind or straddle.')]
        + [refused(burn('??'), 'No card burning is pending.')]
        + [
            refused(
                deal_hole(0, '??'),
                'Currently, nobody can be dealt hole cards.',
            ),
        ]
        + [refused(deal_board('??'), 'No board dealing is pending.')]
        + [refused(fold(0), 'There is no player to act.')]
        + [refused(call(0), 'There is no player to act.')]
        + [refused(raise_to(0, 10), 'There is no player to act.')]
        + [refused(select_runouts(0), NOBODY_SELECTS)]
        + [refused(kill(0), 'Nobody can kill their hand.')]
        + [refused(push(), 'The chip pushing is not allowed.')]
        + [refused(pull(0), 'No one can pull chips.')],
    ),
}


def streets(*cards: str) -> list[dict]:
    """Each string burned for and dealt, as a street of a runout."""
    return [operation for dealt in cards for operation in street(dealt)]


def select_all(players: int, count: int | None) -> list[dict]:
    return [select_runouts(player, count) for player in range(players)]


def heads_up_flop_all_in() -> list[dict]:
    """AA against KK, all in on a flop of 2c7d9h with nothing yet chosen."""
    return (
        holes(TWO_HOLES, 2)
        + [call(1), call(0)]
        + street('2c7d9h')
        + [raise_to(0, 98), call(1)]
    )


def three_way_preflop_all_in() -> list[dict]:
    """AA, KK and QQ, all in before the flop with nothing yet chosen."""
    return holes(THREE_HOLES, 3) + [raise_to(2, 100), call(0), call(1)]


def unknown_kings_flop_all_in() -> list[dict]:
    """``heads_up_flop_all_in`` with player 1's cards never scanned."""
    return (
        holes('As??Ah??', 2)
        + [call(1), call(0)]
        + street('2c7d9h')
        + [raise_to(0, 98), call(1)]
    )


def kept_down(player: int, *cards: str) -> list[dict]:
    """Each street dealt with ``player`` keeping cards down after all but the
    last, where the hand stands at its final showdown."""
    operations = []

    for dealt in cards[:-1]:
        operations += street(dealt) + [show(player, '')]

    return operations + street(cards[-1])


def forty_four_runs() -> list[dict]:
    """Every card left in the deck, each the river of a run from the turn."""
    held = split(TWO_HOLES) + ['2c', '7d', '9h', 'Td']
    rivers = [repr(card) for card in Deck.STANDARD if repr(card) not in held]

    return (
        holes(TWO_HOLES, 2)
        + [call(1), call(0)]
        + check_down([0, 1], '2c7d9h')
        + street('Td')
        + [raise_to(0, 98), call(1)]
        + select_all(2, 44)
        + [show(0), show(1)]
        + streets(*rivers)
    )


def deck_run_out() -> list[dict]:
    """Ten runouts for two players: 47 cards are left after a known burn."""
    held = split(TWO_HOLES) + ['2c']
    cards = [repr(card) for card in Deck.STANDARD if repr(card) not in held]
    runouts = [
        streets(''.join(cards[i:i + 3]), cards[i + 3], cards[i + 4])
        for i in range(0, 45, 5)
    ]
    runouts[0][0] = burn('2c')

    return (
        holes(TWO_HOLES, 2)
        + [raise_to(1, 100), call(0)]
        + select_all(2, 10)
        + [show(0), show(1)]
        + [operation for runout in runouts for operation in runout]
        + street(f'{cards[45]}{cards[46]}??')
        + [duplicate(burn('2c')), burn('??')]
        + [duplicate(deal_board('2c')), deal_board('??')]
        + [burn('??'), unknown_board(deal_board('??'), 2, runout=9)]
    )


# A10, A11 and A12 on more than one board. AA against KK with both hands shown
# unless a scenario says otherwise, so each string below names who wins a run:
# 2c7d9hTd3s goes to the aces, 2c7d9hKcQd to the kings.
RUNOUT_SCENARIOS = {
    'run-it-twice-from-the-flop': (
        config([100, 100]),
        heads_up_flop_all_in()
        + [select_runouts(1, 2), select_runouts(0, 2), show(0), show(1)]
        + [refused(deal_board('Td'), BURN_FIRST)]
        + streets('Td', '3s', 'Kc', 'Qd'),
    ),
    # Main pot 90 and side pot 40 over three runs: 14, 13, 13 of the side pot.
    'run-it-three-times-with-a-side-pot': (
        config([100, 50, 30]),
        holes(THREE_HOLES, 3)
        + [raise_to(2, 30), raise_to(0, 100), call(1)]
        + select_all(3, 3)
        + [show(0), show(1), show(2)]
        + streets('2c7d9h', 'Td', '3s', 'Qc4c5d', '8h', 'Jd')
        + streets('Kc6c6d', '8d', '2d'),
    ),
    'run-it-three-times-from-the-turn': (
        config([100, 100]),
        holes(TWO_HOLES, 2)
        + [call(1), call(0)]
        + check_down([0, 1], '2c7d9h')
        + street('Td')
        + [raise_to(0, 98), call(1)]
        + [select_runouts(0, 3), select_runouts(1), show(0), show(1, '')]
        + street('3s')
        + [refused(burn('Kc'), NO_BURN), show(1, '')]
        + street('Kc')
        + [show(1, '')]
        + street('Qd')
        + [show(1)],
    ),
    'abstaining-agrees-with-a-count': (
        config([100, 100, 100]),
        three_way_preflop_all_in()
        + [select_runouts(0), select_runouts(1, 2), select_runouts(2)]
        + [show(0), show(1), show(2)],
    ),
    # Once the table has disagreed, a later match with the first count is
    # still a disagreement.
    'disagreement-runs-once': (
        config([100, 100, 100]),
        three_way_preflop_all_in()
        + [select_runouts(0, 2), select_runouts(1, 3), select_runouts(2, 2)]
        + [show(0), show(1), show(2)],
    ),
    'two-against-one-runs-once': (
        config([100, 100]),
        heads_up_flop_all_in()
        + [select_runouts(0, 2), select_runouts(1, 1), show(0), show(1)],
    ),
    'everyone-choosing-one-run': (
        config([100, 100]),
        heads_up_flop_all_in()
        + select_all(2, 1)
        + [show(0), show(1)],
    ),
    'count-takes-effect-when-the-first-showdown-ends': (
        config([100, 100, 100]),
        three_way_preflop_all_in()
        + [show(0), show(1), select_runouts(0, 2), show(2)]
        + [select_runouts(1), select_runouts(2, 2)],
    ),
    # A10: a player who mucks has still chosen, for everyone else.
    'mucked-player-sets-the-count': (
        config([100, 100, 100]),
        three_way_preflop_all_in()
        + [muck(2), select_runouts(2, 2), select_runouts(0), select_runouts(1)]
        + [show(0), show(1)]
        + streets('2c7d9h', 'Td', '3s', 'Kc4c5d', '8h', 'Jd'),
    ),
    # 19 chips with a dead ante: 10 on the first run, 9 on the second.
    'remainder-goes-to-the-first-run': (
        config([10, 10], antes=(1, 0)),
        holes(TWO_HOLES, 2)
        + [raise_to(1, 9), call(0)]
        + select_all(2, 2)
        + [show(0), show(1)]
        + streets('2c7d9h', 'Td', '3s', 'Kc4c5d', '8h', 'Jd'),
    ),
    # A 1-chip pot has nothing to push on the second run, which the queens
    # win. They take nothing, and the aces take the rest.
    'one-chip-pot-on-two-runs': (
        config([100, 100, 1], antes=(0, 0, 1)),
        holes(THREE_HOLES, 3)
        + [raise_to(0, 100), call(1)]
        + select_all(3, 2)
        + [show(0), show(1), show(2)]
        + streets('2c7d9h', 'Td', '3s', 'Qc4c5d', '8h', 'Jd'),
    ),
    'scoop-is-paid-as-a-single-survivor': (
        config([100, 100]),
        heads_up_flop_all_in()
        + select_all(2, 2)
        + [show(0), show(1)]
        + streets('Td', '3s', '4c', '5d'),
    ),
    'loser-of-both-runs-is-killed': (
        config([100, 100, 100]),
        three_way_preflop_all_in()
        + select_all(3, 2)
        + [show(0), show(1), show(2)]
        + streets('2c7d9h', 'Td', '3s', 'Kc4c5d', '8h', 'Jd'),
    ),
    'manual-kill-after-two-runs': (
        config([100, 100, 100], automations=MANUAL_SETTLEMENT),
        three_way_preflop_all_in()
        + select_all(3, 2)
        + [show(0), show(1), show(2)]
        + streets('2c7d9h', 'Td', '3s', 'Kc4c5d', '8h', 'Jd')
        + [refused(push(), 'The chip pushing is not allowed.'), kill(2)],
    ),
    'tie-on-one-run': (
        config([100, 100]),
        holes(TWO_HOLES, 2)
        + [raise_to(1, 100), call(0)]
        + select_all(2, 2)
        + [show(0), show(1)]
        + streets('TcJcQc', 'Kc', 'Ac', '2d7d9h', 'Td', '3s'),
    ),
    # Both hands stay face down to the end, so the first run is chopped, and
    # the show between the pushes takes the second.
    'post-hand-show-changes-a-later-run': (
        config([100, 100], automations=MANUAL_PUSH),
        heads_up_flop_all_in()
        + select_all(2, 2)
        + [show(0, ''), show(1, '')]
        + street('Td')
        + [show(0, ''), show(1, '')]
        + street('3s')
        + [show(0, ''), show(1, '')]
        + street('Kc')
        + [show(0, ''), show(1, '')]
        + street('Qd')
        + [show(0, ''), show(1, '')]
        + [push(), show(1, 'KsKh'), push()],
    ),
    # A9: a hand kept face down is asked again after every street of every
    # run, the street having gone back; the river of a run that is not the
    # last has no showdown, and only the last one forgets cards.
    'reask-through-two-runs': (
        config([100, 100]),
        heads_up_flop_all_in()
        + select_all(2, 2)
        + [show(0), show(1, '')]
        + street('Td')
        + [show(1, 'Ks')]
        + street('3s')
        + [refused(burn('Kc'), NO_BURN), show(1, '')]
        + street('Kc')
        + [show(1, 'Kh')]
        + street('Qd')
        + [show(1, '')],
    ),
    # A15: a concession still deals the next street, but no more.
    'concession-before-the-first-run': (
        config([100, 100]),
        heads_up_flop_all_in()
        + select_all(2, 2)
        + [show(0), muck(1)]
        + street('Td'),
    ),
    'concession-with-the-count-still-to-choose': (
        config([100, 100]),
        heads_up_flop_all_in()
        + [show(0), muck(1), select_runouts(0, 2), select_runouts(1)]
        + street('Td'),
    ),
    'concession-on-the-last-street-of-a-run': (
        config([100, 100]),
        heads_up_flop_all_in()
        + select_all(2, 2)
        + [show(0), show(1, '')]
        + street('Td')
        + [muck(1)]
        + street('3s'),
    ),
    'concession-between-runs': (
        config([100, 100]),
        heads_up_flop_all_in()
        + select_all(2, 2)
        + [show(0), show(1, '')]
        + street('Td')
        + [show(1, '')]
        + street('3s')
        + [muck(1)]
        + street('Kc'),
    ),
    'unknown-card-on-a-concession-board': (
        config([100, 100]),
        heads_up_flop_all_in()
        + select_all(2, 2)
        + [show(0), show(1, '')]
        + street('Td')
        + [show(1, '')]
        + street('3s')
        + [muck(1)]
        + street('??'),
    ),
    'b2-muck-refused-between-runs': (
        config([100, 100, 50]),
        holes(THREE_HOLES, 3)
        + [raise_to(2, 50), raise_to(0, 100), call(1)]
        + select_all(3, 2)
        + [show(0, ''), show(1, ''), show(2)]
        + street('2c7d9h')
        + [muck(0), show(1, '')]
        + street('Td')
        + [abandons(muck(1), 1), show(1, '')]
        + street('3s')
        + [abandons(muck(1), 1), show(1, '')],
    ),
    # B1 reaches every run. A burn is a known card like any other.
    'duplicate-from-another-run': (
        config([100, 100]),
        heads_up_flop_all_in()
        + select_all(2, 2)
        + [show(0), show(1)]
        + streets('Td', '3s')
        + [duplicate(burn('Td')), burn('8d')]
        + [duplicate(deal_board('3s')), duplicate(deal_board('8d'))]
        + [deal_board('Kc'), burn('2d'), deal_board('Qd')],
    ),
    # B4 with the runs' board positions: the last deal of the last run is
    # refused, whichever run holds the card.
    'unknown-card-on-the-last-run': (
        config([100, 100]),
        heads_up_flop_all_in()
        + select_all(2, 2)
        + [show(0), show(1)]
        + streets('Td', '3s', 'Kc')
        + [burn('??'), unknown_board(deal_board('??'), 4, runout=1)],
    ),
    'unknown-card-on-the-first-run': (
        config([100, 100]),
        heads_up_flop_all_in()
        + select_all(2, 2)
        + [show(0), show(1)]
        + streets('Td', '??', 'Kc')
        + [burn('??'), unknown_board(deal_board('Qd'), 4)],
    ),
    'unknown-shared-card-before-two-runs': (
        config([100, 100]),
        holes(TWO_HOLES, 2)
        + [call(1), call(0)]
        + street('2c??9h')
        + [raise_to(0, 98), call(1)]
        + select_all(2, 2)
        + [show(0), show(1)]
        + streets('Td', '3s', 'Kc')
        + [burn('??'), unknown_board(deal_board('Qd'), 1)],
    ),
    # The first run's card comes first, though its position is the later one.
    'unknown-cards-on-two-runs': (
        config([100, 100]),
        heads_up_flop_all_in()
        + select_all(2, 2)
        + [show(0), show(1)]
        + streets('Td', '??', '??')
        + [burn('??'), unknown_board(deal_board('Qd'), 4)],
    ),
    # B4's other two operations: the last show and the last muck.
    'unknown-card-refuses-the-last-show': (
        config([100, 100]),
        heads_up_flop_all_in()
        + select_all(2, 2)
        + [show(0), show(1, '')]
        + kept_down(1, 'Td', '3s', 'Kc', '??')
        + [unknown_board(show(1), 4, runout=1)],
    ),
    'unknown-card-refuses-the-last-muck': (
        config([100, 100, 100]),
        three_way_preflop_all_in()
        + select_all(3, 2)
        + [show(0), show(1), show(2, '')]
        + kept_down(2, '2c7d9h', 'Td', '3s', 'Kc4c5d', '8h', '??')
        + [unknown_board(muck(2), 4, runout=1)],
    ),
    # B4: a last muck leaves one player, who is paid whichever board holds
    # the card. PokerKit raises ``KeyError`` for all but the later run.
    'lone-survivor-unknown-later-run': (
        config([100, 100]),
        heads_up_flop_all_in()
        + select_all(2, 2)
        + [show(0), show(1, '')]
        + kept_down(1, 'Td', '3s', 'Kc', '??')
        + [muck(1)],
    ),
    'lone-survivor-unknown-first-run': (
        config([100, 100]),
        heads_up_flop_all_in()
        + select_all(2, 2)
        + [show(0), show(1, '')]
        + kept_down(1, 'Td', '??', 'Kc', 'Qd')
        + [muck(1)],
    ),
    'lone-survivor-unknown-shared-card': (
        config([100, 100]),
        holes(TWO_HOLES, 2)
        + [call(1), call(0)]
        + street('2c??9h')
        + [raise_to(0, 98), call(1)]
        + select_all(2, 2)
        + [show(0), show(1, '')]
        + kept_down(1, 'Td', '3s', 'Kc', 'Qd')
        + [muck(1)],
    ),
    # A card dealt ``??`` can be revealed between runs, one at a time, and
    # B1 reaches into every run and the burns.
    'reveal-between-runs': (
        config([100, 100]),
        unknown_kings_flop_all_in()
        + select_all(2, 2)
        + [show(0), show(1, '')]
        + street('Td')
        + [show(1, '')]
        + street('3s')
        + [refused(show(1), UNKNOWN_SHOWN), show(1, 'Ks')]
        + street('Kc')
        + [show(1, 'KsKh')]
        + street('Qd'),
    ),
    'reveal-naming-a-card-on-another-run': (
        config([100, 100]),
        unknown_kings_flop_all_in()
        + select_all(2, 2)
        + [show(0), show(1, '')]
        + street('Td')
        + [show(1, '')]
        + street('3s', '8d')
        + [duplicate(show(1, '3s')), duplicate(show(1, '8d')), show(1, '')]
        + street('Kc')
        + [duplicate(show(1, 'Kc')), duplicate(show(1, 'Td')), show(1, 'Qs')]
        + street('Qd')
        + [show(1, 'QsJc')],
    ),
    'reveal-at-the-last-river': (
        config([100, 100]),
        unknown_kings_flop_all_in()
        + select_all(2, 2)
        + [show(0), show(1, '')]
        + kept_down(1, 'Td', '3s', 'Kc', 'Qd')
        + [show(1, 'KsKh')],
    ),
    'post-hand-reveal-changes-a-later-run': (
        config([100, 100], automations=MANUAL_PUSH),
        unknown_kings_flop_all_in()
        + select_all(2, 2)
        + [show(0, ''), show(1, '')]
        + street('Td')
        + [show(0, ''), show(1, '')]
        + street('3s')
        + [show(0, ''), show(1, '')]
        + street('Kc')
        + [show(0, ''), show(1, '')]
        + street('Qd')
        + [show(0, ''), show(1, '')]
        + [push(), show(1, 'KsKh'), push()],
    ),
    # B3 between runs: the survivor still has chips, so PokerKit asserts.
    'concession-with-chips-behind-between-runs': (
        config([200, 100]),
        holes(TWO_HOLES, 2)
        + [call(1), call(0)]
        + street('2c7d9h')
        + [raise_to(0, 198), call(1)]
        + select_all(2, 2)
        + [show(0), show(1, '')]
        + street('Td')
        + [show(1, '')]
        + street('3s')
        + [muck(1)]
        + street('Kc'),
    ),
    # With every hole card scanned, as many runs as the deck can fill.
    'forty-four-runs': (config([100, 100]), forty_four_runs()),
    # B5: every count up to a deck's worth of cards is taken. PokerKit takes
    # more.
    'count-above-the-maximum-refused': (
        config([100, 100]),
        heads_up_flop_all_in()
        + [too_many_runouts(select_runouts(0, MAXIMUM_RUNOUT_COUNT + 1))]
        + [select_runouts(0, MAXIMUM_RUNOUT_COUNT), select_runouts(1, 1)]
        + [show(0), show(1)],
    ),
    # B1: PokerKit shuffles the known burn back in once its deck is empty, and
    # the engine does not. Only ``??`` is left to deal, which ends in B4.
    'deck-runs-out-during-runs': (config([100, 100]), deck_run_out()),
    # READMETestCase.test_hellmuth_wiggins, with stacks of 10^7 for the
    # players it gives ``inf``.
    'hellmuth-wiggins-four-runs': (
        config(
            [10**7, 116400, 86900, 10**7, 50000, 10**7],
            antes=(0, 0, 0, 0, 0, 600),
            blinds=(200, 400, 800),
            min_bet=400,
        ),
        holes('JsAhKs5c6h6sTh9dKc2h5h3s', 6)
        + [fold(3), raise_to(4, 2800), fold(5), call(0), raise_to(1, 12600)]
        + [call(2), call(4), call(0)]
        + street('9hTs9s')
        + [call(0), raise_to(1, 17000), raise_to(2, 36000), fold(4), fold(0)]
        + [raise_to(1, 103800), call(2)]
        + [select_runouts(1, 4), select_runouts(2), show(1), show(2)]
        + streets('Jh', 'Ad', 'Kh', '3c', '7s', '8s', 'Qc', 'Kd'),
    ),
}


OMAHA = 'potLimitOmahaHoldem'
# Four aces, four kings and four queens, one card to each player in turn.
OMAHA_THREE_HOLES = 'AsKsQsAhKhQhAdKdQdAcKcQc'
OMAHA_TWO_HOLES = 'AsKsAhKhAdKdAcKc'


def above_maximum(operation: dict, maximum: int) -> dict:
    return refused(
        operation,
        f'The amount {operation["to"]} is above the maximum allowed'
        f' {maximum}.',
    )


OMAHA_SCENARIOS = {
    # The largest bet or raise is a call plus the pot after it.
    'omaha-pot-limit-raises': (
        config([200, 200, 200], variant=OMAHA),
        holes(OMAHA_THREE_HOLES, 3)
        + [above_maximum(raise_to(2, 8), 7), raise_to(2, 7)]
        + [above_maximum(raise_to(0, 24), 23), raise_to(0, 23)]
        + [call(1), call(2)]
        + street('2c7d9h')
        + [above_maximum(raise_to(0, 70), 69), raise_to(0, 69)],
    ),
    # A short stack caps the raise, and a minimum above the pot-sized raise
    # is the maximum too.
    'omaha-pot-limit-short-stack': (
        config([200, 200, 5], variant=OMAHA),
        holes(OMAHA_THREE_HOLES, 3)
        + [above_maximum(raise_to(2, 6), 5), raise_to(2, 5)],
    ),
    'omaha-pot-limit-large-min-bet': (
        config([200, 200, 200], min_bet=10, variant=OMAHA),
        holes(OMAHA_THREE_HOLES, 3)
        + [above_maximum(raise_to(2, 13), 12), raise_to(2, 12)],
    ),
    # Exactly two hole cards: four aces make one pair and lose to a flush
    # made with two spades.
    'omaha-four-aces-lose-to-two-spades': (
        config([100, 100], variant=OMAHA),
        holes('AsKsAhQsAd2cAc3d', 2)
        + [call(1), call(0)]
        + check_down([0, 1], '7s9sTs', '4h', '2h')
        + [show(0), show(1)],
    ),
    # B2: on the river a hand kept face down is forgotten and makes no hand,
    # so the answer that leaves a pot with no possible winner is refused.
    'omaha-kept-hands-cannot-abandon-the-pot': (
        config([100, 100], variant=OMAHA),
        holes(OMAHA_TWO_HOLES, 2)
        + [call(1), call(0)]
        + check_down([0, 1], '2d7h9s', 'Th', '3d')
        + [show(0, ''), abandons(show(1, ''), 0), abandons(show(1, 'Ks'), 0)]
        + [muck(1)],
    ),
    'omaha-muck-refused-after-two-dead-hands': (
        config([200, 200, 200], variant=OMAHA),
        holes(OMAHA_THREE_HOLES, 3)
        + [call(2), call(0), call(1)]
        + check_down([0, 1, 2], '2d7h9s', 'Th', '3d')
        + [show(0, ''), show(1, 'Kh'), abandons(muck(2), 0), show(2, 'QsQh')],
    ),
    # The answer that loses a side pot for certain is the one refused, though
    # the all-in player has still to show for the main pot.
    'omaha-dead-hands-in-a-side-pot': (
        config([8, 200, 200], variant=OMAHA),
        holes(OMAHA_THREE_HOLES, 3)
        + [call(2), raise_to(0, 8), call(1), call(2)]
        + street('2d7h9s')
        + [raise_to(1, 10), call(2)]
        + check_down([1, 2], 'Th', '3d')
        + [show(1, ''), abandons(show(2, ''), 1), show(2), show(0)],
    ),
    'omaha-run-twice': (
        config([10, 10], variant=OMAHA),
        holes(OMAHA_TWO_HOLES, 2)
        + [raise_to(1, 6), raise_to(0, 10), call(1)]
        + [select_runouts(0, 2), select_runouts(1, 2), show(0), show(1)],
    ),
    # Cards nobody scanned are revealed by listing them, and a kept hand of
    # them is as dead as any.
    'omaha-unscanned-hole-cards': (
        config([100, 100], variant=OMAHA),
        holes('??Ks??Kh??Kd??Kc', 2)
        + [call(1), call(0)]
        + check_down([0, 1], '2d7h9s', 'Th', '3d')
        + [refused(show(0), UNKNOWN_SHOWN), show(0, 'AsAhAdAc'), show(1)],
    ),
    # test_papers.py's test_antonius_blom_2009 with every amount times 4,
    # since its stacks have quarters, in PokerKit's default tournament mode.
    'omaha-antonius-blom': (
        config(
            [5037801, 2713894], mode='tournament', ante_trimming=True,
            blinds=(2000, 4000), min_bet=4000, variant=OMAHA,
        ),
        holes('Ah6d3s9sKs7dKh8h', 2)
        + [raise_to(1, 12000), raise_to(0, 36000), raise_to(1, 108000)]
        + [raise_to(0, 324000), call(1)]
        + street('4s5c2h')
        + [raise_to(0, 364000), raise_to(1, 1740000)]
        + [raise_to(0, 3116000), call(1), show(0), show(1)]
        + street('5h')
        + street('9c'),
    ),
}


def finishing_operation(state: State) -> dict:
    """The next step of the fixed policy that plays a scenario out."""
    match bridge.phase(state):
        case 'antePosting':
            return post_ante(next(state.ante_poster_indices))
        case 'betCollection':
            return collect()
        case 'blindOrStraddlePosting':
            return post_blind(next(state.blind_or_straddle_poster_indices))
        case 'dealing':
            if state.card_burning_status:
                return burn('??')
            elif state.hole_dealee_index is not None:
                return deal_hole(
                    state.hole_dealee_index, unseen_cards(state)[0],
                )

            return deal_board(unseen_cards(state)[0])
        case 'betting':
            return call(state.actor_index)
        case 'showdown':
            return finishing_show(state)
        case 'handKilling':
            return kill(next(state.hand_killing_indices))
        case 'chipsPushing':
            return push()
        case _:
            return pull(next(state.chips_pulling_indices))


def finishing_show(state: State) -> dict:
    """Selectors abstain; a hand shows as is, or reveals the lowest unseen."""
    if any(state.runout_count_selector_statuses):
        return select_runouts(state.runout_count_selector_statuses.index(True))

    player = state.showdown_indices[0]

    if all(state.hole_cards[player]):
        return show(player)

    dealt = [card for card, _ in bridge.dealt_hole_cards(state)[player]]
    unseen = unseen_cards(state)

    return show(
        player,
        ''.join(unseen.pop(0) if card == '??' else card for card in dealt),
    )


def scenario_hands(stage: str) -> list[dict]:
    hands = []

    for name, (hand_config, operations) in (
            SCENARIOS | SETTLEMENT_SCENARIOS | RUNOUT_SCENARIOS
            | OMAHA_SCENARIOS
    ).items():
        recorder = Recorder(hand_config)

        for operation in operations:
            assert not recorder.stopped, (name, operation)

            listed = {k: v for k, v in operation.items() if k != 'expect'}
            verdict = recorder.play(listed)

            if 'expect' in operation or name not in SCENARIOS:
                expected = operation.get('expect')

                assert verdict == expected, (name, listed, verdict, expected)

        while not recorder.done:
            operation = finishing_operation(recorder.state)
            verdict = recorder.play(operation)

            assert verdict is None or recorder.stopped, (name, operation)

        hands.append(recorder.hand(name, stage))

    return hands
