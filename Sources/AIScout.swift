import Foundation
import CoreGraphics

struct ShotIdea {
    var subject: String
    var why: String
    var box: CGRect   // normalized, origin top-left, in the image that was sent
}

enum AIScoutError: LocalizedError {
    case http(Int, String)
    case unreadable

    var errorDescription: String? {
        switch self {
        case .http(let code, let message):
            if code == 401 { return "API key not accepted. Check it in Settings." }
            if code == 402 { return "Out of credits on that API account." }
            return "AI error \(code): \(message)"
        case .unreadable:
            return "Couldn't read the AI's answer. Try again."
        }
    }
}

/// Sends the camera view to an AI and gets back the best shots in it.
enum AIScout {
    /// OpenRouter keys start with "sk-or-"; anything else goes to Anthropic directly.
    static func isOpenRouter(_ key: String) -> Bool { key.hasPrefix("sk-or-") }

    static func findShots(jpeg: Data, width: Int, height: Int, apiKey: String, model: AIModel,
                          customModel: String, aspectLabel: String, landscape: Bool,
                          wOverH: Double) async throws -> [ShotIdea] {
        let text: String
        let p = prompt(width: width, height: height, aspectLabel: aspectLabel, landscape: landscape)
        if isOpenRouter(apiKey) {
            text = try await askOpenRouter(jpeg: jpeg, prompt: p, apiKey: apiKey,
                                           model: customModel.isEmpty ? model.openRouterID : customModel)
        } else {
            text = try await askAnthropic(jpeg: jpeg, prompt: p, apiKey: apiKey, model: model.rawValue)
        }
        return try parse(text: text, width: width, height: height, wOverH: wOverH)
    }

    static func prompt(width: Int, height: Int, aspectLabel: String, landscape: Bool) -> String {
        let held = landscape ? "sideways (landscape)" : "upright (portrait)"
        let shape = landscape ? "landscape" : "portrait"
        return """
        You are the eye of a photography app. This image is the live camera view, \(width)x\(height) pixels, phone held \(held).

        Find up to 3 different beautiful photos hiding in this view, best first: the subjects or details a good photographer would walk up to and shoot. Look for warm or dramatic light, glowing objects, flowers, plants, texture, reflections, strong shapes, a clear subject against a simple background. Avoid screens, clutter, half-cut objects and empty areas. If there is only one good shot, return just one.

        Each photo is a \(aspectLabel) \(shape) crop (width:height = \(aspectLabel)). Frame each around its subject with a little breathing room. Crops can be much smaller than the whole view, because the app zooms in.

        Reply with ONLY this JSON and nothing else:
        {"shots": [{"subject": "2-4 word name, lowercase", "why": "coaching line, max 8 words, lowercase, e.g. soft side light, let the color glow", "box": [x, y, width, height]}]}

        box is in pixels of this image, origin top-left, and must contain the whole subject.
        """
    }

    // MARK: Providers

    private static func askAnthropic(jpeg: Data, prompt: String, apiKey: String, model: String) async throws -> String {
        var request = URLRequest(url: URL(string: "https://api.anthropic.com/v1/messages")!)
        request.httpMethod = "POST"
        request.timeoutInterval = 45
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        request.setValue("application/json", forHTTPHeaderField: "content-type")

        let body: [String: Any] = [
            "model": model,
            "max_tokens": 600,
            "messages": [[
                "role": "user",
                "content": [
                    [
                        "type": "image",
                        "source": [
                            "type": "base64",
                            "media_type": "image/jpeg",
                            "data": jpeg.base64EncodedString()
                        ]
                    ],
                    ["type": "text", "text": prompt]
                ]
            ]]
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: request)
        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard code == 200 else { throw AIScoutError.http(code, errorMessage(from: data)) }

        let reply = try JSONDecoder().decode(Reply.self, from: data)
        return reply.content.compactMap { $0.text }.joined()
    }

