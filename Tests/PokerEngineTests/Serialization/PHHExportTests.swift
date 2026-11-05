import Testing
@testable import PokerEngine

@Suite("PHH export")
struct PHHExportTests {
    /// Heads-up, the button shoves before the flop and the big blind calls. Player 0 holds aces, player 1 kings.
    private func allIn() throws -> HandState {
        try HandState(config: .test(stacks: [100, 100])).dealingHoles("AsKsAhKh")
            .applying(.betOrRaise(player: 1, to: 100), .checkOrCall(player: 0))
    }

    private func actions(_ state: HandState) throws -> String {
        let line = try #require(try state.phh().split(separator: "\n").first { $0.hasPrefix("actions = ") })
        return String(line.dropFirst("actions = ".count))
    }

    @Test("the text matches PokerKit's byte for byte (quirks.json, extra_d_phh_text)")
    func referenceText() throws {
        let state = try HandState(config: .test(stacks: [200, 200], antes: [1, 1], anteTrimming: true))
            .dealingHoles("AcKcAdKd")
            .applying(.betOrRaise(player: 1, to: 6), .checkOrCall(player: 0))
            .dealingStreet("Jc8d2s")
            .applying(.checkOrCall(player: 0), .betOrRaise(player: 1, to: 8), .checkOrCall(player: 0))
            .dealingStreet("7h")
            .applying(.checkOrCall(player: 0), .checkOrCall(player: 1))
            .dealingStreet("3c")
            .applying(.betOrRaise(player: 0, to: 20), .checkOrCall(player: 1))
            .applying(.showHoleCards(player: 0), .muckHoleCards(player: 1))
        #expect(try state.phh() == """
            variant = 'NT'
            ante_trimming_status = true
            antes = [1, 1]
            blinds_or_straddles = [1, 2]
            min_bet = 2
            starting_stacks = [200, 200]
            actions = ['d dh p1 AcAd', 'd dh p2 KcKd', 'p2 cbr 6', 'p1 cc', 'd db Jc8d2s', 'p1 cc', 'p2 cbr 8', \
            'p1 cc', 'd db 7h', 'p1 cc', 'p2 cc', 'd db 3c', 'p1 cbr 20', 'p2 cc', 'p1 sm AcAd', 'p2 sm']
            finishing_stacks = [235, 165]
            winnings = [70, 0]
            """)
    }

    @Test("burns, posts, collections, runout choices, kills, pushes and pulls leave no line")
    func bookkeepingIsDropped() throws {
        let state = try HandState(config: .test(stacks: [100, 100], antes: [1, 1], automations: []))
            .applying(.postAnte(player: 0), .postAnte(player: 1), .collectBets)
            .applying(.postBlindOrStraddle(player: 0), .postBlindOrStraddle(player: 1))
            .dealingHoles("AsKsAhKh")
            .applying(.betOrRaise(player: 1, to: 99), .checkOrCall(player: 0), .collectBets)
            .applying(.selectRunoutCount(player: 0, count: nil), .selectRunoutCount(player: 1, count: 1))
            .applying(.showHoleCards(player: 0), .showHoleCards(player: 1))
            .dealingStreet("2c7d9h").dealingStreet("Td").dealingStreet("3s")
            .applying(.killHand(player: 1), .pushChips, .pullChips(player: 0))
        #expect(state.isHandComplete)
        #expect(try actions(state) == """
            ['d dh p1 AsAh', 'd dh p2 KsKh', 'p2 cbr 99', 'p1 cc', 'p1 sm AsAh', 'p2 sm KsKh', 'd db 2c7d9h', \
            'd db Td', 'd db 3s']
            """)
    }

    @Test("hole cards are grouped by player, whatever order they were dealt in")
    func holeCardsGroupedByPlayer() throws {
        let state = try HandState(config: .test(stacks: [100, 100, 100])).applying(
            .dealHole(player: 2, card: card("2c")), .dealHole(player: 2, card: card("3c")),
            .dealHole(player: 0, card: card("As")), .dealHole(player: 1, card: .unknown),
            .dealHole(player: 1, card: card("Kh")), .dealHole(player: 0, card: card("Ah"))
        )
        #expect(try actions(state) == "['d dh p1 AsAh', 'd dh p2 ??Kh', 'd dh p3 2c3c']")
    }

    @Test("a board card dealt so far is written even mid-street")
    func handInProgress() throws {
        let state = try HandState(config: .test(stacks: [100, 100])).dealingHoles("AsKsAhKh").checkingDown()
            .applying(.burnCard(.unknown), .dealBoard(card("2c")), .dealBoard(.unknown))
        let text = try state.phh()
        #expect(text.contains("'p1 cc', 'd db 2c??']\nfinishing_stacks = [98, 98]\nwinnings = [0, 0]"))
        #expect(!text.hasSuffix("\n"))
    }

    @Test("mid-hand stacks leave out live bets, and winnings count only the pushes made so far")
    func midHandValues() throws {
        let betting = try HandState(config: .test(stacks: [100, 100])).dealingHoles("AsKsAhKh")
            .applying(.betOrRaise(player: 1, to: 6))
        #expect(try betting.phh().hasSuffix("finishing_stacks = [98, 94]\nwinnings = [0, 0]"))
        let pushing = try HandState(config: .test(
            stacks: [50, 100, 100], automations: .bookkeeping.subtracting([.chipsPushing, .chipsPulling])
        ))
        .dealingHoles("AsKsQsAhKhQh")
        .applying(.betOrRaise(player: 2, to: 100), .checkOrCall(player: 0), .checkOrCall(player: 1))
        .applying(
            .selectRunoutCount(player: 0, count: nil), .selectRunoutCount(player: 1, count: nil),
            .selectRunoutCount(player: 2, count: nil)
        )
        .applying(.showHoleCards(player: 2), .showHoleCards(player: 0), .showHoleCards(player: 1))
        .dealingStreet("2c7d9h").dealingStreet("Td").dealingStreet("3s")
        .applying(.pushChips)
        #expect(try pushing.phh().hasSuffix("finishing_stacks = [0, 0, 0]\nwinnings = [150, 0, 0]"))
    }

    @Test("a muck has no cards, and a partial show pads with unknown cards as PokerKit records it")
    func showsAndMucks() throws {
        let state = try allIn().applying(.selectRunoutCount(player: 0, count: nil), .selectRunoutCount(player: 1, count: nil))
            .applying(.showHoleCards(player: 0, cards: cards("Ah")), .showHoleCards(player: 1, cards: []))
        #expect(try actions(state).hasSuffix("'p1 sm Ah??', 'p2 sm ????']"))
        let mucked = try allIn().applying(.muckHoleCards(player: 1))
        #expect(try actions(mucked).hasSuffix("'p1 cc', 'p2 sm']"))
    }

    @Test("a show after the hand gets a line like any other")
    func postHandShow() throws {
        let state = try HandState(config: .test(stacks: [100, 100])).dealingHoles("AsKsAhKh")
            .applying(.fold(player: 1))
        let shown = try state.apply(.showHoleCards(player: 0))
        #expect(try actions(shown) == "['d dh p1 AsAh', 'd dh p2 KsKh', 'p2 f', 'p1 sm AsAh']")
    }

    @Test("winnings leave out a bet returned to the winner, and stacks are as they stand")
    func winnings() throws {
        let state = try HandState(config: .test(stacks: [100, 100])).dealingHoles("AsKsAhKh")
            .applying(.betOrRaise(player: 1, to: 6), .fold(player: 0))
        let text = try state.phh()
        #expect(text.hasSuffix("finishing_stacks = [98, 102]\nwinnings = [0, 2]"))
    }

    @Test("a hand on more than one runout cannot be exported")
    func multipleRunouts() throws {
        let chosen = try allIn().applying(.selectRunoutCount(player: 0, count: 2), .selectRunoutCount(player: 1, count: 2))
        #expect(try chosen.phh().hasPrefix("variant = 'NT'\n"), "The count has not taken effect yet")
        let shown = try chosen.applying(.showHoleCards(player: 0), .showHoleCards(player: 1))
        #expect(throws: PHHExportError.multipleRunouts(count: 2)) { try shown.phh() }
        let conceded = try allIn().applying(.selectRunoutCount(player: 0, count: 3), .selectRunoutCount(player: 1, count: 3))
            .applying(.showHoleCards(player: 0), .muckHoleCards(player: 1))
        #expect(throws: PHHExportError.multipleRunouts(count: 3)) { try conceded.phh() }
    }

    @Test("a table that disagrees runs once, so its hand can be exported")
    func disagreementRunsOnce() throws {
        let state = try allIn().applying(.selectRunoutCount(player: 0, count: 2), .selectRunoutCount(player: 1, count: 3))
            .applying(.showHoleCards(player: 0), .showHoleCards(player: 1))
        #expect(state.runoutCount == 1)
        #expect(try state.phh().hasPrefix("variant = 'NT'\n"))
    }
}
