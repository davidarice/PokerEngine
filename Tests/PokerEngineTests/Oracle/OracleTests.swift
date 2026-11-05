import Foundation
import Testing
@testable import PokerEngine

/// One hand recorded on PokerKit by `tools/oracle` (format described in `tools/oracle/hands.py`).
struct OracleHand: Decodable, Sendable, CustomTestStringConvertible {
    struct Step: Decodable, Sendable {
        let op: HandOperation?
        /// "pokerkit" (with PokerKit's `message`), or the deviation that refuses the operation.
        let rejected: String?
        let message: String?
        /// The exact refusal of a deviation. "B1" has none: any `.duplicateCard` will do.
        let error: EngineError?
        let events: [JSONValue]?
        /// The snapshot fields that changed.
        let state: [String: JSONValue]?
    }

    let name: String
    let stage: String
    let config: HandConfig
    let steps: [Step]
    /// PokerKit's PHH text for the state the hand ended in; nil with more than one runout.
    let phh: String?

    var testDescription: String { name }

    static func load(_ url: URL) throws -> [OracleHand] {
        try String(decoding: Data(contentsOf: url), as: UTF8.self)
            .split(separator: "\n")
            .map { try JSONDecoder().decode(OracleHand.self, from: Data($0.utf8)) }
    }

    static func committed(_ name: String) throws -> [OracleHand] {
        try load(Fixtures.directory.appendingPathComponent("oracle/\(name).jsonl"))
    }

    /// Every `.jsonl` file in `POKER_ORACLE_DIR`, for large soaks generated on demand.
    static func soak() throws -> [OracleHand] {
        guard let path = ProcessInfo.processInfo.environment["POKER_ORACLE_DIR"] else { return [] }
        let directory = URL(fileURLWithPath: path)
        let hands = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "jsonl" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
            .flatMap(load)
        // No hands would pass, and read as a soak that ran.
        guard !hands.isEmpty else { throw CocoaError(.fileNoSuchFile, userInfo: [NSFilePathErrorKey: path]) }
        return hands
    }
}

@Suite("PokerKit oracle")
struct OracleTests {
    @Test("hand-written rule scenarios match PokerKit step by step", arguments: try OracleHand.committed("scenarios"))
    func scenarios(_ hand: OracleHand) {
        Self.check(hand)
    }

    @Test("random hands match PokerKit step by step", arguments: try OracleHand.committed("random"))
    func randomHands(_ hand: OracleHand) {
        Self.check(hand)
    }

    @Test("soak hands from POKER_ORACLE_DIR match PokerKit step by step", arguments: try OracleHand.soak())
    func soak(_ hand: OracleHand) {
        Self.check(hand)
    }

    /// Replays the hand through the engine and stops at the first step that differs from PokerKit.
    static func check(_ hand: OracleHand) {
        var state = HandState(config: hand.config)
        var states = [HandState]()
        var expected = [String: JSONValue]()
        for (index, step) in hand.steps.enumerated() {
            let context = "\(hand.name) step \(index)\(step.op.map { " \($0)" } ?? " (start of hand)")"
            if let reason = step.rejected, let operation = step.op {
                guard case let .failure(error) = Result(catching: { () throws(EngineError) in try state.apply(operation) }) else {
                    Issue.record("\(context): accepted, but it should be refused (\(step.expectedRefusal(reason)))")
                    return
                }
                guard legalActions(of: state, agreeWith: error, refusing: operation) else {
                    Issue.record("\(context): refused with \(error), but legalActions says \(String(describing: state.legalActions))")
                    return
                }
                guard handCompleteAgrees(error, with: state, about: operation) else {
                    Issue.record("\(context): \(error) on a hand with isHandComplete \(state.isHandComplete)")
                    return
                }
                if agrees(error, with: step, about: operation) {
                    continue
                }
                Issue.record("\(context): rejected with \(error), which does not match \(step.expectedRefusal(reason))")
                return
            }
            let logCount = step.op == nil ? 0 : state.log.count
            if let operation = step.op {
                do {
                    state = try state.apply(operation)
                } catch {
                    Issue.record("\(context): rejected with \(error), but PokerKit accepts it")
                    return
                }
            }
            guard checkLog(Array(state.log[logCount...]), of: state, against: step, context) else { return }
            expected.merge(step.state ?? [:]) { $1 }
            let actual = snapshot(state)
            for key in expected.keys.sorted() where actual[key] != expected[key] {
                Issue.record("\(context): \(key) is \(actual[key] ?? .null), PokerKit has \(expected[key]!)")
                return
            }
            guard dealtHandsAgree(in: state, context), endingsHold(in: state, context) else { return }
            states.append(state)
        }
        // A sample keeps the soaks quick: every state of every hand would cost a replay per step.
        for sample in Set([states.count / 3, 2 * states.count / 3, states.count - 1]) {
            checkStorage(of: states[sample], hand.name)
        }
        checkPHH(of: state, against: hand)
        checkManualReplay(of: state, hand.name)
    }

