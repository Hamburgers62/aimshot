import Foundation
import CoreGraphics

struct ShotIdea {
    var subject: String
    var why: String
    var box: CGRect   // normalized, origin top-left, in the image that was sent
    var score: Int = 0
    var exposure: Double = 0
    var style: String = ""
}

struct ScanResult {
    var ideas: [ShotIdea]
    /// When nothing is worth shooting: where to point instead.
    var tip: String?
}

enum AIScoutError: LocalizedError {
    case http(Int, String)
    case unreadable(String)
    case noKey

    var errorDescription: String? {
        switch self {
        case .http(let code, let message):
            if code == 401 { return "API key not accepted. Check it in Settings." }
            if code == 402 { return "Out of credits on that API account." }
            if code == 404 { return "That model isn't available: \(message)" }
            return "AI error \(code): \(message)"
        case .unreadable(let snippet):
            return snippet.isEmpty
                ? "The model sent back an empty answer. Try again or pick another model."
                : "The model's answer didn't make sense: \(snippet)"
        case .noKey:
            return "Add an API key in Settings first."
        }
    }
}

/// Talks to the AI: finds shots in the camera view, and suggests edits for a photo.
enum AIScout {
    /// OpenRouter keys start with "sk-or-"; anything else goes to Anthropic directly.
    static func isOpenRouter(_ key: String) -> Bool { key.hasPrefix("sk-or-") }

    // MARK: Find shots

    static func findShots(jpeg: Data, width: Int, height: Int, key: String, model: String,
                          aspectLabel: String, landscape: Bool, wOverH: Double,
                          style: ShotStyle, count: Int) async throws -> ScanResult {
        let p = scanPrompt(width: width, height: height, aspectLabel: aspectLabel,
                           landscape: landscape, style: style, count: count)
        let text = try await ask(jpeg: jpeg, prompt: p, key: key, model: model, maxTokens: 2000)
        return try parseShots(text: text, width: width, height: height, wOverH: wOverH, count: count)
    }

    static func scanPrompt(width: Int, height: Int, aspectLabel: String, landscape: Bool,
                           style: ShotStyle, count: Int) -> String {
        let held = landscape ? "sideways (landscape)" : "upright (portrait)"
        let shape = landscape ? "landscape" : "portrait"
        let howMany = count == 1 ? "the single most beautiful photo" : "up to \(count) different beautiful photos, best first,"
        return """
        You are the eye of a photography app. This image is the live camera view, \(width)x\(height) pixels, phone held \(held).

        Find \(howMany) hiding in this view: the subjects or details a good photographer would walk up to and shoot. Look for warm or dramatic light, glowing objects, texture, reflections, strong shapes, a clear subject against a simple background. Avoid screens, clutter, half-cut objects, messy backgrounds and empty areas.

        Hard rules: only pick things that will still be there in ten seconds (nothing walking or driving away). Never just frame the middle of the view or the whole scene; find a specific detail, so each crop is at most two thirds of the view's width.
        \(style.promptLine)

        Be picky and honest. Score each shot 1-10 for how good the final photo would really look. Name the subject exactly as it is (don't call a laptop a magazine). If nothing here would score 5 or more, return an empty list and say where to point instead.

        If it's dark, prefer subjects that are well lit (signs, windows, lamps, lit buildings) and keep crops larger, because zooming far in at night makes photos soft.

        Each photo is a \(aspectLabel) \(shape) crop (width:height = \(aspectLabel)). Frame tight: the subject should fill most of the crop, with only a little breathing room. For people, crop close around the face and hands, not the whole room. Crops can be much smaller than the whole view, because the app zooms in.

        style is one word for the kind of shot: portrait, glow (light sources, warm lamps, signs), reflection, stilllife (one object), geometry (lines, symmetry, architecture) or texture.

        exposure is a tweak in stops from -1 to 1: negative for bright lights, signs and screens so they don't blow out, positive for dim subjects, 0 if fine.

        Reply with ONLY this JSON, no markdown, no other text:
        {"shots": [{"subject": "2-4 word name, lowercase", "why": "coaching line, max 8 words, lowercase, e.g. soft side light, let the color glow", "score": 1-10, "style": "one word", "exposure": -1.0-1.0, "box": [x, y, width, height]}], "tip": "only if the list is empty: where to point instead, max 10 words"}

        box is in pixels of this image, origin top-left, and must contain the whole subject.
        """
    }

