import Foundation

public struct AIAnalysisService {
    private let client: AICompletionClient
    private let parser: AIResponseParser

    public init(client: AICompletionClient, parser: AIResponseParser = AIResponseParser()) {
        self.client = client
        self.parser = parser
    }

    public func analyze(_ request: AIAnalysisRequest) async throws -> AIAnalysisResult {
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
        You are an English learning assistant for a Chinese-native AI/CS graduate student.
        Analyze the user's input in an AI/CS academic context.

        Rules:
        - If the input is a word, explain the word directly.
        - If the input is a phrase, prioritize the phrase as one complete term.
        - If the input is a sentence, explain the sentence meaning and extract only valuable terms, phrases, technical concepts, fixed expressions, or sentence patterns.
        - Do not explain simple function words unless they have special AI/CS meaning in context.
        - Prefer precise AI/CS explanations over generic dictionary meanings.
        - Chinese meanings must explain how the term is used in this input. Avoid bare synonym lists.
        - Put the contextual meaning first. If the word or phrase has multiple common meanings worth learning, cover the main meanings instead of arbitrarily limiting the answer to one or two senses.
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
              "chinese_meaning": "Explain the contextual Chinese meaning first. If there are multiple common meanings worth learning, include the main senses concisely; do not force extra senses.",
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
