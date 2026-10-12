import Foundation
import CoreGraphics

struct ShotIdea {
    var subject: String
    var why: String
    var rect: CGRect   // normalized Vision coords (origin bottom-left)
}

enum AIScoutError: LocalizedError {
    case http(Int, String)
    case unreadable

    var errorDescription: String? {
        switch self {
        case .http(let code, let message):
            if code == 401 { return "API key not accepted. Check it in Settings." }
            return "AI error \(code): \(message)"
        case .unreadable:
            return "Couldn't read the AI's answer. Try again."
        }
    }
}

/// Sends the camera view to Claude and gets back the best shot in it.
enum AIScout {
    static let photoAspect = 4.0 / 5.0

    static func findShot(jpeg: Data, width: Int, height: Int, apiKey: String, model: String) async throws -> ShotIdea {
        var request = URLRequest(url: URL(string: "https://api.anthropic.com/v1/messages")!)
        request.httpMethod = "POST"
        request.timeoutInterval = 40
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        request.setValue("application/json", forHTTPHeaderField: "content-type")

        let body: [String: Any] = [
            "model": model,
            "max_tokens": 300,
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
                    ["type": "text", "text": prompt(width: width, height: height)]
                ]
            ]]
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: request)
        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard code == 200 else {
            throw AIScoutError.http(code, errorMessage(from: data))
        }
        return try parse(data, width: width, height: height)
    }

    static func prompt(width: Int, height: Int) -> String {
        """
        You are the eye of a photography app. This image is the live camera view, \(width)x\(height) pixels, portrait.

        Find the ONE most beautiful photo hiding in this view: the subject or detail a good photographer would walk up to and shoot. Look for warm or dramatic light, glowing objects, flowers, plants, texture, reflections, strong shapes, a clear subject against a simple background. Avoid screens, clutter, half-cut objects and empty areas.

        The final photo is a 4:5 portrait crop. Frame it around the subject with a little breathing room. It can be much smaller than the whole view, because the app zooms in.

        Reply with ONLY this JSON and nothing else:
        {"subject": "2-4 word name, lowercase", "why": "coaching line, max 8 words, lowercase, e.g. soft side light, let the color glow", "box": [x, y, width, height]}

        box is in pixels of this image, origin top-left, and must contain the whole subject.
        """
    }

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

    static func parse(_ data: Data, width: Int, height: Int) throws -> ShotIdea {
        let reply = try JSONDecoder().decode(Reply.self, from: data)
        let text = reply.content.compactMap { $0.text }.joined()
        guard let start = text.firstIndex(of: "{"),
              let end = text.lastIndex(of: "}"),
              start < end,
              let json = String(text[start...end]).data(using: .utf8),
              let idea = try? JSONDecoder().decode(Idea.self, from: json),
              idea.box.count == 4 else {
            throw AIScoutError.unreadable
        }
        let fullW = Double(width)
        let fullH = Double(height)
        var b = idea.box
        if b.allSatisfy({ $0 <= 1.0 }) {
            // Model answered in 0-1 instead of pixels.
            b = [b[0] * fullW, b[1] * fullH, b[2] * fullW, b[3] * fullH]
        }
        return ShotIdea(subject: idea.subject, why: idea.why, rect: frame(box: b, fullW: fullW, fullH: fullH))
    }

    /// Pixel box (origin top-left) -> 4:5 frame in normalized Vision coords (origin bottom-left).
    static func frame(box b: [Double], fullW: Double, fullH: Double) -> CGRect {
        var w = max(b[2], fullW * 0.08)
        var h = max(b[3], fullH * 0.08)
        let cx = b[0] + b[2] / 2
        let cy = b[1] + b[3] / 2
        if w / h > photoAspect { h = w / photoAspect } else { w = h * photoAspect }
        if w > fullW { w = fullW; h = w / photoAspect }
        if h > fullH { h = fullH; w = h * photoAspect }
        let x = min(max(cx - w / 2, 0), fullW - w)
        let y = min(max(cy - h / 2, 0), fullH - h)
        return CGRect(x: x / fullW, y: 1 - (y + h) / fullH, width: w / fullW, height: h / fullH)
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
