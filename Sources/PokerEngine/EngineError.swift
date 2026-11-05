/// Which deal an error refers to. The synthesized `Codable` form is not part of the stored hand format.
public enum DealKind: Sendable, Hashable, Codable {
    case burn
    case holeCard(player: Int)
    case boardCard
}

/// Where a card already is, for `EngineError.duplicateCard`. The synthesized `Codable` form is not part of the
/// stored hand format.
public enum CardLocation: Sendable, Hashable, Codable {
    case hole(player: Int)
    case board(runout: Int)
    case burned
    /// Folded, mucked or killed hole cards.
    case mucked
    /// Listed twice in the same operation.
    case sameOperation
}

/// Why `HandState.apply(_:)` rejected an operation. The state is never changed by a rejected operation.
///
/// Checks run in this order: whether the hand is over, whether the named player exists, whether the hand expects
/// this kind of operation (PokerKit's first check), whose turn it is, then amounts and cards. A card scanned at the
/// wrong moment therefore reports "not expected" rather than "duplicate". Shows and mucks skip the first check,
/// because a post-hand show is still accepted after the hand, and so does a void, which reaches a finished hand. A show
/// during forced bets, which PokerKit accepts, is refused by the very last check rather than with the other timing
/// checks (DECISIONS.md B9). The synthesized `Codable` form is not part of the stored hand format.
public enum EngineError: Error, Sendable, Hashable, Codable {
    case handComplete
    /// A player index outside `0..<playerCount`.
    case invalidPlayer(Int)

    case noAnteExpected(player: Int)
    case noBetCollectionExpected
    case noBlindOrStraddleExpected(player: Int)

    case noDealExpected(DealKind)
    /// A board card was entered before the burn.
    case burnRequired
    case duplicateCard(Card, location: CardLocation)

    case noActionExpected
    case notYourTurn(player: Int, actor: Int)
    /// Tournament rule.
    case cannotFoldWhenCheckIsFree(player: Int)
    case betBelowMinimum(amount: Int, minimum: Int)
    case betAboveMaximum(amount: Int, maximum: Int)
    case raiseNotAllowed(player: Int, reason: RaiseUnavailableReason)

    case noRunoutSelectionExpected(player: Int)
    /// A count below 1 or above `HandState.maximumRunoutCount`.
    case invalidRunoutCount(Int)

    case noShowdownExpected(player: Int)
    /// The player has folded, mucked or been killed.
    case playerNotInHand(player: Int)
    case tooManyCardsShown(player: Int, count: Int)
    /// A show with `cards: nil` while a hole card is `.unknown`, dealt unscanned or forgotten on the river; list the
    /// cards instead. Also a list holding `.unknown`: scan the card, or leave it out to keep it face down.
    case cannotShowUnknownCard(player: Int)
    /// A listed partial show in a tournament, unless from the player left with nobody all in; with no street in play,
    /// a listed show that leaves a card face down or a muck. A show as is with an unknown card is
    /// `.cannotShowUnknownCard`.
    case mustShowAllCards(player: Int)
    /// A shown card that contradicts the scanned hole cards.
    case shownCardNotDealt(player: Int, card: Card)

    /// Giving up the hand would leave this pot with nobody who can win it. `pot` is an index into the pots as they
    /// would stand if the fold or muck went through: everyone still to act calls, capped by their stack, and bets
    /// are collected. A fold that leaves one player ends the round at once, so then nobody calls. The index need
    /// not exist in the current `HandState.pots`, and this player need not be able to win that pot: the fold may
    /// be refused because it would stop another player calling. In Omaha, showing fewer than two cards on the river
    /// gives up the hand too: the rest are forgotten, and no hand is made without two hole cards.
    case wouldAbandonPot(player: Int, pot: Int)
    /// The hand cannot be settled until this board card (0-based position within the runout) is entered.
    case unknownBoardCard(runout: Int, position: Int)

    case noHandToKill(player: Int)
    case noChipsToPush
    case noChipsToPull(player: Int)

    /// See `HandOperation.chopBlinds` for when the blinds may chop.
    case cannotChopBlinds

