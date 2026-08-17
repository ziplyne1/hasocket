// Wire protocol shared between `hasocket serve` (holds the HA websocket) and
// the client-mode commands (`status`/`list`/`get`/`call`) of the same
// binary, run from any other terminal. Transport is a Unix domain socket at
// a fixed, short path so it stays under sockaddr_un's 104-byte sun_path
// limit regardless of home directory length. Framing is newline-delimited
// JSON, one request/response object per line.
import Foundation

public enum JSONValue: Codable, Equatable {
    case string(String)
    case double(Double)
    case bool(Bool)
    case null
    case array([JSONValue])
    case object([String: JSONValue])

    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null; return }
        if let v = try? c.decode(Bool.self) { self = .bool(v); return }
        if let v = try? c.decode(Double.self) { self = .double(v); return }
        if let v = try? c.decode(String.self) { self = .string(v); return }
        if let v = try? c.decode([JSONValue].self) { self = .array(v); return }
        if let v = try? c.decode([String: JSONValue].self) { self = .object(v); return }
        throw DecodingError.dataCorruptedError(in: c, debugDescription: "unsupported JSON value")
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .string(let v): try c.encode(v)
        case .double(let v): try c.encode(v)
        case .bool(let v): try c.encode(v)
        case .null: try c.encodeNil()
        case .array(let v): try c.encode(v)
        case .object(let v): try c.encode(v)
        }
    }

    public init(any: Any) {
        switch any {
        case let v as String: self = .string(v)
        case let v as Bool: self = .bool(v)
        case let v as Int: self = .double(Double(v))
        case let v as Double: self = .double(v)
        case let v as [Any]: self = .array(v.map { JSONValue(any: $0) })
        case let v as [String: Any]: self = .object(v.mapValues { JSONValue(any: $0) })
        default: self = .null
        }
    }

    public var anyValue: Any {
        switch self {
        case .string(let v): return v
        case .double(let v): return v
        case .bool(let v): return v
        case .null: return NSNull()
        case .array(let v): return v.map(\.anyValue)
        case .object(let v): return v.mapValues(\.anyValue)
        }
    }
}

extension Dictionary where Key == String, Value == JSONValue {
    public var asAnyDict: [String: Any] { mapValues(\.anyValue) }
}

public struct EntitySnapshot: Codable, Equatable, Identifiable {
    public var id: String { entityID }
    public let entityID: String
    public let state: String
    public let attributes: [String: JSONValue]
    public let updatedAt: Date

    public init(entityID: String, state: String, attributes: [String: JSONValue], updatedAt: Date = Date()) {
        self.entityID = entityID
        self.state = state
        self.attributes = attributes
        self.updatedAt = updatedAt
    }
}

public enum IPCRequest: Codable {
    case ping
    case list
    case get(entityID: String)
    case call(domain: String, service: String, entityID: String?, data: [String: JSONValue])
}

public enum IPCResponse: Codable {
    case pong
    case ok
    case error(String)
    case list([EntitySnapshot])
    case entity(EntitySnapshot)
}

public enum IPCSocket {
    /// `/tmp` rather than a Library/Containers path: short and guaranteed under
    /// sockaddr_un's 104-byte sun_path limit no matter how long the user's
    /// home directory is. Named distinctly from HomeBar.app's own
    /// `/tmp/homebar-<uid>.sock` so the two can run side by side.
    public static var path: String { "/tmp/hasocket-\(getuid()).sock" }
}
