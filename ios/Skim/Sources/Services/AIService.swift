import Foundation

/// AI service for article triage and summarization.
/// Supports Claude, OpenAI, and Ollama providers.
actor AIService {
    static let shared = AIService()

    struct TriageItem: Codable {
        let id: String
        let priority: Int
        let reason: String
    }

    struct TriageResponse: Codable {
        let triage: [TriageItem]
    }

    enum Provider: String {
        case anthropic
        case openai
        case ollama
    }

    func triageArticles(
        articles: [(id: String, title: String, source: String, excerpt: String)],
        provider: Provider,
        apiKey: String,
        model: String,
        preferences: String? = nil
    ) async throws -> [TriageItem] {
        let snippets = articles.map { article in
            ["id": article.id, "title": article.title, "source": article.source, "excerpt": article.excerpt]
        }
        let articlesJson = try JSONSerialization.data(withJSONObject: snippets)
        let articlesString = String(data: articlesJson, encoding: .utf8) ?? "[]"

        var systemPrompt = """
        You triage RSS articles for a busy reader. For each article, assign a priority (1-5) and write a one-line reason (under 80 chars) explaining why it matters or doesn't.

        Priority scale:
        5 = Breaking/urgent, directly relevant, actionable
        4 = Important development, significant news
        3 = Interesting, worth reading when time allows
        2 = Routine update, low novelty
        1 = Noise, promotional, or not useful

        Be opinionated. Most articles should be 2-3. Reserve 5 for genuinely important items. Reserve 1 for clear noise.
        """

        if let prefs = preferences, !prefs.isEmpty {
            systemPrompt += "\n\n--- Reader's learned preferences ---\n\(prefs)"
        }

        let userPrompt = """
        Triage these articles. For each, return its id, a priority (1-5), and a reason (one sentence, under 80 chars).

        Articles:
        \(articlesString)

        Respond in this exact JSON format:
        {
          "triage": [
            {"id": "article-id-here", "priority": 3, "reason": "Routine product update, nothing novel"}
          ]
        }
        """

        let responseText = try await chatCompletion(
            provider: provider,
            apiKey: apiKey,
            model: model,
            systemPrompt: systemPrompt,
            userPrompt: userPrompt,
            jsonMode: true,
            maxTokens: articles.count * 60
        )

        // Parse JSON response
        guard let jsonData = responseText.data(using: .utf8),
              let response = try? JSONDecoder().decode(TriageResponse.self, from: jsonData) else {
            throw AIError.parseError("Failed to parse triage response")
        }

        return response.triage.map { item in
            TriageItem(id: item.id, priority: min(5, max(1, item.priority)), reason: item.reason)
        }
    }

    func summarizeArticle(
        title: String,
        content: String,
        provider: Provider,
        apiKey: String,
        model: String
    ) async throws -> String {
        let truncated = String(content.prefix(6000))

        let systemPrompt = "You write concisely and precisely. No filler, no hedging. Lead with the single most important takeaway. Always respond with a JSON object containing exactly two string keys: \"summary\" and \"notes\"."

        let userPrompt = """
        Summarize the following article in 1-2 sentences (~30 words).

        Article title: \(title)

        Article text:
        \(truncated)

        Respond with a JSON object with keys "summary" and "notes".
        """

        let responseText = try await chatCompletion(
            provider: provider,
            apiKey: apiKey,
            model: model,
            systemPrompt: systemPrompt,
            userPrompt: userPrompt,
            jsonMode: true,
            maxTokens: 256
        )

        if let jsonData = responseText.data(using: .utf8),
           let json = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any],
           let summary = json["summary"] as? String {
            return summary
        }

        return responseText
    }

    private func chatCompletion(
        provider: Provider,
        apiKey: String,
        model: String,
        systemPrompt: String,
        userPrompt: String,
        jsonMode: Bool,
        maxTokens: Int
    ) async throws -> String {
        switch provider {
        case .anthropic:
            return try await anthropicCompletion(apiKey: apiKey, model: model, systemPrompt: systemPrompt, userPrompt: userPrompt, maxTokens: maxTokens)
        case .openai:
            return try await openaiCompletion(apiKey: apiKey, model: model, systemPrompt: systemPrompt, userPrompt: userPrompt, jsonMode: jsonMode, maxTokens: maxTokens)
        case .ollama:
            return try await ollamaCompletion(model: model, systemPrompt: systemPrompt, userPrompt: userPrompt, jsonMode: jsonMode, maxTokens: maxTokens)
        }
    }

    private func anthropicCompletion(apiKey: String, model: String, systemPrompt: String, userPrompt: String, maxTokens: Int) async throws -> String {
        var request = URLRequest(url: URL(string: "https://api.anthropic.com/v1/messages")!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")

        let body: [String: Any] = [
            "model": model,
            "max_tokens": maxTokens,
            "system": systemPrompt,
            "messages": [["role": "user", "content": userPrompt]]
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, _) = try await URLSession.shared.data(for: request)
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let content = json["content"] as? [[String: Any]],
              let text = content.first?["text"] as? String else {
            throw AIError.parseError("Invalid Anthropic response")
        }
        return text
    }

    private func openaiCompletion(apiKey: String, model: String, systemPrompt: String, userPrompt: String, jsonMode: Bool, maxTokens: Int) async throws -> String {
        var request = URLRequest(url: URL(string: "https://api.openai.com/v1/chat/completions")!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")

        var body: [String: Any] = [
            "model": model,
            "max_tokens": maxTokens,
            "messages": [
                ["role": "system", "content": systemPrompt],
                ["role": "user", "content": userPrompt]
            ]
        ]
        if jsonMode {
            body["response_format"] = ["type": "json_object"]
        }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, _) = try await URLSession.shared.data(for: request)
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choices = json["choices"] as? [[String: Any]],
              let message = choices.first?["message"] as? [String: Any],
              let text = message["content"] as? String else {
            throw AIError.parseError("Invalid OpenAI response")
        }
        return text
    }

    private func ollamaCompletion(model: String, systemPrompt: String, userPrompt: String, jsonMode: Bool, maxTokens: Int) async throws -> String {
        var request = URLRequest(url: URL(string: "http://localhost:11434/api/chat")!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        var body: [String: Any] = [
            "model": model,
            "stream": false,
            "messages": [
                ["role": "system", "content": systemPrompt],
                ["role": "user", "content": userPrompt]
            ],
            "options": ["num_predict": maxTokens]
        ]
        if jsonMode {
            body["format"] = "json"
        }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, _) = try await URLSession.shared.data(for: request)
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let message = json["message"] as? [String: Any],
              let text = message["content"] as? String else {
            throw AIError.parseError("Invalid Ollama response")
        }
        return text
    }

    enum AIError: LocalizedError {
        case parseError(String)
        case networkError(String)

        var errorDescription: String? {
            switch self {
            case .parseError(let msg): return msg
            case .networkError(let msg): return msg
            }
        }
    }
}
