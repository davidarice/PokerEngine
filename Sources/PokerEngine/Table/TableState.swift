/// The table between hands: who sits in which seat with how many chips, the stakes, and the button. It sets up each
/// hand and takes each finished hand's chips back, so the app keeps no player order or stacks of its own.
///
/// The rules are a home game's (DECISIONS.md C21). Anyone seated with chips is dealt in, and a player with none is
/// dealt out until a rebuy. A player who stands up leaves the seat empty and takes the chips. The button moves to the
/// next player after each hand, Robert's Rules of Poker's moving button, except after a void: a misdeal's redeal keeps
/// it. Nobody owes a missed blind, and there are no straddles or live posts; for those, build a `HandConfig` yourself.
/// Between hands the dealer can change anything: who sits where, the chips, the stakes and the button.
///
/// A value, like `HandState`, for the app to keep. Its `Codable` form saves it between launches, and decoding refuses a
/// table that no calls could have left; it is not part of the stored hand format.
public struct TableState: Sendable, Hashable, Codable {
    /// Seats run clockwise from 0, one for each player a hand can hold.
    public static let seatCount = 10

    /// What every hand at the table is played for. A change takes effect from the next hand.
    public struct Stakes: Sendable, Hashable, Codable {
        public enum Ante: Sendable, Hashable, Codable {
            /// From every player, all equal.
            case everyone(Int)
            /// From the big blind, for the whole table.
            case bigBlind(Int)
        }

        public var variant: HandConfig.Variant
        public var mode: HandConfig.Mode
        public var smallBlind: Int
        public var bigBlind: Int
        public var ante: Ante?
        public var automations: Set<HandConfig.Automation>
        private var explicitMinBet: Int?

        /// The minimum bet and the smallest raise increment: the big blind, even after it changes, unless set.
        public var minBet: Int {
            get { explicitMinBet ?? bigBlind }
            set { explicitMinBet = newValue }
        }

        public init(
            variant: HandConfig.Variant = .noLimitTexasHoldem,
            mode: HandConfig.Mode,
            smallBlind: Int,
            bigBlind: Int,
            ante: Ante? = nil,
            minBet: Int? = nil,
            automations: Set<HandConfig.Automation> = .bookkeeping
        ) {
            self.variant = variant
            self.mode = mode
            self.smallBlind = smallBlind
            self.bigBlind = bigBlind
            self.ante = ante
            self.explicitMinBet = minBet
            self.automations = automations
        }
    }

    /// One hand as the table dealt it.
    public struct Deal: Sendable, Hashable, Codable {
        /// The hands dealt at this table so far, counting this one.
        public let number: Int
        public let config: HandConfig
        /// `seats[i]` is the seat of player `i`.
        public let seats: [Int]
    }

    public var stakes: Stakes
    /// Chips by seat, for every seat taken. A seat with 0 is dealt out.
    public private(set) var stacks: [Int: Int] = [:]
    /// The button's seat in the hand dealt last, unless `moveButton(to:)` has put it elsewhere for the next one; before
    /// the first hand, where it starts.
    public private(set) var buttonSeat: Int
    /// The hand dealt last: in play until it is finished, then the last hand until the next is dealt.
    public private(set) var hand: Deal?
    public private(set) var isHandInPlay = false

    /// The final stacks the last finished hand carried to the seats, so that a correction moves only the difference.
    private var carriedStacks: [Int]?
    /// Seats of that hand whose player has stood up or changed seats since, so a correction can no longer reach their
    /// chips.
    private var seatsLeft: Set<Int> = []
    /// The last hand was voided, so the redeal keeps the button.
    private var keepsButton = false
    /// The dealer moved the button, so the next hand deals it from `buttonSeat` itself, whatever the last hand was.
    private var buttonMoved = false

    /// `buttonSeat` is where the button starts, for example after the draw for it. If nobody sits there when the first
    /// hand is dealt, it goes to the next player.
    public init(stakes: Stakes, buttonSeat: Int = 0) throws(TableError) {
        guard (0..<Self.seatCount).contains(buttonSeat) else { throw .noSuchSeat(buttonSeat) }
        self.stakes = stakes
        self.buttonSeat = buttonSeat
    }

    /// Seats a player with `stack` chips, to be dealt in from the next hand.
    public mutating func sit(_ seat: Int, stack: Int) throws(TableError) {
        try verifyBetweenHands()
        guard (0..<Self.seatCount).contains(seat) else { throw .noSuchSeat(seat) }
        guard stacks[seat] == nil else { throw .seatTaken(seat) }
        guard (1...HandConfig.maximumChips).contains(stack) else { throw .invalidStack(stack) }
        stacks[seat] = stack
    }

