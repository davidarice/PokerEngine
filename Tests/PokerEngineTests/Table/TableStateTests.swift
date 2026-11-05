import Foundation
import Testing
@testable import PokerEngine

@Suite("Table state between hands")
struct TableStateTests {
    private static let stakes = TableState.Stakes(mode: .cashGame, smallBlind: 1, bigBlind: 2)

    /// Seats 2, 5 and 7 taken with 200 each, and the button starting on seat 5.
    private func table(button: Int = 5, stakes: TableState.Stakes = Self.stakes) throws -> TableState {
        var table = try TableState(stakes: stakes, buttonSeat: button)
        for seat in [2, 5, 7] {
            try table.sit(seat, stack: 200)
        }
        return table
    }

    /// Deals every hole card unknown and folds round to the big blind, so the hand ends at once.
    private func foldedToTheBigBlind(_ deal: TableState.Deal) throws -> HandState {
        var hand = HandState(config: deal.config)
        while case let .dealHoleCard(player, _)? = hand.pendingOperation {
            hand = try hand.apply(.dealHole(player: player, card: .unknown))
        }
        while let actor = hand.actor {
            hand = try hand.apply(.fold(player: actor))
        }
        return hand
    }

    // MARK: Dealing

    @Test("a hand's players are the seated players with chips, in order from the seat after the button")
    func nextHand() throws {
        var table = try table()
        let deal = try table.nextHand()
        #expect(deal.seats == [7, 2, 5])
        #expect(deal.config.startingStacks == [200, 200, 200])
        #expect(deal.config.blindsOrStraddles == [1, 2, 0])
        #expect(deal.config.minBet == 2)
        #expect(deal.config.mode == .cashGame)
        #expect(deal.config.variant == .noLimitTexasHoldem)
        #expect(table.isHandInPlay)
        #expect(table.hand == deal)
        #expect(table.buttonSeat == 5)
    }

    @Test("the stakes set the game, the blinds, any ante and the minimum bet")
    func stakes() throws {
        let omaha = TableState.Stakes(
            variant: .potLimitOmahaHoldem, mode: .tournament, smallBlind: 5, bigBlind: 10, ante: .everyone(1),
            minBet: 20, automations: []
        )
        var table = try table(stakes: omaha)
        let deal = try table.nextHand()
        #expect(deal.config.variant == .potLimitOmahaHoldem)
        #expect(deal.config.mode == .tournament)
        #expect(deal.config.blindsOrStraddles == [5, 10, 0])
        #expect(deal.config.antes == [1, 1, 1])
        #expect(deal.config.anteTrimming)
        #expect(deal.config.minBet == 20)
        #expect(deal.config.automations.isEmpty)
        let bigBlindAnte = TableState.Stakes(mode: .cashGame, smallBlind: 1, bigBlind: 2, ante: .bigBlind(2))
        var anteTable = try self.table(stakes: bigBlindAnte)
        let antes = try anteTable.nextHand().config
        #expect(antes.antes == [0, 2, 0])
        #expect(!antes.anteTrimming)
    }

    @Test("the minimum bet follows the big blind until it is set")
    func minBet() {
        var stakes = TableState.Stakes(mode: .cashGame, smallBlind: 1, bigBlind: 2)
        #expect(stakes.minBet == 2)
        stakes.bigBlind = 4
        #expect(stakes.minBet == 4)
        stakes.minBet = 5
        stakes.bigBlind = 10
        #expect(stakes.minBet == 5)
        #expect(TableState.Stakes(mode: .cashGame, smallBlind: 1, bigBlind: 2, minBet: 3).minBet == 3)
    }

