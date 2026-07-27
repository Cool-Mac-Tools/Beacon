import Foundation
import SQLite3

/// A single iMessage/SMS row pulled from the Messages database.
struct MessageRecord {
    let rowid: Int64
    let date: Date
    let isFromMe: Bool
    let handle: String   // the other party's phone/email ("" if unknown / group)
    let chatIdentifier: String
    let chatGUID: String
    let chatName: String
    let text: String
    /// Attachment metadata is aggregated per message (using newlines as the
    /// separator when a message has multiple attachments).
    let attachmentUTI: String
    let attachmentMIMEType: String
    let attachmentFilename: String
    /// One of: text, links, photos, videos, files, audio.
    let contentCategory: String
    /// Case/diacritic-folded "text handle", precomputed once at load so each
    /// keystroke filters without re-folding the whole history.
    let folded: String

    var isGroup: Bool {
        chatGUID.contains(";+;") || chatIdentifier.lowercased().hasPrefix("chat")
    }

    /// Best available one-to-one conversation target. Sent rows often have no
    /// message.handle_id, while their joined chat still identifies the peer.
    var conversationHandle: String {
        guard !isGroup else { return "" }
        if !handle.isEmpty { return handle }
        if chatIdentifier.contains("@") || chatIdentifier.contains(where: \.isNumber) {
            return chatIdentifier
        }
        return ""
    }

    var conversationKey: String {
        if !chatGUID.isEmpty { return chatGUID }
        if !chatIdentifier.isEmpty { return chatIdentifier }
        return conversationHandle
    }
}

/// Reads and searches the macOS Messages database (`~/Library/Messages/chat.db`).
///
/// The DB is opened read-only with WAL awareness so recent, uncheckpointed
/// messages remain visible. Reading it requires Full Disk Access; if that's missing, the
/// open fails and we surface `.needsFullDiskAccess` so the UI can guide the user.
///
/// Messages are loaded once into memory (most-recent first, capped) and then
/// filtered in-process on each keystroke, which keeps typing instant.
final class MessageStore {
    enum State {
        case idle
        case ready
        case needsFullDiskAccess
        case unavailable   // no Messages DB on this machine
    }

    private(set) var state: State = .idle
    private var cache: [MessageRecord] = []
    private var lastSearchTokens: [String] = []
    private var lastSearchMatches: [MessageRecord] = []
    private var lastSearchUsedResolver = false
    private var loadedAt: Date?
    private var maxLoadedRowID: Int64 = 0

    private let dbPath = NSHomeDirectory() + "/Library/Messages/chat.db"
    // Effectively "everything" - a safety ceiling so a pathological history
    // can't exhaust memory. Real histories are far below this.
    private let loadCap = 1_000_000

    var needsFullDiskAccess: Bool { state == .needsFullDiskAccess }

    func probeAccess() -> Bool {
        guard FileManager.default.fileExists(atPath: dbPath) else {
            state = .unavailable
            return false
        }
        var db: OpaquePointer?
        let encoded = dbPath.addingPercentEncoding(
            withAllowedCharacters: .urlPathAllowed
        ) ?? dbPath
        let rc = sqlite3_open_v2(
            "file:\(encoded)?mode=ro", &db,
            SQLITE_OPEN_READONLY | SQLITE_OPEN_URI, nil
        )
        if db != nil { sqlite3_close(db) }
        if rc == SQLITE_OK {
            if state == .needsFullDiskAccess { state = .idle }
            return true
        }
        // A transient open failure must not demote a store that's already
        // serving a warm cache.
        if state != .ready { state = .needsFullDiskAccess }
        return false
    }

    /// Load the DB once. Safe to call repeatedly; only does work when idle.
    func ensureLoaded() {
        guard state == .idle else { return }
        guard FileManager.default.fileExists(atPath: dbPath) else {
            state = .unavailable
            return
        }
        load()
    }

    /// Forget any prior failure and try again (e.g. after the user grants access).
    func retry() {
        state = .idle
        ensureLoaded()
    }

