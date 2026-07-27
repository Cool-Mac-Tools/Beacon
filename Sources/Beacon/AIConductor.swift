import Foundation

/// Drives the AI-mode agentic loop: given a natural-language query, it lets the
/// model call a `search` tool across the user's enabled Beacon sources (as many
/// rounds as it needs), keeps a pool of every real result it surfaces, and ends
/// when the model calls `present_results` to pick the best-matching locations.
/// The output is always locations (result rows) — never prose.
///
/// Provider-agnostic in spirit; the wire calls here are OpenAI Chat Completions
/// (matches the BYOK test key). A Claude adapter can slot in behind the same
/// pool/tool contract.
enum AIConductor {
    private static let maxRounds = 6
    // Smaller than the UI's page size on purpose: the agent should run several
    // focused searches and read threads, not wade through one huge list. Keeps
    // each round's context (and therefore latency) down.
    private static let perSearchCap = 15

    static func run(query: String, engine: SearchEngine) {
        let settings = AISettings.shared
        guard let key = settings.apiKey, !key.isEmpty else {
            engine.aiSetStatus("Add your API key in AI settings to use AI mode.")
            engine.aiPublish([])
            return
        }
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

        // Conversation transcript sent to the model each round.
        var messages: [[String: Any]] = [
            ["role": "system", "content": systemPrompt(sources: sources)],
            ["role": "user", "content": query],
        ]
        let tools = toolSpecs(sources: sources)

        for round in 0..<maxRounds {
            engine.aiSetStatus(round == 0 ? "Thinking…" : "Refining…")
            guard let message = chat(key: key, model: settings.model,
                                     messages: messages, tools: tools) else {
                engine.aiSetStatus("Couldn't reach the AI service. Check your key and connection.")
                engine.aiPublish(pool)   // show anything found so far
                return
            }
            messages.append(assistantEcho(message))

            guard let toolCalls = message["tool_calls"] as? [[String: Any]], !toolCalls.isEmpty else {
                // Model produced no tool call — nothing more to do. Fall back to
                // whatever it surfaced so the user still gets locations.
                engine.aiPublish(pool)
                return
            }

            for call in toolCalls {
                let callID = call["id"] as? String ?? ""
                let fn = call["function"] as? [String: Any] ?? [:]
                let name = fn["name"] as? String ?? ""
                let args = parseArgs(fn["arguments"])

                if name == "present_results" {
                    let refs = (args["refs"] as? [Any])?.compactMap { intFrom($0) } ?? []
                    let chosen = refs.compactMap { $0 >= 0 && $0 < pool.count ? pool[$0] : nil }
                    engine.aiSetStatus("")
                    engine.aiPublish(chosen.isEmpty ? pool : chosen)
                    return
                }

                if name == "search" {
                    let sourceRaw = args["source"] as? String ?? ""
                    let keywords = args["keywords"] as? String ?? ""
                    let limit = min(intFrom(args["limit"] ?? 0) ?? perSearchCap, perSearchCap)
                    let source = AISource(rawValue: sourceRaw)
                    if let source, sources.contains(source) {
                        engine.aiSetStatus("Searching \(source.displayName)…")
                        let tokens = SearchText.tokens(keywords)
                        let rows = engine.aiToolSearch(source, tokens: tokens,
                                                       limit: limit > 0 ? limit : perSearchCap)
                        var refsForThisCall: [[String: Any]] = []
                        for row in rows {
                            let ref = poolRef(for: row, pool: &pool, ids: &poolIDs)
                            refsForThisCall.append(describe(row, ref: ref))
                        }
                        messages.append(toolResult(callID: callID, payload: [
                            "results": refsForThisCall,
                        ]))
                    } else {
                        messages.append(toolResult(callID: callID, payload: [
                            "error": "unknown or disabled source",
                        ]))
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
                        messages.append(toolResult(callID: callID, payload: [
                            "thread": out,
                        ]))
                    } else {
                        messages.append(toolResult(callID: callID, payload: [
                            "error": "read_thread needs the ref of a message result",
                        ]))
                    }
                } else {
                    messages.append(toolResult(callID: callID, payload: ["error": "unknown tool"]))
                }
            }
        }

        // Ran out of rounds without an explicit selection — publish the pool.
        engine.aiSetStatus("")
        engine.aiPublish(pool)
    }

    // MARK: - Prompt & tool specs

