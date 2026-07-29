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

    /// Build and run a synchronous MDQuery. `tokens` are ANDed (each must appear
    /// in the name or text content); `fileType`/`after`/`before` are hard
    /// filters. Returns up to `limit` hits, newest first.
    static func search(tokens: [String], fileType: String?,
                       after: Date?, before: Date?, limit: Int) -> [Hit] {
        var clauses: [String] = []

        for token in tokens {
            let t = escape(token)
            guard !t.isEmpty else { continue }
            clauses.append("(kMDItemDisplayName == \"*\(t)*\"cd || kMDItemTextContent == \"*\(t)*\"cd)")
        }
        if let tree = contentTypeTree(for: fileType) {
            clauses.append("kMDItemContentTypeTree == \"\(tree)\"")
        }
        if let after {
            clauses.append("kMDItemFSContentChangeDate >= $time.iso(\(iso(after)))")
        }
        if let before {
            clauses.append("kMDItemFSContentChangeDate <= $time.iso(\(iso(before)))")
        }
        // A bare "everything" query is meaningless/expensive — require at least
        // one keyword or a type filter to anchor it.
        guard !clauses.isEmpty, !(tokens.isEmpty && fileType == nil) else { return [] }

        let queryString = clauses.joined(separator: " && ")
        guard let query = MDQueryCreate(kCFAllocatorDefault, queryString as CFString, nil, nil) else {
            return []
        }
        // Newest first, and cap the gather.
        MDQuerySetSortComparator(query, nil, nil)
        MDQuerySetMaxCount(query, max(limit, 1))
        guard MDQueryExecute(query, CFOptionFlags(kMDQuerySynchronous.rawValue)) else {
            return []
        }

        let count = MDQueryGetResultCount(query)
        var hits: [Hit] = []
        hits.reserveCapacity(count)
        for i in 0..<count {
            guard let raw = MDQueryGetResultAtIndex(query, i) else { continue }
            let item = unsafeBitCast(raw, to: MDItem.self)
            guard let path = MDItemCopyAttribute(item, kMDItemPath) as? String else { continue }
            let name = (MDItemCopyAttribute(item, kMDItemDisplayName) as? String)
                ?? (path as NSString).lastPathComponent
            let modified = MDItemCopyAttribute(item, kMDItemFSContentChangeDate) as? Date
            let ctype = MDItemCopyAttribute(item, kMDItemContentType) as? String
            let kind = (MDItemCopyAttribute(item, kMDItemKind) as? String)
                ?? (ctype == "public.folder" ? "Folder" : "File")
            hits.append(Hit(path: path, name: name, modified: modified, contentType: ctype, kind: kind))
        }
        // MDQuery honors the sort comparator loosely; ensure newest-first.
        return hits.sorted { ($0.modified ?? .distantPast) > ($1.modified ?? .distantPast) }
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