    /// Pull in messages that arrived since the last load, so texts received
    /// mid-session are findable without relaunching. Incremental
    /// (`WHERE ROWID > max loaded`) and throttled, so it's cheap enough to run
    /// on every panel show.
    func refreshIfStale(olderThan ttl: TimeInterval = 60) {
        guard state == .ready else { return }
        if let loadedAt, Date().timeIntervalSince(loadedAt) < ttl { return }
        load(sinceRowID: maxLoadedRowID)
    }

    /// Search by message text, raw handle, or (when `nameResolver` is given)
    /// the resolved contact name — so typing "Mom" finds Mom's messages, not
    /// just messages containing the word. Tokens must already be folded.
    ///
    /// `isCancelled` is polled during the scan; a search that has been
    /// superseded by newer keystrokes aborts immediately instead of grinding
    /// through the rest of the history (its partial result is dropped by the
    /// caller's generation check anyway).
    func search(tokens: [String], limit: Int = 80,
                nameResolver: ((String) -> String?)? = nil,
                isCancelled: (() -> Bool)? = nil) -> [MessageRecord] {
        guard state == .ready else {
            Log.write("MessageStore: search skipped (state=\(state), tokens=\(tokens))")
            return []
        }
        if tokens.isEmpty { return Array(cache.prefix(limit)) }
        // A cached result computed before the contact resolver was ready must
        // not be reused once names become resolvable — "Mom" should start
        // matching Mom's messages the moment contacts finish loading.
        if tokens == lastSearchTokens,
           (nameResolver != nil) == lastSearchUsedResolver {
            return Array(lastSearchMatches.prefix(limit))
        }
        var out: [(record: MessageRecord, quality: SearchText.MatchQuality)] = []
        for (index, rec) in cache.enumerated() {   // already sorted newest-first
            if index & 0xFF == 0, isCancelled?() == true {
                return out.map(\.record)
            }
            // Fast path: match on the precomputed text+handle haystack first;
            // only fall back to the contact-name lookup when the text misses.
            let textQuality = SearchText.matchQuality(rec.folded, tokens: tokens)
            let nameQuality: SearchText.MatchQuality?
            if let nameResolver,
               let name = foldedName(for: rec.conversationHandle, resolve: nameResolver) {
                nameQuality = SearchText.matchQuality(name, tokens: tokens)
            } else {
                nameQuality = nil
            }
            let quality = [textQuality, nameQuality].compactMap { $0 }.min()
            if let quality {
                out.append((rec, quality))
            }
        }
        let matches = out
            .sorted {
                if $0.quality != $1.quality { return $0.quality < $1.quality }
                return $0.record.date > $1.record.date
            }
            .map(\.record)
        lastSearchTokens = tokens
        lastSearchMatches = matches
        lastSearchUsedResolver = nameResolver != nil
        let results = Array(matches.prefix(limit))
        Log.write("MessageStore: search tokens=\(tokens) cache=\(cache.count) matched=\(out.count) returned=\(results.count)")
        return results
    }

    /// A chronological window around one result in the same conversation.
    func context(around rowid: Int64, radius: Int = 8) -> [MessageRecord] {
        guard let target = cache.first(where: { $0.rowid == rowid }) else { return [] }
        let key = target.conversationKey
        guard !key.isEmpty else { return [target] }
        let thread = cache
            .filter { $0.conversationKey == key }
            .sorted { $0.date < $1.date }
        guard let index = thread.firstIndex(where: { $0.rowid == rowid }) else { return [target] }
        let lower = max(0, index - radius)
        let upper = min(thread.count, index + radius + 1)
        return Array(thread[lower..<upper])
    }

    /// Folded contact names, cached per handle. Only consulted once the
    /// resolver is ready, so cached values are stable. Accessed solely from the
    /// engine's serial message queue.
    private var nameCache: [String: String?] = [:]

    private func foldedName(for handle: String, resolve: (String) -> String?) -> String? {
        guard !handle.isEmpty else { return nil }
        if let cached = nameCache[handle] { return cached }
        let folded = resolve(handle)?.searchFolded
        nameCache[handle] = folded
        return folded
    }

