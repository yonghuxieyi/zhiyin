import RunseCore
import XCTest

final class ProviderTests: XCTestCase {
    func testOpenAICompatibleRequestEncoding() throws {
        let profile = ProviderProfile.defaultDeepSeek()
        let request = LLMRequest(action: .refine, model: profile.model, systemPrompt: "system", userPrompt: "user")
        let body = ProviderRequestFactory.body(profile: profile, request: request)

        XCTAssertEqual(body["model"] as? String, "deepseek-flash")
        let messages = body["messages"] as? [[String: String]]
        XCTAssertEqual(messages?.first?["role"], "system")
        XCTAssertEqual(messages?.last?["content"], "user")
    }

    func testDeepSeekRequestDisablesThinking() throws {
        let profile = ProviderProfile.defaultDeepSeek()
        let request = LLMRequest(action: .refine, model: profile.model, systemPrompt: "system", userPrompt: "user")
        let body = ProviderRequestFactory.body(profile: profile, request: request)

        // Thinking on makes DeepSeek ignore `temperature`; translation calls
        // must disable it explicitly.
        let thinking = body["thinking"] as? [String: String]
        XCTAssertEqual(thinking?["type"], "disabled")
    }

    func testOpenAICompatibleResponseParsing() throws {
        let data = """
        {"id":"abc","model":"m","choices":[{"message":{"content":"Result"}}],"usage":{"total_tokens":3}}
        """.data(using: .utf8)!

        let response = try ProviderResponseParser.parse(data: data, kind: .openAICompatible)

        XCTAssertEqual(response.text, "Result")
        XCTAssertEqual(response.responseID, "abc")
        XCTAssertEqual(response.usage["total_tokens"], 3)
    }

    func testReasoningOnlyResponseThrowsEmptyOutput() {
        // M4: a response with empty content but reasoning text must not
        // be returned as the translation.
        let data = Data(#"{"choices":[{"message":{"content":"","reasoning_content":"some chain of thought"}}]}"#.utf8)
        XCTAssertThrowsError(try ProviderResponseParser.parse(data: data, kind: .openAICompatible)) { error in
            XCTAssertEqual(error as? LLMProviderError, .emptyOutput)
        }
    }

    func testQwenMTPlusIsNonIncrementalProfile() {
        XCTAssertTrue(ProviderProfile.qwenMTPlus().isQwenMTPlus)
        XCTAssertFalse(ProviderProfile.qwenMTFlash().isQwenMTPlus)
        XCTAssertFalse(ProviderProfile.defaultDeepSeek().isQwenMTPlus)
    }

    func testMalformedJSONAndEmptyOutputErrors() {
        XCTAssertThrowsError(try ProviderResponseParser.parse(data: Data("nope".utf8), kind: .openAICompatible)) { error in
            XCTAssertEqual(error as? LLMProviderError, .malformedJSON)
        }
        XCTAssertThrowsError(try ProviderResponseParser.parse(data: Data(#"{"choices":[{"message":{"content":""}}]}"#.utf8), kind: .openAICompatible)) { error in
            XCTAssertEqual(error as? LLMProviderError, .emptyOutput)
        }
    }
}