    /// `dealtHand(of:)` ranks every player on every board without trapping. Where a player's live cards are still the
    /// cards dealt, it agrees with `hand(of:)`, which the snapshot compares with PokerKit.
    private static func dealtHandsAgree(in state: HandState, _ context: String) -> Bool {
        for player in 0..<state.playerCount {
            let live = state.holeCards[player]
            let dealt = state.dealtHoleCards[player]
            let unchanged = state.statuses[player] == .active && live.count == dealt.count
                && live.allSatisfy(dealt.contains) && dealt.allSatisfy(live.contains)
            for board in 0...state.boards.count {
                for faceUpOnly in [false, true] {
                    let dealtRank = state.dealtHand(of: player, board: board, faceUpOnly: faceUpOnly)
                    let liveRank = state.hand(of: player, board: board, faceUpOnly: faceUpOnly)
                    if unchanged, dealtRank != liveRank {
                        Issue.record("""
                            \(context): dealtHand(of: \(player), board: \(board), faceUpOnly: \(faceUpOnly)) is \
                            \(dealtRank.map(String.init(describing:)) ?? "nil"), hand(of:) is \
                            \(liveRank.map(String.init(describing:)) ?? "nil")
                            """)
                        return false
                    }
                }
            }
        }
        return true
    }

    /// PokerKit has neither a void nor a chop (B12), so every step checks them from the public API: a void is accepted
    /// and gives every chip back, and a chop is accepted exactly where the rule allows it, giving every chip back too.
    private static func endingsHold(in state: HandState, _ context: String) -> Bool {
        let starting = state.config.startingStacks
        func returnsEveryChip(_ ended: HandState) -> Bool {
            ended.isHandComplete && ended.stacks == starting && ended.totalPot == 0 && ended.statuses == state.statuses
                && ended.results?.allSatisfy { $0.net == 0 && $0.won == 0 } == true
                && !ended.canApply(.voidHand) && !ended.canApply(.showHoleCards(player: 0))
        }
        guard let voided = try? state.apply(.voidHand), returnsEveryChip(voided) else {
            Issue.record("\(context): a void is refused or does not give every chip back")
            return false
        }
        let chopped = try? state.apply(.chopBlinds)
        guard (chopped != nil) == choppable(state), chopped.map(returnsEveryChip) ?? true else {
            let verdict = chopped == nil ? "refused" : "accepted"
            Issue.record("\(context): chopBlinds is \(verdict), which the rule does not say")
            return false
        }
        return true
    }

    /// The chop rule, read from the public API: a cash game, a first round with someone to act, the two blinds the only
    /// players left, nothing in front of them but what they posted, and no chip from anyone else.
    private static func choppable(_ state: HandState) -> Bool {
        let blinds = state.playerCount == 2 ? [1, 0] : [0, 1]
        var posted = Array(repeating: 0, count: state.playerCount)
        for case let .blindOrStraddlePosted(player, amount) in state.log.map(\.event) {
            posted[player] = amount
        }
        return state.config.mode == .cashGame && state.street == .preflop && state.actor != nil
            && (0..<state.playerCount).allSatisfy { player in
                let bet = state.bets[player]
                return blinds.contains(player)
                    ? state.statuses[player] == .active && bet > 0 && bet == posted[player]
                    : state.statuses[player] != .active && state.stacks[player] == state.config.startingStacks[player]
            }
    }

    /// The operations rebuild the state, and so does the stored JSON, whose bytes come out the same again.
    private static func checkStorage(of state: HandState, _ name: String) {
        do {
            let context = "\(name) after \(state.operations.count) operations"
            guard try HandState.replay(config: state.config, operations: state.operations) == state else {
                Issue.record("\(context): replay gives a different state")
                return
            }
            let json = try state.json()
            let decoded = try HandState(json: json)
            guard decoded == state else {
                Issue.record("\(context): decoding gives a different state")
                return
            }
            guard try decoded.json() == json else {
                Issue.record("\(context): JSON changes on a round trip")
                return
            }
        } catch {
            Issue.record("\(name) after \(state.operations.count) operations: \(error)")
        }
    }

