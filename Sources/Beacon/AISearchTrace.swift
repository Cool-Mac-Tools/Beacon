import Foundation

struct AISearchStep: Identifiable, Equatable {
    enum State: String { case running, complete, warning, failed }
    let id: UUID
    var title: String
    var detail: String
    var state: State
    let startedAt: Date
    var finishedAt: Date?
    init(id: UUID = UUID(), title: String, detail: String = "", state: State = .complete,
         startedAt: Date = Date(), finishedAt: Date? = nil) {
        self.id = id; self.title = String(title.prefix(160)); self.detail = String(detail.prefix(8_000))
        self.state = state; self.startedAt = startedAt
        self.finishedAt = finishedAt ?? (state == .running ? nil : Date())
    }
}

/// Ephemeral, inspectable operations — no API headers, model reasoning, or disk log.
/// A generation rejects late callbacks from canceled/replaced searches.
struct AISearchTrace {
    private(set) var generation = 0
    private(set) var query = ""
    private(set) var steps: [AISearchStep] = []
    private(set) var startedAt = Date()
    mutating func reset(query: String, generation: Int) {
        self.query = query; self.generation = generation; steps = []; startedAt = Date()
    }
    mutating func record(_ step: AISearchStep, generation: Int) {
        guard self.generation == generation else { return }
        if let index = steps.firstIndex(where: { $0.id == step.id }) { steps[index] = step }
        else { steps.append(step); if steps.count > 200 { steps.removeFirst(steps.count - 200) } }
    }
    mutating func finishRunning(state: AISearchStep.State, detail: String) {
        for i in steps.indices where steps[i].state == .running {
            steps[i].state = state; steps[i].finishedAt = Date()
            if !detail.isEmpty { steps[i].detail += "\n" + detail }
        }
    }
    var text: String {
        (["Beacon search: \(query)"] + steps.map { step in
            let time = String(format: "+%.1fs", max(0, step.startedAt.timeIntervalSince(startedAt)))
            let duration = step.finishedAt.map { String(format: " · %.1fs", max(0, $0.timeIntervalSince(step.startedAt))) } ?? ""
            return "[\(time)] \(step.state.rawValue.uppercased()) \(step.title)\(duration)\n\(step.detail)"
        }).joined(separator: "\n\n")
    }
}

enum AISearchTraceDetails {
    static func parameters(_ args: [String: Any]) -> String {
        // Whitelist actual search controls; never serialize an arbitrary request.
        ["source", "keywords", "from", "after", "before", "fileType", "limit", "description", "ref", "refs"].compactMap { key in
            guard let value = args[key] else { return nil }
            return "\(key): \(String(String(describing: value).prefix(1_000)))"
        }.joined(separator: "\n")
    }
    static func result(_ payload: [String: Any]) -> String {
        if let error = payload["error"] { return "Error: \(error)" }
        if let rows = (payload["results"] ?? payload["thread"]) as? [[String: Any]] {
            let examples = rows.prefix(8).map { row in
                "#\(row["ref"] ?? "?") · \(row["name"] ?? row["title"] ?? row["subject"] ?? "Result")"
            }.joined(separator: "\n")
            return "\(rows.count) candidates returned\n\(examples)"
        }
        if let excerpt = payload["excerpt"] as? String { return "Document excerpt:\n" + String(excerpt.prefix(600)) }
        if let matches = payload["matches"] as? [Int] {
            return "Inspected \(payload["inspected_count"] ?? payload["candidate_count"] ?? 0) of \(payload["candidate_count"] ?? 0) candidates · \(matches.count) matches\nRefs: \(matches.map(String.init).joined(separator: ", "))\n\(payload["coverage"] ?? "")"
        }
        return "Completed"
    }
}
