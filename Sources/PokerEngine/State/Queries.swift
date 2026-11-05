// What the UI asks the state. Every query is computed by the same validators `apply(_:)` uses, so the UI and
// the engine cannot disagree.

extension HandState {
    /// What the hand is waiting for; nil once it is complete.
    public var pendingOperation: PendingOperation? {
        if antePostingStatuses.contains(true) {
            return .postAnte(players.filter { antePostingStatuses[$0] }.map {
                ForcedBet(player: $0, amount: effectiveAnte($0))
            })
        } else if betCollectionStatus {
            return .collectBets
        } else if blindOrStraddlePostingStatuses.contains(true) {
            return .postBlindOrStraddle(players.filter { blindOrStraddlePostingStatuses[$0] }.map {
                ForcedBet(player: $0, amount: effectiveBlindOrStraddle($0))
            })
        } else if cardBurningStatus {
            return .burnCard(street: currentStreet!, runout: dealingRunout)
        } else if let dealee = holeDealeeIndex {
            return .dealHoleCard(player: dealee, cardIndex: holeCards[dealee].count)
        } else if boardDealingCount > 0 {
            let count = currentStreet!.spec(config.variant).boardCardCount
            return .dealBoardCard(
                street: currentStreet!, runout: dealingRunout, cardIndex: count - boardDealingCount, cardCount: count
            )
        } else if let actor {
            return .act(player: actor)
        } else if runoutCountSelectorStatuses.contains(true) || !showdownIndices.isEmpty {
            return .showdown(
                runoutSelectors: players.filter { runoutCountSelectorStatuses[$0] }, showOrder: showdownIndices
            )
        } else if handKillingStatuses.contains(true) {
            return .killHand(players: players.filter { handKillingStatuses[$0] })
        } else if let subPot = subPots.first {
            return .pushChips(pot: subPot.pot, runout: subPot.runout)
        } else if chipsPullingStatuses.contains(true) {
            return .pullChips(players: players.filter { chipsPullingStatuses[$0] })
        }
        return nil
    }

    public var isHandComplete: Bool { !status }

    /// The player to act, if a betting round is under way.
    public var actor: Int? { actorIndices.first }

    public var legalActions: LegalActions? {
        guard let actor, let toCall else { return nil }
        let betOrRaise: BetOrRaise
        if let reason = raiseUnavailableReason(for: actor) {
            betOrRaise = .unavailable(reason)
        } else {
            let amounts = minCompletionBettingOrRaisingToAmount(actor)...maxCompletionBettingOrRaisingToAmount(actor)
            betOrRaise = maxBet == 0 ? .bet(amounts) : .raise(amounts)
        }
        let canFold = (try? verifyFolding(actor)) != nil
        return LegalActions(player: actor, canFold: canFold, toCall: toCall, betOrRaise: betOrRaise)
    }

    /// What checking or calling costs the actor (0 is a check), capped at the actor's stack.
    public var toCall: Int? { checkingOrCallingAmount }

    /// The smallest street total the actor may bet or raise to; nil when betting or raising is not allowed.
    /// Below the usual minimum only when that is the actor's whole stack.
    public var minRaiseTo: Int? {
        guard let actor, raiseUnavailableReason(for: actor) == nil else { return nil }
        return minCompletionBettingOrRaisingToAmount(actor)
    }

    /// The largest street total the actor may bet or raise to: the whole stack.
    public var maxRaiseTo: Int? {
        guard let actor, raiseUnavailableReason(for: actor) == nil else { return nil }
        return maxCompletionBettingOrRaisingToAmount(actor)
    }

    /// PokerKit's street: nil while forced bets are posted, and from chips pushing on. It goes back after the river
    /// of every run but the last: to the street of the all-in while a hand kept face down is asked again, otherwise
    /// straight to the first street the next run deals.
    public var street: Street? { currentStreet }

