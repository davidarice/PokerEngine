import PokerEngine

/// Any JSON value, for comparing oracle fixtures field by field.
enum JSONValue: Hashable, Sendable, Decodable, CustomStringConvertible {
    case null
    case bool(Bool)
    case int(Int)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Int.self) {
            self = .int(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([JSONValue].self) {
            self = .array(value)
        } else {
            self = .object(try container.decode([String: JSONValue].self))
        }
    }

    init(_ value: Int?) {
        self = value.map(JSONValue.int) ?? .null
    }

    init(_ value: Bool?) {
        self = value.map(JSONValue.bool) ?? .null
    }

    init(_ value: String?) {
        self = value.map(JSONValue.string) ?? .null
    }

    init(_ values: [Int]) {
        self = .array(values.map(JSONValue.int))
    }

    init(_ cards: [Card]) {
        self = .array(cards.map { .string($0.description) })
    }

    var description: String {
        switch self {
        case .null: "null"
        case let .bool(value): "\(value)"
        case let .int(value): "\(value)"
        case let .string(value): "\"\(value)\""
        case let .array(values): "[\(values.map(\.description).joined(separator: ","))]"
        case let .object(fields):
            "{\(fields.sorted { $0.key < $1.key }.map { "\"\($0.key)\":\($0.value)" }.joined(separator: ","))}"
        }
    }
}