    static func parseShots(text: String, width: Int, height: Int, wOverH: Double, count: Int) throws -> ScanResult {
        guard let json = extractJSON(text) else { throw AIScoutError.unreadable(snippet(text)) }

        var raw: [[String: Any]] = []
        var tip: String? = nil
        if let dict = json as? [String: Any] {
            tip = dict["tip"] as? String
            if let shots = dict["shots"] as? [[String: Any]] {
                raw = shots
            } else if dict["box"] != nil {
                raw = [dict]
            }
        } else if let list = json as? [[String: Any]] {
            raw = list
        }

        let fullW = Double(width)
        let fullH = Double(height)
        let ideas: [ShotIdea] = raw.prefix(max(count, 1)).compactMap { item in
            guard var b = box(item["box"] ?? item["bbox"] ?? item["rect"]) else { return nil }
            if b.allSatisfy({ $0 <= 1.0 }) {
                b = [b[0] * fullW, b[1] * fullH, b[2] * fullW, b[3] * fullH]   // answered in 0-1
            }
            let subject = (item["subject"] as? String) ?? (item["name"] as? String) ?? "nice shot"
            let why = (item["why"] as? String) ?? (item["reason"] as? String) ?? ""
            let score = Int((number(item["score"]) ?? 6).rounded())
            let exposure = min(max(number(item["exposure"]) ?? 0, -1), 1)
            let style = ((item["style"] as? String) ?? "").lowercased().replacingOccurrences(of: " ", with: "")
            return ShotIdea(subject: subject.lowercased(), why: why.lowercased(),
                            box: frame(box: b, fullW: fullW, fullH: fullH, wOverH: wOverH),
                            score: min(max(score, 1), 10), exposure: exposure, style: style)
        }
        // Drop weak ideas; best first.
        let good = ideas.filter { $0.score >= 5 }.sorted { $0.score > $1.score }
        if good.isEmpty && raw.isEmpty && tip == nil { throw AIScoutError.unreadable(snippet(text)) }
        return ScanResult(ideas: good, tip: tip)
    }

    // MARK: Fine-tune the crop up close

    /// Second look, once zoomed in on the subject: returns a tighter, more precise crop
    /// (normalized, origin top-left, in the image sent).
    static func refineCrop(jpeg: Data, width: Int, height: Int, key: String, model: String,
                           subject: String, aspectLabel: String, landscape: Bool, wOverH: Double) async throws -> CGRect {
        let shape = landscape ? "landscape" : "portrait"
        let p = """
        This is a zoomed-in camera view (\(width)x\(height) pixels) of: \(subject).

        Choose the best final \(aspectLabel) \(shape) crop of it, like a skilled photographer would: tight and intentional, the subject filling most of the frame, clean edges (don't cut through hands, heads or key details, and leave distracting objects out), rule of thirds where it helps. For a person, put the face and eyes in the upper third.

        Reply with ONLY this JSON, no markdown, no other text:
        {"box": [x, y, width, height]}

        box is in pixels of this image, origin top-left.
        """
        let text = try await ask(jpeg: jpeg, prompt: p, key: key, model: model, maxTokens: 800)
        guard let dict = extractJSON(text) as? [String: Any],
              var b = box(dict["box"] ?? dict["crop"]) else {
            throw AIScoutError.unreadable(snippet(text))
        }
        let fullW = Double(width)
        let fullH = Double(height)
        if b.allSatisfy({ $0 <= 1.0 }) {
            b = [b[0] * fullW, b[1] * fullH, b[2] * fullW, b[3] * fullH]
        }
        return frame(box: b, fullW: fullW, fullH: fullH, wOverH: wOverH)
    }

    // MARK: Suggest an edit

    static func suggestEdit(jpeg: Data, key: String, model: String, subject: String) async throws
        -> (settings: EditSettings, note: String) {
        let p = """
        You are the photo editor in a film-camera app. Look at this photo (subject: \(subject)) and pick the film look that suits it best, like a tasteful photographer would. Subtle beats dramatic.

        Looks:
        - none: untouched
        - natural: barely-there polish, safe for anything
        - golden: warm, sunny, nostalgic; daylight, autumn, golden hour
        - soft: gentle and flattering; portraits and people in soft light
        - night: cool shadows, glowing lights; night scenes with street lights or neon
        - ember: warm and moody with deeper contrast; lamps, candles, cosy interiors, warm night light
        - tide: cool and calm; overcast days, water, blue hour
        - slide: punchy and vivid; bright colourful daylight scenes
        - faded: matte and pastel; bright daytime only (never at night)
        - mono: classic black and white
        - noir: high-contrast black and white; strong light and shadow

        Reply with ONLY this JSON, no markdown, no other text:
        {"look": "look id", "strength": 0.4-1.0, "exposure": -0.5-0.5, "warmth": -0.3-0.3, "note": "max 10 words, lowercase, why this look"}

        exposure and warmth are small corrections only; use 0 if the photo is already right. If unsure, choose natural.
        """
        let text = try await ask(jpeg: jpeg, prompt: p, key: key, model: model, maxTokens: 1200)
        guard let dict = extractJSON(text) as? [String: Any] else { throw AIScoutError.unreadable(snippet(text)) }
        let note = (dict["note"] as? String) ?? ""
        return (EditSettings.fromAI(dict), note.lowercased())
    }

    // MARK: Test

    /// Quick check that the key and model work. Returns seconds taken.
    static func test(key: String, model: String) async throws -> Double {
        let start = Date()
        _ = try await ask(jpeg: nil, prompt: "Reply with just the word: ok", key: key, model: model, maxTokens: 50)
        return Date().timeIntervalSince(start)
    }