    // MARK: - Loading

    private func load(sinceRowID: Int64? = nil) {
        var db: OpaquePointer?
        defer { if db != nil { sqlite3_close(db) } }

        // Read-only mode prevents writes while still merging Messages' live WAL.
        let encoded = dbPath.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? dbPath
        let uri = "file:\(encoded)?mode=ro"

        let openFlags = SQLITE_OPEN_READONLY | SQLITE_OPEN_URI
        let openRC = sqlite3_open_v2(uri, &db, openFlags, nil)
        guard openRC == SQLITE_OK else {
            let msg = db.map { String(cString: sqlite3_errmsg($0)) } ?? "nil db"
            Log.write("MessageStore: open failed rc=\(openRC) err=\(msg)")
            // An incremental refresh failing (e.g. transient lock) must not
            // demote a working store; keep serving the warm cache.
            guard sinceRowID == nil else { return }
            // Typically "authorization denied" => Full Disk Access not granted.
            state = .needsFullDiskAccess
            return
        }
        sqlite3_busy_timeout(db, 1500)

        let chatColumns = Self.columns(db, table: "chat")
        let messageColumns = Self.columns(db, table: "message")
        let attachmentColumns = Self.columns(db, table: "attachment")
        let attachmentJoinColumns = Self.columns(db, table: "message_attachment_join")
        let chatNameExpression = chatColumns.contains("display_name")
            ? "COALESCE(c.display_name, '')"
            : "''"
        let attributedBodyExpression = messageColumns.contains("attributedBody")
            ? "m.attributedBody"
            : "NULL"
        let isAudioMessageExpression = messageColumns.contains("is_audio_message")
            ? "COALESCE(m.is_audio_message, 0)"
            : "0"
        let canLoadAttachments = attachmentJoinColumns.contains("message_id")
            && attachmentJoinColumns.contains("attachment_id")
            && !attachmentColumns.isEmpty

        // Correlated aggregate subqueries keep this a strict one-row-per-message
        // query. Building each expression from PRAGMA results also lets older
        // chat.db schemas omit attachment columns (or the join table) safely.
        func attachmentMetadataExpression(column: String) -> String {
            guard canLoadAttachments, attachmentColumns.contains(column) else { return "''" }
            return """
            COALESCE((
                SELECT GROUP_CONCAT(COALESCE(a.\(column), ''), char(10))
                FROM message_attachment_join AS maj
                JOIN attachment AS a ON a.ROWID = maj.attachment_id
                WHERE maj.message_id = m.ROWID
            ), '')
            """
        }
        let attachmentUTIExpression = attachmentMetadataExpression(column: "uti")
        let attachmentMIMETypeExpression = attachmentMetadataExpression(column: "mime_type")
        let attachmentFilenameExpression = attachmentMetadataExpression(column: "filename")
        let hasAttachmentExpression = canLoadAttachments
            ? """
              EXISTS (
                  SELECT 1
                  FROM message_attachment_join AS maj
                  WHERE maj.message_id = m.ROWID
              )
              """
            : "0"
        // `sinceRowID` is our own Int64, not user input — safe to interpolate.
        let whereClause = sinceRowID.map { "WHERE m.ROWID > \($0)" } ?? ""
        let sql = """
        SELECT m.ROWID, m.date, m.is_from_me, COALESCE(h.id, ''),
               m.text, \(attributedBodyExpression),
               COALESCE(c.chat_identifier, ''), COALESCE(c.guid, ''),
               \(chatNameExpression),
               \(attachmentUTIExpression),
               \(attachmentMIMETypeExpression),
               \(attachmentFilenameExpression),
               \(hasAttachmentExpression),
               \(isAudioMessageExpression)
        FROM message AS m
        LEFT JOIN handle AS h ON m.handle_id = h.ROWID
        LEFT JOIN chat AS c ON c.ROWID = (
            SELECT cmj.chat_id
            FROM chat_message_join AS cmj
            WHERE cmj.message_id = m.ROWID
            ORDER BY cmj.chat_id
            LIMIT 1
        )
        \(whereClause)
        ORDER BY m.date DESC
        LIMIT \(loadCap);
        """

        var stmt: OpaquePointer?
        let prepRC = sqlite3_prepare_v2(db, sql, -1, &stmt, nil)
        guard prepRC == SQLITE_OK else {
            let msg = String(cString: sqlite3_errmsg(db))
            Log.write("MessageStore: prepare failed rc=\(prepRC) err=\(msg)")
            guard sinceRowID == nil else { return }
            // The DB opened, so access is fine — a prepare failure means the
            // schema changed (macOS update). Reporting it as a permission
            // problem would send users to grant FDA they already have.
            state = .unavailable
            return
        }
        defer { sqlite3_finalize(stmt) }

        var records: [MessageRecord] = []
        var scanned = 0, fromTextCol = 0, fromBlob = 0, dropped = 0
        while sqlite3_step(stmt) == SQLITE_ROW {
            scanned += 1
            let rowid = sqlite3_column_int64(stmt, 0)
            let rawDate = sqlite3_column_int64(stmt, 1)
            let isFromMe = sqlite3_column_int(stmt, 2) == 1
            let handle = sqlite3_column_text(stmt, 3).map { String(cString: $0) } ?? ""
            let chatIdentifier = sqlite3_column_text(stmt, 6).map { String(cString: $0) } ?? ""
            let chatGUID = sqlite3_column_text(stmt, 7).map { String(cString: $0) } ?? ""
            let chatName = sqlite3_column_text(stmt, 8).map { String(cString: $0) } ?? ""
            let attachmentUTI = sqlite3_column_text(stmt, 9).map { String(cString: $0) } ?? ""
            let attachmentMIMEType = sqlite3_column_text(stmt, 10).map { String(cString: $0) } ?? ""
            let attachmentFilename = sqlite3_column_text(stmt, 11).map { String(cString: $0) } ?? ""
            let hasAttachment = sqlite3_column_int(stmt, 12) == 1
            let isAudioMessage = sqlite3_column_int(stmt, 13) == 1

            var text = sqlite3_column_text(stmt, 4).map { String(cString: $0) } ?? ""
            if !text.isEmpty {
                fromTextCol += 1
            } else if let blob = sqlite3_column_blob(stmt, 5) {
                let len = Int(sqlite3_column_bytes(stmt, 5))
                if len > 0 {
                    let data = Data(bytes: blob, count: len)
                    text = Self.decodeAttributedBody(data) ?? ""
                    if !text.isEmpty { fromBlob += 1 }
                }
            }
            guard !text.isEmpty else { dropped += 1; continue }
            let contentCategory = Self.contentCategory(
                text: text,
                attachmentUTI: attachmentUTI,
                attachmentMIMEType: attachmentMIMEType,
                attachmentFilename: attachmentFilename,
                hasAttachment: hasAttachment,
                isAudioMessage: isAudioMessage
            )

            records.append(MessageRecord(rowid: rowid,
                                         date: Self.appleDate(rawDate),
                                         isFromMe: isFromMe,
                                         handle: handle,
                                         chatIdentifier: chatIdentifier,
                                         chatGUID: chatGUID,
                                         chatName: chatName,
                                         text: text,
                                         attachmentUTI: attachmentUTI,
                                         attachmentMIMEType: attachmentMIMEType,
                                         attachmentFilename: attachmentFilename,
                                         contentCategory: contentCategory,
                                         folded: (text + " " + handle + " " + chatIdentifier
                                                  + " " + chatName).searchFolded))
        }

        if sinceRowID != nil {
            loadedAt = Date()
            guard !records.isEmpty else { return }
            // New rows are the newest; prepend to keep newest-first order.
            cache = records + cache
            if cache.count > loadCap {
                cache.removeLast(cache.count - loadCap)
            }
        } else {
            cache = records
            state = .ready
            loadedAt = Date()
        }
        maxLoadedRowID = max(maxLoadedRowID, records.map(\.rowid).max() ?? 0)
        lastSearchTokens = []
        lastSearchMatches = []
        Log.write("MessageStore: loaded scanned=\(scanned) textCol=\(fromTextCol) blob=\(fromBlob) dropped=\(dropped) cache=\(cache.count) incremental=\(sinceRowID != nil)")
    }

