import RunseCore
import XCTest

/// Live integration test for the pinyin TransformAction. Builds the built-in
/// pinyin prompt, hits the default DeepSeek provider, and verifies the model
/// returns Hanyu Pinyin with tone marks rather than numeric tones or
/// untransformed Chinese characters.
///
/// Key resolution: the `ZHIYIN_TEST_API_KEY` env var (or its
/// `TEST_RUNNER_…` variant). Skipped if it is unset. No key is ever read
/// from a config file or baked into the repo.
///
/// NOTE: The resolved key is never logged, asserted on, or otherwise echoed
/// in test output — only the model's response text is printed.
///
/// Run with:
///   xcodebuild test -scheme Zhiyin \
///     -destination 'platform=iOS Simulator,name=iPhone 17' \
///     -only-testing:RunseTests/PinyinLiveTests
final class PinyinLiveTests: XCTestCase {
    @MainActor
    func testPinyinLiveRoundTripProducesToneMarks() async throws {
        let apiKey = Self.resolveAPIKey()
        try XCTSkipIf(apiKey.isEmpty, "No API key available (set ZHIYIN_TEST_API_KEY).")

        let profile = ProviderProfile.defaultDeepSeek()
        let template = PromptTemplate.builtIns().first { $0.action == .pinyin }!
        let input = "你好，世界"
        let prompt = PromptRenderer.render(
            template: template,
            context: PromptContext(selectedText: input, action: .pinyin)
        )
        let request = LLMRequest(
            action: .pinyin,
            model: profile.model,
            systemPrompt: prompt.system,
            userPrompt: prompt.user,
            temperature: 0
        )

        let response = try await HTTPProviderClient(profile: profile, apiKey: apiKey).complete(request)
        // Safe to print: this is the pinyin output, not the key. Do NOT print
        // `apiKey` or include it in any XCAssert message — XCTest writes
        // assertion failure strings into test logs.
        print("Pinyin live response: \(response.text)")
        let text = response.text.lowercased()

        XCTAssertFalse(text.contains("你"), "Response still contains source Han characters: \(response.text)")
        XCTAssertFalse(text.contains("世"), "Response still contains source Han characters: \(response.text)")

        let toneMarks: Set<Character> = [
            "ā", "á", "ǎ", "à",
            "ē", "é", "ě", "è",
            "ī", "í", "ǐ", "ì",
            "ō", "ó", "ǒ", "ò",
            "ū", "ú", "ǔ", "ù",
            "ǖ", "ǘ", "ǚ", "ǜ"
        ]
        XCTAssertTrue(text.contains(where: { toneMarks.contains($0) }),
                      "Response lacks Hanyu Pinyin tone marks: \(response.text)")
        XCTAssertTrue(text.contains("ni") && text.contains("hao"),
                      "Response missing expected syllables for 你好: \(response.text)")
    }

    private static func resolveAPIKey() -> String {
        let env = ProcessInfo.processInfo.environment
        for name in ["ZHIYIN_TEST_API_KEY", "TEST_RUNNER_ZHIYIN_TEST_API_KEY"] {
            if let key = env[name]?.trimmingCharacters(in: .whitespacesAndNewlines), !key.isEmpty {
                return key
            }
        }
        return ""
    }
}
