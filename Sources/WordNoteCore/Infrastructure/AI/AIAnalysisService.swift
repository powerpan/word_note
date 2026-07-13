import Foundation

public struct AIAnalysisService {
    public static let maximumInputCharacters = 8_000

    private let client: AICompletionClient
    private let parser: AIResponseParser

    public init(client: AICompletionClient, parser: AIResponseParser = AIResponseParser()) {
        self.client = client
        self.parser = parser
    }

    public func analyze(_ request: AIAnalysisRequest) async throws -> AIAnalysisResult {
        guard request.rawText.count <= Self.maximumInputCharacters else {
            throw AIAnalysisError.inputTooLong(maxCharacters: Self.maximumInputCharacters)
        }

        let messages = [
            DeepSeekMessage(role: "system", content: systemPrompt(for: request.lookupDirection)),
            DeepSeekMessage(role: "user", content: userPrompt(for: request))
        ]
        let completion = try await client.complete(messages: messages, responseFormat: .jsonObject)
        let result = try parser.parse(
            content: completion.content,
            model: completion.model,
            responseID: completion.id
        )
        return try validatedResult(result, for: request.lookupDirection)
    }

    private func systemPrompt(for lookupDirection: LookupDirection) -> String {
        """
        You are an English learning assistant for a Chinese-native graduate student who often reads AI/CS material.
        Analyze the user's input without assuming every word has a special AI/CS meaning.

        \(directionInstructions(for: lookupDirection))

        Rules:
        - If the input is a word, explain the word directly.
        - If the input is a phrase, prioritize the phrase as one complete term.
        - If the input is a sentence, explain the sentence meaning and extract only valuable terms, phrases, technical concepts, fixed expressions, or sentence patterns.
        - Do not explain simple function words unless they are useful for this learner.
        - Chinese meanings must explain the word or phrase itself first. Avoid bare synonym lists.
        - Start chinese_meaning with the term's general Chinese meaning or meanings. If the word or phrase has multiple common meanings worth learning, cover the main meanings instead of arbitrarily limiting the answer to one or two senses.
        - Add an AI/CS-specific explanation only when the technical meaning is materially different from the general meaning, or when the term is a known technical term of art.
        - Do not use boilerplate like "in an AI/ML context" for ordinary words whose meaning is unchanged.
        - When both general and technical meanings are needed, format chinese_meaning as "本義：...；AI/計算機：...".
        - Do not force multiple meanings for a single-sense term, and do not invent rare meanings that are not useful for this learner.
        - Keep each meaning concise and natural in Chinese. Do not include example sentences inside chinese_meaning.
        - Return strict JSON only. Do not wrap it in Markdown.
        - The response must be a JSON object with keys: input_type, sentence_meaning, items.
        - Keep the candidate list concise, usually 1 to 5 items.
        """
    }

    private func directionInstructions(for lookupDirection: LookupDirection) -> String {
        switch lookupDirection {
        case .englishToChinese:
            return """
            This is an English-to-Chinese lookup. Treat the English input as the vocabulary subject and explain it in Chinese.
            """
        case .chineseToEnglish:
            return """
            This is a Chinese-to-English lookup. Treat the Chinese input as the source meaning or expression the learner wants to say in English.
            - Every items[].term must be an English word, phrase, expression, or sentence pattern. Never copy Chinese source text into term.
            - Put the most idiomatic and generally useful English candidate first.
            - Include multiple candidates only when they are genuine alternatives with useful differences in meaning, register, or AI/CS usage.
            - chinese_meaning must explain the English candidate in Chinese and distinguish it from alternatives when needed.
            - english_definition and example_sentence must remain English.
            - For a Chinese sentence or paragraph, sentence_meaning contains a natural English rendering of the full input.
            """
        }
    }

    private func userPrompt(for request: AIAnalysisRequest) -> String {
        """
        Return a JSON object in this schema:
        {
          "input_type": "word | phrase | sentence | paragraph | unknown",
          "sentence_meaning": "",
          "items": [
            {
              "term": "",
              "term_type": "word | phrase | expression | sentence_pattern",
              "need_to_learn": true,
              "importance": "low | medium | high",
              "category": "general | academic | AI/ML | DL | NLP | CV | math | programming",
              "reason": "",
              "chinese_meaning": "Explain the word or phrase's general Chinese meaning first. Add AI/CS-specific meaning only if it differs materially; do not force AI-context wording.",
              "english_definition": "",
              "ai_context_explanation": "",
              "example_sentence": "",
              "related_terms": [],
              "confidence": 0.0,
              "should_auto_select": false
            }
          ]
        }

        Preferred explanation language: \(request.preferredLanguage)
        Lookup direction: \(request.lookupDirection.displayTitle)
        Course: \(request.courseName ?? "unspecified")
        Source: \(request.sourceType.displayTitle)
        User note: \(request.userNote ?? "none")

        User input:
        \(request.rawText)
        """
    }

    private func validatedResult(
        _ result: AIAnalysisResult,
        for lookupDirection: LookupDirection
    ) throws -> AIAnalysisResult {
        guard lookupDirection == .chineseToEnglish else { return result }

        let candidates = result.candidates.filter { candidate in
            LookupDirectionDetector.isEnglishVocabularyTerm(candidate.term) &&
                !TextNormalizer.isBlank(candidate.chineseMeaning ?? "")
        }
        guard !candidates.isEmpty else {
            throw AIAnalysisError.schemaMismatch(
                "Chinese-to-English analysis returned no English candidate with a Chinese meaning."
            )
        }

        return AIAnalysisResult(
            inputType: result.inputType,
            sentenceMeaning: result.sentenceMeaning,
            candidates: candidates,
            model: result.model,
            rawResponseID: result.rawResponseID
        )
    }
}
