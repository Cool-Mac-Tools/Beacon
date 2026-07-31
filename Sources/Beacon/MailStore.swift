import Foundation
import SQLite3

private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

struct MailRecord {
    let rowid: Int64
    let messageID: String
    let subject: String
    let senderAddress: String
    let senderName: String
    let snippet: String
    let received: Date
    let mailboxURL: String
    let mailboxName: String
    let accountName: String
    let isUnread: Bool
    let isFlagged: Bool

    var senderDisplay: String {
        if !senderName.isEmpty { return senderName }
        if !senderAddress.isEmpty { return senderAddress }
        return "Unknown Sender"
    }
}

/// Read-only search over Apple Mail's Envelope Index. The index spans every
/// account currently configured in Mail, so account switching is automatic.
final class MailStore {
    enum State { case idle, ready, needsFullDiskAccess, unavailable }

    private struct Schema {
        let databasePath: String
        let subjectJoin: String
        let subjectExpression: String
        let senderJoin: String
        let senderAddressExpression: String
        let senderNameExpression: String
        let summaryJoin: String
        let summaryExpression: String
        let mailboxJoin: String
        let mailboxExpression: String
        let mailboxNameExpression: String
        let accountNameExpression: String
        let globalDataJoin: String
        let messageIDExpression: String
        let dateExpression: String
        let unreadExpression: String
        let flaggedExpression: String
        let deletedClause: String
    }

    private(set) var state: State = .idle
    private var schema: Schema?
    private var lastTokens: [String] = []
    private var lastMatches: [MailRecord] = []
    private var lastSearchWasGmailOnly = false
    private(set) var hasGmailAccount = false

    var needsFullDiskAccess: Bool { state == .needsFullDiskAccess }
    var needsSetup: Bool { state == .unavailable }

    func ensureLoaded() {
        guard state == .idle else { return }
        guard let databasePath = locateDatabase() else { return }

        var db: OpaquePointer?
        defer { if db != nil { sqlite3_close(db) } }
        guard open(databasePath, into: &db) else {
            state = .needsFullDiskAccess
            return
        }
        guard let db, Self.tables(db).contains("messages") else {
            state = .unavailable
            return
        }

        schema = resolveSchema(db, databasePath: databasePath)
        state = schema == nil ? .unavailable : .ready
        hasGmailAccount = Self.scalarInt(
            db,
            "SELECT EXISTS(SELECT 1 FROM mailboxes WHERE LOWER(url) LIKE '%gmail%' LIMIT 1);"
        ) == 1
        Log.write("MailStore: state=\(state) db=\(databasePath)")
    }

    func retry() {
        state = .idle
        schema = nil
        lastTokens = []
        lastMatches = []
        lastSearchWasGmailOnly = false
        hasGmailAccount = false
        ensureLoaded()
    }

    /// Drop the last-search memo so a repeated query re-hits the live index.
    /// Mail re-queries the Envelope Index per search, so this is all a panel
    /// show needs to surface mail that arrived mid-session.
    func invalidateSearchCache() {
        lastTokens = []
        lastMatches = []
    }