    private static func systemPrompt(sources: [AISource]) -> String {
        let list = sources.map(\.displayName).joined(separator: ", ")
        return """
        You are Beacon's search agent. The user describes — often vaguely, from \
        memory — something on their Mac they want to find. Your job is to locate \
        the specific item(s) that answer the request and return them as locations, \
        never as prose.

        Tools:
        - `search(source, keywords)` across these sources: \(list). Search is \
        keyword-based. Message results include `from` (sender) and `date`.
        - `read_thread(ref)` reads the conversation around a message result, in \
        time order.
        - `present_results(refs)` finishes the task.

        Strategy — follow it:
        1. Pull apart the request into WHO (a person/sender), WHAT (the topic or \
        the kind of thing), and WHEN (any date range). Search using the person's \
        name AND the topic as keywords; run several focused searches with \
        different keyword combinations rather than one broad query.
        2. THE ITEM YOU NEED OFTEN DOES NOT CONTAIN THE OBVIOUS KEYWORDS. Example: \
        an email address + password someone texted will not contain the words \
        "email", "password", or the account name — those appear in the messages \
        around it. So when a Messages search surfaces a plausible thread or a \
        message near the topic (right person, right timeframe), call \
        `read_thread` on it and look at the neighbouring messages for the actual \
        answer (a raw email/login, a phone number, an address, a code).
        3. Honour WHO and WHEN: prefer messages whose `from` matches the named \
        person and whose `date` falls in the requested range. Use these to pick \
        between candidates and to discard unrelated hits.
        4. Finish with `present_results` listing ONLY the few refs that directly \
        answer the request, most relevant first — ideally 1–3. Do not dump every \
        keyword match. If you genuinely cannot find it, present your closest \
        candidates.

        Only call tools; never write explanations. Always finish by calling \
        `present_results`.
        """
    }

    private static func toolSpecs(sources: [AISource]) -> [[String: Any]] {
        let sourceEnum = sources.map(\.rawValue)
        return [
            ["type": "function", "function": [
                "name": "search",
                "description": "Search one source of the user's Mac by keywords. Returns matching items, each with a numeric ref.",
                "parameters": [
                    "type": "object",
                    "properties": [
                        "source": ["type": "string", "enum": sourceEnum,
                                   "description": "Which source to search."],
                        "keywords": ["type": "string",
                                     "description": "Space-separated keywords to match."],
                        "limit": ["type": "integer",
                                  "description": "Max results (default 25)."],
                    ],
                    "required": ["source", "keywords"],
                ],
            ]],
            ["type": "function", "function": [
                "name": "read_thread",
                "description": "Read the messages surrounding a message result (same conversation, in time order). Use this after a Messages search when the item you actually need might be a neighbouring message that doesn't contain the search keywords — e.g. a raw email/password sent right after a message about the topic. Returns messages each with their own ref, plus from/date.",
                "parameters": [
                    "type": "object",
                    "properties": [
                        "ref": ["type": "integer",
                                "description": "The ref of a message result to read around."],
                    ],
                    "required": ["ref"],
                ],
            ]],
            ["type": "function", "function": [
                "name": "present_results",
                "description": "Finish by presenting the chosen locations to the user, most relevant first.",
                "parameters": [
                    "type": "object",
                    "properties": [
                        "refs": ["type": "array", "items": ["type": "integer"],
                                 "description": "The refs of the items to show, best first."],
                    ],
                    "required": ["refs"],
                ],
            ]],
        ]
    }

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

    // MARK: - OpenAI Chat Completions (synchronous; called on aiQueue)

    /// Returns the assistant `message` object, or nil on failure.
    private static func chat(key: String, model: String,
                             messages: [[String: Any]], tools: [[String: Any]]) -> [String: Any]? {
        guard let url = URL(string: "https://api.openai.com/v1/chat/completions") else { return nil }
        let body: [String: Any] = [
            "model": model,
            "messages": messages,
            "tools": tools,
            "tool_choice": "auto",
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: body) else { return nil }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        request.httpBody = data
        request.timeoutInterval = 60

        let sem = DispatchSemaphore(value: 0)
        var out: Data?
        URLSession.shared.dataTask(with: request) { d, _, _ in out = d; sem.signal() }.resume()
        _ = sem.wait(timeout: .now() + 65)

        guard let out,
              let json = try? JSONSerialization.jsonObject(with: out) as? [String: Any] else { return nil }
        if let err = json["error"] as? [String: Any] {
            Log.write("AI chat error: \(err["message"] ?? "unknown")")
            return nil
        }
        let choices = json["choices"] as? [[String: Any]]
        return choices?.first?["message"] as? [String: Any]
    }

    // MARK: - Message helpers

    /// Echo the assistant message back into the transcript. Only the fields the
    /// API needs to continue the tool loop are preserved.
    private static func assistantEcho(_ message: [String: Any]) -> [String: Any] {
        var echo: [String: Any] = ["role": "assistant"]
        echo["content"] = message["content"] ?? NSNull()
        if let toolCalls = message["tool_calls"] { echo["tool_calls"] = toolCalls }
        return echo
    }

    private static func toolResult(callID: String, payload: [String: Any]) -> [String: Any] {
        let content = (try? JSONSerialization.data(withJSONObject: payload))
            .flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
        return ["role": "tool", "tool_call_id": callID, "content": content]
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