    @Test("the button moves to the next player after each hand, skipping empty seats and players with no chips")
    func buttonMoves() throws {
        var table = try table(button: 5)
        try table.sit(6, stack: 100)
        try table.setStack(of: 6, to: 0)
        var buttons = [Int]()
        for _ in 0..<4 {
            let deal = try table.nextHand()
            buttons.append(try #require(deal.seats.last))
            try table.finish(foldedToTheBigBlind(deal), of: deal)
        }
        #expect(buttons == [5, 7, 2, 5])
        #expect(table.buttonSeat == 5)
    }

    @Test("a button starting on an empty seat goes to the next player")
    func buttonOnAnEmptySeat() throws {
        var table = try table(button: 3)
        #expect(try table.nextHand().seats == [7, 2, 5])
        #expect(table.buttonSeat == 5)
    }

    @Test("between hands the dealer puts the button on any seat for the next hand, and it moves on as usual after")
    func moveButton() throws {
        var table = try table(button: 5)
        let deal = try table.nextHand()
        try table.finish(foldedToTheBigBlind(deal), of: deal)
        try table.moveButton(to: 2)
        #expect(table.buttonSeat == 2)
        let moved = try table.nextHand()
        #expect(moved.seats.last == 2)
        try table.finish(foldedToTheBigBlind(moved), of: moved)
        #expect(try table.nextHand().seats.last == 5)
    }

    @Test("a button moved to an empty seat goes to the next player, and it moves only between hands")
    func moveButtonLimits() throws {
        var table = try table(button: 2)
        try table.moveButton(to: 3)
        #expect(throws: TableError.noSuchSeat(10)) { try table.moveButton(to: 10) }
        #expect(throws: TableError.noSuchSeat(-1)) { try table.moveButton(to: -1) }
        #expect(try table.nextHand().seats.last == 5)
        #expect(throws: TableError.handInPlay) { try table.moveButton(to: 2) }
        #expect(table.buttonSeat == 5)
    }

    @Test("a moved button wins over a void's redeal, and a correction of the last hand does not undo it")
    func movedButtonStays() throws {
        var table = try table(button: 5)
        let deal = try table.nextHand()
        let folded = try foldedToTheBigBlind(deal)
        try table.finish(folded.apply(.voidHand), of: deal)
        try table.moveButton(to: 2)
        var corrected = table
        #expect(try table.nextHand().seats.last == 2)
        // The void was a mistake: the hand as played moves its chips, and the button stays where it was put.
        try corrected.finish(folded, of: deal)
        #expect(corrected.stacks == [2: 201, 5: 200, 7: 199])
        #expect(try corrected.nextHand().seats.last == 2)
    }

    @Test("after a void the button stays for the redeal, and after a chop it moves on")
    func voidKeepsTheButton() throws {
        var table = try table(button: 5)
        let first = try table.nextHand()
        try table.finish(HandState(config: first.config).apply(.voidHand), of: first)
        #expect(try table.nextHand().seats.last == 5)
        let redeal = try #require(table.hand)
        var hand = HandState(config: redeal.config)
        while case let .dealHoleCard(player, _)? = hand.pendingOperation {
            hand = try hand.apply(.dealHole(player: player, card: .unknown))
        }
        try table.finish(hand.applying(.fold(player: 2), .chopBlinds), of: redeal)
        #expect(table.stacks == [2: 200, 5: 200, 7: 200])
        #expect(try table.nextHand().seats.last == 7)
    }

    @Test("a void found once the hand is finished moves its chips back like a correction, and keeps the button")
    func voidAfterTheHand() throws {
        var table = try table(button: 5)
        let deal = try table.nextHand()
        let paid = try foldedToTheBigBlind(deal)
        try table.finish(paid, of: deal)
        try table.setStack(of: 5, to: 300)
        try table.finish(paid.apply(.voidHand), of: deal)
        #expect(table.stacks == [2: 200, 5: 300, 7: 200])
        var undone = table
        #expect(try table.nextHand().seats.last == 5)
        // Taking the void back, as `TableSession.undo()` does, moves the button on again.
        try undone.finish(paid, of: deal)
        #expect(undone.stacks == [2: 201, 5: 300, 7: 199])
        #expect(try undone.nextHand().seats.last == 7)
    }

    @Test("the button starts on a seat of the table")
    func startingButton() {
        #expect(throws: TableError.noSuchSeat(10)) { try TableState(stakes: Self.stakes, buttonSeat: 10) }
        #expect(throws: TableError.noSuchSeat(-1)) { try TableState(stakes: Self.stakes, buttonSeat: -1) }
    }

    @Test("a hand needs two players with chips")
    func notEnoughPlayers() throws {
        var table = try TableState(stakes: Self.stakes, buttonSeat: 0)
        try table.sit(4, stack: 100)
        #expect(throws: TableError.notEnoughPlayers(1)) { try table.nextHand() }
        try table.sit(6, stack: 100)
        try table.setStack(of: 6, to: 0)
        #expect(throws: TableError.notEnoughPlayers(1)) { try table.nextHand() }
        #expect(!table.isHandInPlay)
    }

    @Test("stakes that make no hand are refused, a negative blind included, since the table has no live posts")
    func invalidStakes() throws {
        var table = try table(stakes: .init(mode: .cashGame, smallBlind: 0, bigBlind: 0))
        #expect(throws: TableError.handConfigRefused(.noForcedBets)) { try table.nextHand() }
        table.stakes = .init(mode: .cashGame, smallBlind: -1, bigBlind: 2)
        #expect(throws: TableError.negativeBlind(-1)) { try table.nextHand() }
        table.stakes = .init(mode: .cashGame, smallBlind: 1, bigBlind: -2, minBet: 2)
        #expect(throws: TableError.negativeBlind(-2)) { try table.nextHand() }
        #expect(!table.isHandInPlay)
    }

    // MARK: Finishing

    @Test("a finished hand's chips go back to the seats, and a player left with none is dealt out")
    func finishCarriesTheChips() throws {
        var table = try table(button: 5)
        let deal = try table.nextHand()
        var hand = HandState(config: deal.config)
        while case let .dealHoleCard(player, _)? = hand.pendingOperation {
            hand = try hand.apply(.dealHole(player: player, card: .unknown))
        }
        // Seat 7, player 0, shoves; seat 2 calls; seat 5 folds. Both all in, so no more betting.
        hand = try hand.applying(
            .fold(player: 2), .betOrRaise(player: 0, to: 200), .checkOrCall(player: 1),
            .selectRunoutCount(player: 0, count: nil), .selectRunoutCount(player: 1, count: nil),
            .showHoleCards(player: 0, cards: cards("AsAh")), .showHoleCards(player: 1, cards: cards("KsKh")),
            .burnCard(.unknown), .dealBoard(card("2c")), .dealBoard(card("7d")), .dealBoard(card("9h")),
            .burnCard(.unknown), .dealBoard(card("Td")), .burnCard(.unknown), .dealBoard(card("3s"))
        )
        #expect(hand.isHandComplete)
        try table.finish(hand, of: deal)
        #expect(!table.isHandInPlay)
        #expect(table.stacks == [2: 0, 5: 200, 7: 400])
        let next = try table.nextHand()
        #expect(next.seats == [5, 7])
        #expect(next.config.startingStacks == [200, 400])
    }

    @Test("a correction before the next deal moves only the difference, so a rebuy in between stays")
    func correctionBeforeTheNextDeal() throws {
        var table = try table(button: 5)
        let deal = try table.nextHand()
        let folded = try foldedToTheBigBlind(deal)
        try table.finish(folded, of: deal)
        #expect(table.stacks == [2: 201, 5: 200, 7: 199])
        try table.setStack(of: 5, to: 300)
        // The big blind really folded too, and the small blind took the pot.
        var corrected = folded.operations
        corrected[corrected.count - 1] = .checkOrCall(player: 0)
        let replayed = try HandState.replay(config: deal.config, operations: corrected + [.fold(player: 1)])
        #expect(replayed.stacks == [202, 198, 200])
        try table.finish(replayed, of: deal)
        #expect(table.stacks == [2: 198, 5: 300, 7: 202])
    }

    @Test("a correction is refused once a player of that hand has stood, or once the next hand is dealt")
    func correctionRefused() throws {
        var table = try table(button: 5)
        let deal = try table.nextHand()
        let folded = try foldedToTheBigBlind(deal)
        try table.finish(folded, of: deal)
        var stood = table
        #expect(try stood.stand(2) == 201)
        try stood.sit(2, stack: 500)
        #expect(throws: TableError.seatChanged(2)) { try stood.finish(folded, of: deal) }
        // The result stands once the next hand is dealt.
        let next = try table.nextHand()
        #expect(throws: TableError.notThisHand) { try table.finish(folded, of: deal) }
        try table.finish(foldedToTheBigBlind(next), of: next)
        #expect(throws: TableError.notThisHand) { try table.finish(folded, of: deal) }
    }

    @Test("a correction may not take more chips than a seat now has, and new stakes start with the next hand")
    func correctionBelowZeroAndNewStakes() throws {
        var table = try table(button: 5)
        let deal = try table.nextHand()
        let folded = try foldedToTheBigBlind(deal)
        try table.finish(folded, of: deal)
        try table.setStack(of: 2, to: 2)
        // The small blind really took the pot, so seat 2 would give back 3 of the 2 it kept.
        var corrected = folded.operations
        corrected[corrected.count - 1] = .checkOrCall(player: 0)
        let replayed = try HandState.replay(config: deal.config, operations: corrected + [.fold(player: 1)])
        let before = table
        #expect(throws: TableError.stackBelowZero(seat: 2)) { try table.finish(replayed, of: deal) }
        #expect(table == before)
        table.stakes = TableState.Stakes(mode: .cashGame, smallBlind: 2, bigBlind: 4)
        let next = try table.nextHand()
        #expect(next.config.blindsOrStraddles == [2, 4, 0])
        #expect(next.config.minBet == 4)
    }

    @Test("a stack never goes above the most chips a hand may hold, a correction's included")
    func stackLimit() throws {
        let tooMany = HandConfig.maximumChips + 1
        var table = try table(button: 5)
        #expect(throws: TableError.invalidStack(tooMany)) { try table.sit(0, stack: tooMany) }
        #expect(throws: TableError.invalidStack(tooMany)) { try table.setStack(of: 2, to: tooMany) }
        let deal = try table.nextHand()
        let folded = try foldedToTheBigBlind(deal)
        try table.finish(folded, of: deal)
        try table.setStack(of: 7, to: HandConfig.maximumChips)
        // The small blind, seat 7, really took the pot: 3 more chips than the limit.
        var corrected = folded.operations
        corrected[corrected.count - 1] = .checkOrCall(player: 0)
        let replayed = try HandState.replay(config: deal.config, operations: corrected + [.fold(player: 1)])
        #expect(throws: TableError.invalidStack(HandConfig.maximumChips + 3)) { try table.finish(replayed, of: deal) }
        #expect(table.stacks[7] == HandConfig.maximumChips)
    }

    @Test("finishing needs the hand last dealt, complete and with its players")
    func finishRefusals() throws {
        var table = try table()
        var other = try self.table()
        let otherDeal = try other.nextHand()
        #expect(throws: TableError.noHandDealt) {
            try table.finish(HandState(config: otherDeal.config).apply(.voidHand), of: otherDeal)
        }
        let deal = try table.nextHand()
        #expect(throws: TableError.handNotComplete) { try table.finish(HandState(config: deal.config), of: deal) }
        let headsUp = try HandState(config: .test(stacks: [100, 100])).apply(.voidHand)
        #expect(throws: TableError.notThisHand) { try table.finish(headsUp, of: deal) }
        #expect(table.isHandInPlay)
        #expect(deal.number == 1)
        #expect(otherDeal.number == 1)
    }