    /// `phh()` gives PokerKit's text byte for byte, or refuses exactly the hands `bridge.phh` gives no text for.
    private static func checkPHH(of state: HandState, against hand: OracleHand) {
        do {
            let text = try state.phh()
            if text != hand.phh {
                Issue.record("\(hand.name): PHH is\n\(text)\nPokerKit has\n\(hand.phh ?? "no PHH")")
            }
        } catch {
            if hand.phh != nil || error != .multipleRunouts(count: state.runoutCount) {
                Issue.record("\(hand.name): phh() throws \(error), PokerKit has \(hand.phh ?? "no PHH")")
            }
        }
    }

    /// With every automation off and each automated event entered as the operation it stands for, the same hand
    /// comes out: automation only saves the dealer the typing.
    private static func checkManualReplay(of state: HandState, _ name: String) {
        let operations = state.log.map { entry in
            entry.isAutomated ? bookkeepingOperation(for: entry.event) : state.operations[entry.operationIndex!]
        }
        do {
            let config = state.config
            let manual = try HandState.replay(
                config: HandConfig(
                    variant: config.variant, mode: config.mode, startingStacks: config.startingStacks,
                    antes: config.antes, anteTrimming: config.anteTrimming, blindsOrStraddles: config.blindsOrStraddles,
                    minBet: config.minBet, automations: []
                ),
                operations: operations
            )
            guard manual.log.map(\.event) == state.log.map(\.event), snapshot(manual) == snapshot(state),
                  storedProperties(of: manual) == storedProperties(of: state) else {
                Issue.record("\(name): entering the automated steps by hand gives a different hand")
                return
            }
        } catch {
            Issue.record("\(name): entering the automated steps by hand fails: \(error)")
        }
    }

    /// Everything the state holds, which the snapshot does not all reach, except what entering the bookkeeping by hand
    /// changes on purpose: the config, the operations and the log's flags.
    private static func storedProperties(of state: HandState) -> [String: AnyHashable] {
        var properties = [String: AnyHashable]()
        for case let (label?, value) in Mirror(reflecting: state).children {
            guard !["config", "operations", "log"].contains(label) else { continue }
            guard let value = value as? AnyHashable else { preconditionFailure("\(label) cannot be compared") }
            properties[label] = value
        }
        return properties
    }

    private static func bookkeepingOperation(for event: HandEvent) -> HandOperation {
        switch event {
        case let .antePosted(player, _): .postAnte(player: player)
        case .betsCollected: .collectBets
        case let .blindOrStraddlePosted(player, _): .postBlindOrStraddle(player: player)
        case let .runoutCountSelected(player, count): .selectRunoutCount(player: player, count: count)
        case let .handKilled(player): .killHand(player: player)
        case .chipsPushed: .pushChips
        case let .chipsPulled(player, _): .pullChips(player: player)
        default: preconditionFailure("Only bookkeeping is automated, not \(event)")
        }
    }

    /// `legalActions` must not offer what `apply` refuses: a refused raise gives the reason it gives, and a fold by
    /// the actor that would abandon a pot is one it rules out.
    private static func legalActions(
        of state: HandState,
        agreeWith error: EngineError,
        refusing operation: HandOperation
    ) -> Bool {
        if case let .raiseNotAllowed(_, reason) = error {
            return state.legalActions?.betOrRaise == .unavailable(reason)
        } else if case .wouldAbandonPot = error, case let .fold(player) = operation, player == state.actor {
            return state.legalActions?.canFold == false
        }
        return true
    }

    /// `.handComplete` is the refusal of a finished hand and of nothing else, and a show or a muck never gets it:
    /// they answer for themselves after the hand (B9). `matches` cannot judge this, as it sees no state.
    private static func handCompleteAgrees(
        _ error: EngineError,
        with state: HandState,
        about operation: HandOperation
    ) -> Bool {
        switch operation {
        case .showHoleCards, .muckHoleCards:
            return error != .handComplete
        default:
            return (error == .handComplete) == state.isHandComplete
        }
    }

