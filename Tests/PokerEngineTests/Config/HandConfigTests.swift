import Foundation
import Testing
@testable import PokerEngine

@Suite("Hand config")
struct HandConfigTests {
    @Test("pads antes and blinds to the player count")
    func padsForcedBets() throws {
        let config = try HandConfig(
            mode: .cashGame, startingStacks: [200, 200, 200, 200], antes: [0, 2],
            blindsOrStraddles: [1, 2], minBet: 2
        )
        #expect(config.playerCount == 4)
        #expect(config.antes == [0, 2, 0, 0])
        #expect(config.blindsOrStraddles == [1, 2, 0, 0])
        #expect(config.anteTrimming == false)
        #expect(config.automations == .bookkeeping)
    }

    @Test("bookkeeping automates everything except runout selection")
    func bookkeepingAutomations() {
        #expect(Set<HandConfig.Automation>.bookkeeping == Set(HandConfig.Automation.allCases).subtracting([.runoutCountSelection]))
    }

    @Test("rejects invalid configs with a specific error")
    func rejectsInvalidConfigs() {
        func make(
            stacks: [Int] = [200, 200, 200], antes: [Int] = [], anteTrimming: Bool = false,
            blinds: [Int] = [1, 2], minBet: Int = 2
        ) throws(ConfigError) -> HandConfig {
            try HandConfig(
                mode: .tournament, startingStacks: stacks, antes: antes, anteTrimming: anteTrimming,
                blindsOrStraddles: blinds, minBet: minBet
            )
        }
        #expect(throws: ConfigError.playerCountOutOfRange(1)) { try make(stacks: [200]) }
        #expect(throws: ConfigError.playerCountOutOfRange(11)) { try make(stacks: Array(repeating: 200, count: 11)) }
        #expect(throws: ConfigError.nonPositiveStartingStack(player: 1)) { try make(stacks: [200, 0, 200]) }
        #expect(throws: ConfigError.negativeAnte(position: 2)) { try make(antes: [1, 1, -1]) }
        #expect(throws: ConfigError.tooManyAntes(4)) { try make(antes: [1, 1, 1, 1]) }
        // PokerKit silently drops the extra entries, which loses a heads-up straddle (DECISIONS.md B8).
        #expect(throws: ConfigError.tooManyBlindsOrStraddles(3)) { try make(stacks: [200, 200], blinds: [1, 2, 4]) }
        #expect(throws: ConfigError.noForcedBets) { try make(antes: [0, 0], blinds: [0, 0]) }
        #expect(throws: ConfigError.nonPositiveMinBet(0)) { try make(minBet: 0) }
        #expect(throws: ConfigError.anteTrimmingRequiresUniformAntes) { try make(antes: [0, 2], anteTrimming: true) }
        // [5] pads to [5, 0, 0], and trimming would refund that ante in full.
        #expect(throws: ConfigError.anteTrimmingRequiresUniformAntes) { try make(antes: [5], anteTrimming: true) }
    }

    @Test("rejects amounts that could overflow the engine's arithmetic")
    func rejectsHugeAmounts() throws {
        func make(stacks: [Int] = [200, 200], antes: [Int] = [], blinds: [Int] = [1, 2], minBet: Int = 2) throws(ConfigError) {
            _ = try HandConfig(mode: .cashGame, startingStacks: stacks, antes: antes, blindsOrStraddles: blinds, minBet: minBet)
        }
        let limit = HandConfig.maximumChips
        #expect(throws: ConfigError.amountsTooLarge) { try make(stacks: [Int.max, Int.max]) }
        #expect(throws: ConfigError.amountsTooLarge) { try make(stacks: [limit / 2 + 1, limit / 2]) }
        #expect(throws: ConfigError.amountsTooLarge) { try make(blinds: [Int.min, 2]) }
        #expect(throws: ConfigError.amountsTooLarge) { try make(blinds: [1, limit + 1]) }
        #expect(throws: ConfigError.amountsTooLarge) { try make(antes: [0, limit + 1]) }
        #expect(throws: ConfigError.amountsTooLarge) { try make(minBet: limit + 1) }
        try make(stacks: [limit / 2, limit / 2], antes: [0, limit], blinds: [-limit, limit], minBet: limit)
    }

    @Test("accepts live posts, ante-only hands and uniform trimmed antes")
    func acceptsValidEdgeCases() throws {
        // A negative blind is PokerKit's live post by a player who just sat down.
        let livePost = try HandConfig(mode: .cashGame, startingStacks: [200, 200, 200, 200], blindsOrStraddles: [1, 2, 0, -2], minBet: 2)
        #expect(livePost.blindsOrStraddles == [1, 2, 0, -2])
        let anteOnly = try HandConfig(mode: .tournament, startingStacks: [50, 50], antes: [1, 1], anteTrimming: true, blindsOrStraddles: [], minBet: 1)
        #expect(anteOnly.blindsOrStraddles == [0, 0])
        let noAntesTrimmed = try HandConfig(mode: .tournament, startingStacks: [50, 50], anteTrimming: true, blindsOrStraddles: [1, 2], minBet: 2)
        #expect(noAntesTrimmed.antes == [0, 0])
    }

