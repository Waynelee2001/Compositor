import Foundation

/// Unknown notification fields remain decodable when Codex adds protocol fields.
nonisolated enum CodexJSON: Codable, Equatable, Sendable {
    case null, bool(Bool), integer(Int), number(Double), string(String)
    case array([CodexJSON]), object([String: CodexJSON])
    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null }
        else if let v = try? c.decode(Bool.self) { self = .bool(v) }
        else if let v = try? c.decode(Int.self) { self = .integer(v) }
        else if let v = try? c.decode(Double.self) { self = .number(v) }
        else if let v = try? c.decode(String.self) { self = .string(v) }
        else if let v = try? c.decode([CodexJSON].self) { self = .array(v) }
        else { self = .object(try c.decode([String: CodexJSON].self)) }
    }
    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .null: try c.encodeNil()
        case .bool(let v): try c.encode(v)
        case .integer(let v): try c.encode(v)
        case .number(let v): try c.encode(v)
        case .string(let v): try c.encode(v)
        case .array(let v): try c.encode(v)
        case .object(let v): try c.encode(v)
        }
    }
    subscript(_ key: String) -> CodexJSON { object[key] ?? .null }
    var object: [String: CodexJSON] { if case .object(let v) = self { return v }; return [:] }
    var array: [CodexJSON] { if case .array(let v) = self { return v }; return [] }
    var string: String? { if case .string(let v) = self { return v }; return nil }
    var bool: Bool? { if case .bool(let v) = self { return v }; return nil }
    var double: Double? {
        switch self { case .integer(let v): return Double(v); case .number(let v): return v; default: return nil }
    }
    var requestKey: String? {
        switch self { case .integer(let v): return "n:\(v)"; case .string(let v): return "s:\(v)"; default: return nil }
    }
    func data() throws -> Data { try JSONEncoder().encode(self) }
    var pretty: String {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return (try? String(decoding: encoder.encode(self), as: UTF8.self)) ?? "null"
    }
    static func decode(_ data: Data) throws -> CodexJSON { try JSONDecoder().decode(Self.self, from: data) }
}

extension CodexJSON: ExpressibleByStringLiteral, ExpressibleByIntegerLiteral, ExpressibleByBooleanLiteral,
    ExpressibleByArrayLiteral, ExpressibleByDictionaryLiteral {
    init(stringLiteral value: String) { self = .string(value) }
    init(integerLiteral value: Int) { self = .integer(value) }
    init(booleanLiteral value: Bool) { self = .bool(value) }
    init(arrayLiteral elements: CodexJSON...) { self = .array(elements) }
    init(dictionaryLiteral elements: (String, CodexJSON)...) { self = .object(Dictionary(uniqueKeysWithValues: elements)) }
}

nonisolated struct CodexRuntimeError: LocalizedError, Sendable {
    let message: String
    var errorDescription: String? { message }
}

/// A pipe read is not necessarily a line, or even a complete UTF-8 character.
nonisolated struct CodexJSONLines {
    static let maximumFrameBytes = 16 * 1024 * 1024
    private var buffer = Data()
    mutating func append(_ chunk: Data) throws -> [CodexJSON] {
        buffer.append(chunk)
        var messages: [CodexJSON] = []
        while let end = buffer.firstIndex(of: 10) {
            let line = Data(buffer[..<end])
            guard line.count <= Self.maximumFrameBytes else { throw CodexRuntimeError(message: "Codex frame is too large.") }
            buffer.removeSubrange(...end)
            if line.allSatisfy({ $0 == 13 || $0 == 32 || $0 == 9 }) { continue }
            let message = try CodexJSON.decode(line)
            guard case .object = message else { throw CodexRuntimeError(message: "Invalid Codex RPC envelope.") }
            messages.append(message)
        }
        guard buffer.count <= Self.maximumFrameBytes else { throw CodexRuntimeError(message: "Codex frame is too large.") }
        return messages
    }
    mutating func finish() throws {
        defer { buffer.removeAll() }
        guard buffer.allSatisfy({ $0 == 13 || $0 == 32 || $0 == 9 }) else {
            throw CodexRuntimeError(message: "Codex disconnected during a JSON frame.")
        }
    }
}
