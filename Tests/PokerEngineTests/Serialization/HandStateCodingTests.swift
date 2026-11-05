import Foundation
import Testing
@testable import PokerEngine

/// The stored documents in `Fixtures/json`, and the hands behind them.
enum StoredDocument: String, CaseIterable, Sendable {
    case foldOut = "fold-out", midHand = "mid-hand", twoRuns = "two-runs", showdown, chopped, voided, omaha

    func hand() throws -> HandState {
        let holes = try HandState(config: .test(stacks: [100, 100])).dealingHoles("AsKsAhKh")
        switch self {
        case .omaha:
            return try HandState(config: .test(variant: .potLimitOmahaHoldem, stacks: [100, 100]))
                .dealingHoles("AsKsAhKhAdKdAcKc").applying(.betOrRaise(player: 1, to: 6), .fold(player: 0))
        case .foldOut:
            return try holes.applying(.betOrRaise(player: 1, to: 6), .fold(player: 0))
        case .chopped:
            return try holes.apply(.chopBlinds)
        case .voided:
            return try holes.checkingDown().dealingStreet("2c7d9h").applying(.betOrRaise(player: 0, to: 6), .voidHand)
        case .midHand:
            return try holes.checkingDown().dealingStreet("2c7d9h").applying(.betOrRaise(player: 0, to: 6))
        case .twoRuns:
            return try holes.checkingDown().dealingStreet("2c7d9h")
                .applying(.betOrRaise(player: 0, to: 98), .checkOrCall(player: 1))
                .applying(.selectRunoutCount(player: 0, count: 2), .selectRunoutCount(player: 1, count: nil))
                .applying(.showHoleCards(player: 0), .showHoleCards(player: 1))
                .dealingStreet("Td").dealingStreet("3s").dealingStreet("Kc").dealingStreet("Qd")
        case .showdown:
            return try HandState(config: .test(stacks: [100, 100, 100])).dealingHoles("AsKsQsAhKhQh")
                .checkingDown().dealingStreet("2c7d9h").checkingDown().dealingStreet("Td").checkingDown()
                .dealingStreet("3s").checkingDown()
                .applying(.showHoleCards(player: 0), .muckHoleCards(player: 1), .showHoleCards(player: 2))
        }
    }

    func text() throws -> String {
        try String(decoding: Fixtures.data("json/\(rawValue).json"), as: UTF8.self).trimmingCharacters(in: .newlines)
    }
}

@Suite("Hand JSON")
struct HandStateCodingTests {
    /// The fold-out document with `old` replaced, which must be there.
    private func tampered(_ old: String, with new: String) throws -> Data {
        let text = try StoredDocument.foldOut.text()
        #expect(text.contains(old), "\(old) is not in the document")
        return Data(text.replacingOccurrences(of: old, with: new).utf8)
    }

    private func decodingError(_ json: Data) -> DecodingError? {
        do {
            _ = try HandState(json: json)
            return nil
        } catch {
            return error as? DecodingError
        }
    }

    // MARK: The stored format

    @Test("these documents pin the stored format: a change that breaks one needs a new formatVersion", arguments: StoredDocument.allCases)
    func storedDocuments(document: StoredDocument) throws {
        let state = try document.hand()
        let json = Data(try document.text().utf8)
        // Contents, not bytes: the order of sorted keys depends on the OS (DECISIONS.md C14).
        let decoder = JSONDecoder()
        #expect(try decoder.decode(JSONValue.self, from: state.json()) == decoder.decode(JSONValue.self, from: json))
        #expect(try HandState(json: json) == state)
    }

    @Test("a hand under way has no results yet, and its stacks are as they stand")
    func handUnderWay() throws {
        let state = try StoredDocument.midHand.hand()
        let summary = try JSONSerialization.jsonObject(with: state.json()) as? [String: Any]
        #expect(summary?["complete"] as? Bool == false)
        #expect(summary?["results"] is NSNull)
        #expect(summary?["finalStacks"] as? [Int] == [92, 98])
    }

    @Test("a plain JSONEncoder writes the same document as json(), given sorted keys")
    func plainEncoder() throws {
        let state = try StoredDocument.twoRuns.hand()
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        #expect(try encoder.encode(state) == state.json())
    }