    func search(tokens: [String], limit: Int = 80,
                gmailOnly: Bool = false,
                isCancelled: (() -> Bool)? = nil) -> [MailRecord] {
        guard state == .ready, let schema else { return [] }
        if tokens == lastTokens, gmailOnly == lastSearchWasGmailOnly,
           lastMatches.count >= limit {
            return Array(lastMatches.prefix(limit))
        }

        var db: OpaquePointer?
        defer { if db != nil { sqlite3_close(db) } }
        guard open(schema.databasePath, into: &db), let db else { return [] }

        let searchable = [
            schema.subjectExpression,
            schema.senderAddressExpression,
            schema.senderNameExpression,
            schema.summaryExpression
        ]
        let tokenClauses = tokens.map { _ in
            "(" + searchable.map { "\($0) LIKE ? ESCAPE '\\' COLLATE NOCASE" }
                .joined(separator: " OR ") + ")"
        }
        let searchClause = tokenClauses.isEmpty
            ? "1 = 1"
            : tokenClauses.joined(separator: " AND ")
        let scanLimit = max(500, limit * 10)
        let sql = """
        SELECT m.ROWID,
               \(schema.messageIDExpression),
               \(schema.subjectExpression),
               \(schema.senderAddressExpression),
               \(schema.senderNameExpression),
               \(schema.summaryExpression),
               \(schema.dateExpression),
               \(schema.mailboxExpression),
               \(schema.mailboxNameExpression),
               \(schema.accountNameExpression),
               \(schema.unreadExpression),
               \(schema.flaggedExpression)
        FROM messages AS m
        \(schema.subjectJoin)
        \(schema.senderJoin)
        \(schema.summaryJoin)
        \(schema.mailboxJoin)
        \(schema.globalDataJoin)
        WHERE \(searchClause)
              \(schema.deletedClause)
              \(gmailOnly ? "AND LOWER(\(schema.mailboxExpression)) LIKE '%gmail%'" : "")
        ORDER BY \(schema.dateExpression) DESC
        LIMIT \(scanLimit);
        """

        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            Log.write("MailStore: prepare failed \(String(cString: sqlite3_errmsg(db)))")
            return []
        }
        defer { sqlite3_finalize(stmt) }

        var bindIndex: Int32 = 1
        for token in tokens {
            let pattern = "%" + Self.escapeLike(token) + "%"
            for _ in searchable {
                sqlite3_bind_text(stmt, bindIndex, pattern, -1, SQLITE_TRANSIENT)
                bindIndex += 1
            }
        }

        var scored: [(MailRecord, SearchText.MatchQuality)] = []
        var rowIndex = 0
        while sqlite3_step(stmt) == SQLITE_ROW {
            rowIndex += 1
            if rowIndex & 0xFF == 0, isCancelled?() == true { return [] }
            let mailboxURL = Self.text(stmt, 7)
            let record = MailRecord(
                rowid: sqlite3_column_int64(stmt, 0),
                messageID: Self.text(stmt, 1),
                subject: Self.text(stmt, 2).isEmpty ? "(No Subject)" : Self.text(stmt, 2),
                senderAddress: Self.text(stmt, 3),
                senderName: Self.text(stmt, 4),
                snippet: Self.text(stmt, 5),
                received: Self.mailDate(sqlite3_column_double(stmt, 6)),
                mailboxURL: mailboxURL,
                mailboxName: Self.mailboxName(Self.text(stmt, 8), mailboxURL: mailboxURL),
                accountName: Self.accountName(Self.text(stmt, 9), mailboxURL: mailboxURL),
                isUnread: sqlite3_column_int(stmt, 10) != 0,
                isFlagged: sqlite3_column_int(stmt, 11) != 0
            )
            let folded = [
                record.subject,
                record.senderAddress,
                record.senderName,
                record.snippet
            ].joined(separator: " ").searchFolded
            if tokens.isEmpty {
                scored.append((record, .exactPhrase))
            } else if let quality = SearchText.matchQuality(folded, tokens: tokens) {
                scored.append((record, quality))
            }
        }

