import Foundation
import CoreServices

/// Synchronous, full-disk file search via MDQuery (the C Spotlight API). Unlike
/// NSMetadataQuery — which is async and bound to the main run loop — MDQuery can
/// run a one-shot synchronous gather off the main thread, which is exactly what
/// the AI conductor needs on its background queue.
///
/// This is the upgrade past RecentsStore's recent-files-only window: the agent
/// can now find a file from months ago by name/content, narrowed hard by type
/// and date range.
enum SpotlightFileSearch {

    struct Hit {
        let path: String
        let name: String
        let modified: Date?
        let contentType: String?
        let kind: String
        var isFolder: Bool { contentType == "public.folder" }
    }

    /// Gather separate filename and content lanes. Each lane is sorted by the
    /// metadata engine before its cap; a strong old filename match can survive
    /// a large set of recent incidental content matches.
    static func search(tokens: [String], fileType: String?, after: Date?, before: Date?, limit: Int,
                       report: (String) -> Void = { _ in }) -> [Hit] {
        guard limit > 0 else { return [] }
        let cap = min(800, max(100, limit * 2))
        var hits: [Hit] = []
        if !tokens.isEmpty, let nameQuery = predicate(tokens: tokens, fileType: fileType, after: after, before: before, nameOnly: true) {
            report("Filename search · cap \(cap)\n\(nameQuery)")
            hits += gather(nameQuery, limit: cap)
        }
        if let contentQuery = predicate(tokens: tokens, fileType: fileType, after: after, before: before) {
            report("Name/content search · cap \(cap)\n\(contentQuery)")
            hits += gather(contentQuery, limit: cap)
        }
        return ranked(hits, tokens: tokens, limit: limit)
    }
    static func predicate(tokens: [String], fileType: String?, after: Date?, before: Date?, nameOnly: Bool = false) -> String? {
        var clauses: [String] = []
        for token in tokens {
            let t = escape(token)
            guard !t.isEmpty else { continue }
            clauses.append(nameOnly ? "kMDItemDisplayName == \"*\(t)*\"cd" : "(kMDItemDisplayName == \"*\(t)*\"cd || kMDItemTextContent == \"*\(t)*\"cd)")
        }
        if let tree = contentTypeTree(for: fileType) { clauses.append("kMDItemContentTypeTree == \"\(tree)\"") }
        if let after { clauses.append("kMDItemFSContentChangeDate >= $time.iso(\(iso(after)))") }
        if let before { clauses.append("kMDItemFSContentChangeDate <= $time.iso(\(iso(before)))") }
        guard !clauses.isEmpty else { return nil }
        return clauses.joined(separator: " && ")
    }
    static func ranked(_ hits: [Hit], tokens: [String], limit: Int) -> [Hit] {
        var seen = Set<String>()
        let unique = hits.filter { !JunkPath.contains($0.path) && seen.insert($0.path).inserted }
        func score(_ hit: Hit) -> Int {
            guard !tokens.isEmpty else { return 0 }
            let name = hit.name.searchFolded, phrase = tokens.joined(separator: " ").searchFolded
            if (hit.name as NSString).deletingPathExtension.searchFolded == phrase { return 100 }
            if name.contains(phrase) { return 80 }
            return tokens.filter { name.contains($0.searchFolded) }.count * 10
        }
        return Array(unique.sorted {
            let a = score($0), b = score($1)
            if a != b { return a > b }
            if $0.modified != $1.modified { return ($0.modified ?? .distantPast) > ($1.modified ?? .distantPast) }
            return $0.path < $1.path
        }.prefix(max(0, limit)))
    }
    private static func gather(_ predicate: String, limit: Int) -> [Hit] {
        guard let query = MDQueryCreate(kCFAllocatorDefault, predicate as CFString, nil,
                                       [kMDItemFSContentChangeDate] as CFArray) else { return [] }
        defer { MDQueryStop(query) }
        MDQuerySetSortOptionFlagsForAttribute(query, kMDItemFSContentChangeDate, kMDQueryReverseSortOrderFlag.rawValue)
        MDQuerySetMaxCount(query, limit)
        guard MDQueryExecute(query, CFOptionFlags(kMDQuerySynchronous.rawValue)) else { return [] }
        var hits: [Hit] = []
        for i in 0..<min(MDQueryGetResultCount(query), limit) {
            guard let raw = MDQueryGetResultAtIndex(query, i) else { continue }
            let item = unsafeBitCast(raw, to: MDItem.self)
            guard let path = MDItemCopyAttribute(item, kMDItemPath) as? String else { continue }
            hits.append(Hit(path: path,
                name: (MDItemCopyAttribute(item, kMDItemDisplayName) as? String) ?? (path as NSString).lastPathComponent,
                modified: MDItemCopyAttribute(item, kMDItemFSContentChangeDate) as? Date,
                contentType: MDItemCopyAttribute(item, kMDItemContentType) as? String,
                kind: (MDItemCopyAttribute(item, kMDItemKind) as? String) ?? "File"))
        }
        return hits
    }

    // MARK: - Helpers

    private static let isoFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        f.timeZone = TimeZone(identifier: "UTC")
        return f
    }()

    private static func iso(_ date: Date) -> String { isoFormatter.string(from: date) }

    /// Escape characters that would break the MDQuery string literal.
    private static func escape(_ term: String) -> String {
        term.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "*", with: "")
    }

    /// Map the AI's fileType to a UTI tree (matches the type and its subtypes).
    private static func contentTypeTree(for fileType: String?) -> String? {
        switch fileType?.lowercased() {
        case "image", "images", "photo", "photos": return "public.image"
        case "pdf": return "com.adobe.pdf"
        case "audio", "music": return "public.audio"
        case "video", "movie", "videos": return "public.movie"
        case "folder", "folders": return "public.folder"
        case "document", "documents", "doc", "docs": return "public.content"
        default: return nil
        }
    }
}
