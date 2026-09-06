import Foundation

/// A single, cheap look at one screenshot, outside the Live session.
///
/// Exists because of a hard constraint in the Live API: a `clientContent` text
/// turn cannot see the `realtimeInput` video stream. Measured — asked by voice,
/// the model quotes a compiler error off the screen exactly; asked by injected
/// text over the identical video feed, it reports having received no frame at
/// all. So anything Kweku says *unprompted* about the screen — nobody spoke, so
/// there is no voice turn — cannot be grounded in the live feed.
///
/// Rather than let the model guess (it will, fluently, and be wrong), the
/// looking happens here against a plain `generateContent` call, and only the
/// quoted result is handed to the conversation. The Live model is then
/// repeating something read, not imagining something unseen.
enum ScreenGlance {

    /// Model for one-shot looks. Cheap and fast — this runs on a trigger, not
    /// on a cadence, so latency matters more than depth. Overridable, because
    /// this is the string that rots: `gemini-2.5-flash` already 404s with
    /// "no longer available to new users", and a glance that 404s fails silent.
    static var model: String {
        UserDefaults.standard.string(forKey: "glanceModel") ?? "gemini-3.6-flash"
    }

    /// Reply that means "nothing here". Kept short so a wrong answer is
    /// obvious rather than plausible.
    static let nothing = "NONE"

    static let triagePrompt = """
        This is a screenshot of a developer's screen. If it clearly shows an \
        error, a failed build, a crash, or a stack trace, reply with the single \
        most specific error line, quoted exactly as it appears — nothing else. \
        If there is no clear failure visible, reply with exactly NONE. Do not \
        explain, do not guess, and never describe an error you cannot read.
        """

    static let recallPrompt = """
        This is a screenshot from a developer's screen history. In at most two \
        sentences, say what it shows. Quote any error message, URL, or command \
        exactly as it appears. Do not speculate about anything not visible.
        """

    /// Ask the model about one frame. Nil when there's nothing to report, the
    /// request failed, or no key is configured — every one of which should
    /// leave Kweku silent rather than guessing.
    static func inspect(jpeg: Data, prompt: String, apiKey: String) async -> String? {
        var request = URLRequest(url: URL(string:
            "https://generativelanguage.googleapis.com/v1beta/models/\(model):generateContent")!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        // Header rather than a query parameter: keys in URLs end up in logs.
        request.setValue(apiKey, forHTTPHeaderField: "x-goog-api-key")
        request.timeoutInterval = 20

        let body: [String: Any] = [
            "contents": [["parts": [
                ["text": prompt],
                ["inline_data": ["mime_type": "image/jpeg",
                                 "data": jpeg.base64EncodedString()]],
            ]]],
            // Deterministic: this is a reading task, not a creative one.
            //
            // The budget looks absurd for a one-line answer, and isn't: this
            // model spends output tokens on reasoning before it writes, so a
            // tight cap truncates mid-quote ("cannot find 'ScreenMomnt' in").
            // Setting `thinkingConfig.thinkingBudget: 0` to reclaim it is
            // rejected outright with a 400, so headroom is the only lever.
            "generationConfig": ["temperature": 0, "maxOutputTokens": 800],
        ]
        guard let payload = try? JSONSerialization.data(withJSONObject: body) else { return nil }
        request.httpBody = payload

        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200
        else { return nil }
        return text(from: data).flatMap(clean)
    }

    /// Pull the answer out of a `generateContent` response.
    static func text(from data: Data) -> String? {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let candidates = obj["candidates"] as? [[String: Any]],
              let content = candidates.first?["content"] as? [String: Any],
              let parts = content["parts"] as? [[String: Any]]
        else { return nil }
        let joined = parts.compactMap { $0["text"] as? String }.joined()
        return joined.isEmpty ? nil : joined
    }

    /// Normalise, and turn "nothing to report" into nil so callers can't
    /// accidentally announce the word NONE.
    static func clean(_ raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let bare = trimmed.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        guard bare.uppercased() != nothing else { return nil }
        return trimmed
    }
}
