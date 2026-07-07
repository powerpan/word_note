import Foundation

public protocol AICompletionClient {
    func complete(messages: [DeepSeekMessage], responseFormat: DeepSeekResponseFormat) async throws -> DeepSeekCompletion
}

public struct DeepSeekMessage: Codable, Equatable {
    public let role: String
    public let content: String

    public init(role: String, content: String) {
        self.role = role
        self.content = content
    }
}

public struct DeepSeekResponseFormat: Codable, Equatable {
    public let type: String

    public static let jsonObject = DeepSeekResponseFormat(type: "json_object")
}

public struct DeepSeekCompletion: Equatable {
    public let id: String?
    public let model: String
    public let content: String

    public init(id: String?, model: String, content: String) {
        self.id = id
        self.model = model
        self.content = content
    }
}

public struct DeepSeekChatClient: AICompletionClient {
    public let apiKey: String
    public let baseURL: URL
    public let model: String
    public let timeout: TimeInterval
    private let session: URLSession

    public init(
        apiKey: String,
        baseURL: URL = URL(string: "https://api.deepseek.com")!,
        model: String = "deepseek-v4-flash",
        timeout: TimeInterval = 30,
        session: URLSession = .shared
    ) {
        self.apiKey = apiKey
        self.baseURL = baseURL
        self.model = model
        self.timeout = timeout
        self.session = session
    }

    public func complete(messages: [DeepSeekMessage], responseFormat: DeepSeekResponseFormat) async throws -> DeepSeekCompletion {
        guard !TextNormalizer.isBlank(apiKey) else {
            throw AIAnalysisError.missingAPIKey
        }

        let url = baseURL.appending(path: "chat/completions")
        var request = URLRequest(url: url, timeoutInterval: timeout)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(
            DeepSeekChatRequest(
                model: model,
                messages: messages,
                responseFormat: responseFormat,
                temperature: 0.2,
                maxTokens: 2000
            )
        )

        do {
            let (data, response) = try await session.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse else {
                throw AIAnalysisError.invalidResponse
            }

            guard (200..<300).contains(httpResponse.statusCode) else {
                if httpResponse.statusCode == 429 {
                    throw AIAnalysisError.rateLimited
                }
                let summary = String(data: data, encoding: .utf8) ?? "No response body"
                throw AIAnalysisError.server(statusCode: httpResponse.statusCode, summary: String(summary.prefix(300)))
            }

            let payload = try JSONDecoder().decode(DeepSeekChatResponse.self, from: data)
            guard let content = payload.choices.first?.message.content,
                  !TextNormalizer.isBlank(content)
            else {
                throw AIAnalysisError.emptyResponse
            }

            return DeepSeekCompletion(id: payload.id, model: payload.model ?? model, content: content)
        } catch let error as AIAnalysisError {
            throw error
        } catch let error as URLError where error.code == .timedOut {
            throw AIAnalysisError.timeout
        } catch {
            throw AIAnalysisError.network(error.localizedDescription)
        }
    }
}

private struct DeepSeekChatRequest: Encodable {
    let model: String
    let messages: [DeepSeekMessage]
    let responseFormat: DeepSeekResponseFormat
    let temperature: Double
    let maxTokens: Int

    private enum CodingKeys: String, CodingKey {
        case model
        case messages
        case responseFormat = "response_format"
        case temperature
        case maxTokens = "max_tokens"
    }
}

private struct DeepSeekChatResponse: Decodable {
    let id: String?
    let model: String?
    let choices: [Choice]

    struct Choice: Decodable {
        let message: Message
    }

    struct Message: Decodable {
        let content: String?
    }
}