    /// Whether the engine's refusal is the one the step records.
    private static func agrees(
        _ error: EngineError,
        with step: OracleHand.Step,
        about operation: HandOperation
    ) -> Bool {
        if let message = step.message {
            return matches(error, for: operation, pokerKitMessage: message)
        } else if let expected = step.error {
            return error == expected
        } else if case .duplicateCard = error {
            return step.rejected == "B1"
        }
        return false
    }

    /// The PokerKit refusal each engine error corresponds to (DECISIONS.md, section D). `Player … is not the actor`
    /// comes from the oracle's bridge: PokerKit's betting actions take no player. PokerKit's message cannot tell
    /// which reason a refused raise should give, so `check` requires the reason `legalActions` gives, whose label
    /// the snapshot's `betOrRaise` compares with PokerKit before every action. The same two messages refuse a listed
    /// show and a show as is, so only `operation` tells `.mustShowAllCards` from `.cannotShowUnknownCard`. PokerKit
    /// has no check for a finished hand: `.handComplete` stands for whatever the operation's own refusal says, and
    /// `handCompleteAgrees` judges when it may be given.
    static func matches(_ error: EngineError, for operation: HandOperation, pokerKitMessage message: String) -> Bool {
        let shortAllIn = "Short all-in cannot be raised."
        let alreadyActed = "The player already acted and hence cannot raise in face of a non-full all-in wager"
        let mustShow = message == "The player must show when all-in."
            || message == "A card is not shown in final showdown."
        switch error {
        case .handComplete:
            return true
        case let .noAnteExpected(player):
            return message == "Nobody can post the ante." || message == "The Player \(player) cannot post the ante."
        case .noBetCollectionExpected:
            return message == "The bet collection is currently prohibited."
        case let .noBlindOrStraddleExpected(player):
            return message == "Nobody can post the blind or straddle."
                || message == "The Player \(player) cannot post the blind or straddle"
        case .noDealExpected(.burn):
            return message == "No card burning is pending."
        case let .noDealExpected(.holeCard(player)):
            return message == "Currently, nobody can be dealt hole cards."
                || message == "The Player \(player) cannot be dealt any hole cards."
        case .noDealExpected(.boardCard):
            return message == "No board dealing is pending."
        case .burnRequired:
            return message == "A card must be burnt before board dealing."
        case .noActionExpected:
            return message == "There is no player to act."
        case let .notYourTurn(player, _):
            return message == "Player \(player) is not the actor"
        case .cannotFoldWhenCheckIsFree:
            return message == "There is no reason for this player to fold."
        case let .betBelowMinimum(amount, minimum):
            return message == "The amount \(amount) is below the minimum allowed \(minimum)."
        case let .betAboveMaximum(amount, maximum):
            return message == "The amount \(amount) is above the maximum allowed \(maximum)."
        case .raiseNotAllowed(_, .playerIsCovered):
            // PokerKit checks short all-ins and acted players before coverage; the engine names coverage first.
            return message == shortAllIn || message == alreadyActed || message.hasPrefix("The player is already covered")
        case .raiseNotAllowed(_, .actionNotReopened):
            return message == shortAllIn || message == alreadyActed
        case .raiseNotAllowed(_, .noOpponentCanRespond):
            return message.hasPrefix("There is no reason to complete, bet, or raise since every other player")
        case let .noRunoutSelectionExpected(player):
            return player == operation.player && (
                message == "Nobody can choose the number of runouts."
                    || message == "The Player \(player) cannot choose the number of runouts."
            )
        case let .invalidRunoutCount(count):
            return message == "The runout count \(count) is not positive."
        case let .noShowdownExpected(player):
            return player == operation.player && (
                message == "There is no player to showdown."
                    || message == "The Player \(player) cannot perform a showdown."
            )
        case let .playerNotInHand(player):
            return player == operation.player && message == "Player is not active."
        case let .tooManyCardsShown(player, count):
            guard case let .showHoleCards(shower, cards?) = operation else { return false }
            return player == shower && count == cards.count && message == "too many cards shown"
        case let .mustShowAllCards(player):
            switch operation {
            case .showHoleCards(player, .some), .muckHoleCards(player):
                return mustShow || message == "Non-standard showdown must show all cards."
            default:
                return false
            }
        case let .cannotShowUnknownCard(player):
            guard case .showHoleCards(player, nil) = operation else { return false }
            return mustShow || message == "An unknown card is shown."
        case let .noHandToKill(player):
            return player == operation.player && (
                message == "Nobody can kill their hand." || message == "The Player \(player) cannot kill their hand."
            )
        case .noChipsToPush:
            return message == "The chip pushing is not allowed."
        case let .noChipsToPull(player):
            return player == operation.player && (
                message == "No one can pull chips." || message == "There is no chip to be pulled."
            )
        default:
            return false
        }
    }

