import Foundation

/// Where the walker is and what they asked: the context that goes with the photo (PRD §6).
public struct TravelerContext: Sendable, Equatable {
    public var from: String?
    public var to: String?
    /// Nearest sights from the fetched corridor, closest first.
    public var nearbySights: [String]
    public var question: String?
    public var lat: Double?
    public var lon: Double?
    public init(from: String? = nil, to: String? = nil, nearbySights: [String] = [], question: String? = nil,
                lat: Double? = nil, lon: Double? = nil) {
        self.from = from; self.to = to; self.nearbySights = nearbySights; self.question = question; self.lat = lat; self.lon = lon
    }
    public var hasQuestion: Bool { !(question?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true) }
}

public struct TourAnswer: Codable, Sendable, Equatable {
    public var title: String?
    public var text: String
}

/// The prompts, carried over from PocketTourGuide (spoken aloud, no links) plus the walk context.
public enum TourPrompt {
    public static func system(hasQuestion: Bool) -> String {
        var s = "You are a friendly expert tour guide speaking to a tourist on a walk. Given their photo, location and the sights nearby, identify what they are looking at."
        s += hasQuestion ? " They asked a question: answer it directly, then add one sentence of context if it helps."
                         : " Say what it is and why it matters in 3 to 6 sentences: notable facts, style or history. Be factual, engaging and concise."
        s += " If you are not sure what it is, say so and give your best guess with the reason. Avoid guessing about people."
        s += " This answer is spoken aloud: plain sentences only, no URLs, links, lists or markdown, and never ask them to tap or click anything."
        s += " Respond only with a JSON object {\"title\": string or null, \"text\": string}."
        return s
    }

    public static func user(_ c: TravelerContext) -> String {
        var parts: [String] = []
        if let lat = c.lat, let lon = c.lon { parts.append(String(format: "Photo taken at %.5f, %.5f.", lat, lon)) }
        if let f = c.from, let t = c.to { parts.append("They are walking from \(f) to \(t).") }
        if !c.nearbySights.isEmpty { parts.append("Mapped sights within a short walk: " + c.nearbySights.joined(separator: "; ") + ".") }
        parts.append(c.hasQuestion ? "Their question: \(c.question!.trimmingCharacters(in: .whitespacesAndNewlines))"
                                   : "Explain what they are looking at.")
        return parts.joined(separator: " ")
    }
}

/// OpenAI Chat Completions with an image, on the user's own key (Keychain, never in the repo).
/// Sign in with ChatGPT (BACKLOG, M6) will add a Responses-API sibling with a token instead.
public struct OpenAIClient: Sendable {
    public enum Failure: Error, LocalizedError, Equatable {
        case noKey, badKey, rateLimited, server(Int), empty
        public var errorDescription: String? {
            switch self {
            case .noKey: return "Add your OpenAI API key in Settings."
            case .badKey: return "OpenAI rejected the API key. Check it in Settings."
            case .rateLimited: return "OpenAI is rate-limiting this key. Try again in a minute."
            case .server(let s): return "OpenAI returned an error (HTTP \(s))."
            case .empty: return "OpenAI returned no answer."
            }
        }
    }
    public static let endpoint = URL(string: "https://api.openai.com/v1/chat/completions")!
    let apiKey: String
    let model: String
    let transport: HTTPTransport

    public init(apiKey: String, model: String = "gpt-5", transport: HTTPTransport = URLSessionTransport(requestTimeout: 90, resourceTimeout: 120)) {
        self.apiKey = apiKey; self.model = model; self.transport = transport
    }

    public func request(jpeg: Data, context: TravelerContext) throws -> URLRequest {
        guard !apiKey.isEmpty else { throw Failure.noKey }
        let body: [String: Any] = [
            "model": model,
            "response_format": ["type": "json_object"],
            "messages": [
                ["role": "system", "content": TourPrompt.system(hasQuestion: context.hasQuestion)],
                ["role": "user", "content": [
                    ["type": "text", "text": TourPrompt.user(context)],
                    ["type": "image_url", "image_url": ["url": "data:image/jpeg;base64," + jpeg.base64EncodedString()]],
                ]],
            ],
        ]
        var r = URLRequest(url: Self.endpoint)
        r.httpMethod = "POST"
        r.setValue("Bearer " + apiKey, forHTTPHeaderField: "Authorization")
        r.setValue("application/json", forHTTPHeaderField: "Content-Type")
        r.httpBody = try JSONSerialization.data(withJSONObject: body)
        return r
    }

    public func describe(jpeg: Data, context: TravelerContext) async throws -> TourAnswer {
        let (data, response) = try await transport.data(for: try request(jpeg: jpeg, context: context))
        switch response.statusCode {
        case 200..<300: break
        case 401, 403: throw Failure.badKey
        case 429: throw Failure.rateLimited
        default: throw Failure.server(response.statusCode)
        }
        return try Self.parse(data)
    }

    static func parse(_ data: Data) throws -> TourAnswer {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let content = ((root["choices"] as? [[String: Any]])?.first?["message"] as? [String: Any])?["content"] as? String,
              !content.isEmpty else { throw Failure.empty }
        if let parsed = try? JSONDecoder().decode(TourAnswer.self, from: Data(content.utf8)) { return parsed }
        return TourAnswer(title: nil, text: content.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    /// A cheap check that the key works (lists models; no tokens spent).
    public func testKey() async -> Bool {
        var r = URLRequest(url: URL(string: "https://api.openai.com/v1/models")!)
        r.setValue("Bearer " + apiKey, forHTTPHeaderField: "Authorization")
        guard let (_, resp) = try? await transport.data(for: r) else { return false }
        return resp.statusCode == 200
    }
}
