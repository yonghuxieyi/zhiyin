import Foundation

public struct PromptContext: Sendable {
    public var selectedText: String
    public var action: TransformAction
    public var targetLanguage: String
    public var tone: Tone
    public var length: OutputLength
    public var formality: Formality
    public var outputLocale: String
    public var customInstruction: String

    public init(
        selectedText: String,
        action: TransformAction,
        targetLanguage: String = RunseConstants.defaultTranslationLanguage,
        tone: Tone = .natural,
        length: OutputLength = .same,
        formality: Formality = .neutral,
        outputLocale: String = "same as input",
        customInstruction: String = ""
    ) {
        self.selectedText = selectedText
        self.action = action
        self.targetLanguage = targetLanguage
        self.tone = tone
        self.length = length
        self.formality = formality
        self.outputLocale = outputLocale
        self.customInstruction = customInstruction
    }
}

public struct RenderedPrompt: Equatable, Sendable {
    public var system: String
    public var user: String
}

public enum PromptRenderer {
    public static func render(template: PromptTemplate, context: PromptContext) -> RenderedPrompt {
        let variables = [
            "selected_text": context.selectedText,
            "action": context.action.rawValue,
            "target_language": context.targetLanguage,
            "tone": context.tone.rawValue,
            "length": context.length.rawValue,
            "formality": context.formality.rawValue,
            "output_locale": context.outputLocale,
            "custom_instruction": context.customInstruction
        ]
        return RenderedPrompt(
            system: replace(in: template.systemTemplate, variables: variables),
            user: replace(in: template.userTemplate, variables: variables)
        )
    }

    /// Single-pass scan replacement. The old implementation ran one
    /// `replacingOccurrences` pass per variable, so a value that itself
    /// contained `{{...}}` (selected text often does) would be
    /// re-scanned and wrongly substituted by a later pass. Here the
    /// template is walked once and only placeholders present in the
    /// original template are replaced; values are copied verbatim
    /// and never re-scanned. Unknown placeholders are left as-is.
    private static func replace(in template: String, variables: [String: String]) -> String {
        var result = ""
        result.reserveCapacity(template.count)
        var cursor = template.startIndex
        while let open = template[cursor...].range(of: "{{") {
            result += template[cursor..<open.lowerBound]
            guard let close = template[open.upperBound...].range(of: "}}") else {
                // Unclosed "{{": copy the rest verbatim.
                result += template[open.lowerBound...]
                return result
            }
            let key = String(template[open.upperBound..<close.lowerBound])
            if let value = variables[key] {
                result += value
            } else {
                result += template[open.lowerBound..<close.upperBound]
            }
            cursor = close.upperBound
        }
        result += template[cursor...]
        return result
    }
}