    private static func checkLog(_ entries: [LogEntry], of state: HandState, against step: OracleHand.Step, _ context: String) -> Bool {
        let events = entries.map { event($0.event) }
        guard events == step.events ?? [] else {
            Issue.record("\(context): events \(events), PokerKit has \(step.events ?? [])")
            return false
        }
        let operationIndex = step.op == nil ? nil : state.operations.count - 1
        let flags = entries.enumerated().map { LogEntry(event: $1.event, isAutomated: step.op == nil || $0 > 0, operationIndex: operationIndex) }
        guard entries == flags else {
            Issue.record("\(context): log entries \(entries) should be \(flags)")
            return false
        }
        return true
    }

    /// The engine's state in the oracle's terms (`tools/oracle/bridge.py`, `snapshot`).
    static func snapshot(_ state: HandState) -> [String: JSONValue] {
        let actions = state.legalActions
        // `legalActions` must repeat the actor, the call and `minRaiseTo...maxRaiseTo`, which are compared with
        // PokerKit; where it does not, the field shows what it gives instead.
        func agreed(_ value: Int?, _ given: Int?) -> JSONValue {
            value == given ? JSONValue(value) : .string("\(JSONValue(value)), but legalActions gives \(JSONValue(given))")
        }
        func label(_ kind: String, _ amounts: ClosedRange<Int>) -> String {
            amounts.lowerBound == state.minRaiseTo && amounts.upperBound == state.maxRaiseTo ? kind : "\(kind) \(amounts)"
        }
        let betOrRaise: String? = switch actions?.betOrRaise {
        case nil: nil
        case let .bet(amounts)?: label("bet", amounts)
        case let .raise(amounts)?: label("raise", amounts)
        case let .unavailable(reason)?: reason.rawValue
        }
        return [
            "stacks": JSONValue(state.stacks),
            "bets": JSONValue(state.bets),
            "statuses": .array(state.statuses.map { .string($0.rawValue) }),
            "street": JSONValue(state.street?.rawValue),
            "actor": agreed(state.actor, actions?.player),
            "toCall": agreed(state.toCall, actions?.toCall),
            "canFold": JSONValue(actions?.canFold),
            "betOrRaise": JSONValue(betOrRaise),
            "minRaiseTo": JSONValue(state.minRaiseTo),
            "maxRaiseTo": JSONValue(state.maxRaiseTo),
            "pots": .array(state.pots.map {
                .object(["amount": .int($0.amount), "eligiblePlayers": JSONValue($0.eligiblePlayers)])
            }),
            "totalPot": .int(state.totalPot),
            "boards": .array(state.boards.map(JSONValue.init)),
            "runoutCount": .int(state.runoutCount),
            "holeCards": .array(state.holeCards.map { JSONValue($0.map(\.card)) }),
            "faceUp": .array(state.holeCards.map { .array($0.map { .bool($0.isFaceUp) }) }),
            "pending": pending(state.pendingOperation),
            "hands": hands(state, faceUpOnly: false),
            "upHands": hands(state, faceUpOnly: true),
            "complete": .bool(state.isHandComplete),
            "results": results(state.results),
        ]
    }

    /// Every player's hand on every board.
    private static func hands(_ state: HandState, faceUpOnly: Bool) -> JSONValue {
        .array((0..<state.runoutCount).map { board in
            .array((0..<state.playerCount).map {
                JSONValue(state.hand(of: $0, board: board, faceUpOnly: faceUpOnly)?.description)
            })
        })
    }

    static func results(_ results: [PlayerResult]?) -> JSONValue {
        guard let results else { return .null }
        return .array(results.map {
            .object([
                "player": .int($0.player),
                "net": .int($0.net),
                "won": .int($0.won),
                "status": .string($0.status.rawValue),
                "holeCards": JSONValue($0.holeCards.map(\.card)),
                "faceUp": .array($0.holeCards.map { .bool($0.isFaceUp) }),
                "shown": .bool($0.shown),
            ])
        })
    }

