# /// script
# requires-python = "==3.12.*"
# dependencies = ["pokerkit==0.7.7"]
# ///
"""PokerKit 0.7.7 oracle for the PokerEngine Swift port.

Run from the repository root:

    uv run tools/oracle/generate.py quirks --out tools/oracle/quirks.json
    uv run tools/oracle/generate.py evaluator \\
        --out Tests/PokerEngineTests/Fixtures/evaluator/pokerkit-samples.json
    uv run tools/oracle/generate.py scenarios --stage full \\
        --out Tests/PokerEngineTests/Fixtures/oracle/scenarios.jsonl
    uv run tools/oracle/generate.py hands --stage full \\
        --out Tests/PokerEngineTests/Fixtures/oracle/random.jsonl

A larger soak, read by the Swift harness when POKER_ORACLE_DIR is set:

    uv run tools/oracle/generate.py hands --stage full --seed 7 --pool 10000 \\
        --count 10000 --out .oracle/s7/random.jsonl
    POKER_ORACLE_DIR=.oracle/s7 swift test --filter Oracle
"""

import argparse
import importlib.metadata
import json
import random
from hashlib import md5
from pathlib import Path

from pokerkit import Deck, OmahaHoldemHand, StandardHighHand

import bridge
import hands
import quirks
import scenarios

POKERKIT_VERSION = '0.7.7'


def main() -> None:
    installed = importlib.metadata.version('pokerkit')

    assert installed == POKERKIT_VERSION, f'PokerKit {installed} is installed'

    arguments = parse_arguments()

    if arguments.command in ('scenarios', 'hands'):
        bridge.emulate_deviations()

    if arguments.command == 'quirks':
        write_quirks(arguments.out)
    elif arguments.command == 'scenarios':
        write_hands(arguments.out, scenarios.scenario_hands(arguments.stage))
    elif arguments.command == 'hands':
        chosen, coverage = hands.random_hands(
            arguments.seed, arguments.pool, arguments.count, arguments.stage,
        )
        write_hands(arguments.out, chosen)
        print_coverage(coverage)
    else:
        counts = {
            7: arguments.samples7,
            6: arguments.samples6,
            5: arguments.samples5,
        }
        write_evaluator_samples(
            arguments.out, arguments.seed, counts, arguments.omaha_samples,
        )


def parse_arguments() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description=__doc__,
        formatter_class=argparse.RawDescriptionHelpFormatter,
    )
    commands = parser.add_subparsers(dest='command', required=True)

    quirks_command = commands.add_parser(
        'quirks',
        help='run every open-question probe against PokerKit',
    )
    quirks_command.add_argument('--out', type=Path, required=True)

    evaluator_command = commands.add_parser(
        'evaluator',
        help='sample PokerKit hand evaluations and the lookup-order digest',
    )
    evaluator_command.add_argument('--out', type=Path, required=True)
    evaluator_command.add_argument('--seed', type=int, default=1)
    evaluator_command.add_argument(
        '--samples7', type=non_negative_int, default=2000,
    )
    evaluator_command.add_argument(
        '--samples6', type=non_negative_int, default=1000,
    )
    evaluator_command.add_argument(
        '--samples5', type=non_negative_int, default=500,
    )
    evaluator_command.add_argument(
        '--omaha-samples', type=non_negative_int, default=2000,
    )

    scenarios_command = commands.add_parser(
        'scenarios',
        help='record the hand-written rule scenarios step by step',
    )
    scenarios_command.add_argument('--out', type=Path, required=True)
    scenarios_command.add_argument(
        '--stage', choices=hands.STAGES, required=True,
    )

    hands_command = commands.add_parser(
        'hands',
        help='record random hands step by step, chosen to cover every feature',
    )
    hands_command.add_argument('--out', type=Path, required=True)
    hands_command.add_argument(
        '--stage', choices=hands.STAGES, required=True,
    )
    hands_command.add_argument('--seed', type=int, default=1)
    hands_command.add_argument('--pool', type=non_negative_int, default=1000)
    hands_command.add_argument('--count', type=non_negative_int, default=200)

    return parser.parse_args()


def non_negative_int(text: str) -> int:
    value = int(text)

    if value < 0:
        raise argparse.ArgumentTypeError(f'{value} is negative')

    return value


def write_quirks(path: Path) -> None:
    probes = quirks.run_probes()
    document = {'pokerkit': POKERKIT_VERSION, 'probes': probes}
    write(path, json.dumps(document, indent=2))
    outcomes = [probe['matches'] for probe in probes]
    print(
        f'{len(probes)} probes: {outcomes.count(True)} match,'
        f' {outcomes.count(False)} mismatch,'
        f' {outcomes.count(None)} not machine-checkable -> {path}',
    )


def write_evaluator_samples(
        path: Path,
        seed: int,
        counts: dict[int, int],
        omaha_count: int,
) -> None:
    digest = md5(quirks.lookup_order_bytes()).hexdigest()
    document = {
        'pokerkit': POKERKIT_VERSION,
        'seed': seed,
        'md5': digest,
        'samples': evaluator_samples(seed, counts),
        'omahaSamples': omaha_samples(seed, omaha_count),
    }
    write(path, json.dumps(document, separators=(',', ':')))
    print(f'{len(document["samples"])} samples, md5 {digest} -> {path}')


def evaluator_samples(seed: int, counts: dict[int, int]) -> list[dict]:
    """PokerKit's best high hand for random draws, by card count."""
    rng = random.Random(seed)
    samples = []

    for card_count, sample_count in counts.items():
        for _ in range(sample_count):
            cards = rng.sample(Deck.STANDARD, card_count)
            hand = StandardHighHand.from_game(cards, ())
            samples.append(
                {
                    'cards': ''.join(map(repr, cards)),
                    'strength': hand.entry.index,
                    'label': hand.entry.label.value,
                    'best': repr(hand),
                },
            )

    return samples


def omaha_samples(seed: int, count: int) -> list[dict]:
    """PokerKit's best Omaha hand for random deals, with null for none.

    Up to two hole cards are left out, as ``get_hand`` leaves out cards
    nobody scanned. A separate generator keeps the hold'em samples as they
    were.
    """
    rng = random.Random(f'omaha-{seed}')
    samples = []

    for _ in range(count):
        board_count = rng.choice((3, 4, 5))
        hole_count = rng.choices((4, 3, 2, 1), (8, 2, 2, 1))[0]
        cards = rng.sample(Deck.STANDARD, hole_count + board_count)
        hole, board = cards[:hole_count], cards[hole_count:]
        hand = OmahaHoldemHand.from_game_or_none(hole, board)
        samples.append(
            {
                'hole': ''.join(map(repr, hole)),
                'board': ''.join(map(repr, board)),
                'strength': None if hand is None else hand.entry.index,
                'best': None if hand is None else str(hand),
            },
        )

    return samples


def write_hands(path: Path, recorded: list[dict]) -> None:
    lines = [json.dumps(hand, separators=(',', ':')) for hand in recorded]
    write(path, '\n'.join(lines))
    steps = sum(len(hand['steps']) for hand in recorded)
    print(f'{len(recorded)} hands, {steps} steps -> {path}')


def print_coverage(coverage: dict[str, int]) -> None:
    for feature in hands.SAMPLE_FEATURES:
        marker = '' if coverage[feature] >= 3 else '  <- below 3'
        print(f'  {feature}: {coverage[feature]}{marker}')


def write(path: Path, text: str) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(text + '\n')


if __name__ == '__main__':
    main()
