import Foundation
import ImageIO

/// Drives the AI-mode agentic loop: given a natural-language query, it lets the
/// model call `search` across the user's enabled Beacon sources, `read_thread`
/// to read the conversation around a message hit, and finally `present_results`
/// to pick the best-matching locations. The output is always locations (result
/// rows) — never prose.
///
/// The loop is provider-agnostic: it keeps a neutral transcript and a neutral
/// tool spec, and a per-provider adapter (OpenAI Chat Completions, Anthropic
/// Messages, Google Gemini) serializes that transcript to the wire and parses
/// the response back into the same neutral shape. BYOK — the active provider's
/// own key and model are used.
enum AIConductor {
    private static let maxRounds = 6
    // Smaller than the UI's page size on purpose: the agent should run several
    // focused searches and read threads, not wade through one huge list. Keeps
    // each round's context (and therefore latency) down.
    private static let perSearchCap = 15
    // When the query is narrowed by a hard filter (sender/date/type), return a
    // larger set so the model can read through it for an item whose own text
    // doesn't contain the keywords.
    private static let filteredCap = 50
    // Never show a giant wall of results — cap what actually gets published.
    private static let maxPresent = 10
    // Cap how many image thumbnails go to the model per look_at_images call —
    // bounds both the payload/latency and the user's token cost.
    private static let maxVisionImages = 9

    // MARK: - Neutral transcript & tool call

    struct ToolCall {
        let id: String
        let name: String
        let args: [String: Any]
    }

    /// A base64-encoded image thumbnail for multimodal ("vision") turns.
    struct AIImage {
        let mediaType: String   // e.g. "image/jpeg"
        let base64: String
    }

    private enum Turn {
        case user(String)
        case assistant(text: String?, toolCalls: [ToolCall])
        case toolResults([(call: ToolCall, payload: [String: Any])])
        /// A user turn carrying images for the model to look at (vision).
        case userImages(text: String, images: [AIImage])
    }

    struct ToolSpec {
        let name: String
        let description: String
        let parameters: [String: Any]   // JSON Schema object
    }

    // MARK: - Run

