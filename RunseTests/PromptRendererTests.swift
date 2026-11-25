import RunseCore
import XCTest

final class PromptRendererTests: XCTestCase {
    func testRefineRenderingReplacesSupportedVariables() {
        let template = PromptTemplate.builtIns().first { $0.action == .refine }!
        let prompt = PromptRenderer.render(
            template: template,
            context: PromptContext(
                selectedText: "hello",
                action: .refine,
                targetLanguage: "Japanese",
                tone: .polished,
                length: .shorter,
                formality: .formal,
                outputLocale: "en_US",
                customInstruction: "Keep markdown."
            )
        )

        XCTAssertTrue(prompt.system.contains("careful editor"))
        XCTAssertTrue(prompt.user.contains("hello"))
        XCTAssertTrue(prompt.user.contains("polished"))
        XCTAssertTrue(prompt.user.contains("Preserve the input language"))
        XCTAssertFalse(prompt.user.contains("Output locale"))
        XCTAssertFalse(prompt.user.contains("en_US"))
        XCTAssertFalse(prompt.user.contains("{{selected_text}}"))
    }

    func testTranslateRenderingUsesTargetLanguage() {
        let template = PromptTemplate.builtIns().first { $0.action == .translate }!
        let prompt = PromptRenderer.render(
            template: template,
            context: PromptContext(selectedText: "Good morning", action: .translate, targetLanguage: "French")
        )

        XCTAssertTrue(prompt.user.contains("French"))
        XCTAssertTrue(prompt.user.contains("Good morning"))
    }

    func testPinyinBuiltInTemplateExists() {
        let templates = PromptTemplate.builtIns()
        XCTAssertNotNil(templates.first { $0.id == PromptTemplate.defaultPinyinID })
        XCTAssertTrue(TransformAction.allCases.contains(.pinyin))
    }

    func testPinyinRenderingEmbedsTextAndToneGuidance() {
        let template = PromptTemplate.builtIns().first { $0.action == .pinyin }!
        let prompt = PromptRenderer.render(
            template: template,
            context: PromptContext(
                selectedText: "你好，世界",
                action: .pinyin,
                customInstruction: "Keep punctuation."
            )
        )

        XCTAssertTrue(prompt.system.contains("Hanyu Pinyin"))
        // Verifies the system prompt actually carries the tone-mark vowels —
        // without them the model often falls back to numeric tones (ni3 hao3).
        XCTAssertTrue(prompt.system.contains("ā"))
        XCTAssertTrue(prompt.system.contains("ǚ"))
        XCTAssertTrue(prompt.user.contains("你好，世界"))
        XCTAssertTrue(prompt.user.contains("Keep punctuation."))
        XCTAssertFalse(prompt.user.contains("{{selected_text}}"))
        XCTAssertFalse(prompt.user.contains("{{custom_instruction}}"))
    }
}