    /// A sentence for the dealer. `name` gives each player's label in the UI; the default numbers players from 1.
    /// For errors the engine throws, `name` is only called with valid player indices. `.invalidPlayer` does not
    /// call it and shows the raw index, since the index is not a player. Runs and board cards are numbered from 1,
    /// with wrapping arithmetic (`&+`), because a decoded error can carry any value and must not trap.
    public func message(naming name: (Int) -> String = { "Player \($0 &+ 1)" }) -> String {
        switch self {
        case .handComplete:
            "The hand is over."
        case let .invalidPlayer(player):
            "There is no player with index \(player)."
        case let .noAnteExpected(player):
            "\(name(player)) has no ante to post."
        case .noBetCollectionExpected:
            "Bets cannot be collected now."
        case let .noBlindOrStraddleExpected(player):
            "\(name(player)) cannot post a blind or straddle now."
        case .noDealExpected(.burn):
            "No card should be burned now."
        case let .noDealExpected(.holeCard(player)):
            "\(name(player)) should not be dealt a hole card now."
        case .noDealExpected(.boardCard):
            "No board card should be dealt now."
        case .burnRequired:
            "Burn a card before dealing the board."
        case let .duplicateCard(card, location):
            "\(card) is \(Self.describe(location, naming: name))."
        case .noActionExpected:
            "Nobody is due to act."
        case let .notYourTurn(player, actor):
            "It is \(name(actor))'s turn, not \(name(player))'s."
        case let .cannotFoldWhenCheckIsFree(player):
            "\(name(player)) can check, so folding is not allowed in a tournament."
        case let .betBelowMinimum(amount, minimum):
            "\(amount) is below the minimum of \(minimum)."
        case let .betAboveMaximum(amount, maximum):
            "\(amount) is above the maximum of \(maximum)."
        // Name only the refusal: the call can be a free check, and a tournament then refuses the fold. A covered
        // player and a closed action always face a bet, but nobody left to respond can also refuse the first bet.
        case let .raiseNotAllowed(player, .playerIsCovered):
            "\(name(player)) cannot raise: the bet covers their stack."
        case let .raiseNotAllowed(player, .actionNotReopened):
            "\(name(player)) cannot raise: the all-in was not a full raise."
        case let .raiseNotAllowed(player, .noOpponentCanRespond):
            "\(name(player)) cannot bet or raise: nobody else could call it."
        case let .noRunoutSelectionExpected(player):
            "\(name(player)) has no runout count to choose."
        case let .invalidRunoutCount(count):
            "\(count) is not a valid number of runouts."
        case let .noShowdownExpected(player):
            "\(name(player)) has nothing to show or muck now."
        case let .playerNotInHand(player):
            "\(name(player)) is no longer in the hand."
        case let .tooManyCardsShown(player, count):
            "\(name(player)) cannot show \(count) cards."
        case let .cannotShowUnknownCard(player):
            "Scan \(name(player))'s cards to show them."
        case let .mustShowAllCards(player):
            "\(name(player)) must show every card."
        case let .shownCardNotDealt(player, card):
            "\(card) was not dealt to \(name(player))."
        case let .wouldAbandonPot(player, pot):
            "If \(name(player)) gave up the hand, nobody could win \(pot == 0 ? "the main pot" : "side pot \(pot)")."
        case let .unknownBoardCard(runout, position):
            "Scan board card \(position &+ 1) of run \(runout &+ 1) to settle the hand."
        case let .noHandToKill(player):
            "\(name(player))'s hand cannot be killed now."
        case .noChipsToPush:
            "Chips cannot be pushed now."
        case let .noChipsToPull(player):
            "\(name(player)) cannot pull chips now."
        case .cannotChopBlinds:
            "The blinds can chop only in a cash game, before the flop, once everyone else has folded, with nothing in "
                + "the pot but their blinds and antes."
        }
    }

    private static func describe(_ location: CardLocation, naming name: (Int) -> String) -> String {
        switch location {
        case let .hole(player): "already in \(name(player))'s hand"
        case .board(runout: 0): "already on the board"
        case let .board(runout): "already on board \(runout &+ 1)"
        case .burned: "already burned"
        case .mucked: "already in the muck"
        case .sameOperation: "listed twice"
        }
    }
}

/// Why `HandState.replay(config:operations:)` or `replacingOperation(at:with:)` failed: the first operation that
/// no longer fits, and the error it caused. The synthesized `Codable` form is not part of the stored hand format.
public struct ReplayError: Error, Sendable, Hashable, Codable {
    public let operationIndex: Int
    public let operation: HandOperation
    public let error: EngineError
}