    // MARK: Transport

    static func ask(jpeg: Data?, prompt: String, key: String, model: String, maxTokens: Int) async throws -> String {
        guard !key.isEmpty else { throw AIScoutError.noKey }
        if isOpenRouter(key) {
            return try await askOpenRouter(jpeg: jpeg, prompt: prompt, key: key, model: model, maxTokens: maxTokens)
        }
        return try await askAnthropic(jpeg: jpeg, prompt: prompt, key: key, model: model, maxTokens: maxTokens)
    }

    private static func askAnthropic(jpeg: Data?, prompt: String, key: String, model: String,
                                     maxTokens: Int) async throws -> String {
        var request = URLRequest(url: URL(string: "https://api.anthropic.com/v1/messages")!)
        request.httpMethod = "POST"
        request.timeoutInterval = 60
        request.setValue(key, forHTTPHeaderField: "x-api-key")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        request.setValue("application/json", forHTTPHeaderField: "content-type")

        var content: [[String: Any]] = []
        if let jpeg = jpeg {
            content.append([
                "type": "image",
                "source": ["type": "base64", "media_type": "image/jpeg", "data": jpeg.base64EncodedString()]
            ])
        }
        content.append(["type": "text", "text": prompt])
        let body: [String: Any] = [
            "model": model,
            "max_tokens": maxTokens,
            "messages": [["role": "user", "content": content]]
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: request)
        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard code == 200 else { throw AIScoutError.http(code, errorMessage(from: data)) }

        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let blocks = obj["content"] as? [[String: Any]] else {
            throw AIScoutError.unreadable(snippet(String(data: data, encoding: .utf8) ?? ""))
        }
        return blocks.compactMap { $0["text"] as? String }.joined()
    }

    private static func askOpenRouter(jpeg: Data?, prompt: String, key: String, model: String,
                                      maxTokens: Int) async throws -> String {
        var request = URLRequest(url: URL(string: "https://openrouter.ai/api/v1/chat/completions")!)
        request.httpMethod = "POST"
        request.timeoutInterval = 60
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Aimshot", forHTTPHeaderField: "X-Title")

        var content: [[String: Any]] = []
        if let jpeg = jpeg {
            content.append([
                "type": "image_url",
                "image_url": ["url": "data:image/jpeg;base64,\(jpeg.base64EncodedString())"]
            ])
        }
        content.append(["type": "text", "text": prompt])
        let body: [String: Any] = [
            "model": model,
            "max_tokens": maxTokens,
            "messages": [["role": "user", "content": content]]
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: request)
        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard code == 200 else { throw AIScoutError.http(code, errorMessage(from: data)) }

        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw AIScoutError.unreadable(snippet(String(data: data, encoding: .utf8) ?? ""))
        }
        if let err = obj["error"] as? [String: Any], let message = err["message"] as? String {
            throw AIScoutError.http(code, message)
        }
        guard let choices = obj["choices"] as? [[String: Any]],
              let message = choices.first?["message"] as? [String: Any] else {
            throw AIScoutError.unreadable(snippet(String(data: data, encoding: .utf8) ?? ""))
        }
        if let text = message["content"] as? String, !text.isEmpty { return text }
        if let parts = message["content"] as? [[String: Any]] {
            let text = parts.compactMap { $0["text"] as? String }.joined()
            if !text.isEmpty { return text }
        }
        // Some models put everything in "reasoning" and leave content empty.
        if let reasoning = message["reasoning"] as? String { return reasoning }
        return ""
    }

    // MARK: Forgiving parsing helpers

    /// Pulls the JSON object out of a reply, even with markdown fences or chatter around it.
    static func extractJSON(_ text: String) -> Any? {
        guard let start = text.firstIndex(of: "{"),
              let end = text.lastIndex(of: "}"),
              start < end else { return nil }
        return try? JSONSerialization.jsonObject(with: Data(text[start...end].utf8))
    }

    static func number(_ v: Any?) -> Double? {
        if let n = v as? NSNumber { return n.doubleValue }
        if let s = v as? String { return Double(s.trimmingCharacters(in: .whitespaces)) }
        return nil
    }

    /// Accepts [x, y, w, h] or {"x":…, "y":…, "width":…, "height":…}.
    static func box(_ v: Any?) -> [Double]? {
        if let arr = v as? [Any] {
            let nums = arr.compactMap { number($0) }
            return nums.count == 4 ? nums : nil
        }
        if let d = v as? [String: Any],
           let x = number(d["x"] ?? d["left"]),
           let y = number(d["y"] ?? d["top"]),
           let w = number(d["width"] ?? d["w"]),
           let h = number(d["height"] ?? d["h"]) {
            return [x, y, w, h]
        }
        return nil
    }

    private static func snippet(_ text: String) -> String {
        let flat = text.replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespaces)
        return flat.count > 90 ? String(flat.prefix(90)) + "…" : flat
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
