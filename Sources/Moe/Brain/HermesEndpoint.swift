import Foundation

/// Where the Hermes gateway is and how to be let in — the part of talking to
/// it that `HermesBrain` (the conversation) and `DictationPolisher` (a
/// one-shot rewrite) must agree on: the port from config.json, the bearer
/// key, and the two session headers Hermes only honours on authenticated
/// requests.
struct HermesEndpoint {
    let port: Int
    let baseURL: URL
    /// Resolved once: config.json, else ~/.hermes/.env. Empty means none.
    let apiKey: String

    init(config: Config) {
        // A bad port would crash on the force-unwrap below; fall back loudly.
        if (1...65535).contains(config.hermesPort) {
            port = config.hermesPort
        } else {
            port = 8642
            Log.write("config.json: hermesPort \(config.hermesPort) is not a port; using 8642")
        }
        baseURL = URL(string: "http://127.0.0.1:\(port)")!
        apiKey = HermesKey.resolve(config)
    }

    /// A session that never leaves the machine. These requests carry the
    /// bearer key, the memory files, the brief — and, for dictation, whatever
    /// the user was typing — so a system-wide HTTP proxy (corporate, Charles,
    /// a leftover env var) must never see them.
    static func sessionConfiguration() -> URLSessionConfiguration {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.waitsForConnectivity = false
        cfg.connectionProxyDictionary = [:]
        return cfg
    }

    func request(_ path: String) -> URLRequest {
        var req = URLRequest(url: baseURL.appendingPathComponent(path))
        if !apiKey.isEmpty {
            req.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        }
        return req
    }

    /// `POST /v1/chat/completions` carrying one system and one user message.
    ///
    /// `sessionID` is the transcript (Hermes reloads it from its own state.db);
    /// `sessionKey` scopes Hermes's long-term memory and is stable on purpose.
    /// Without a key Hermes ignores both, so they are not sent at all.
    ///
    /// `brain` names the provider and model for this turn (see
    /// `BrainSelection`). For the Claude Code provider that reaches
    /// `claude --model` when Hermes builds the session's child — a warm child
    /// keeps the model it was started with, which is why a model change
    /// rotates session ids (`Conductor.applyBrain`).
    /// `images` make the user message multipart — a text part and one
    /// `image_url` data URL part each, the OpenAI vision shape api_server
    /// accepts (`_normalize_multimodal_content`).
    ///
    /// `origin` says who started this turn, as `X-Hermes-Turn-Origin` (see `TurnStarter`).
    /// Hermes lets its Chrome-extension browser lane act on the person's screen only in a
    /// `.person` turn, so a URL inside a transcript can never open a window in front of them.
    /// `nil` sends nothing, which Hermes treats as "not a person's live turn" — right for the
    /// side sessions (meeting scans, dictation polish, the settings probe). No default: each
    /// caller says which.
    ///
    /// `personWords` is what the person typed or said this turn, apart from
    /// everything Moe wraps around it — the Now line, the brief (other
    /// people's mail and chats), a recap with Moe's own lines, the delivery
    /// rules. It goes as `X-Hermes-Person-Words` (base64 of the UTF-8), on a
    /// `.person` turn only, and it is all the send gate's recipient grounding
    /// counts as the owner's words: on 2026-10-07 a live ledger held the whole
    /// wrapper as "the owner's words", so a number somebody else wrote in the
    /// brief could count as one the owner named. Hermes files an undeclared
    /// person turn as nobody's words.
    ///
    /// `spoken` says the person said this turn aloud and is waiting to hear
    /// the answer: `X-Hermes-Voice-Turn: 1`, on a `.person` turn only. Hermes
    /// then opens the turn at the lowest reasoning effort that brain has
    /// (`Config.spokenTurnsOpenQuick`). A header rather than a body field or
    /// a different system prompt on purpose: it is not part of what the
    /// brain's process was started with (`LaunchSignature`), so a spoken turn
    /// after a typed one costs no restart.
    ///
    /// `noMemory` says the chat is one the person asked not to be remembered
    /// ("Don't remember this chat"): `X-Hermes-No-Memory: 1`, on every turn of
    /// it whoever started it — a priming or a background note in that chat is
    /// as private as the person's words. Hermes then refuses every memory
    /// write in the turn, spawns no memory review after it, and the memory
    /// plugins learn nothing from it.

    func chatRequest(sessionID: String, sessionKey: String,
                     system: String, user: String, stream: Bool,
                     brain: BrainSelection? = nil, images: [ImageAttachment] = [],
                     origin: TurnStarter?, personWords: String? = nil,
                     spoken: Bool = false, noMemory: Bool = false) -> URLRequest {
        var req = request("v1/chat/completions")
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue(stream ? "text/event-stream" : "application/json", forHTTPHeaderField: "Accept")
        if let origin { req.setValue(origin.rawValue, forHTTPHeaderField: "X-Hermes-Turn-Origin") }
        if origin == .person, spoken { req.setValue("1", forHTTPHeaderField: "X-Hermes-Voice-Turn") }
        if noMemory { req.setValue("1", forHTTPHeaderField: "X-Hermes-No-Memory") }
        if origin == .person, let words = personWords, let value = Self.personWordsHeader(words) {
            req.setValue(value, forHTTPHeaderField: "X-Hermes-Person-Words")
        }
        if !apiKey.isEmpty {
            req.setValue(sessionID, forHTTPHeaderField: "X-Hermes-Session-Id")
            req.setValue(sessionKey, forHTTPHeaderField: "X-Hermes-Session-Key")
        }
        let userContent: Any
        if !images.isEmpty {
            userContent = [["type": "text", "text": user]]
                + images.map { ["type": "image_url", "image_url": ["url": $0.dataURL]] }
        } else {
            userContent = user
        }
        var body: [String: Any] = [
            "stream": stream,
            "messages": [
                ["role": "system", "content": system],
                ["role": "user", "content": userContent],
            ],
        ]
        for (k, v) in brain?.bodyFields ?? [:] { body[k] = v }
        req.httpBody = try? JSONSerialization.data(withJSONObject: body)
        return req
    }

    /// Most of the person's words a header carries, in UTF-8 bytes. aiohttp
    /// refuses a header field over 8190 bytes, and base64 grows this by a
    /// third; a longer turn keeps its beginning, and an address past the cut
    /// is simply not one the person named — refused, never invented.
    static let personWordsLimit = 4500

    /// `X-Hermes-Person-Words` for `words`: base64 of their UTF-8, cut to
    /// `personWordsLimit` on a character boundary. nil when there are none.
    static func personWordsHeader(_ words: String) -> String? {
        var text = words.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        while text.utf8.count > personWordsLimit {
            text = String(text.dropLast(max(1, (text.utf8.count - personWordsLimit) / 4)))
        }
        return Data(text.utf8).base64EncodedString()
    }
}
