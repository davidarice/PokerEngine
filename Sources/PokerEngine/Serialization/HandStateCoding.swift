import Foundation

// The stored hand format (DECISIONS.md C14, C20): the config and the operations, which rebuild the hand, and a summary
// for readers that do not run the engine. Version 1 is Texas Hold'em; version 2 adds `config.variant`, for Omaha.

extension HandState: Codable {
    /// The newest `formatVersion` this engine reads and writes. A Texas Hold'em hand is still written as version 1,
    /// which every version of the engine reads; version 2 names the game in `config.variant`.
    public static let formatVersion = 2

    private enum CodingKeys: String, CodingKey {
        case formatVersion, config, operations, complete, finalStacks, boards, runoutCount, results
    }

    private enum ConfigKeys: String, CodingKey {
        case variant
    }

    /// The oldest version that can hold the hand, so that an older engine reads every Texas Hold'em hand.
    private var documentVersion: Int {
        config.variant == .noLimitTexasHoldem ? 1 : 2
    }

    /// What a document says about the hand besides the operations.
    private struct Summary: Equatable {
        let complete: Bool
        let finalStacks: [Int]
        let boards: [[Card]]
        let runoutCount: Int
        let results: [PlayerResult]?
    }

    private var summary: Summary {
        Summary(
            complete: isHandComplete, finalStacks: stacks, boards: boards, runoutCount: runoutCount, results: results
        )
    }

    /// Replays the operations. The document must have every key, and its summary must be the one the operations
    /// give: it is what other readers go by, so a document that disagrees with itself is refused. A `JSONDecoder`
    /// reads more than the engine writes, so read documents from outside with `init(json:)`.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let version = try container.decode(Int.self, forKey: .formatVersion)
        guard (1...Self.formatVersion).contains(version) else {
            throw DecodingError.dataCorruptedError(
                forKey: .formatVersion, in: container, debugDescription: "Unsupported format version \(version)"
            )
        }
        var config = try container.decode(HandConfig.self, forKey: .config)
        if version == 1 {
            // Version 1 has no `variant`, so the key is one the format does not have, and is ignored as such.
            config = HandConfig(config, variant: .noLimitTexasHoldem)
        } else {
            // Version 2 must name its game: a missing key throws.
            _ = try container.nestedContainer(keyedBy: ConfigKeys.self, forKey: .config)
                .decode(HandConfig.Variant.self, forKey: .variant)
        }
        let operations = try container.decode([HandOperation].self, forKey: .operations)
        let stored = Summary(
            complete: try container.decode(Bool.self, forKey: .complete),
            finalStacks: try container.decode([Int].self, forKey: .finalStacks),
            boards: try container.decode([[Card]].self, forKey: .boards),
            runoutCount: try container.decode(Int.self, forKey: .runoutCount),
            results: try container.decode([PlayerResult]?.self, forKey: .results)
        )
        do {
            self = try Self.replay(config: config, operations: operations)
        } catch {
            throw DecodingError.dataCorrupted(DecodingError.Context(
                codingPath: decoder.codingPath,
                debugDescription: "Operation \(error.operationIndex) cannot be replayed: \(error.error)",
                underlyingError: error
            ))
        }
        guard stored == summary else {
            throw DecodingError.dataCorrupted(DecodingError.Context(
                codingPath: decoder.codingPath, debugDescription: "The summary disagrees with the operations"
            ))
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(documentVersion, forKey: .formatVersion)
        try container.encode(config, forKey: .config)
        try container.encode(operations, forKey: .operations)
        try container.encode(isHandComplete, forKey: .complete)
        try container.encode(stacks, forKey: .finalStacks)
        try container.encode(boards, forKey: .boards)
        try container.encode(runoutCount, forKey: .runoutCount)
        try container.encode(results, forKey: .results)
    }

    /// The hand as a stored document, version 1 for Texas Hold'em and 2 for Omaha, for storage or upload at any point
    /// in the hand. Keys are sorted, so a hand gives the same bytes every time on one version of Foundation.
    public func json() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        return try encoder.encode(self)
    }

    /// Reads a stored document of either version, replaying its operations. Throws `DecodingError` if the text is not
    /// JSON as the engine writes it (printable ASCII with no escape, whole numbers of at most 19 digits with no
    /// fraction or exponent, each key once, at most 32 levels deep and 1 MiB long) or does not describe one consistent
    /// hand: a missing key, another version, an invalid config, a refused operation or a summary that disagrees.
    /// Layout and key order are free, and a key the format does not have is allowed, within the same text rules, and
    /// is then ignored (DECISIONS.md C10, C14).
    public init(json: Data) throws {
        try StoredJSONScanner.check(json)
        self = try JSONDecoder().decode(Self.self, from: json)
    }
}

