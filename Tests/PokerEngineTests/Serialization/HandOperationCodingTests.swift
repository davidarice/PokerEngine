import Foundation
import Testing
@testable import PokerEngine

@Suite("Hand operation JSON")
struct HandOperationCodingTests {
    private static let allCases: [(HandOperation, String)] = [
        (.postAnte(player: 1), #"{"player":1,"type":"postAnte"}"#),
        (.collectBets, #"{"type":"collectBets"}"#),
        (.postBlindOrStraddle(player: 0), #"{"player":0,"type":"postBlindOrStraddle"}"#),
        (.burnCard(.unknown), #"{"card":"??","type":"burnCard"}"#),
        (.dealHole(player: 2, card: Card(.ace, .spades)), #"{"card":"As","player":2,"type":"dealHole"}"#),
        (.dealBoard(Card(.ten, .hearts)), #"{"card":"Th","type":"dealBoard"}"#),
        (.fold(player: 3), #"{"player":3,"type":"fold"}"#),
        (.checkOrCall(player: 4), #"{"player":4,"type":"checkOrCall"}"#),
        (.betOrRaise(player: 5, to: 60), #"{"player":5,"to":60,"type":"betOrRaise"}"#),
        (.selectRunoutCount(player: 0, count: 2), #"{"count":2,"player":0,"type":"selectRunoutCount"}"#),
        (.selectRunoutCount(player: 1, count: nil), #"{"player":1,"type":"selectRunoutCount"}"#),
        (.showHoleCards(player: 0), #"{"player":0,"type":"showHoleCards"}"#),
        (.showHoleCards(player: 1, cards: []), #"{"cards":[],"player":1,"type":"showHoleCards"}"#),
        (.showHoleCards(player: 1, cards: [Card(.king, .clubs)]), #"{"cards":["Kc"],"player":1,"type":"showHoleCards"}"#),
        (.muckHoleCards(player: 2), #"{"player":2,"type":"muckHoleCards"}"#),
        (.killHand(player: 3), #"{"player":3,"type":"killHand"}"#),
        (.pushChips, #"{"type":"pushChips"}"#),
        (.pullChips(player: 4), #"{"player":4,"type":"pullChips"}"#),
        (.chopBlinds, #"{"type":"chopBlinds"}"#),
        (.voidHand, #"{"type":"voidHand"}"#),
    ]

    @Test("encodes every case as a flat object with a type tag, and decodes it back")
    func roundTripsEveryCase() throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        for (operation, json) in Self.allCases {
            #expect(String(decoding: try encoder.encode(operation), as: UTF8.self) == json)
            #expect(try JSONDecoder().decode(HandOperation.self, from: Data(json.utf8)) == operation)
        }
    }

    @Test("rejects unknown types, missing fields, malformed cards and malformed optional fields")
    func rejectsMalformedOperations() {
        for json in [
            #"{"type":"shuffle"}"#,
            #"{"type":"fold"}"#,
            #"{"type":"betOrRaise","player":0}"#,
            #"{"type":"dealBoard","card":"as"}"#,
            #"{"type":"dealBoard","card":"AsKs"}"#,
            // A malformed optional field is an error, not an omitted one: corrupt cards must not become a show as
            // dealt, nor a corrupt count no preference.
            #"{"type":"showHoleCards","player":0,"cards":["as"]}"#,
            #"{"type":"showHoleCards","player":0,"cards":"As"}"#,
            #"{"type":"selectRunoutCount","player":0,"count":"2"}"#,
            #"{"type":"selectRunoutCount","player":0,"count":1.5}"#,
        ] {
            #expect(throws: DecodingError.self, "\(json)") { try JSONDecoder().decode(HandOperation.self, from: Data(json.utf8)) }
        }
    }
}