    @Test("a plain JSONDecoder replays and checks the version and the summary, but not the text (DECISIONS.md C10)")
    func plainDecoder() throws {
        let decoder = JSONDecoder()
        let document = StoredDocument.foldOut
        #expect(try decoder.decode(HandState.self, from: Data(document.text().utf8)) == document.hand())
        #expect(throws: DecodingError.self) {
            try decoder.decode(HandState.self, from: tampered(#""formatVersion":1"#, with: #""formatVersion":2"#))
        }
        #expect(throws: DecodingError.self) {
            try decoder.decode(HandState.self, from: tampered(#""won":2"#, with: #""won":3"#))
        }
        let outsideTheFormat = try tampered(#""complete":true"#, with: #""complete":true,"x":0.5"#)
        #expect(try decoder.decode(HandState.self, from: outsideTheFormat) == document.hand())
        #expect(decodingError(outsideTheFormat) != nil)
    }

    // MARK: Refusals

    @Test("any other format version is refused", arguments: [
        #""formatVersion":0"#, #""formatVersion":3"#, #""formatVersion":"1""#, #""formatVersion":1.5"#,
        #""formatVersion":null"#,
    ])
    func otherVersions(version: String) throws {
        #expect(decodingError(try tampered(#""formatVersion":1"#, with: version)) != nil)
    }

    @Test("an Omaha hand is version 2 with its game in the config, and a Texas Hold'em hand stays version 1")
    func versionsByGame() throws {
        let decoder = JSONDecoder()
        let omaha = try decoder.decode([String: JSONValue].self, from: StoredDocument.omaha.hand().json())
        #expect(omaha["formatVersion"] == .int(2))
        #expect(omaha["config"] == JSONValue.object(try decoder.decode(
            [String: JSONValue].self, from: JSONEncoder().encode(StoredDocument.omaha.hand().config)
        )))
        let holdem = try decoder.decode([String: JSONValue].self, from: StoredDocument.foldOut.hand().json())
        #expect(holdem["formatVersion"] == .int(1))
        guard case let .object(config)? = holdem["config"] else {
            Issue.record("No config in \(holdem)")
            return
        }
        #expect(config["variant"] == nil)
    }