        let matches = scored.sorted {
            if $0.1 != $1.1 { return $0.1 < $1.1 }
            return $0.0.received > $1.0.received
        }.map(\.0)
        lastTokens = tokens
        lastMatches = matches
        lastSearchWasGmailOnly = gmailOnly
        Log.debug("MailStore: tokens=\(tokens) matched=\(matches.count)")
        return Array(matches.prefix(limit))
    }

    private func locateDatabase() -> String? {
        let root = NSHomeDirectory() + "/Library/Mail"
        do {
            let versions = try FileManager.default.contentsOfDirectory(atPath: root)
                .filter { $0.first == "V" && Int($0.dropFirst()) != nil }
                .sorted {
                    (Int($0.dropFirst()) ?? 0) > (Int($1.dropFirst()) ?? 0)
                }
            for version in versions {
                let path = root + "/\(version)/MailData/Envelope Index"
                if FileManager.default.fileExists(atPath: path) { return path }
            }
            state = .unavailable
        } catch {
            // A machine that never used Mail.app has no ~/Library/Mail at all;
            // that's "no mail here", not a permission problem. Only a real
            // access denial should send the user to the FDA pane.
            let nsError = error as NSError
            if nsError.domain == NSCocoaErrorDomain,
               nsError.code == NSFileReadNoSuchFileError {
                state = .unavailable
            } else {
                state = .needsFullDiskAccess
            }
            Log.write("MailStore: cannot inspect Mail directory \(error.localizedDescription)")
        }
        return nil
    }

    private func open(_ path: String, into db: inout OpaquePointer?) -> Bool {
        let encoded = path.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? path
        let uri = "file:\(encoded)?mode=ro"
        let rc = sqlite3_open_v2(uri, &db, SQLITE_OPEN_READONLY | SQLITE_OPEN_URI, nil)
        if rc == SQLITE_OK {
            sqlite3_busy_timeout(db, 1500)
            return true
        }
        Log.write("MailStore: open failed rc=\(rc)")
        return false
    }

    private func resolveSchema(_ db: OpaquePointer, databasePath: String) -> Schema? {
        let tables = Self.tables(db)
        let messages = Self.columns(db, table: "messages")

        let hasSubjects = tables.contains("subjects") && messages.contains("subject")
        let hasAddresses = tables.contains("addresses") && messages.contains("sender")
        let hasSummaries = tables.contains("summaries") && messages.contains("summary")
        let hasMailboxes = tables.contains("mailboxes") && messages.contains("mailbox")
        let mailboxColumns = Self.columns(db, table: "mailboxes")
        let globalColumns = Self.columns(db, table: "message_global_data")
        let hasGlobalData = tables.contains("message_global_data")
            && messages.contains("global_message_id")
            && globalColumns.contains("message_id_header")

        let dateColumn = messages.contains("date_received")
            ? "m.date_received"
            : messages.contains("date_sent") ? "m.date_sent" : "0"
        let mailboxURLExpression = hasMailboxes && mailboxColumns.contains("url")
            ? "COALESCE(mb.url, '')"
            : "''"
        let mailboxNameExpression = Self.firstExpression(
            columns: mailboxColumns,
            alias: "mb",
            candidates: ["display_name", "mailbox_name", "name"],
            fallback: mailboxURLExpression
        )
        let accountNameExpression = Self.firstExpression(
            columns: mailboxColumns,
            alias: "mb",
            candidates: ["account_name", "account", "account_identifier"],
            fallback: "''"
        )
        let unreadExpression: String
        if messages.contains("read") {
            unreadExpression = "CASE WHEN COALESCE(m.read, 0) = 0 THEN 1 ELSE 0 END"
        } else if messages.contains("is_read") {
            unreadExpression = "CASE WHEN COALESCE(m.is_read, 0) = 0 THEN 1 ELSE 0 END"
        } else if messages.contains("unread") {
            unreadExpression = "CASE WHEN COALESCE(m.unread, 0) <> 0 THEN 1 ELSE 0 END"
        } else if messages.contains("flags") {
            unreadExpression = "CASE WHEN (COALESCE(m.flags, 0) & 1) = 0 THEN 1 ELSE 0 END"
        } else {
            unreadExpression = "0"
        }
        let flaggedExpression: String
        if messages.contains("flagged") {
            flaggedExpression = "CASE WHEN COALESCE(m.flagged, 0) <> 0 THEN 1 ELSE 0 END"
        } else if messages.contains("is_flagged") {
            flaggedExpression = "CASE WHEN COALESCE(m.is_flagged, 0) <> 0 THEN 1 ELSE 0 END"
        } else if messages.contains("flags") {
            flaggedExpression = "CASE WHEN (COALESCE(m.flags, 0) & 16) <> 0 THEN 1 ELSE 0 END"
        } else {
            flaggedExpression = "0"
        }

        return Schema(
            databasePath: databasePath,
            subjectJoin: hasSubjects ? "LEFT JOIN subjects AS s ON m.subject = s.ROWID" : "",
            subjectExpression: hasSubjects ? "COALESCE(s.subject, '')" : "''",
            senderJoin: hasAddresses ? "LEFT JOIN addresses AS a ON m.sender = a.ROWID" : "",
            senderAddressExpression: hasAddresses ? "COALESCE(a.address, '')" : "''",
            senderNameExpression: hasAddresses ? "COALESCE(a.comment, '')" : "''",
            summaryJoin: hasSummaries ? "LEFT JOIN summaries AS sm ON m.summary = sm.ROWID" : "",
            summaryExpression: hasSummaries
                ? "COALESCE(sm.summary, '')"
                : messages.contains("snippet") ? "COALESCE(m.snippet, '')" : "''",
            mailboxJoin: hasMailboxes ? "LEFT JOIN mailboxes AS mb ON m.mailbox = mb.ROWID" : "",
            mailboxExpression: mailboxURLExpression,
            mailboxNameExpression: mailboxNameExpression,
            accountNameExpression: accountNameExpression,
            globalDataJoin: hasGlobalData
                ? "LEFT JOIN message_global_data AS mgd ON m.global_message_id = mgd.ROWID"
                : "",
            messageIDExpression: hasGlobalData ? "COALESCE(mgd.message_id_header, '')" : "''",
            dateExpression: dateColumn,
            unreadExpression: unreadExpression,
            flaggedExpression: flaggedExpression,
            deletedClause: messages.contains("deleted") ? "AND COALESCE(m.deleted, 0) = 0" : ""
        )
    }

    private static func firstExpression(columns: Set<String>, alias: String,
                                        candidates: [String], fallback: String) -> String {
        guard let column = candidates.first(where: columns.contains) else { return fallback }
        return "COALESCE(CAST(\(alias).\(column) AS TEXT), '')"
    }

    private static func tables(_ db: OpaquePointer) -> Set<String> {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(
            db,
            "SELECT name FROM sqlite_master WHERE type = 'table';",
            -1,
            &stmt,
            nil
        ) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(stmt) }
        var names = Set<String>()
        while sqlite3_step(stmt) == SQLITE_ROW {
            names.insert(text(stmt, 0))
        }
        return names
    }

    private static func columns(_ db: OpaquePointer, table: String) -> Set<String> {
        guard !table.isEmpty else { return [] }
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, "PRAGMA table_info(\(table));", -1, &stmt, nil) == SQLITE_OK
        else { return [] }
        defer { sqlite3_finalize(stmt) }
        var names = Set<String>()
        while sqlite3_step(stmt) == SQLITE_ROW {
            names.insert(text(stmt, 1))
        }
        return names
    }

    private static func scalarInt(_ db: OpaquePointer, _ sql: String) -> Int64? {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_step(stmt) == SQLITE_ROW else { return nil }
        return sqlite3_column_int64(stmt, 0)
    }

    private static func text(_ stmt: OpaquePointer?, _ column: Int32) -> String {
        sqlite3_column_text(stmt, column).map { String(cString: $0) } ?? ""
    }

    private static func escapeLike(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "%", with: "\\%")
            .replacingOccurrences(of: "_", with: "\\_")
    }

    private static func mailboxName(_ value: String, mailboxURL: String) -> String {
        if !value.isEmpty, value != mailboxURL { return value }
        guard let components = URLComponents(string: mailboxURL) else { return value }
        let path = components.percentEncodedPath
            .split(separator: "/", omittingEmptySubsequences: true)
            .last
            .map(String.init) ?? ""
        return path.removingPercentEncoding ?? path
    }

    private static func accountName(_ value: String, mailboxURL: String) -> String {
        if !value.isEmpty { return value }
        guard let components = URLComponents(string: mailboxURL) else { return "" }
        if let user = components.user, !user.isEmpty {
            return user.removingPercentEncoding ?? user
        }
        return components.host?.removingPercentEncoding ?? components.host ?? ""
    }

    private static func mailDate(_ raw: Double) -> Date {
        // Mail versions have used both Unix and Cocoa epochs.
        if raw > 1_200_000_000 { return Date(timeIntervalSince1970: raw) }
        return Date(timeIntervalSinceReferenceDate: raw)
    }
}