    // MARK: Seats

    @Test("players sit with chips, stand with them, and rebuy, all between hands")
    func seats() throws {
        var table = try TableState(stakes: Self.stakes, buttonSeat: 0)
        try table.sit(0, stack: 150)
        try table.sit(9, stack: 80)
        #expect(table.stacks == [0: 150, 9: 80])
        #expect(throws: TableError.seatTaken(9)) { try table.sit(9, stack: 100) }
        #expect(throws: TableError.noSuchSeat(10)) { try table.sit(10, stack: 100) }
        #expect(throws: TableError.noSuchSeat(-1)) { try table.sit(-1, stack: 100) }
        #expect(throws: TableError.invalidStack(0)) { try table.sit(3, stack: 0) }
        #expect(throws: TableError.seatEmpty(4)) { try table.stand(4) }
        #expect(throws: TableError.invalidStack(-5)) { try table.setStack(of: 0, to: -5) }
        try table.setStack(of: 9, to: 200)
        #expect(try table.stand(0) == 150)
        #expect(table.stacks == [9: 200])
    }

    @Test("a player with no chips is dealt out until a rebuy, and then owes no missed blind")
    func rebuy() throws {
        var table = try table(button: 7)
        try table.setStack(of: 2, to: 0)
        let dealtOut = try table.nextHand()
        #expect(dealtOut.seats == [5, 7])
        #expect(table.stacks[2] == 0)
        try table.finish(foldedToTheBigBlind(dealtOut), of: dealtOut)
        // Seat 2 rebuys and the button moves to it, so it posts nothing.
        try table.setStack(of: 2, to: 300)
        let back = try table.nextHand()
        #expect(back.seats == [5, 7, 2])
        #expect(HandState(config: back.config).bets == [1, 2, 0])
    }