    /// Empties the seat, and returns the chips the player takes.
    @discardableResult
    public mutating func stand(_ seat: Int) throws(TableError) -> Int {
        try verifyBetweenHands()
        let stack = try stack(of: seat)
        stacks[seat] = nil
        if carriedStacks != nil, hand?.seats.contains(seat) == true {
            seatsLeft.insert(seat)
        }
        return stack
    }

    /// A rebuy, a top-up or chips taken off the table. A stack of 0 is dealt out.
    public mutating func setStack(of seat: Int, to stack: Int) throws(TableError) {
        try verifyBetweenHands()
        _ = try self.stack(of: seat)
        guard (0...HandConfig.maximumChips).contains(stack) else { throw .invalidStack(stack) }
        stacks[seat] = stack
    }

    /// Moves the player in `from` to `to` with their chips, even none. If someone sits in `to`, the two trade seats.
    /// The button stays with its seat, and a correction of the last hand is refused for a player who moved, as for one
    /// who stood up.
    public mutating func changeSeat(from: Int, to: Int) throws(TableError) {
        try verifyBetweenHands()
        let moving = try stack(of: from)
        guard (0..<Self.seatCount).contains(to) else { throw .noSuchSeat(to) }
        guard from != to else { return }
        stacks[from] = stacks[to]
        stacks[to] = moving
        if carriedStacks != nil, let seats = hand?.seats {
            seatsLeft.formUnion([from, to].filter(seats.contains))
        }
    }

    /// Puts the button on `seat` for the next hand, or on the next player dealt in after it if nobody there is, as with
    /// the seat it starts on. This wins over a void's redeal and over any correction of the last hand, and after the
    /// next hand the button moves on as usual.
    public mutating func moveButton(to seat: Int) throws(TableError) {
        try verifyBetweenHands()
        guard (0..<Self.seatCount).contains(seat) else { throw .noSuchSeat(seat) }
        buttonSeat = seat
        buttonMoved = true
    }

    /// Deals the next hand to every seated player with chips: the button moves on, and the deal's config is ready
    /// for a `HandState` or a `TableSession`. Once it is dealt, the last hand's result stands.
    public mutating func nextHand() throws(TableError) -> Deal {
        try verifyBetweenHands()
        let players = stacks.filter { $0.value > 0 }.keys.sorted()
        guard players.count >= 2 else { throw .notEnoughPlayers(players.count) }
        if let blind = [stakes.smallBlind, stakes.bigBlind].first(where: { $0 < 0 }) {
            throw .negativeBlind(blind)
        }
        // The first player clockwise after the last hand's button, or from `buttonSeat` itself for the first hand, a
        // redeal or a button the dealer moved.
        let from = hand == nil || keepsButton || buttonMoved ? buttonSeat : buttonSeat + 1
        let button = players.first { $0 >= from } ?? players[0]
        let seats = HandConfig.playerOrder(occupiedSeats: players, buttonSeat: button)
        let antes: [Int]
        switch stakes.ante {
        case nil: antes = []
        case let .everyone(amount)?: antes = Array(repeating: amount, count: seats.count)
        case let .bigBlind(amount)?: antes = [0, amount]
        }
        let config: HandConfig
        do throws(ConfigError) {
            config = try HandConfig(
                variant: stakes.variant, mode: stakes.mode, startingStacks: seats.map { stacks[$0]! }, antes: antes,
                anteTrimming: stakes.ante.map { if case .everyone = $0 { true } else { false } } ?? false,
                blindsOrStraddles: [stakes.smallBlind, stakes.bigBlind], minBet: stakes.minBet,
                automations: stakes.automations
            )
        } catch {
            throw .handConfigRefused(error)
        }
        let deal = Deal(number: (hand?.number ?? 0) + 1, config: config, seats: seats)
        buttonSeat = button
        hand = deal
        isHandInPlay = true
        carriedStacks = nil
        seatsLeft = []
        keepsButton = false
        buttonMoved = false
        return deal
    }

