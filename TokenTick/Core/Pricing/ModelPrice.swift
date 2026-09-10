import Foundation

struct PriceRates: Codable, Equatable, Sendable {
    var input: Decimal?
    var output: Decimal?
    var cacheRead: Decimal?
    var cacheWrite: Decimal?
    static let unknown = PriceRates()

    enum CodingKeys: String, CodingKey {
        case input, output
        case cacheRead = "cache_read"
        case cacheWrite = "cache_write"
    }

    func multiplied(by factor: Decimal) -> Self {
        Self(input: input.map { $0 * factor }, output: output.map { $0 * factor },
             cacheRead: cacheRead.map { $0 * factor }, cacheWrite: cacheWrite.map { $0 * factor })
    }

    func validated() throws -> Self {
        for price in [input, output, cacheRead, cacheWrite].compactMap({ $0 }) {
            guard !price.isNaN, price >= 0 else { throw PriceError.invalidRate }
        }
        return self
    }
}

struct ModelPrice: Codable, Equatable, Sendable {
    let model: String
    let date: String
    let standard: PriceRates
    let fast: PriceRates
    let long: PriceRates
    let fastLong: PriceRates
    let longContextThreshold: Int64?
    let contextRule: ContextRule
    let source: PriceSource

    enum ContextRule: String, Codable { case uniform, requestInputGreaterThan, unsupported }

    /// 价格和规则决定是否需要新快照，名称和原始 JSON 的字段顺序不参与比较。
    func samePricing(as other: Self) -> Bool {
        standard == other.standard && fast == other.fast && long == other.long && fastLong == other.fastLong
            && longContextThreshold == other.longContextThreshold && contextRule == other.contextRule
            && source.combinationRule == other.source.combinationRule
            && (contextRule != .unsupported || source.cost == other.source.cost)
    }
}

struct PriceSource: Codable, Equatable, Sendable {
    let url: String
    let cost: SourceJSON
    let experimental: SourceJSON?
    let combinationRule: String?
    let combinationSource: String?
    let contextRule: ModelPrice.ContextRule
}

/// 保留统计来源的扩展字段，数字以十进制解码，避免经过 Double 丢失单价精度。
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

enum PriceError: Error, LocalizedError {
    case invalidRate, invalidDocument, invalidDate, amountOverflow, invalidUsage
    var errorDescription: String? {
        switch self {
        case .invalidRate: "模型单价必须是非负十进制数。"
        case .invalidDocument: "价格响应缺少有效的 OpenAI 模型条目。"
        case .invalidDate: "价格日期必须为有效的 UTC YYYY-MM-DD。"
        case .amountOverflow: "金额超出整数纳美元范围，未写入近似结果。"
        case .invalidUsage: "Token 总量或缓存分项不一致，无法可靠计算金额。"
        }
    }
}