    @Test("maps physical seats to player indices, starting left of the button")
    func playerOrder() {
        #expect(HandConfig.playerOrder(occupiedSeats: [2, 5, 7, 9], buttonSeat: 7) == [9, 2, 5, 7])
        #expect(HandConfig.playerOrder(occupiedSeats: [9, 2, 7, 5], buttonSeat: 9) == [2, 5, 7, 9])
        // Heads-up the button posts the small blind and is player 1; player 0 is the big blind.
        #expect(HandConfig.playerOrder(occupiedSeats: [3, 8], buttonSeat: 3) == [8, 3])
        // A dead button on an empty seat: the seat before it acts last.
        #expect(HandConfig.playerOrder(occupiedSeats: [1, 4, 6], buttonSeat: 5) == [6, 1, 4])
    }

    @Test("round-trips through JSON with automations in declaration order")
    func jsonRoundTrip() throws {
        // Declaration order puts handKilling, chipsPushing and chipsPulling the reverse of alphabetical order.
        let config = try HandConfig(
            mode: .cashGame, startingStacks: [100, 250, 400], antes: [0, 0, 5],
            blindsOrStraddles: [1, 2, 4], minBet: 2, automations: [.chipsPulling, .chipsPushing, .handKilling, .antePosting]
        )
        let json = try JSONEncoder().encode(config)
        let stored = Data(#"{"anteTrimming":false,"antes":[0,0,5],"automations":["antePosting","handKilling","chipsPushing","chipsPulling"],"blindsOrStraddles":[1,2,4],"minBet":2,"mode":"cashGame","startingStacks":[100,250,400]}"#.utf8)
        let decoder = JSONDecoder()
        #expect(try decoder.decode(JSONValue.self, from: json) == decoder.decode(JSONValue.self, from: stored))
        #expect(try decoder.decode(HandConfig.self, from: stored) == config)
    }

    @Test("decoding validates the config, passing on why, and rejects duplicate automations and missing keys")
    func decodingValidates() throws {
        let invalid = #"{"anteTrimming":false,"antes":[],"automations":[],"blindsOrStraddles":[1,2],"minBet":2,"mode":"cashGame","startingStacks":[200]}"#
        let error = #expect(throws: DecodingError.self) { try JSONDecoder().decode(HandConfig.self, from: Data(invalid.utf8)) }
        guard case let .dataCorrupted(context)? = error else {
            Issue.record("Expected a dataCorrupted error, got \(String(describing: error))")
            return
        }
        #expect(context.underlyingError as? ConfigError == .playerCountOutOfRange(1))
        let duplicate = #"{"anteTrimming":false,"antes":[],"automations":["betCollection","betCollection"],"blindsOrStraddles":[1,2],"minBet":2,"mode":"cashGame","startingStacks":[200,200]}"#
        #expect(throws: DecodingError.self) { try JSONDecoder().decode(HandConfig.self, from: Data(duplicate.utf8)) }
        // Every key is required: a stored config that lost one must not load with the init's default.
        let fields = [
            #""anteTrimming":false"#, #""antes":[]"#, #""automations":[]"#, #""blindsOrStraddles":[1,2]"#,
            #""minBet":2"#, #""mode":"cashGame""#, #""startingStacks":[200,200]"#,
        ]
        func document(_ fields: [String]) -> Data { Data("{\(fields.joined(separator: ","))}".utf8) }
        #expect(try JSONDecoder().decode(HandConfig.self, from: document(fields)).playerCount == 2)
        for field in fields {
            #expect(throws: DecodingError.self, "without \(field)") {
                try JSONDecoder().decode(HandConfig.self, from: document(fields.filter { $0 != field }))
            }
        }
    }

    @Test("the game is Texas Hold'em unless chosen, and only another game writes it")
    func variant() throws {
        let holdem = try HandConfig(mode: .cashGame, startingStacks: [100, 100], blindsOrStraddles: [1, 2], minBet: 2)
        #expect(holdem.variant == .noLimitTexasHoldem)
        let omaha = try HandConfig(
            variant: .potLimitOmahaHoldem, mode: .cashGame, startingStacks: [100, 100], blindsOrStraddles: [1, 2],
            minBet: 2
        )
        #expect(omaha.variant == .potLimitOmahaHoldem)
        #expect(omaha != holdem)
        let decoder = JSONDecoder()
        let written = try decoder.decode([String: JSONValue].self, from: JSONEncoder().encode(omaha))
        #expect(written["variant"] == .string("potLimitOmahaHoldem"))
        #expect(try decoder.decode([String: JSONValue].self, from: JSONEncoder().encode(holdem))["variant"] == nil)
        #expect(try decoder.decode(HandConfig.self, from: JSONEncoder().encode(omaha)) == omaha)
        let unknown = #"{"anteTrimming":false,"antes":[0,0],"automations":[],"blindsOrStraddles":[1,2],"minBet":2,"mode":"cashGame","startingStacks":[100,100],"variant":"razz"}"#
        #expect(throws: DecodingError.self) { try decoder.decode(HandConfig.self, from: Data(unknown.utf8)) }
    }
}