    private static func askOpenRouter(jpeg: Data, prompt: String, apiKey: String, model: String) async throws -> String {
        var request = URLRequest(url: URL(string: "https://openrouter.ai/api/v1/chat/completions")!)
        request.httpMethod = "POST"
        request.timeoutInterval = 45
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Aimshot", forHTTPHeaderField: "X-Title")

        let body: [String: Any] = [
            "model": model,
            "max_tokens": 600,
            "messages": [[
                "role": "user",
                "content": [
                    [
                        "type": "image_url",
                        "image_url": ["url": "data:image/jpeg;base64,\(jpeg.base64EncodedString())"]
                    ],
                    ["type": "text", "text": prompt]
                ]
            ]]
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: request)
        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard code == 200 else { throw AIScoutError.http(code, errorMessage(from: data)) }

        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw AIScoutError.unreadable
        }
        if let err = obj["error"] as? [String: Any], let message = err["message"] as? String {
            throw AIScoutError.http(code, message)
        }
        guard let choices = obj["choices"] as? [[String: Any]],
              let message = choices.first?["message"] as? [String: Any] else {
            throw AIScoutError.unreadable
        }
        if let text = message["content"] as? String { return text }
        if let parts = message["content"] as? [[String: Any]] {
            return parts.compactMap { $0["text"] as? String }.joined()
        }
        throw AIScoutError.unreadable
    }

    // MARK: Parsing

    private struct Reply: Decodable {
        struct Block: Decodable {
            let type: String
            let text: String?
        }
        let content: [Block]
    }

    private struct Idea: Decodable {
        let subject: String
        let why: String
        let box: [Double]
    }

    private struct Shots: Decodable {
        let shots: [Idea]
    }

    static func parse(text: String, width: Int, height: Int, wOverH: Double) throws -> [ShotIdea] {
        guard let start = text.firstIndex(of: "{"),
              let end = text.lastIndex(of: "}"),
              start < end,
              let json = String(text[start...end]).data(using: .utf8) else {
            throw AIScoutError.unreadable
        }
        var raw: [Idea] = []
        if let shots = try? JSONDecoder().decode(Shots.self, from: json) {
            raw = shots.shots
        } else if let one = try? JSONDecoder().decode(Idea.self, from: json) {
            raw = [one]
        }

        let fullW = Double(width)
        let fullH = Double(height)
        let ideas: [ShotIdea] = raw.prefix(3).compactMap { idea in
            guard idea.box.count == 4 else { return nil }
            var b = idea.box
            if b.allSatisfy({ $0 <= 1.0 }) {
                b = [b[0] * fullW, b[1] * fullH, b[2] * fullW, b[3] * fullH]
            }
            return ShotIdea(subject: idea.subject, why: idea.why,
                            box: frame(box: b, fullW: fullW, fullH: fullH, wOverH: wOverH))
        }
        guard !ideas.isEmpty else { throw AIScoutError.unreadable }
        return ideas
    }

    /// Pixel box (origin top-left) -> frame of the right shape, normalized, origin top-left.
    static func frame(box b: [Double], fullW: Double, fullH: Double, wOverH: Double) -> CGRect {
        var w = max(b[2], fullW * 0.08)
        var h = max(b[3], fullH * 0.08)
        let cx = b[0] + b[2] / 2
        let cy = b[1] + b[3] / 2
        if w / h > wOverH { h = w / wOverH } else { w = h * wOverH }
        if w > fullW { w = fullW; h = w / wOverH }
        if h > fullH { h = fullH; w = h * wOverH }
        let x = min(max(cx - w / 2, 0), fullW - w)
        let y = min(max(cy - h / 2, 0), fullH - h)
        return CGRect(x: x / fullW, y: y / fullH, width: w / fullW, height: h / fullH)
    }

    private static func errorMessage(from data: Data) -> String {
        if let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let err = obj["error"] as? [String: Any],
           let message = err["message"] as? String {
            return message
        }
        if let s = String(data: data, encoding: .utf8) { return String(s.prefix(120)) }
        return "unknown"
    }
}