    /// Carries the finished hand's chips to the seats of its players, `deal` being the one `nextHand()` gave for it.
    /// Until the next hand is dealt, finishing it again with a corrected `HandState` moves only the difference, so a
    /// rebuy since stays, while all of its players are still seated. A void keeps the button for the redeal.
    public mutating func finish(_ finished: HandState, of deal: Deal) throws(TableError) {
        guard let current = hand else { throw .noHandDealt }
        guard deal == current, finished.playerCount == deal.seats.count else { throw .notThisHand }
        guard finished.isHandComplete else { throw .handNotComplete }
        var carried = stacks
        if let previous = carriedStacks {
            if let seat = deal.seats.first(where: seatsLeft.contains) {
                throw .seatChanged(seat)
            }
            for (player, seat) in deal.seats.enumerated() {
                let stack = carried[seat]! + finished.stacks[player] - previous[player]
                guard stack >= 0 else { throw .stackBelowZero(seat: seat) }
                guard stack <= HandConfig.maximumChips else { throw .invalidStack(stack) }
                carried[seat] = stack
            }
        } else {
            for (player, seat) in deal.seats.enumerated() {
                carried[seat] = finished.stacks[player]
            }
        }
        stacks = carried
        carriedStacks = finished.stacks
        keepsButton = finished.operations.last == .voidHand
        isHandInPlay = false
    }

    private func verifyBetweenHands() throws(TableError) {
        if isHandInPlay {
            throw .handInPlay
        }
    }

    private func stack(of seat: Int) throws(TableError) -> Int {
        guard let stack = stacks[seat] else {
            throw (0..<Self.seatCount).contains(seat) ? .seatEmpty(seat) : .noSuchSeat(seat)
        }
        return stack
    }

    /// What every call leaves true. Decoding checks it, so that no call traps on a damaged save or is stuck on one.
    private var isConsistent: Bool {
        let seatNumbers = 0..<Self.seatCount
        let chips = 0...HandConfig.maximumChips
        guard seatNumbers.contains(buttonSeat),
              stacks.allSatisfy({ seatNumbers.contains($0.key) && chips.contains($0.value) })
        else { return false }
        guard let hand else {
            return !isHandInPlay && carriedStacks == nil && seatsLeft.isEmpty && !keepsButton
        }
        // `playerOrder` traps on a repeated seat, so distinct seats are checked first.
        guard (1..<Int.max).contains(hand.number), hand.seats.count == hand.config.playerCount,
              Set(hand.seats).count == hand.seats.count, hand.seats.allSatisfy(seatNumbers.contains),
              let handButton = hand.seats.last, buttonMoved || handButton == buttonSeat,
              hand.seats == HandConfig.playerOrder(occupiedSeats: hand.seats, buttonSeat: handButton),
              seatsLeft.isSubset(of: hand.seats), hand.seats.allSatisfy({ seatsLeft.contains($0) || stacks[$0] != nil })
        else { return false }
        if isHandInPlay {
            return carriedStacks == nil && seatsLeft.isEmpty && !keepsButton && !buttonMoved
                && hand.seats.map({ stacks[$0] ?? 0 }) == hand.config.startingStacks
        }
        // Not their sum: `replaceConfig(with:)` may have corrected a starting stack, so the hand ended on other stacks.
        return carriedStacks.map { $0.count == hand.seats.count && $0.allSatisfy(chips.contains) } ?? false
    }
}

extension TableState {
    private enum CodingKeys: String, CodingKey {
        case stakes, stacks, buttonSeat, hand, isHandInPlay, carriedStacks, seatsLeft, keepsButton, buttonMoved
    }

    /// Reads what `encode(to:)` wrote, and refuses a table that no sequence of calls could have left.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        stakes = try container.decode(Stakes.self, forKey: .stakes)
        stacks = try container.decode([Int: Int].self, forKey: .stacks)
        buttonSeat = try container.decode(Int.self, forKey: .buttonSeat)
        hand = try container.decodeIfPresent(Deal.self, forKey: .hand)
        isHandInPlay = try container.decode(Bool.self, forKey: .isHandInPlay)
        carriedStacks = try container.decodeIfPresent([Int].self, forKey: .carriedStacks)
        seatsLeft = try container.decode(Set<Int>.self, forKey: .seatsLeft)
        keepsButton = try container.decode(Bool.self, forKey: .keepsButton)
        // A table saved by 0.2.2, which could not move the button, has no such key.
        buttonMoved = try container.decodeIfPresent(Bool.self, forKey: .buttonMoved) ?? false
        guard isConsistent else {
            throw DecodingError.dataCorrupted(DecodingError.Context(
                codingPath: decoder.codingPath, debugDescription: "Not a table that TableState's calls could leave"
            ))
        }
    }
}