    @Test("between hands a player changes seats with their chips, or trades seats with another")
    func changeSeat() throws {
        var table = try table(button: 5)
        try table.changeSeat(from: 7, to: 9)
        #expect(table.stacks == [2: 200, 5: 200, 9: 200])
        try table.setStack(of: 2, to: 150)
        try table.changeSeat(from: 2, to: 9)
        #expect(table.stacks == [2: 200, 5: 200, 9: 150])
        // A player with no chips keeps a seat, so they can change it too.
        try table.setStack(of: 5, to: 0)
        try table.changeSeat(from: 5, to: 3)
        #expect(table.stacks == [2: 200, 3: 0, 9: 150])
        try table.changeSeat(from: 3, to: 3)
        #expect(table.stacks == [2: 200, 3: 0, 9: 150])
        #expect(throws: TableError.seatEmpty(4)) { try table.changeSeat(from: 4, to: 6) }
        #expect(throws: TableError.noSuchSeat(10)) { try table.changeSeat(from: 2, to: 10) }
        #expect(throws: TableError.noSuchSeat(-1)) { try table.changeSeat(from: -1, to: 2) }
        _ = try table.nextHand()
        #expect(throws: TableError.handInPlay) { try table.changeSeat(from: 2, to: 4) }
    }

    @Test("the button stays with its seat when its player moves, and a correction cannot reach a player who moved")
    func changeSeatAfterAHand() throws {
        var table = try table(button: 5)
        let deal = try table.nextHand()
        let folded = try foldedToTheBigBlind(deal)
        try table.finish(folded, of: deal)
        // The player on the button, seat 5, moves to seat 8, and the button goes on from seat 5 to seat 7.
        try table.changeSeat(from: 5, to: 8)
        #expect(throws: TableError.seatChanged(5)) { try table.finish(folded, of: deal) }
        #expect(try table.nextHand().seats == [8, 2, 7])
    }