    static func pending(_ operation: PendingOperation?) -> JSONValue {
        func forcedBets(_ bets: [ForcedBet]) -> JSONValue {
            .array(bets.map { JSONValue([$0.player, $0.amount]) })
        }
        let fields: [String: JSONValue]
        switch operation {
        case nil: return .null
        case let .postAnte(bets): fields = ["type": "postAnte", "forcedBets": forcedBets(bets)]
        case .collectBets: fields = ["type": "collectBets"]
        case let .postBlindOrStraddle(bets): fields = ["type": "postBlindOrStraddle", "forcedBets": forcedBets(bets)]
        case let .burnCard(street, runout):
            fields = ["type": "burnCard", "street": .string(street.rawValue), "runout": .int(runout)]
        case let .dealHoleCard(player, cardIndex):
            fields = ["type": "dealHoleCard", "player": .int(player), "cardIndex": .int(cardIndex)]
        case let .dealBoardCard(street, runout, cardIndex, cardCount):
            fields = [
                "type": "dealBoardCard", "street": .string(street.rawValue), "runout": .int(runout),
                "cardIndex": .int(cardIndex), "cardCount": .int(cardCount),
            ]
        case let .act(player): fields = ["type": "act", "player": .int(player)]
        case let .showdown(selectors, showOrder):
            fields = ["type": "showdown", "runoutSelectors": JSONValue(selectors), "showOrder": JSONValue(showOrder)]
        case let .killHand(players): fields = ["type": "killHand", "players": JSONValue(players)]
        case let .pushChips(pot, runout): fields = ["type": "pushChips", "pot": .int(pot), "runout": JSONValue(runout)]
        case let .pullChips(players): fields = ["type": "pullChips", "players": JSONValue(players)]
        }
        return .object(fields)
    }

    /// An event in the oracle's terms (`tools/oracle/bridge.py`, `event`).
    static func event(_ event: HandEvent) -> JSONValue {
        let fields: [String: JSONValue]
        switch event {
        case let .antePosted(player, amount): fields = ["type": "antePosted", "player": .int(player), "amount": .int(amount)]
        case let .blindOrStraddlePosted(player, amount):
            fields = ["type": "blindOrStraddlePosted", "player": .int(player), "amount": .int(amount)]
        case let .betsCollected(collected, returned):
            fields = ["type": "betsCollected", "collected": JSONValue(collected), "returned": JSONValue(returned)]
        case let .cardBurned(card, street, runout):
            fields = ["type": "cardBurned", "card": .string(card.description), "street": .string(street.rawValue), "runout": .int(runout)]
        case let .holeCardDealt(player, card): fields = ["type": "holeCardDealt", "player": .int(player), "card": .string(card.description)]
        case let .boardCardDealt(card, street, runout):
            fields = ["type": "boardCardDealt", "card": .string(card.description), "street": .string(street.rawValue), "runout": .int(runout)]
        case let .folded(player): fields = ["type": "folded", "player": .int(player)]
        case let .checkedOrCalled(player, amount): fields = ["type": "checkedOrCalled", "player": .int(player), "amount": .int(amount)]
        case let .betOrRaised(player, to): fields = ["type": "betOrRaised", "player": .int(player), "to": .int(to)]
        case let .runoutCountSelected(player, count):
            fields = ["type": "runoutCountSelected", "player": .int(player), "count": JSONValue(count)]
        case let .holeCardsShown(player, cards):
            fields = ["type": "holeCardsShown", "player": .int(player), "cards": JSONValue(cards)]
        case let .holeCardsMucked(player): fields = ["type": "holeCardsMucked", "player": .int(player)]
        case let .handKilled(player): fields = ["type": "handKilled", "player": .int(player)]
        case let .chipsPushed(pot, runout, amounts):
            fields = [
                "type": "chipsPushed", "pot": .int(pot), "runout": JSONValue(runout), "amounts": JSONValue(amounts),
            ]
        case let .chipsPulled(player, amount):
            fields = ["type": "chipsPulled", "player": .int(player), "amount": .int(amount)]
        // PokerKit has neither (B12), so no step records them.
        case let .blindsChopped(returned):
            fields = ["type": "blindsChopped", "returned": JSONValue(returned)]
        case let .handVoided(returned):
            fields = ["type": "handVoided", "returned": JSONValue(returned)]
        }
        return .object(fields)
    }
}

extension OracleHand.Step {
    /// What the step expected, for a failure message.
    func expectedRefusal(_ reason: String) -> String {
        message ?? error.map { "\(reason): \($0)" } ?? "\(reason): a repeated card"
    }
}

extension JSONValue: ExpressibleByStringLiteral {
    init(stringLiteral value: String) {
        self = .string(value)
    }
}
