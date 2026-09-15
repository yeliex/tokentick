import Foundation
import Testing
@testable import TokenTickCore

struct LocalizationTests {
    @Test func supportedLanguagesAndEnglishFallback() {
        #expect(Bundle.module.developmentLocalization == "en")
        #expect(Set(Bundle.module.localizations).isSuperset(of: ["en", "zh-Hans"]))
        #expect(Bundle.preferredLocalizations(from: ["en", "zh-Hans"], forPreferences: ["fr"]) == ["en"])
        #expect(Bundle.preferredLocalizations(from: ["en", "zh-Hans"], forPreferences: ["zh-Hans"]) == ["zh-Hans"])
    }

    @Test(arguments: ["en", "zh-Hans"])
    func localizedErrorAndIntegerInterpolation(language: String) throws {
        let path = try #require(Bundle.module.path(forResource: language, ofType: "lproj"))
        let bundle = try #require(Bundle(path: path))
        let message = String(localized: "The statistics timezone must be a valid IANA timezone.", bundle: bundle)
        #expect(message == (language == "en"
            ? "The statistics timezone must be a valid IANA timezone."
            : "统计时区必须是有效的 IANA 时区。"))
        let code = 429
        let error = String(localized: "The models.dev request failed (HTTP \(code)). Existing prices were kept.", bundle: bundle)
        #expect(error == (language == "en"
            ? "The models.dev request failed (HTTP 429). Existing prices were kept."
            : "models.dev 请求失败（HTTP 429），保留已有价格。"))
    }

    @Test func allCoreTranslationsHaveMatchingPlaceholders() throws {
        func strings(_ language: String) throws -> [String: String] {
            let path = try #require(Bundle.module.path(forResource: "Localizable", ofType: "strings", inDirectory: nil, forLocalization: language))
            let data = try Data(contentsOf: URL(fileURLWithPath: path))
            return try #require(PropertyListSerialization.propertyList(from: data, format: nil) as? [String: String])
        }
        let english = try strings("en")
        let chinese = try strings("zh-Hans")
        #expect(!english.isEmpty)
        #expect(Set(english.keys) == Set(chinese.keys))
        let placeholder = try NSRegularExpression(pattern: #"%(?:\d+\$)?(?:lld|@)"#)
        for (key, translation) in chinese {
            func formats(_ value: String) -> [String] {
                placeholder.matches(in: value, range: NSRange(value.startIndex..., in: value)).map {
                    String(value[Range($0.range, in: value)!])
                }.sorted()
            }
            #expect(!translation.isEmpty)
            #expect(formats(key) == formats(translation))
        }
    }
}