    @Test("seats and stacks cannot change while a hand is in play")
    func seatsFixedInAHand() throws {
        var table = try table()
        _ = try table.nextHand()
        #expect(throws: TableError.handInPlay) { try table.sit(0, stack: 100) }
        #expect(throws: TableError.handInPlay) { try table.stand(2) }
        #expect(throws: TableError.handInPlay) { try table.setStack(of: 2, to: 50) }
        #expect(throws: TableError.handInPlay) { try table.nextHand() }
        #expect(table.stacks == [2: 200, 5: 200, 7: 200])
    }

    @Test("heads-up the button posts the small blind, as the engine orders it")
    func headsUp() throws {
        var table = try TableState(stakes: Self.stakes, buttonSeat: 4)
        try table.sit(4, stack: 100)
        try table.sit(8, stack: 120)
        let deal = try table.nextHand()
        #expect(deal.seats == [8, 4])
        let hand = HandState(config: deal.config)
        #expect(hand.bets == [2, 1])
    }

    @Test("the table survives a JSON round trip, a hand in play included")
    func codable() throws {
        var table = try table()
        _ = try table.nextHand()
        let decoded = try JSONDecoder().decode(TableState.self, from: JSONEncoder().encode(table))
        #expect(decoded == table)
    }

    @Test("a moved button survives saving, a table saved before 0.2.3 reads as not moved, and a hand in play has none")
    func movedButtonCoding() throws {
        func object(_ table: TableState) throws -> [String: Any] {
            try #require(try JSONSerialization.jsonObject(with: JSONEncoder().encode(table)) as? [String: Any])
        }
        func decoded(_ object: [String: Any]) throws -> TableState {
            try JSONDecoder().decode(TableState.self, from: JSONSerialization.data(withJSONObject: object))
        }
        var table = try table(button: 5)
        let deal = try table.nextHand()
        try table.finish(foldedToTheBigBlind(deal), of: deal)
        var older = try object(table)
        older["buttonMoved"] = nil
        #expect(try decoded(older) == table)

        try table.moveButton(to: 2)
        #expect(try decoded(object(table)) == table)
        // Without the key the button is the last hand's, which was on seat 5.
        var unmoved = try object(table)
        unmoved["buttonMoved"] = nil
        #expect(throws: DecodingError.self) { try decoded(unmoved) }

        _ = try table.nextHand()
        var inPlay = try object(table)
        inPlay["buttonMoved"] = true
        #expect(throws: DecodingError.self) { try decoded(inPlay) }
    }

