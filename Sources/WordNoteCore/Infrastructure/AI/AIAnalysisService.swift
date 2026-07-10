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
            DeepSeekMessage(role: "system", content: systemPrompt),
            DeepSeekMessage(role: "user", content: userPrompt(for: request))
        ]
        let completion = try await client.complete(messages: messages, responseFormat: .jsonObject)
        return try parser.parse(
            content: completion.content,
            model: completion.model,
            responseID: completion.id
        )
    }

    private var systemPrompt: String {
        """
        You are an English learning assistant for a Chinese-native graduate student who often reads AI/CS material.
        Analyze the user's input without assuming every word has a special AI/CS meaning.

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
        Course: \(request.courseName ?? "unspecified")
        Source: \(request.sourceType.displayTitle)
        User note: \(request.userNote ?? "none")

        User input:
        \(request.rawText)
        """
    }
}
