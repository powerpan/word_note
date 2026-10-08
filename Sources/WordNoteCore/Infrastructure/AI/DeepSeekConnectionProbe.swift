import Foundation

/// A fixed, content-free request. It never analyzes or stores vocabulary.
public struct DeepSeekConnectionProbe: Sendable {
    private let client: any AICompletionClient

    public init(client: any AICompletionClient) { self.client = client }

    public func run() async throws -> String {
        try Task.checkCancellation()
        let completion = try await client.complete(messages: [
            .init(role: "system", content: "This is a connection test. Return exactly this JSON object: {\"wordnote_connection\":\"ok\"}"),
            .init(role: "user", content: "Test connection.")
        ], responseFormat: .jsonObject)
        try Task.checkCancellation()
        let model = completion.model.trimmingCharacters(in: .whitespacesAndNewlines)
        guard completion.content.utf8.count <= 1_024,
              let data = completion.content.data(using: .utf8),
              let reply = try? JSONDecoder().decode(Reply.self, from: data), reply.wordnote_connection == "ok",
              !model.isEmpty, model.utf8.count <= 128,
              model.unicodeScalars.allSatisfy({ CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-._/: ")).contains($0) }) else {
            throw AIAnalysisError.invalidResponse
        }
        return model
    }

    private struct Reply: Decodable { let wordnote_connection: String }
}
