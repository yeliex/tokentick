enum CodexServiceTier {
    static func normalized(_ value: String?) -> String? {
        guard let value, !value.isEmpty else { return nil }
        switch value {
        case "priority", "fast": return "fast"
        case "default", "standard": return "standard"
        default: return value
        }
    }

    static func isFast(_ value: String?) -> Bool? {
        switch value {
        case "priority", "fast": true
        case "default", "standard": false
        default: nil
        }
    }
}