    // MARK: - Helpers

    private static func columns(_ db: OpaquePointer?, table: String) -> Set<String> {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, "PRAGMA table_info(\(table));", -1, &stmt, nil) == SQLITE_OK else {
            return []
        }
        defer { sqlite3_finalize(stmt) }
        var names = Set<String>()
        while sqlite3_step(stmt) == SQLITE_ROW {
            if let value = sqlite3_column_text(stmt, 1) {
                names.insert(String(cString: value))
            }
        }
        return names
    }

    /// Messages stores dates as nanoseconds (modern) or seconds (legacy) since
    /// the 2001-01-01 reference date.
    private static func appleDate(_ raw: Int64) -> Date {
        let seconds = raw > 100_000_000_000 ? Double(raw) / 1_000_000_000.0 : Double(raw)
        return Date(timeIntervalSinceReferenceDate: seconds)
    }

    private static func contentCategory(
        text: String,
        attachmentUTI: String,
        attachmentMIMEType: String,
        attachmentFilename: String,
        hasAttachment: Bool,
        isAudioMessage: Bool
    ) -> String {
        let metadata = (attachmentUTI + "\n" + attachmentMIMEType + "\n"
                        + attachmentFilename).lowercased()

        if isAudioMessage || metadata.contains("audio/")
            || metadata.contains("public.audio") || metadata.contains("audio-message")
            || metadata.contains("voicememo") {
            return "audio"
        }
        if metadata.contains("image/") || metadata.contains("public.image")
            || metadata.contains("heic") || metadata.contains("jpeg")
            || metadata.contains("png") || metadata.contains("gif") {
            return "photos"
        }
        if metadata.contains("video/") || metadata.contains("public.movie")
            || metadata.contains("public.video") || metadata.contains(".mov")
            || metadata.contains(".mp4") || metadata.contains(".m4v") {
            return "videos"
        }
        if hasAttachment {
            return "files"
        }
        if containsLink(text) {
            return "links"
        }
        return "text"
    }

    private static func containsLink(_ text: String) -> Bool {
        guard let detector = try? NSDataDetector(
            types: NSTextCheckingResult.CheckingType.link.rawValue
        ) else {
            return false
        }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        return detector.firstMatch(in: text, options: [], range: range) != nil
    }

    /// Best-effort extraction of the message text from the `attributedBody`
    /// blob (an old-style "streamtyped" archive). Newer Messages versions leave
    /// the `text` column NULL and store the body only here.
    static func decodeAttributedBody(_ data: Data) -> String? {
        guard let marker = data.range(of: Data("NSString".utf8)) else { return nil }

        // After "NSString" comes a class marker; the string value is preceded by
        // a 0x2B ('+') byte, then a variable-length count, then the UTF-8 bytes.
        var i = marker.upperBound
        let scanEnd = min(data.count, marker.upperBound + 12)
        var found = false
        while i < scanEnd {
            if data[i] == 0x2B { i += 1; found = true; break }
            i += 1
        }
        guard found, i < data.count else { return nil }

        var length = Int(data[i]); i += 1
        // 0x81/0x82 signal 2- and 3-byte little-endian lengths.
        if length == 0x81 {
            guard i + 1 < data.count else { return nil }
            length = Int(data[i]) | (Int(data[i + 1]) << 8)
            i += 2
        } else if length == 0x82 {
            guard i + 2 < data.count else { return nil }
            length = Int(data[i]) | (Int(data[i + 1]) << 8) | (Int(data[i + 2]) << 16)
            i += 3
        }
        guard length > 0, i + length <= data.count else { return nil }
        return String(data: data.subdata(in: i..<(i + length)), encoding: .utf8)
    }
}
