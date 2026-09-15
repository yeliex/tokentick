import Foundation

/// Decode source numbers as Decimal to preserve price precision without a Double conversion.
indirect enum SourceJSON: Codable, Equatable, Sendable {
    case object([String: SourceJSON]), array([SourceJSON]), number(Decimal), string(String), bool(Bool), null

    init(from decoder: any Decoder) throws {
        let value = try decoder.singleValueContainer()
        if value.decodeNil() { self = .null }
        else if let bool = try? value.decode(Bool.self) { self = .bool(bool) }
        else if let number = try? value.decode(Decimal.self) { self = .number(number) }
        else if let string = try? value.decode(String.self) { self = .string(string) }
        else if let object = try? value.decode([String: SourceJSON].self) { self = .object(object) }
        else { self = .array(try value.decode([SourceJSON].self)) }
    }

    func encode(to encoder: any Encoder) throws {
        var value = encoder.singleValueContainer()
        switch self {
        case .object(let object): try value.encode(object)
        case .array(let array): try value.encode(array)
        case .number(let number): try value.encode(number)
        case .string(let string): try value.encode(string)
        case .bool(let bool): try value.encode(bool)
        case .null: try value.encodeNil()
        }
    }

    subscript(_ key: String) -> Self? {
        guard case .object(let object) = self else { return nil }
        return object[key]
    }
}