    /// The number of boards the hand is played on: 1 until the first showdown ends, then the count agreed there.
    public var runoutCount: Int { streetReturnIndex == nil ? 1 : selectedRunoutCount! }

    /// One board per runout, with the shared cards repeated on each. A run holds only the cards dealt to it so far,
    /// which can be all it ever gets if the hand ends in a concession (DECISIONS.md A15).
    public var boards: [[Card]] {
        let shared = streetReturnIndex.map(firstBoardPosition(ofStreet:)) ?? boardCards.count
        return (0..<runoutCount).map { runout in
            boardCards.enumerated().compactMap { position, cards in
                let index = position < shared ? 0 : runout
                return index < cards.count ? cards[index] : nil
            }
        }
    }

    /// The best five-card hand from the player's known hole cards and a board; with `faceUpOnly`, from shown
    /// cards only, as pots are awarded. In Omaha that is exactly two hole cards and three board cards. Nil for a player
    /// out of the hand, for a board that does not exist yet (the count takes effect when the first showdown ends),
    /// before five cards are known (in Omaha, two hole cards and three board cards), or while the board holds an
    /// unknown card. `player` must be a valid index.
    public func hand(of player: Int, board: Int = 0, faceUpOnly: Bool = false) -> HandRank? {
        precondition(players.contains(player), "Invalid player index \(player)")
        guard statuses[player] == .active else { return nil }
        return bestHand(holeCards[player], board: board, faceUpOnly: faceUpOnly)
    }

    /// The best five-card hand from the player's cards as dealt, the ones `results` keeps, and a board, whatever
    /// became of the hand. Unlike `hand(of:)`, it ranks a hand that was beaten, mucked or folded, and cards kept face
    /// down that the last river forgot. A folded hand is ranked with the whole board, cards dealt after the fold
    /// included. With `faceUpOnly`, from the cards shown at any point, as `results` marks them. Nil for a board that
    /// does not exist yet, before five cards are known, or while the board holds an unknown card. `player` must be a
    /// valid index.
    public func dealtHand(of player: Int, board: Int = 0, faceUpOnly: Bool = false) -> HandRank? {
        precondition(players.contains(player), "Invalid player index \(player)")
        return bestHand(dealtHoleCards[player], board: board, faceUpOnly: faceUpOnly)
    }

    /// Dealt cards are unique across hands, boards, burns and the muck (deviation B1), so the evaluator never sees a
    /// card twice. Unknown hole cards are left out, as PokerKit's `get_hand` leaves them out.
    private func bestHand(_ holeCards: [HoleCard], board: Int, faceUpOnly: Bool) -> HandRank? {
        let boards = boards
        guard boards.indices.contains(board) else { return nil }
        let hole = holeCards.filter { !faceUpOnly || $0.isFaceUp }.map(\.card).filter { $0 != .unknown }
        return switch config.variant {
        case .noLimitTexasHoldem: Evaluator.bestHand(hole + boards[board])
        case .potLimitOmahaHoldem: Evaluator.bestOmahaHand(hole: hole, board: boards[board])
        }
    }

    /// Each player's outcome, by player index, once the hand is complete; nil until then. A post-hand show after
    /// completion can still change `holeCards` and `shown`.
    public var results: [PlayerResult]? {
        guard isHandComplete else { return nil }
        let won = chipsWon
        return players.map { player in
            PlayerResult(
                player: player, net: payoffs[player], won: won[player], status: statuses[player],
                holeCards: dealtHoleCards[player], shown: dealtHoleCards[player].allSatisfy(\.isFaceUp)
            )
        }
    }

    /// Chips pushed to each player so far, without any bet returned. A void gives them back (deviation B12).
    var chipsWon: [Int] {
        var won = Array(repeating: 0, count: config.playerCount)
        guard !isVoidedOrChopped else { return won }
        for case let .chipsPushed(_, _, amounts) in log.lazy.map(\.event) {
            for player in players {
                won[player] += amounts[player]
            }
        }
        return won
    }
}