    @Test("decoding refuses a table that no calls could have left, such as a damaged save")
    func damagedSave() throws {
        var table = try table()
        let deal = try table.nextHand()
        try table.finish(foldedToTheBigBlind(deal), of: deal)
        let saved = try #require(try JSONSerialization.jsonObject(with: JSONEncoder().encode(table)) as? [String: Any])
        func decoded(_ change: (inout [String: Any]) -> Void) throws -> TableState {
            var object = saved
            change(&object)
            return try JSONDecoder().decode(TableState.self, from: JSONSerialization.data(withJSONObject: object))
        }
        #expect(try decoded { _ in } == table)
        let damage: [(inout [String: Any]) -> Void] = [
            { $0["stacks"] = ["2": -1, "5": 200, "7": 199] },
            { $0["stacks"] = ["2": HandConfig.maximumChips + 1, "5": 200, "7": 199] },
            { $0["stacks"] = ["2": 201, "5": 200, "7": 199, "12": 50] },
            { $0["buttonSeat"] = 10 },
            { $0["isHandInPlay"] = true },
            { $0["carriedStacks"] = [201, 200] },
            { $0["carriedStacks"] = [Int.max, Int.max, 0] },
            { $0["hand"] = nil },
            { $0["seatsLeft"] = [3] },
            { $0["hand"] = ($0["hand"] as? [String: Any]).map { $0.merging(["seats": [7, 7, 5]]) { $1 } } },
            { $0["hand"] = ($0["hand"] as? [String: Any]).map { $0.merging(["number": 0]) { $1 } } },
        ]
        for change in damage {
            #expect(throws: DecodingError.self) { try decoded(change) }
        }
    }

    @Test("a hand replayed on a corrected starting stack carries its chips to the seats, and the table still decodes")
    func correctedStartingStack() throws {
        var table = try table()
        let deal = try table.nextHand()
        // Seat 2, player 1, really started with 260.
        let old = deal.config
        let corrected = try HandConfig(
            mode: old.mode, startingStacks: [200, 260, 200], blindsOrStraddles: old.blindsOrStraddles,
            minBet: old.minBet
        )
        let folded = try foldedToTheBigBlind(deal)
        try table.finish(HandState.replay(config: corrected, operations: folded.operations), of: deal)
        #expect(table.stacks == [2: 261, 5: 200, 7: 199])
        #expect(try JSONDecoder().decode(TableState.self, from: JSONEncoder().encode(table)) == table)
    }
}