/// Reads a document's bytes before `JSONDecoder` does, and refuses anything but JSON as the engine writes it: printable
/// ASCII with no escape, whole numbers of at most 19 digits, and each key once in its object. `JSONDecoder` alone
/// accepts more, what more depends on the OS, and the rest of Unicode can stall it or mean another hand to other
/// readers (DECISIONS.md C10).
struct StoredJSONScanner {
    /// Over ten times the longest hand a table would play. Only a hand of tens of thousands of operations would
    /// pass it.
    static let maximumSize = 1 << 20
    /// A finished hand reaches 6 levels, counting each value on the path. A limit stops a hostile document from
    /// exhausting the stack.
    static let maximumDepth = 32
    /// The digits of the longest `Int`. Past them readers part ways, even under a key nothing reads.
    static let maximumDigits = 19

    private let bytes: [UInt8]
    private var index = 0

    static func check(_ json: Data) throws {
        guard json.count <= maximumSize else { throw refusal("Over \(maximumSize) bytes") }
        var scanner = StoredJSONScanner(bytes: [UInt8](json))
        try scanner.scanValue(depth: 0)
        guard scanner.next == nil else { throw scanner.unexpected }
    }

    private static func refusal(_ description: String) -> DecodingError {
        DecodingError.dataCorrupted(DecodingError.Context(codingPath: [], debugDescription: description))
    }

    private var unexpected: DecodingError { Self.refusal("Not expected at byte \(index)") }
    private var next: UInt8? { index < bytes.endIndex ? bytes[index] : nil }

    private mutating func skip(_ character: Unicode.Scalar) -> Bool {
        guard next == UInt8(ascii: character) else { return false }
        index += 1
        return true
    }

    private mutating func expect(_ character: Unicode.Scalar) throws {
        guard skip(character) else { throw unexpected }
    }

    private mutating func skipWhitespace() {
        while let byte = next, byte == 0x20 || byte == 0x0A || byte == 0x0D || byte == 0x09 {
            index += 1
        }
    }

    /// A value and the whitespace around it.
    private mutating func scanValue(depth: Int) throws {
        guard depth < Self.maximumDepth else { throw Self.refusal("Nested too deep at byte \(index)") }
        skipWhitespace()
        switch next {
        case UInt8(ascii: "{"): try scanObject(depth: depth)
        case UInt8(ascii: "["): try scanArray(depth: depth)
        case UInt8(ascii: "\""): _ = try scanString()
        case UInt8(ascii: "t"): try scanWord("true")
        case UInt8(ascii: "f"): try scanWord("false")
        case UInt8(ascii: "n"): try scanWord("null")
        default: try scanInteger()
        }
        skipWhitespace()
    }

    private mutating func scanObject(depth: Int) throws {
        try expect("{")
        skipWhitespace()
        if skip("}") { return }
        var keys = Set<ArraySlice<UInt8>>()
        repeat {
            skipWhitespace()
            let key = try scanString()
            guard keys.insert(key).inserted else {
                throw Self.refusal("Repeated key \(String(decoding: key, as: UTF8.self))")
            }
            skipWhitespace()
            try expect(":")
            try scanValue(depth: depth + 1)
        } while skip(",")
        try expect("}")
    }

    private mutating func scanArray(depth: Int) throws {
        try expect("[")
        skipWhitespace()
        if skip("]") { return }
        repeat {
            try scanValue(depth: depth + 1)
        } while skip(",")
        try expect("]")
    }

    /// A string's text, which needs no decoding: with no escape, equal bytes are equal text.
    private mutating func scanString() throws -> ArraySlice<UInt8> {
        try expect("\"")
        let start = index
        while let byte = next, byte != UInt8(ascii: "\"") {
            guard (0x20...0x7E).contains(byte), byte != UInt8(ascii: "\\") else { throw unexpected }
            index += 1
        }
        let text = bytes[start..<index]
        try expect("\"")
        return text
    }

    private mutating func scanWord(_ word: String) throws {
        guard bytes[index...].starts(with: word.utf8) else { throw unexpected }
        index += word.utf8.count
    }

    private mutating func scanInteger() throws {
        _ = skip("-")
        let start = index
        while let byte = next, (0x30...0x39).contains(byte) {
            index += 1
        }
        guard index > start, index - start <= Self.maximumDigits, bytes[start] != 0x30 || index == start + 1 else {
            throw unexpected
        }
    }
}
