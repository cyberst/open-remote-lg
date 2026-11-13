import Foundation

/// A Sendable, Codable JSON value used for SSAP payloads.
public enum JSON: Sendable, Hashable, Codable, ExpressibleByDictionaryLiteral, ExpressibleByArrayLiteral,
    ExpressibleByStringLiteral, ExpressibleByIntegerLiteral, ExpressibleByFloatLiteral, ExpressibleByBooleanLiteral, ExpressibleByNilLiteral {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([JSON])
    case object([String: JSON])

    public init(dictionaryLiteral elements: (String, JSON)...) { self = .object(Dictionary(elements, uniquingKeysWith: { $1 })) }
    public init(arrayLiteral elements: JSON...) { self = .array(elements) }
    public init(stringLiteral value: String) { self = .string(value) }
    public init(integerLiteral value: Int) { self = .number(Double(value)) }
    public init(floatLiteral value: Double) { self = .number(value) }
    public init(booleanLiteral value: Bool) { self = .bool(value) }
    public init(nilLiteral: ()) { self = .null }

    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null }
        else if let b = try? c.decode(Bool.self) { self = .bool(b) }
        else if let n = try? c.decode(Double.self) { self = .number(n) }
        else if let s = try? c.decode(String.self) { self = .string(s) }
        else if let a = try? c.decode([JSON].self) { self = .array(a) }
        else { self = .object(try c.decode([String: JSON].self)) }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .null: try c.encodeNil()
        case .bool(let b): try c.encode(b)
        case .number(let n):
            if n.rounded() == n, abs(n) < 1e15 { try c.encode(Int64(n)) } else { try c.encode(n) }
        case .string(let s): try c.encode(s)
        case .array(let a): try c.encode(a)
        case .object(let o): try c.encode(o)
        }
    }

    public subscript(key: String) -> JSON? { if case .object(let o) = self { return o[key] } else { return nil } }
    public subscript(index: Int) -> JSON? { if case .array(let a) = self, a.indices.contains(index) { return a[index] } else { return nil } }
    public var stringValue: String? { if case .string(let s) = self { return s } else { return nil } }
    public var doubleValue: Double? { if case .number(let n) = self { return n } else { return nil } }
    public var intValue: Int? { doubleValue.map { Int($0) } ?? stringValue.flatMap { Int($0) } }
    public var boolValue: Bool? { if case .bool(let b) = self { return b } else { return nil } }
    public var arrayValue: [JSON]? { if case .array(let a) = self { return a } else { return nil } }
    public var objectValue: [String: JSON]? { if case .object(let o) = self { return o } else { return nil } }

    public func data() throws -> Data { try JSONEncoder().encode(self) }
    public static func parse(_ data: Data) throws -> JSON { try JSONDecoder().decode(JSON.self, from: data) }
}