    @Test("version 1 has no game, so a variant in its config is ignored, and version 2 must name the game")
    func variantByVersion() throws {
        let ignored = try tampered(#""minBet":2"#, with: #""minBet":2,"variant":"potLimitOmahaHoldem""#)
        #expect(try HandState(json: ignored) == StoredDocument.foldOut.hand())
        let unnamed = try tampered(#""formatVersion":1"#, with: #""formatVersion":2"#)
        guard case let .keyNotFound(missing, _)? = decodingError(unnamed) else {
            Issue.record("A version 2 document without a variant: \(String(describing: decodingError(unnamed)))")
            return
        }
        #expect(missing.stringValue == "variant")
        let named = try StoredDocument.foldOut.text()
            .replacingOccurrences(of: #""formatVersion":1"#, with: #""formatVersion":2"#)
            .replacingOccurrences(of: #""minBet":2"#, with: #""minBet":2,"variant":"noLimitTexasHoldem""#)
        #expect(try HandState(json: Data(named.utf8)) == StoredDocument.foldOut.hand())
    }

    @Test("every key is required", arguments: [
        "boards", "complete", "config", "finalStacks", "formatVersion", "operations", "results", "runoutCount",
    ])
    func missingKeys(key: String) throws {
        var object = try #require(
            try JSONSerialization.jsonObject(with: Data(StoredDocument.foldOut.text().utf8)) as? [String: Any]
        )
        object[key] = nil
        let error = decodingError(try JSONSerialization.data(withJSONObject: object))
        guard case let .keyNotFound(missing, _)? = error else {
            Issue.record("\(key): \(String(describing: error))")
            return
        }
        #expect(missing.stringValue == key)
    }

    @Test("an invalid config is refused")
    func invalidConfig() throws {
        #expect(decodingError(try tampered(#""minBet":2"#, with: #""minBet":0"#)) != nil)
    }

    @Test("an operation the hand refuses is refused, naming it")
    func operationRefused() throws {
        let error = decodingError(try tampered(
            #"{"player":1,"to":6,"type":"betOrRaise"}"#, with: #"{"player":0,"to":6,"type":"betOrRaise"}"#
        ))
        guard case let .dataCorrupted(context)? = error else {
            Issue.record("\(String(describing: error))")
            return
        }
        let refusal = try #require(context.underlyingError as? ReplayError)
        #expect(refusal.operationIndex == 4)
        #expect(refusal.error == .notYourTurn(player: 0, actor: 1))
    }

    @Test("a summary that disagrees with the operations is refused, whichever field it is", arguments: [
        (#""finalStacks":[98,102]"#, #""finalStacks":[102,98]"#),
        (#""complete":true"#, #""complete":false"#),
        (#""runoutCount":1"#, #""runoutCount":2"#),
        (#""boards":[[]]"#, #""boards":[["As"]]"#),
        (#""boards":[[]]"#, #""boards":[[],[]]"#),
        (#""won":2"#, #""won":3"#),
        (#""net":2"#, #""net":3"#),
        (#""status":"folded""#, #""status":"mucked""#),
        (#""shown":false"#, #""shown":true"#),
        (#""holeCards":[{"card":"As""#, #""holeCards":[{"card":"Ac""#),
        (#"{"card":"As","isFaceUp":false}"#, #"{"card":"As","isFaceUp":true}"#),
        (#""net":-2,"player":0"#, #""net":-2,"player":1"#),
    ])
    func disagreeingSummary(old: String, new: String) throws {
        guard case .dataCorrupted? = decodingError(try tampered(old, with: new)) else {
            Issue.record("\(new) was not refused as corrupt")
            return
        }
    }

    @Test("a key the format does not have is ignored, so a later addition within C10's rules cannot change the hand")
    func unknownKey() throws {
        let json = try tampered(#""complete":true"#, with: #""complete":true,"note":"x""#)
        #expect(try HandState(json: json) == StoredDocument.foldOut.hand())
    }

    @Test("results that are missing or there too early are refused")
    func resultsAndCompletion() throws {
        #expect(decodingError(try tampered(#""results":["#, with: #""results":null,"x":["#)) != nil)
        let midHand = try StoredDocument.midHand.text()
        let early = midHand.replacingOccurrences(of: #""results":null"#, with: #""results":[]"#)
        #expect(early != midHand)
        #expect(decodingError(Data(early.utf8)) != nil)
    }

    @Test("malformed JSON is refused", arguments: [#"{"#, #""#, #"[]"#, #"null"#])
    func malformed(text: String) {
        #expect(decodingError(Data(text.utf8)) != nil)
    }

    @Test("a document ends where it ends: nothing may follow it, not even a second document")
    func trailingText() throws {
        let text = try StoredDocument.foldOut.text()
        #expect(decodingError(Data((text + "trailing").utf8)) != nil)
        #expect(decodingError(Data((text + text).utf8)) != nil)
    }

    // MARK: Repeated keys

    @Test("a repeated key is refused at any depth, because other readers would see a different hand", arguments: [
        (#""complete":true"#, #""complete":true,"complete":true"#),
        (#""formatVersion":1"#, #""formatVersion":1,"formatVersion":2"#),
        (#""minBet":2"#, #""minBet":2,"minBet":4"#),
        (#"{"player":1,"to":6,"type":"betOrRaise"}"#, #"{"player":1,"player":1,"to":6,"type":"betOrRaise"}"#),
        (#""won":2"#, #""won":2,"won":99"#),
        (#""card":"As","isFaceUp":false"#, #""card":"As","card":"As","isFaceUp":false"#),
    ])
    func repeatedKeys(old: String, new: String) throws {
        let error = decodingError(try tampered(old, with: new))
        guard case .dataCorrupted? = error else {
            Issue.record("\(new): \(String(describing: error))")
            return
        }
    }

    @Test("the same key in different objects, and text that only looks like a key, are not repeats", arguments: [
        #"{"a":{"a":1},"b":{"a":2}}"#,
        #"[{"a":1},{"a":2}]"#,
        #"{"a":"b","b":"a"}"#,
        #"{"a":["b","b"],"b":"a:1"}"#,
        "{\n  \"a\" : 1 ,\n  \"b\" : {\t\"a\" : 2 }\r\n}",
    ])
    func notRepeats(json: String) {
        #expect(!refused(json))
    }

    @Test("repeats are found wherever they are", arguments: [
        (#"{"a":1,"a":2}"#, "a"),
        ("{\"b\" : 1 ,\n\"b\"\t: 2}", "b"),
        ("{\"b\"\r\n: 1, \"b\"\n: 2}", "b"),
        (#"{"a":{"c":[{"d":1,"e":{"f":2},"d":3}]}}"#, "d"),
        (#"{"a":{"b":1},"c":2,"a":3}"#, "a"),
    ])
    func repeats(json: String, key: String) {
        let error = #expect(throws: DecodingError.self) { try StoredJSONScanner.check(Data(json.utf8)) }
        guard case let .dataCorrupted(context)? = error else {
            Issue.record("\(json): \(String(describing: error))")
            return
        }
        #expect(context.debugDescription == "Repeated key \(key)")
    }

    // MARK: The text of a document

    /// Whether the scanner alone refuses the text, so that `JSONDecoder` cannot hide a check that is missing.
    private func refused(_ text: String) -> Bool {
        refused(Data(text.utf8))
    }

    private func refused(_ json: Data) -> Bool {
        do {
            try StoredJSONScanner.check(json)
            return false
        } catch {
            return error is DecodingError
        }
    }

    @Test("a string holds printable ASCII and no escape, as a value or as a key", arguments: [
        #"\u0061"#, #"\u12"#, #"\ud800"#, #"\""#, #"\\"#, #"\/"#, #"\n"#, #"\q"#, "\\",
        "\n", "\t", "\u{7F}", "\u{0}", "\u{E9}", "\u{212A}", "e\u{301}", "\u{1F0A1}",
    ])
    func stringsOutsideTheFormat(text: String) {
        #expect(refused("{\"a\":\"\(text)\"}"))
        #expect(refused("{\"\(text)\":1}"))
    }

    @Test("bytes that are not text are refused, wherever they are", arguments: [
        [0xFF], [0xC0, 0x80], [0xEF, 0xBB, 0xBF], [0xED, 0xA0, 0x80],
    ] as [[UInt8]])
    func bytesOutsideTheFormat(bytes: [UInt8]) {
        #expect(refused(Data(Array(#"{"a":""#.utf8) + bytes + Array(#""}"#.utf8))))
        #expect(refused(Data(bytes + Array("{}".utf8))))
    }

    @Test("a number is a whole number of at most 19 digits, written as JSON writes one", arguments: [
        "2.0", "2e0", "2E0", "20e-1", "1e+1", "1.9999999999999999", "1e-400", "-2.0", "01", "-01", "00", "--1", "-",
        "+1", ".5", "1.", "1e", "1e5e5", "NaN", "Infinity", "-Infinity", "0x10",
        "10000000000000000000", "-10000000000000000000", String(repeating: "9", count: 4_301),
    ])
    func numbersOutsideTheFormat(number: String) {
        #expect(refused("[\(number)]"))
        #expect(refused("{\"a\":\(number)}"))
        #expect(refused(number))
    }

    @Test("anything out of place is refused, including what JSONDecoder lets through", arguments: [
        "", " ", "[", "]", "[[]", "[]]", "[1,]", "[,1]", "[,]", "[1,,2]", "[1 2]", "{", "}", "{,}", "{}{}", "1 1",
        #"{"a":1,}"#, #"{"a":1 "b":2}"#, #"{"a"}"#, #"{"a":}"#, #"{"a" 1}"#, #"{"a":1"#, #"{"a":1}}"#, "{a:1}",
        "{1:2}", "{null:1}",
        "'a'", "\"a", "tru", "truex", "nul", "fals", "False", "// note", "/* note */ 1", "[1] // note",
        "[\u{B}]", "[\u{C}]", "[\u{85}]", "[\u{A0}]", "[\u{2028}]", "[\u{3000}]",
    ])
    func structureOutsideTheFormat(text: String) {
        #expect(refused(text))
    }

    @Test("JSON in the engine's own terms passes", arguments: [
        "{}", "[]", "{ }", "[ ]", "null", "true", "false", "0", "-0", "-1", "10", "1234567890", #""""#, #"" ~!""#,
        "1125899906842624", "9223372036854775807", "-9223372036854775808", "9999999999999999999",
        #"{"a":[1,{"b":[]},null,true,false,"c"],"d":{}}"#,
        " \t\r\n[ 1 , { \"a\" : [ ] } ] \t\r\n",
    ])
    func jsonWithinTheFormat(text: String) {
        #expect(!refused(text))
    }

    @Test("nesting is limited, so a hostile document cannot exhaust the stack")
    func depth() {
        func arrays(_ levels: Int) -> String {
            String(repeating: "[", count: levels) + String(repeating: "]", count: levels)
        }
        func objects(_ levels: Int) -> String {
            String(repeating: #"{"a":"#, count: levels) + "1" + String(repeating: "}", count: levels)
        }
        #expect(!refused(arrays(StoredJSONScanner.maximumDepth)))
        #expect(refused(arrays(StoredJSONScanner.maximumDepth + 1)))
        #expect(!refused(objects(StoredJSONScanner.maximumDepth - 1)))
        #expect(refused(objects(StoredJSONScanner.maximumDepth)))
        #expect(refused(String(repeating: "[", count: StoredJSONScanner.maximumSize)))
    }

    @Test("a document over the size limit is refused, whatever it holds")
    func size() {
        let padding = String(repeating: " ", count: StoredJSONScanner.maximumSize - 2)
        #expect(!refused("{}" + padding))
        #expect(refused("{}" + padding + " "))
    }

    @Test("the text is checked first, so JSONDecoder never reads what it could stall on")
    func checkedFirst() throws {
        let error = decodingError(try tampered(#""minBet":2"#, with: #""minBet":0,"x":0.5"#))
        guard case let .dataCorrupted(context)? = error else {
            Issue.record("\(String(describing: error))")
            return
        }
        #expect(context.underlyingError == nil, "An invalid config reached the decoder")
    }

    @Test("marks that take the square of their length to sort are refused, as a key or a value", arguments: [
        ("\u{301}", "\u{323}"), (#"\u0301"#, #"\u0323"#),
    ])
    func marksOutOfOrder(raised: String, lowered: String) throws {
        let marks = "a" + String(repeating: raised, count: 40_000) + String(repeating: lowered, count: 40_000)
        let complete = #""complete":true"#
        #expect(decodingError(try tampered(complete, with: "\(complete),\"x\":{\"\(marks)\":1}")) != nil)
        #expect(decodingError(try tampered(complete, with: "\(complete),\"x\":\"\(marks)\"")) != nil)
    }

    @Test("what other readers would take for something else is refused", arguments: [
        ("handKilling", "hand\u{212A}illing"),
        ("handKilling", #"hand\u212Ailling"#),
        (#""complete":true"#, #""complete":true,"x":{"\ud800":1,"\uD800":2}"#),
        (#""complete":true"#, "\"complete\":true,\"x\":{\"\u{E9}\":1,\"e\u{301}\":2}"),
        (#""complete":true"#, #""y":"\u000\","complete":true,"complete":false"#),
        (#""formatVersion":1"#, #""formatVersion":1.0"#),
        (#""formatVersion":1"#, #""formatVersion":1.0000000000000001"#),
        (#""minBet":2"#, #""minBet":2.0"#),
        (#""minBet":2"#, #""minBet":1.9999999999999999"#),
        (#""to":6"#, #""to":6e0"#),
        (#""won":2"#, #""won":2.0"#),
        (#""net":-2"#, #""net":-2.0"#),
    ])
    func otherReaders(old: String, new: String) throws {
        #expect(decodingError(try tampered(old, with: new)) != nil)
    }

    @Test(
        "every other encoding JSONDecoder accepts is refused: NUL bytes and byte order marks are not in the format",
        arguments: [String.Encoding.utf16, .utf16LittleEndian, .utf16BigEndian, .utf32LittleEndian, .utf32BigEndian]
    )
    func otherEncodings(encoding: String.Encoding) throws {
        let json = try #require(StoredDocument.foldOut.text().data(using: encoding))
        #expect(decodingError(json) != nil)
    }

    @Test("a UTF-8 byte order mark is refused like any other byte the engine does not write")
    func byteOrderMark() throws {
        #expect(decodingError(Data([0xEF, 0xBB, 0xBF]) + Data(try StoredDocument.foldOut.text().utf8)) != nil)
    }

    @Test("layout and key order are free, so a document survives a database that rewrites them")
    func layout() throws {
        let document = StoredDocument.twoRuns
        let text = try document.text()
        let spaced = text.replacingOccurrences(of: ":", with: ": ").replacingOccurrences(of: ",", with: ", ")
        #expect(try HandState(json: Data(spaced.utf8)) == document.hand())
        let object = try JSONSerialization.jsonObject(with: Data(text.utf8))
        let rewritten = try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
        #expect(rewritten != Data(text.utf8))
        #expect(try HandState(json: rewritten) == document.hand())
    }
}