    static func run(query: String, engine: SearchEngine) {
        let settings = AISettings.shared
        // Use whichever provider actually has a key (falls back off the selected
        // tab so viewing a keyless provider doesn't dead-end the query).
        let provider = settings.effectiveProvider
        guard let key = settings.apiKey(for: provider), !key.isEmpty else {
            engine.aiSetStatus("Add an API key in Manage to use AI mode.")
            engine.aiPublish([])
            return
        }
        let model = settings.model(for: provider)
        let enabled = AISource.allCases.filter { settings.enabledSources.contains($0) }
        guard !enabled.isEmpty else {
            engine.aiSetStatus("No sources enabled for AI mode.")
            engine.aiPublish([])
            return
        }

        // Drop FDA-gated sources that aren't granted; search the rest. Only wall
        // the query if literally everything the user enabled needs FDA.
        let sources = engine.aiUsableSources(enabled)
        guard !sources.isEmpty else {
            engine.aiSetStatus("Grant Full Disk Access to search Messages/Mail/Notes, then reopen Beacon.")
            engine.aiPublish([])
            return
        }

        var pool: [SearchResult] = []           // ref = index into this array
        var poolIDs = Set<String>()

        let system = systemPrompt(sources: sources)
        let tools = toolSpecs(sources: sources)
        var turns: [Turn] = [.user(query)]

        for round in 0..<maxRounds {
            engine.aiSetStatus(round == 0 ? "Thinking…" : "Refining…")
            guard let response = chat(provider: provider, key: key, model: model,
                                      system: system, tools: tools, turns: turns) else {
                engine.aiSetStatus("Couldn't reach \(provider.displayName). Check your key and connection.")
                engine.aiPublish(Array(pool.prefix(maxPresent)))   // a few candidates, never the full pool
                return
            }
            turns.append(.assistant(text: response.text, toolCalls: response.toolCalls))

            guard !response.toolCalls.isEmpty else {
                // No tool call — nothing more to do. Fall back to a few of
                // what it surfaced (capped, never the full unranked pool) so
                // the user still gets locations.
                engine.aiPublish(Array(pool.prefix(maxPresent)))
                return
            }

            var results: [(call: ToolCall, payload: [String: Any])] = []
            var visionImages: [AIImage] = []   // images to show the model this round
            var visionRefs: [Int] = []
            for call in response.toolCalls {
                let name = call.name
                let args = call.args
                Log.debug("AI[round \(round)] tool=\(name)")

                if name == "present_results" {
                    let refs = (args["refs"] as? [Any])?.compactMap { intFrom($0) } ?? []
                    let chosen = refs.compactMap { $0 >= 0 && $0 < pool.count ? pool[$0] : nil }
                    Log.debug("AI present_results refs=\(refs.count) resolved=\(chosen.count)")
                    engine.aiSetStatus("")
                    // Publish exactly what the model chose (capped). An explicit
                    // empty selection means "nothing matched" — show nothing,
                    // never fall back to dumping the whole candidate pool.
                    engine.aiPublish(Array(chosen.prefix(maxPresent)))
                    return
                }

                if name == "search" {
                    let sourceRaw = args["source"] as? String ?? ""
                    let keywords = args["keywords"] as? String ?? ""
                    let from = (args["from"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
                    let fileType = (args["fileType"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
                    let after = parseDay(args["after"], endOfDay: false)
                    let before = parseDay(args["before"], endOfDay: true)
                    // When a hard filter (sender/date/type) has narrowed the set,
                    // hand the model the WHOLE set so it can read to find items
                    // whose own text lacks the keywords (raw credentials, codes).
                    let isFiltered = (from?.isEmpty == false) || after != nil || before != nil
                        || (fileType?.isEmpty == false)
                    let cap = isFiltered ? filteredCap : perSearchCap
                    let limit = min(intFrom(args["limit"] ?? 0) ?? cap, cap)
                    let source = AISource(rawValue: sourceRaw)
                    if let source, sources.contains(source) {
                        engine.aiSetStatus("Searching \(source.displayName)…")
                        let tokens = SearchText.tokens(keywords)
                        let rows = engine.aiToolSearch(
                            source, tokens: tokens, limit: limit > 0 ? limit : perSearchCap,
                            from: (from?.isEmpty == false) ? from : nil,
                            after: after, before: before,
                            fileType: (fileType?.isEmpty == false) ? fileType : nil)
                        var refsForThisCall: [[String: Any]] = []
                        for row in rows {
                            let ref = poolRef(for: row, pool: &pool, ids: &poolIDs)
                            refsForThisCall.append(describe(row, ref: ref))
                        }
                        results.append((call, ["results": refsForThisCall]))
                    } else {
                        results.append((call, ["error": "unknown or disabled source"]))
                    }
                } else if name == "read_thread" {
                    // Let the model read the conversation around a message it
                    // already found. The item that answers the query is often an
                    // adjacent message with none of the search keywords (a raw
                    // email + password sent right after "here's the nintendo
                    // login"), so it's unreachable by search alone.
                    let ref = intFrom(args["ref"] ?? -1) ?? -1
                    let target = (ref >= 0 && ref < pool.count) ? pool[ref] : nil
                    if let target, target.source == .message, let rowid = target.messageRowID {
                        engine.aiSetStatus("Reading the conversation…")
                        let thread = engine.aiThreadContext(around: rowid)
                        var out: [[String: Any]] = []
                        for row in thread {
                            let r = poolRef(for: row, pool: &pool, ids: &poolIDs)
                            out.append(describe(row, ref: r))
                        }
                        results.append((call, ["thread": out]))
                    } else {
                        results.append((call, ["error": "read_thread needs the ref of a message result"]))
                    }
                } else if name == "look_at_images" {
                    // Vision: render thumbnails of the requested image results and
                    // hand them to the model to inspect in the next user turn.
                    let refs = (args["refs"] as? [Any])?.compactMap { intFrom($0) } ?? []
                    engine.aiSetStatus("Looking at the images…")
                    var shown: [Int] = []
                    for ref in refs where ref >= 0 && ref < pool.count {
                        guard visionImages.count < maxVisionImages else { break }
                        let row = pool[ref]
                        guard isImageResult(row), let img = encodeThumbnail(path: row.path) else { continue }
                        visionImages.append(img)
                        visionRefs.append(ref)
                        shown.append(ref)
                    }
                    Log.debug("AI look_at_images requested=\(refs.count) shown=\(shown.count)")
                    results.append((call, shown.isEmpty
                        ? ["error": "no readable images among those refs"]
                        : ["shown": shown, "note": "the \(shown.count) image(s) are in the next message, in ref order"]))
                } else {
                    results.append((call, ["error": "unknown tool"]))
                }
            }
            turns.append(.toolResults(results))
            if !visionImages.isEmpty {
                let refList = visionRefs.map(String.init).joined(separator: ", ")
                turns.append(.userImages(
                    text: "Here are the images for refs [\(refList)], in that order. Look at each and decide which match the request: \"\(query)\". Then call present_results with only the matching ref(s).",
                    images: visionImages))
            }
        }

        // Ran out of rounds without committing. Rather than dumping the whole
        // accumulated pool (unordered, noisy — the answer buried among unrelated
        // hits), force ONE decisive pick from what's already been surfaced.
        engine.aiSetStatus("Finishing…")
        turns.append(.user("Stop searching. From the results you've already seen, call present_results NOW with only the ref(s) that best answer the request — usually exactly one item that IS the answer."))
        if let response = chat(provider: provider, key: key, model: model,
                               system: system, tools: tools, turns: turns),
           let call = response.toolCalls.first(where: { $0.name == "present_results" }) {
            let refs = (call.args["refs"] as? [Any])?.compactMap { intFrom($0) } ?? []
            let chosen = refs.compactMap { $0 >= 0 && $0 < pool.count ? pool[$0] : nil }
            if !chosen.isEmpty {
                engine.aiSetStatus("")
                engine.aiPublish(Array(chosen.prefix(maxPresent)))
                return
            }
        }
        // Last resort: a few candidates, never the full pool.
        engine.aiSetStatus("")
        engine.aiPublish(Array(pool.prefix(maxPresent)))
    }

    // MARK: - Prompt & tool specs

    private static func systemPrompt(sources: [AISource]) -> String {
        let list = sources.map(\.displayName).joined(separator: ", ")
        let today = dayParser.string(from: Date())
        return """
        You are Beacon's search agent. Today is \(today). The user describes — \
        often vaguely, from memory — something on their Mac. Return the specific \
        item(s) as locations, never as prose.

        FIRST decompose the request into every constraint given, and pass EACH as \
        a filter — not just keywords. The more constraints you apply, the fewer \
        and sharper the results:
        • WHO — a person/sender → `from` (e.g. "Sean M").
        • CONTENT — words likely in or near the item → `keywords`.
        • TYPE — messages, mail, notes, files, an image, a pdf… → pick `source`, \
        and for the files source set `fileType` (image/pdf/document/audio/video/folder).
        • WHEN — an exact or rough date range → `after`/`before` as YYYY-MM-DD, \
        resolved against today. "between May 20 and June 1" → after=2026-05-20, \
        before=2026-06-01. "late May" → that span. "2–3 months ago" → a window a \
        few weeks wide centered ~10 weeks back.

        Never run a bare keyword search when the user gave you a sender, a type, \
        or a date — that returns dozens of irrelevant hits. Filter hard first.

        Disambiguate SOURCE from CONTENT. "an email and password", "login", \
        "credentials", "the password for my/his account" describe a shared LOGIN \
        — the "email" is an address, NOT the Mail app. People share logins in \
        Messages, so search Messages first for these; only use the mail source \
        when the user clearly means the Mail app (a subject, an email thread, a \
        sender's email). If the user names the source ("in messages", "over \
        text", "in my email"), obey it exactly.

        VISUAL IMAGE QUERIES — this is a hard rule. If the user wants an image by \
        what it SHOWS (a hooded figure, a screenshot of X, a receipt, a person or \
        scene): (1) search files with fileType=image plus any date/folder hint to \
        narrow the candidates; (2) you MUST then call `look_at_images` on those \
        refs and inspect the actual pixels; (3) present ONLY the refs whose pixels \
        match the description. NEVER call present_results with image results you \
        have not looked at — returning unviewed images is a failure. If, after \
        looking, none match, present an EMPTY list rather than guessing. Only the \
        images your search returns are candidates, so if the picture may be old, \
        include a rough date to bring it into range.

        When the item's OWN text won't contain your words — a raw email+password, \
        a login, a verification code, a phone number, an address — do NOT pass \
        keywords (they'd exclude the very thing you want). Instead filter by \
        `from` + date (+ type), which returns the whole narrowed set, and READ \
        those results to spot the one that looks like the answer.

        Tools:
        - search(source, keywords?, from?, after?, before?, fileType?) across: \(list). \
        Message results also carry from/date.
        - read_thread(ref) — read the conversation around a message result. The \
        item you need is often a neighbouring message with none of the keywords \
        (a raw email+password sent right after a message about the topic).
        - present_results(refs) — finish. List ONLY the ref(s) that answer the \
        request, best first. For a SPECIFIC item (a credential, a code, an \
        address, one particular file/message), present EXACTLY ONE — the single \
        item that IS the answer — not a list of maybes.

        Be decisive and fast: usually ONE well-filtered search is enough. The \
        moment a search returns a strong candidate, STOP — read it and call \
        present_results. Do not keep running more searches, and never present the \
        raw filtered list; pick the answer out of it.

        Examples:
        • "the email & password Sean sent me over text in May 2026" \
        → search(source=messages, from="Sean", after="2026-05-01", \
        before="2026-05-31") with NO keywords (the credentials text won't contain \
        "email"/"password"), then READ the returned messages and present the one \
        that looks like an email address + a password. It may be inside a group \
        thread — that's fine, `from` still finds Sean's message.
        • "an image I made ~2–3 months ago of a hooded figure on a white background" \
        → search(source=files, fileType="image", after=<~3mo ago>, before=<~2mo ago>, \
        keywords="hooded figure"). Filenames rarely contain the visual content, so \
        rely on type+date to narrow, then present the most likely.

        Only call tools; never write explanations. Always finish with present_results.
        """
    }

    private static func toolSpecs(sources: [AISource]) -> [ToolSpec] {
        let sourceEnum = sources.map(\.rawValue)
        return [
            ToolSpec(
                name: "search",
                description: "Search one source of the user's Mac. Apply every constraint the user gave as a filter — not just keywords — to get a small, precise result set. Returns matching items, each with a numeric ref (message results also carry from/date).",
                parameters: [
                    "type": "object",
                    "properties": [
                        "source": ["type": "string", "enum": sourceEnum,
                                   "description": "Which source to search."],
                        "keywords": ["type": "string",
                                     "description": "Words likely in or near the item's content. Optional when a from/date/type filter alone identifies it."],
                        "from": ["type": "string",
                                 "description": "Sender/person the item is from (e.g. \"Sean M\"). For messages this hard-filters by contact, even inside a differently-named thread."],
                        "after": ["type": "string",
                                  "description": "Only items on or after this date, YYYY-MM-DD."],
                        "before": ["type": "string",
                                   "description": "Only items on or before this date, YYYY-MM-DD."],
                        "fileType": ["type": "string",
                                     "enum": ["image", "pdf", "document", "audio", "video", "folder"],
                                     "description": "For the files source: restrict to this kind of file."],
                        "limit": ["type": "integer",
                                  "description": "Max results (default 15)."],
                    ],
                    "required": ["source"],
                ]
            ),
            ToolSpec(
                name: "read_thread",
                description: "Read the messages surrounding a message result (same conversation, in time order). Use after a Messages search when the item you need might be a neighbouring message that doesn't contain the search keywords — e.g. a raw email/password sent right after a message about the topic. Returns messages each with their own ref, plus from/date.",
                parameters: [
                    "type": "object",
                    "properties": [
                        "ref": ["type": "integer",
                                "description": "The ref of a message result to read around."],
                    ],
                    "required": ["ref"],
                ]
            ),
            ToolSpec(
                name: "look_at_images",
                description: "Actually SEE image results — inspect their pixels to find ones matching a visual description (e.g. \"a hooded figure on a white background\", \"a screenshot of a login screen\"). Pass the refs of candidate images from a files search (fileType=image). The images are shown to you in the next message; then call present_results with the ref(s) that match. Filenames don't describe what's in a picture, so you MUST look for any visual query.",
                parameters: [
                    "type": "object",
                    "properties": [
                        "refs": ["type": "array", "items": ["type": "integer"],
                                 "description": "Refs of candidate image results to look at (a handful, most-likely first)."],
                    ],
                    "required": ["refs"],
                ]
            ),
            ToolSpec(
                name: "present_results",
                description: "Finish by presenting the chosen locations to the user, most relevant first.",
                parameters: [
                    "type": "object",
                    "properties": [
                        "refs": ["type": "array", "items": ["type": "integer"],
                                 "description": "The refs of the items to show, best first."],
                    ],
                    "required": ["refs"],
                ]
            ),
        ]
    }

    // MARK: - Result description

    /// Insert a result into the shared pool (deduped by id) and return its ref.
    private static func poolRef(for row: SearchResult,
                                pool: inout [SearchResult],
                                ids: inout Set<String>) -> Int {
        if ids.insert(row.id).inserted {
            pool.append(row)
            return pool.count - 1
        }
        return pool.firstIndex(where: { $0.id == row.id }) ?? (pool.count - 1)
    }

    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm"
        return f
    }()

    private static let dayParser: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }()

    /// Parse a model-supplied "YYYY-MM-DD" into a Date. `endOfDay` pushes it to
    /// 23:59:59 so a `before` bound includes the whole day.
    private static func parseDay(_ any: Any?, endOfDay: Bool) -> Date? {
        guard let raw = (any as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
              raw.count >= 10,
              let day = dayParser.date(from: String(raw.prefix(10))) else { return nil }
        guard endOfDay else { return day }
        return Calendar.current.date(byAdding: DateComponents(day: 1, second: -1), to: day) ?? day
    }

    /// The dict the model sees for one result. Messages carry `from` and `date`
    /// so the model can honour "from Sean" and "between May 20 and June 1"
    /// without a dedicated filter param.
    private static func describe(_ r: SearchResult, ref: Int) -> [String: Any] {
        let sourceName: String
        switch r.source {
        case .file: sourceName = "files"
        case .message: sourceName = "messages"
        case .note: sourceName = "notes"
        case .mail: sourceName = "mail"
        case .calendar: sourceName = "calendar"
        case .clipboard: sourceName = "clipboard"
        case .history: sourceName = "history"
        case .settings: sourceName = "apps"
        }
        var d: [String: Any] = [
            "ref": ref,
            "source": sourceName,
            "name": r.name,
            "detail": snippet(r),
        ]
        if r.source == .message {
            d["from"] = r.messageFromMe ? "You" : r.name
            if let date = r.modified { d["date"] = dateFormatter.string(from: date) }
        }
        return d
    }

    /// A short, token-cheap description of a result for the model to reason over.
    private static func snippet(_ r: SearchResult) -> String {
        let raw: String
        switch r.source {
        case .file:
            raw = r.directory
        case .history, .settings:
            raw = (r.messageBody ?? r.path)
        default:
            raw = (r.messageBody ?? r.kind)
        }
        let flat = raw.replacingOccurrences(of: "\n", with: " ")
        return String(flat.prefix(160))
    }

    // MARK: - Vision helpers

    private static func isImageResult(_ r: SearchResult) -> Bool {
        guard r.source == .file, !r.path.isEmpty else { return false }
        if r.contentTypes.contains(where: { $0.contains("image") }) { return true }
        let ext = (r.path as NSString).pathExtension.lowercased()
        return ["jpg","jpeg","png","gif","heic","heif","webp","tiff","bmp","psd"].contains(ext)
    }

    /// Decode a downscaled JPEG thumbnail of an image file and base64-encode it.
    /// ImageIO does the downscale during decode, so this stays cheap even for
    /// large originals, and the small payload keeps vision token cost down.
    private static func encodeThumbnail(path: String, maxPixel: Int = 768) -> AIImage? {
        let url = URL(fileURLWithPath: path) as CFURL
        guard let src = CGImageSourceCreateWithURL(url, nil) else { return nil }
        let opts: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel,
        ]
        guard let cg = CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary) else { return nil }
        let data = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(data, "public.jpeg" as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(dest, cg, [kCGImageDestinationLossyCompressionQuality: 0.7] as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { return nil }
        return AIImage(mediaType: "image/jpeg", base64: (data as Data).base64EncodedString())
    }

    // MARK: - Provider dispatch

    private struct Reply {
        let text: String?
        let toolCalls: [ToolCall]
    }

    /// Serialize the neutral transcript for `provider`, POST it, and parse the
    /// reply back into the neutral shape. Synchronous; called on aiQueue.
    private static func chat(provider: AISettings.Provider, key: String, model: String,
                             system: String, tools: [ToolSpec], turns: [Turn]) -> Reply? {
        let request: URLRequest?
        switch provider {
        case .openai:    request = openAIRequest(key: key, model: model, system: system, tools: tools, turns: turns)
        case .anthropic: request = anthropicRequest(key: key, model: model, system: system, tools: tools, turns: turns)
        case .google:    request = geminiRequest(key: key, model: model, system: system, tools: tools, turns: turns)
        }
        guard let request, let json = send(request) else { return nil }
        if let err = json["error"] as? [String: Any] {
            Log.write("AI \(provider.rawValue) error: \(err["message"] ?? "unknown")")
            return nil
        }
        switch provider {
        case .openai:    return openAIParse(json)
        case .anthropic: return anthropicParse(json)
        case .google:    return geminiParse(json)
        }
    }

    /// Fire the request synchronously (we're already off the main thread on
    /// aiQueue) and decode the JSON body.
    ///
    /// Retries once, but only on a transport-level failure where the server
    /// replied with nothing (a dropped connection, DNS hiccup, TLS reset). We
    /// deliberately do NOT retry on our own 65s wait timing out — by then the
    /// request may have reached the model, and re-sending would double-charge
    /// the user's tokens.
    private static func send(_ request: URLRequest) -> [String: Any]? {
        for attempt in 0..<2 {
            let sem = DispatchSemaphore(value: 0)
            var out: Data?
            var transportFailed = false
            URLSession.shared.dataTask(with: request) { d, _, error in
                out = d
                transportFailed = (error != nil)
                sem.signal()
            }.resume()
            guard sem.wait(timeout: .now() + 65) == .success else { return nil }
            if let out,
               let json = try? JSONSerialization.jsonObject(with: out) as? [String: Any] {
                return json
            }
            // No usable body. Retry once only if the server never answered.
            if transportFailed, attempt == 0 { continue }
            return nil
        }
        return nil
    }

    private static func post(_ url: URL, headers: [String: String], body: [String: Any]) -> URLRequest? {
        guard let data = try? JSONSerialization.data(withJSONObject: body) else { return nil }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        for (k, v) in headers { request.setValue(v, forHTTPHeaderField: k) }
        request.httpBody = data
        request.timeoutInterval = 60
        return request
    }

    // MARK: - OpenAI (Chat Completions)

    private static func openAIRequest(key: String, model: String, system: String,
                                      tools: [ToolSpec], turns: [Turn]) -> URLRequest? {
        var messages: [[String: Any]] = [["role": "system", "content": system]]
        for turn in turns {
            switch turn {
            case .user(let text):
                messages.append(["role": "user", "content": text])
            case .assistant(let text, let calls):
                var msg: [String: Any] = ["role": "assistant"]
                msg["content"] = text ?? NSNull()
                if !calls.isEmpty {
                    msg["tool_calls"] = calls.map { c -> [String: Any] in
                        ["id": c.id, "type": "function",
                         "function": ["name": c.name, "arguments": jsonString(c.args)]]
                    }
                }
                messages.append(msg)
            case .userImages(let text, let images):
                var content: [[String: Any]] = [["type": "text", "text": text]]
                for img in images {
                    content.append(["type": "image_url",
                                    "image_url": ["url": "data:\(img.mediaType);base64,\(img.base64)"]])
                }
                messages.append(["role": "user", "content": content])
            case .toolResults(let results):
                for r in results {
                    messages.append(["role": "tool", "tool_call_id": r.call.id,
                                     "content": jsonString(r.payload)])
                }
            }
        }
        let toolSpecs = tools.map { t -> [String: Any] in
            ["type": "function",
             "function": ["name": t.name, "description": t.description, "parameters": t.parameters]]
        }
        let body: [String: Any] = [
            "model": model, "messages": messages,
            "tools": toolSpecs, "tool_choice": "auto",
        ]
        guard let url = URL(string: "https://api.openai.com/v1/chat/completions") else { return nil }
        return post(url, headers: ["Authorization": "Bearer \(key)"], body: body)
    }

    private static func openAIParse(_ json: [String: Any]) -> Reply? {
        guard let choices = json["choices"] as? [[String: Any]],
              let message = choices.first?["message"] as? [String: Any] else { return nil }
        let text = message["content"] as? String
        var calls: [ToolCall] = []
        if let toolCalls = message["tool_calls"] as? [[String: Any]] {
            for call in toolCalls {
                let id = call["id"] as? String ?? ""
                let fn = call["function"] as? [String: Any] ?? [:]
                let name = fn["name"] as? String ?? ""
                calls.append(ToolCall(id: id, name: name, args: parseArgs(fn["arguments"])))
            }
        }
        return Reply(text: text, toolCalls: calls)
    }

    // MARK: - Anthropic (Messages)

    private static func anthropicRequest(key: String, model: String, system: String,
                                         tools: [ToolSpec], turns: [Turn]) -> URLRequest? {
        var messages: [[String: Any]] = []
        for turn in turns {
            switch turn {
            case .user(let text):
                messages.append(["role": "user", "content": text])
            case .assistant(let text, let calls):
                var content: [[String: Any]] = []
                if let text, !text.isEmpty { content.append(["type": "text", "text": text]) }
                for c in calls {
                    content.append(["type": "tool_use", "id": c.id, "name": c.name, "input": c.args])
                }
                messages.append(["role": "assistant", "content": content])
            case .userImages(let text, let images):
                var content: [[String: Any]] = [["type": "text", "text": text]]
                for img in images {
                    content.append(["type": "image",
                                    "source": ["type": "base64", "media_type": img.mediaType, "data": img.base64]])
                }
                messages.append(["role": "user", "content": content])
            case .toolResults(let results):
                let content = results.map { r -> [String: Any] in
                    ["type": "tool_result", "tool_use_id": r.call.id, "content": jsonString(r.payload)]
                }
                messages.append(["role": "user", "content": content])
            }
        }
        let toolSpecs = tools.map { t -> [String: Any] in
            ["name": t.name, "description": t.description, "input_schema": t.parameters]
        }
        let body: [String: Any] = [
            "model": model, "max_tokens": 2048, "system": system,
            "messages": messages, "tools": toolSpecs, "tool_choice": ["type": "auto"],
        ]
        guard let url = URL(string: "https://api.anthropic.com/v1/messages") else { return nil }
        return post(url, headers: [
            "x-api-key": key,
            "anthropic-version": "2023-06-01",
        ], body: body)
    }

    private static func anthropicParse(_ json: [String: Any]) -> Reply? {
        guard let content = json["content"] as? [[String: Any]] else { return nil }
        var text = ""
        var calls: [ToolCall] = []
        for block in content {
            switch block["type"] as? String {
            case "text":
                text += block["text"] as? String ?? ""
            case "tool_use":
                let id = block["id"] as? String ?? ""
                let name = block["name"] as? String ?? ""
                let input = block["input"] as? [String: Any] ?? [:]
                calls.append(ToolCall(id: id, name: name, args: input))
            default:
                break
            }
        }
        return Reply(text: text.isEmpty ? nil : text, toolCalls: calls)
    }

    // MARK: - Google (Gemini generateContent)

    private static func geminiRequest(key: String, model: String, system: String,
                                      tools: [ToolSpec], turns: [Turn]) -> URLRequest? {
        var contents: [[String: Any]] = []
        for turn in turns {
            switch turn {
            case .user(let text):
                contents.append(["role": "user", "parts": [["text": text]]])
            case .assistant(let text, let calls):
                var parts: [[String: Any]] = []
                if let text, !text.isEmpty { parts.append(["text": text]) }
                for c in calls {
                    parts.append(["functionCall": ["name": c.name, "args": c.args]])
                }
                contents.append(["role": "model", "parts": parts])
            case .userImages(let text, let images):
                var parts: [[String: Any]] = [["text": text]]
                for img in images {
                    parts.append(["inlineData": ["mimeType": img.mediaType, "data": img.base64]])
                }
                contents.append(["role": "user", "parts": parts])
            case .toolResults(let results):
                let parts = results.map { r -> [String: Any] in
                    ["functionResponse": ["name": r.call.name, "response": r.payload]]
                }
                contents.append(["role": "user", "parts": parts])
            }
        }
        let declarations = tools.map { t -> [String: Any] in
            ["name": t.name, "description": t.description, "parameters": t.parameters]
        }
        let body: [String: Any] = [
            "system_instruction": ["parts": [["text": system]]],
            "contents": contents,
            "tools": [["function_declarations": declarations]],
            "tool_config": ["function_calling_config": ["mode": "AUTO"]],
        ]
        let endpoint = "https://generativelanguage.googleapis.com/v1beta/models/\(model):generateContent"
        guard let url = URL(string: endpoint) else { return nil }
        return post(url, headers: ["x-goog-api-key": key], body: body)
    }

    private static func geminiParse(_ json: [String: Any]) -> Reply? {
        guard let candidates = json["candidates"] as? [[String: Any]],
              let content = candidates.first?["content"] as? [String: Any],
              let parts = content["parts"] as? [[String: Any]] else { return nil }
        var text = ""
        var calls: [ToolCall] = []
        for (i, part) in parts.enumerated() {
            if let t = part["text"] as? String {
                text += t
            } else if let fc = part["functionCall"] as? [String: Any] {
                let name = fc["name"] as? String ?? ""
                let args = fc["args"] as? [String: Any] ?? [:]
                // Gemini function calls carry no id; synthesize a stable one.
                calls.append(ToolCall(id: "call_\(i)", name: name, args: args))
            }
        }
        return Reply(text: text.isEmpty ? nil : text, toolCalls: calls)
    }

    // MARK: - JSON helpers

    private static func jsonString(_ obj: [String: Any]) -> String {
        (try? JSONSerialization.data(withJSONObject: obj))
            .flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
    }

    private static func parseArgs(_ raw: Any?) -> [String: Any] {
        if let dict = raw as? [String: Any] { return dict }
        if let str = raw as? String, let data = str.data(using: .utf8),
           let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            return dict
        }
        return [:]
    }

    private static func intFrom(_ any: Any) -> Int? {
        if let i = any as? Int { return i }
        if let d = any as? Double { return Int(d) }
        if let s = any as? String { return Int(s) }
        if let n = any as? NSNumber { return n.intValue }
        return nil
    }
}
