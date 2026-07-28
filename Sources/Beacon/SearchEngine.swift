import AppKit
import Foundation
import UniformTypeIdentifiers

/// Why a result matched the query: by its name/path, or by text found inside
/// the file's contents. Used for ranking and for the UI badge.
enum MatchKind {
    case name
    case content
}

/// Whether a result is a file/folder from the index, a text message, a note,
/// a clipboard entry, or a browser-history page.
enum ResultSource {
    case file
    case message
    case note
    case mail
    case calendar
    case clipboard
    case history
    case settings
}

struct MessageThreadItem: Identifiable {
    let id: Int64
    let body: String
    let sender: String
    let date: Date
    let isFromMe: Bool
    let isMatch: Bool
}

struct MessageThreadPreview {
    let title: String
    let result: SearchResult
    let items: [MessageThreadItem]
}

/// One row in the results list, from either the Spotlight index or Messages.
struct SearchResult: Identifiable, Hashable {
    private static let iconCache: NSCache<NSString, NSImage> = {
        let cache = NSCache<NSString, NSImage>()
        cache.countLimit = 1_000
        return cache
    }()
    let id: String        // unique + stable (file path, or "msg:<rowid>")
    let source: ResultSource
    let name: String      // file name, or the message's sender/contact
    let path: String      // file path; "" for messages
    let kind: String
    let size: Int64?
    let modified: Date?
    let lastUsed: Date?
    let dateAdded: Date?  // when the file appeared in its folder (downloads/saves)
    let isFolder: Bool
    let isApp: Bool
    let contentTypes: [String]
    let matchKind: MatchKind

    /// The most recent moment the user touched this item in any way - opened,
    /// saved/modified, or added to a folder. Drives the Recents timeline.
    var effectiveRecency: Date {
        let date = max(lastUsed ?? .distantPast,
                       max(dateAdded ?? .distantPast, modified ?? .distantPast))
        if source == .calendar, date > Date() {
            return Date().addingTimeInterval(-date.timeIntervalSinceNow)
        }
        return date
    }

    let messageBody: String?
    let messageHandle: String?
    let messageFromMe: Bool
    let messageChatGUID: String?
    let messageRowID: Int64?

    let noteID: String?
    let mailMessageID: String?
    var facets: RefinementFacets

    var url: URL { URL(fileURLWithPath: path) }

    var icon: NSImage {
        let iconPath: String?
        switch source {
        case .file:
            iconPath = path
        case .message:
            iconPath = "/System/Applications/Messages.app"
        case .note:
            iconPath = "/System/Applications/Notes.app"
        case .mail:
            iconPath = "/System/Applications/Mail.app"
        case .calendar:
            iconPath = "/System/Applications/Calendar.app"
        case .clipboard:
            let symbol = NSImage(systemSymbolName: "doc.on.clipboard",
                                 accessibilityDescription: "Clipboard")
            return symbol ?? NSImage()
        case .history:
            let symbol = NSImage(systemSymbolName: "globe",
                                 accessibilityDescription: "Web history")
            return symbol ?? NSImage()
        case .settings:
            let symbol = NSImage(systemSymbolName: kind,
                                 accessibilityDescription: "System Settings")
            return symbol ?? NSWorkspace.shared.icon(forFile: "/System/Applications/System Settings.app")
        }
        guard let iconPath else { return NSImage() }
        let key = iconPath as NSString
        if let cached = Self.iconCache.object(forKey: key) { return cached }
        let image = NSWorkspace.shared.icon(forFile: iconPath)
        Self.iconCache.setObject(image, forKey: key)
        return image
    }

    var directory: String {
        (path as NSString).deletingLastPathComponent
    }

    static func == (lhs: SearchResult, rhs: SearchResult) -> Bool { lhs.id == rhs.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }

    /// File result.
    init(id: String, name: String, path: String, kind: String, size: Int64?,
         modified: Date?, lastUsed: Date?, dateAdded: Date?,
         isFolder: Bool, isApp: Bool, contentTypes: [String] = [],
         matchKind: MatchKind, facets: RefinementFacets = .empty) {
        self.id = id; self.source = .file; self.name = name; self.path = path
        self.kind = kind; self.size = size; self.modified = modified
        self.lastUsed = lastUsed; self.dateAdded = dateAdded
        self.isFolder = isFolder; self.isApp = isApp
        self.contentTypes = contentTypes
        self.matchKind = matchKind
        self.messageBody = nil; self.messageHandle = nil; self.messageFromMe = false
        self.messageChatGUID = nil; self.messageRowID = nil
        self.noteID = nil; self.mailMessageID = nil
        self.facets = facets
    }

    /// Filesystem-backed Recents result.
    init(recent r: RecentFileRecord) {
        self.id = r.path
        self.source = .file
        self.name = r.name
        self.path = r.path
        self.kind = r.kind
        self.size = r.size
        self.modified = r.modified
        self.lastUsed = r.recency
        self.dateAdded = r.dateAdded
        self.isFolder = r.isFolder
        self.isApp = r.isApp
        self.contentTypes = r.contentTypes
        self.matchKind = .name
        self.messageBody = nil
        self.messageHandle = nil
        self.messageFromMe = false
        self.messageChatGUID = nil
        self.messageRowID = nil
        self.noteID = nil
        self.mailMessageID = nil
        var facets = RefinementFacets()
        if r.path.hasPrefix(NSHomeDirectory() + "/Downloads/") {
            facets.activity = "downloaded"
        } else if r.dateAdded != nil {
            facets.activity = "added"
        } else {
            facets.activity = "modified"
        }
        self.facets = facets
    }

    init(folder r: FolderRecord) {
        self.init(
            id: r.path,
            name: r.name,
            path: r.path,
            kind: "Folder",
            size: nil,
            modified: r.modified,
            lastUsed: nil,
            dateAdded: nil,
            isFolder: true,
            isApp: false,
            contentTypes: ["public.folder"],
            matchKind: .name,
            facets: .empty
        )
    }

    /// Combine a duplicate row for the same path surfaced by another gather
    /// lane (Spotlight, priority MDQuery, FolderStore, fresh recents). Keeps
    /// this row as primary and fills any missing metadata from `other`, so a
    /// fast-lane row can never strip dates/facets off a richer Spotlight row.
    func enriched(with other: SearchResult) -> SearchResult {
        guard source == .file, other.source == .file, path == other.path else {
            return self
        }
        func latest(_ a: Date?, _ b: Date?) -> Date? {
            switch (a, b) {
            case let (a?, b?): return max(a, b)
            default: return a ?? b
            }
        }
        return SearchResult(
            id: id,
            name: name,
            path: path,
            kind: kind.isEmpty ? other.kind : kind,
            size: size ?? other.size,
            modified: latest(modified, other.modified),
            lastUsed: latest(lastUsed, other.lastUsed),
            dateAdded: dateAdded ?? other.dateAdded,
            isFolder: isFolder || other.isFolder,
            isApp: isApp || other.isApp,
            contentTypes: contentTypes.count >= other.contentTypes.count
                ? contentTypes : other.contentTypes,
            matchKind: matchKind == .name || other.matchKind == .name
                ? .name : matchKind,
            facets: facets.merged(with: other.facets)
        )
    }

    init(metadata r: BoundedMetadataRecord, facets: RefinementFacets) {
        self.init(
            id: r.path,
            name: r.name,
            path: r.path,
            kind: r.kind,
            size: r.size,
            modified: r.modified,
            lastUsed: r.lastUsed,
            dateAdded: r.dateAdded,
            isFolder: r.contentTypes.contains("public.folder"),
            isApp: r.contentTypes.contains("com.apple.application"),
            contentTypes: r.contentTypes,
            matchKind: .name,
            facets: facets
        )
    }

    /// Installed app result.
    init(app a: AppRecord) {
        self.id = a.path
        self.source = .file
        self.name = a.name
        self.path = a.path
        self.kind = "Application"
        self.size = nil
        self.modified = a.modified
        self.lastUsed = a.lastUsed
        self.dateAdded = nil
        self.isFolder = false
        self.isApp = true
        self.contentTypes = ["com.apple.application"]
        self.matchKind = .name
        self.messageBody = nil
        self.messageHandle = nil
        self.messageFromMe = false
        self.messageChatGUID = nil
        self.messageRowID = nil
        self.noteID = nil
        self.mailMessageID = nil
        var facets = RefinementFacets()
        facets.category = a.category
        self.facets = facets
    }

    /// Message result. `contactName` (when resolved from Contacts) is shown
    /// instead of the raw phone/email.
    init(message m: MessageRecord, contactName: String?) {
        self.id = "msg:\(m.rowid)"
        self.source = .message
        let who: String
        if !m.chatName.isEmpty {
            who = m.chatName
        } else if m.isGroup {
            who = "Group Chat"
        } else {
            who = contactName ?? (m.conversationHandle.isEmpty
                ? (m.isFromMe ? "You" : "Unknown")
                : m.conversationHandle)
        }
        self.name = who
        self.path = ""
        self.kind = "Message"
        self.size = nil
        self.modified = m.date
        self.lastUsed = m.date
        self.dateAdded = nil
        self.isFolder = false
        self.isApp = false
        self.contentTypes = []
        self.matchKind = .content
        self.messageBody = m.text
        self.messageHandle = m.conversationHandle
        self.messageFromMe = m.isFromMe
        self.messageChatGUID = m.chatGUID.isEmpty ? nil : m.chatGUID
        self.messageRowID = m.rowid
        self.noteID = nil
        self.mailMessageID = nil
        var facets = RefinementFacets()
        facets.contentCategory = m.contentCategory
        self.facets = facets
    }

    /// Note result. The note title is the title; the body/snippet is the detail.
    init(note n: NoteRecord) {
        self.id = "note:\(n.pk)"
        self.source = .note
        self.name = n.title
        self.path = ""
        self.kind = "Note"
        self.size = nil
        self.modified = n.modified
        self.lastUsed = n.modified
        self.dateAdded = nil
        self.isFolder = false
        self.isApp = false
        self.contentTypes = []
        self.matchKind = .content
        self.messageBody = n.body.isEmpty ? n.snippet : n.body
        self.messageHandle = nil
        self.messageFromMe = false
        self.messageChatGUID = nil
        self.messageRowID = nil
        self.noteID = n.appleScriptID
        self.mailMessageID = nil
        var facets = RefinementFacets()
        facets.container = n.folderName
        facets.account = n.accountName
        self.facets = facets
    }

    /// Apple Mail result. Subject is primary; sender and extracted summary are
    /// retained for ranking, preview, copying, and exact-message opening.
    init(mail m: MailRecord) {
        self.id = "mail:\(m.rowid)"
        self.source = .mail
        self.name = m.subject
        self.path = ""
        self.kind = m.senderDisplay
        self.size = nil
        self.modified = m.received
        self.lastUsed = m.received
        self.dateAdded = nil
        self.isFolder = false
        self.isApp = false
        self.contentTypes = []
        self.matchKind = .content
        self.messageBody = m.snippet
        self.messageHandle = m.senderAddress
        self.messageFromMe = false
        self.messageChatGUID = nil
        self.messageRowID = nil
        self.noteID = nil
        self.mailMessageID = m.messageID
        var facets = RefinementFacets()
        facets.container = m.mailboxName
        facets.account = m.accountName
        facets.isUnread = m.isUnread
        facets.isFlagged = m.isFlagged
        self.facets = facets
    }

    init(calendar event: CalendarRecord) {
        self.id = "calendar:\(event.identifier)"
        self.source = .calendar
        self.name = event.title
        self.path = event.identifier
        self.kind = event.calendarName
        self.size = nil
        self.modified = event.start
        self.lastUsed = event.start
        self.dateAdded = event.end
        self.isFolder = false
        self.isApp = false
        self.contentTypes = []
        self.matchKind = .content
        self.messageBody = [event.location, event.notes]
            .filter { !$0.isEmpty }
            .joined(separator: "\n")
        self.messageHandle = nil
        self.messageFromMe = false
        self.messageChatGUID = nil
        self.messageRowID = nil
        self.noteID = nil
        self.mailMessageID = nil
        var facets = RefinementFacets()
        facets.container = event.calendarName
        self.facets = facets
    }

    /// Clipboard-history result. `name` is a one-line preview; `messageBody`
    /// holds the full copied text (used for the snippet and copy-back).
    init(clip c: ClipEntry) {
        self.id = "clip:\(c.id)"
        self.source = .clipboard
        let firstLine = c.text.split(whereSeparator: \.isNewline).first.map(String.init) ?? c.text
        self.name = firstLine.trimmingCharacters(in: .whitespaces)
        self.path = ""
        self.kind = c.app ?? "Clipboard"
        self.size = nil
        self.modified = c.date
        self.lastUsed = c.date
        self.dateAdded = nil
        self.isFolder = false
        self.isApp = false
        self.contentTypes = []
        self.matchKind = .content
        self.messageBody = c.text
        self.messageHandle = nil
        self.messageFromMe = false
        self.messageChatGUID = nil
        self.messageRowID = nil
        self.noteID = nil
        self.mailMessageID = nil
        var facets = RefinementFacets()
        facets.contentCategory = Self.clipboardCategory(c.text)
        facets.sourceApp = c.app ?? ""
        self.facets = facets
    }

    /// Browser-history result. `name` is the page title (or URL), `path` holds
    /// the URL (opened on Return), `kind` the browser, `messageBody` the URL for
    /// the subtitle/copy.
    init(history h: HistoryEntry) {
        self.id = "hist:\(h.url)"
        self.source = .history
        self.name = h.title.isEmpty ? h.url : h.title
        self.path = h.url
        self.kind = h.browser
        self.size = nil
        self.modified = h.lastVisit
        self.lastUsed = h.lastVisit
        self.dateAdded = nil
        self.isFolder = false
        self.isApp = false
        self.contentTypes = []
        self.matchKind = .content
        self.messageBody = h.url
        self.messageHandle = nil
        self.messageFromMe = false
        self.messageChatGUID = nil
        self.messageRowID = nil
        self.noteID = nil
        self.mailMessageID = nil
        var facets = RefinementFacets()
        facets.domain = URL(string: h.url)?.host ?? ""
        facets.sourceApp = h.browser
        self.facets = facets
    }

    /// System Settings result.
    init(setting s: SettingRecord) {
        self.id = "setting:\(s.id)"
        self.source = .settings
        self.name = s.title
        self.path = s.url
        self.kind = s.symbol
        self.size = nil
        self.modified = nil
        self.lastUsed = UserDefaults.standard.object(
            forKey: "beacon.setting.lastOpened.\(s.id)"
        ) as? Date
        self.dateAdded = nil
        self.isFolder = false
        self.isApp = false
        self.contentTypes = []
        self.matchKind = .name
        self.messageBody = s.subtitle
        self.messageHandle = nil
        self.messageFromMe = false
        self.messageChatGUID = nil
        self.messageRowID = nil
        self.noteID = nil
        self.mailMessageID = nil
        var facets = RefinementFacets()
        facets.category = s.category
        facets.isFavorite = s.isCommonFavorite
        self.facets = facets
    }

    private static func clipboardCategory(_ text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if URL(string: trimmed)?.scheme != nil { return "url" }
        if trimmed.contains("@"), !trimmed.contains(" ") { return "email" }
        if trimmed.hasPrefix("/") || trimmed.hasPrefix("~/") { return "path" }
        if trimmed.contains("\n"), trimmed.contains("{") || trimmed.contains("=") {
            return "code"
        }
        let digits = trimmed.filter(\.isNumber)
        if digits.count >= 7, digits.count <= 15 { return "phone" }
        return "text"
    }
}

enum ResultSortMode: String, CaseIterable {
    case alphabetical
    case recent
}

private struct BoundedBrowseCacheEntry {
    let rows: [SearchResult]
    let exhausted: Bool
    let readLimit: Int
    let cachedAt: Date
}

private struct SearchViewSnapshot {
    let results: [SearchResult]
    let refinementCandidates: [SearchResult]
    let canLoadMore: Bool
    let capturedAt: Date
}

/// Wraps the Spotlight index via two `NSMetadataQuery` passes:
///   1. a name/path query (fast, few results) and
///   2. a document-contents query (text inside files).
/// Results are merged and ranked client-side so exact name matches always
/// surface above incidental content matches. Queries are debounced.
final class SearchEngine: ObservableObject {
    @Published var queryText: String = "" {
        didSet {
            guard oldValue != queryText else { return }
            cacheViewSnapshot(query: oldValue)
            let key = viewSnapshotKey(
                type: selectedType,
                query: queryText,
                selection: refinementSelection
            )
            if let snapshot = viewSnapshots[key],
               Date().timeIntervalSince(snapshot.capturedAt) < 60 {
                results = displayRows(snapshot.results)
                refinementCandidates = snapshot.refinementCandidates
                canLoadMore = snapshot.canLoadMore
            }
            isShowingStaleResults = !results.isEmpty
            scheduleSearch()
        }
    }
    @Published var selectedType: FileType = .all {
        didSet {
            guard oldValue != selectedType else { return }
            cacheViewSnapshot(
                type: oldValue,
                query: queryText,
                selection: refinementSelection
            )
            refinementSelection = RefinementCatalog.sanitized(
                Self.savedRefinement(for: selectedType),
                dimensions: RefinementLayoutStore.shared.resolvedDimensions(
                    for: selectedType
                )
            )
            pendingIndexPublish?.cancel()
            nameQuery.stop()
            contentQuery.stop()
            contentQueryActive = false
            activeIndexToken = 0
            indexedBrowsePaused = false
            lastIndexedPublishCount = 0
            fileResults = []
            priorityFolderResults = []
            freshRecentResults = []
            scannedAppResults = []
            messageResults = []
            noteResults = []
            mailResults = []
            calendarResults = []
            refinementCandidates = []
            restoreViewSnapshotIfAvailable()
            needsFullDiskAccess = false
            mailNeedsSetup = false
            gmailNeedsSetup = false
            historySafariDenied = false
            scheduleSearch()
        }
    }
    @Published private(set) var results: [SearchResult] = []
    @Published private(set) var isSearching: Bool = false
    @Published private(set) var canLoadMore: Bool = false
    @Published private(set) var isLoadingMore: Bool = false
    @Published private(set) var isShowingStaleResults: Bool = false
    @Published private(set) var refinementSelection = RefinementSelection()
    @Published private(set) var sortMode = ResultSortMode(
        rawValue: UserDefaults.standard.string(forKey: "beacon.resultSortMode") ?? ""
    ) ?? .recent

    /// AI mode: an opt-in agentic layer that searches across sources and returns
    /// locations (result rows), driven by the user's own API key. `aiStatus` is
    /// a live progress line ("Searching Messages…"); `aiRunning` gates the UI.
    @Published var aiMode: Bool = false {
        didSet {
            guard aiMode != oldValue else { return }
            aiRunning = false
            aiStatus = ""
            if aiMode {
                // Entering AI mode: stop any in-flight normal search so its async
                // callbacks can't republish files into the list.
                pendingSearch?.cancel()
                pendingIndexPublish?.cancel()
                nameQuery.stop()
                contentQuery.stop()
                contentQueryActive = false
                searchToken &+= 1
                results = []
                isSearching = false
                needsFullDiskAccess = false
            } else {
                // Leaving AI mode restores the normal live search for the query.
                results = []
                scheduleSearch()
            }
        }
    }
    @Published private(set) var aiStatus: String = ""
    @Published private(set) var aiRunning: Bool = false
    /// Serial queue for the AI agent loop so tool searches don't race the
    /// normal (mode-off) search path, which shares the same store instances.
    private let aiQueue = DispatchQueue(label: "com.beacon.ai", qos: .userInitiated)

    /// When non-nil, Beacon is browsing the immediate contents of this folder
    /// (Finder-style drill-in) instead of running a Spotlight search. Typing
    /// filters the folder's children in memory; navigation is instant.
    @Published private(set) var drillURL: URL?
    private var drillChildren: [SearchResult] = []
    private var drillLoadID = 0
    private let directoryQueue = DispatchQueue(label: "com.beacon.directory", qos: .userInitiated)
    /// Watches the drilled-in folder so its contents stay live. `reloadCurrentView`
    /// no-ops safely if the user has since left drill mode.
    private lazy var drillWatcher = DirectoryWatcher { [weak self] in
        self?.reloadCurrentView()
    }

    var refinementDimensions: [RefinementDimension] {
        if let cachedRefinementDimensions { return cachedRefinementDimensions }
        let dimensions = RefinementCatalog.enriched(
            RefinementLayoutStore.shared.resolvedDimensions(for: selectedType),
            with: refinementCandidates
        )
        cachedRefinementDimensions = dimensions
        return dimensions
    }

    /// True when the Messages filter is active but we can't read the Messages
    /// database because Full Disk Access hasn't been granted.
    @Published private(set) var needsFullDiskAccess: Bool = false
    @Published private(set) var mailNeedsSetup: Bool = false
    @Published private(set) var gmailNeedsSetup: Bool = false
    @Published private(set) var calendarPermission: CalendarPermissionState = .notDetermined

    /// True in the History filter when Safari's history is locked behind Full
    /// Disk Access (other browsers may still have loaded). Drives a slim footer
    /// rather than blocking the whole results list.
    @Published private(set) var historySafariDenied: Bool = false

    /// Bumped by the app delegate to ask the search field to (re)take focus.
    @Published var focusRequestToken: Int = 0

    private var nameQuery = NSMetadataQuery()
    private var contentQuery = NSMetadataQuery()
    private let homePath = NSHomeDirectory()

    private let messageStore = MessageStore()
    private let notesStore = NotesStore()
    private let mailStore = MailStore()
    private let calendarStore = CalendarStore()
    private let historyStore = BrowserHistoryStore()
    private let recentsStore = RecentsStore()
    private let folderStore = FolderStore()
    private let appStore = AppStore()
    private let boundedMetadataStore = BoundedMetadataStore()
    private let settingsStore = SettingsStore()
    private let contacts = ContactResolver()
    private let messageQueue = DispatchQueue(label: "com.beacon.messages", qos: .userInitiated)
    private let notesQueue = DispatchQueue(label: "com.beacon.notes", qos: .userInitiated)
    private let mailQueue = DispatchQueue(label: "com.beacon.mail", qos: .userInitiated)
    private let historyQueue = DispatchQueue(label: "com.beacon.history", qos: .userInitiated)
    private let calendarQueue = DispatchQueue(label: "com.beacon.calendar", qos: .userInitiated)
    private let recentsQueue = DispatchQueue(label: "com.beacon.recents", qos: .userInitiated)
    private let folderQueue = DispatchQueue(label: "com.beacon.folders", qos: .userInitiated)
    private let appQueue = DispatchQueue(label: "com.beacon.apps", qos: .userInitiated)
    private let metadataQueue = DispatchQueue(
        label: "com.beacon.metadata", qos: .userInitiated
    )
    private let priorityMetadataQueue = DispatchQueue(
        label: "com.beacon.metadata.priority", qos: .userInitiated
    )
    private let indexProcessingQueue = DispatchQueue(
        label: "com.beacon.metadata.processing", qos: .userInitiated
    )
    private let facetQueue = DispatchQueue(
        label: "com.beacon.refinement-facets", qos: .utility
    )
    /// Monotonic generation bumped on every scheduled search (query OR filter
    /// change). Async work captures the value and only applies its results if
    /// the token still matches - so stale/superseded searches are dropped.
    private var searchToken = 0

    /// Thread-safe mirror of `searchToken`, readable from the background scan
    /// so an in-flight store search can abort mid-scan the moment it's
    /// superseded. Without this, slow scans (a rare word across a huge
    /// Messages history) pile up on the serial queue, every publish gets
    /// dropped as stale, and the UI wedges on old results until relaunch.
    private let liveToken = SearchGeneration()

    /// Cancellation probe for a store scan started under `token`.
    private func cancellation(for token: Int) -> () -> Bool {
        { [liveToken] in !liveToken.isCurrent(token) }
    }

    private let nameReadCap = 800
    private let contentReadCap = 400
    private let pageSize = SearchPerformancePolicy.pageSize
    private var pageLimit = SearchPerformancePolicy.pageSize
    /// Recents reads deeper than regular searches: it is scoped to the user's
    /// own folders, but a burst of new files (a build, an export) shouldn't
    /// push a fresh download out of the readable window.
    private let recentsReadCap = 1500

    private var fileResults: [SearchResult] = []
    private var priorityFolderResults: [SearchResult] = []
    private var freshRecentResults: [SearchResult] = []
    private var scannedAppResults: [SearchResult] = []
    private var messageResults: [SearchResult] = []
    private var noteResults: [SearchResult] = []
    private var mailResults: [SearchResult] = []
    private var calendarResults: [SearchResult] = []
    private var refinementCandidates: [SearchResult] = [] {
        didSet { cachedRefinementDimensions = nil }
    }
    private var cachedRefinementDimensions: [RefinementDimension]?
    private var recentFileCatalog: [SearchResult] = []
    private var projectDiscoverySignature = ""
    private var boundedBrowseCaches: [String: BoundedBrowseCacheEntry] = [:]
    private var viewSnapshots: [String: SearchViewSnapshot] = [:]

    private let allFileCap = 100
    private let allMessageCap = 12
    private let allNoteCap = 12
    private let allMailCap = 12
    private let allCalendarCap = 12

    private var pagedAllFileCap: Int { max(allFileCap, pageLimit * 65 / 100) }
    private var pagedAllMessageCap: Int { max(allMessageCap, pageLimit * 8 / 100) }
    private var pagedAllNoteCap: Int { max(allNoteCap, pageLimit * 8 / 100) }
    private var pagedAllMailCap: Int {
        max(allMailCap, pageLimit * 8 / 100)
    }
    private var pagedAllCalendarCap: Int {
        max(allCalendarCap, pageLimit - pagedAllFileCap - pagedAllMessageCap
            - pagedAllNoteCap - pagedAllMailCap)
    }
    private var allRefinementIsFileScoped: Bool {
        refinementSelection.optionID(for: "location") != nil
            || ["files", "folders", "apps", "images", "pdfs"].contains(
                refinementSelection.optionID(for: "kind")
            )
    }
    private var isBrowsing: Bool {
        queryText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
    private var effectiveAllFileCap: Int {
        isBrowsing ? pageLimit : (allRefinementIsFileScoped ? pageLimit : pagedAllFileCap)
    }
    private var effectiveAllMessageCap: Int {
        if isBrowsing { return pageLimit }
        return refinementSelection.optionID(for: "kind") == "messages"
            ? pageLimit : pagedAllMessageCap
    }
    private var effectiveAllNoteCap: Int {
        if isBrowsing { return pageLimit }
        return refinementSelection.optionID(for: "kind") == "notes"
            ? pageLimit : pagedAllNoteCap
    }
    private var effectiveAllMailCap: Int {
        if isBrowsing { return pageLimit }
        return refinementSelection.optionID(for: "kind") == "mail"
            ? pageLimit : pagedAllMailCap
    }
    private var effectiveAllCalendarCap: Int {
        isBrowsing ? pageLimit : pagedAllCalendarCap
    }

    private var pendingSearch: DispatchWorkItem?
    private var currentTokens: [String] = []
    private var activeIndexToken = 0
    private var indexedBrowsePaused = false
    private var lastIndexedPublishCount = 0
    private var pendingIndexPublish: DispatchWorkItem?
    private var lastIndexPublishAt = Date.distantPast
    private var indexProcessingGeneration = 0
    private var allIncludedTypes = Set(FileType.allCases.filter(\.includedInAll))

    /// Content search (text inside files) only kicks in once the query is long
    /// enough to be meaningful; 1-2 characters would drown the list in noise
    /// and slow the query down. Name search still runs from the first character.
    private let contentMinQueryLength = 3
    /// Whether the content query was started for the current search. When it
    /// wasn't, its stale results from a previous search must not be read.
    private var contentQueryActive = false

    /// Applies the user's visible filter selection to the blended All view.
    /// Hidden filters stop contributing immediately.
    func updateAllIncludedTypes(_ types: Set<FileType>) {
        guard allIncludedTypes != types else { return }
        allIncludedTypes = types
        if selectedType == .all { scheduleSearch() }
    }

    func selectRefinement(dimensionID: String, optionID: String?) {
        var updated = refinementSelection
        if let optionID {
            updated.choices[dimensionID] = optionID
        } else {
            updated.choices.removeValue(forKey: dimensionID)
        }
        updated = RefinementCatalog.sanitized(updated, for: selectedType)
        guard updated != refinementSelection else { return }
        refinementSelection = updated
        Self.saveRefinement(updated, for: selectedType)
        results = results.filter {
            RefinementMatcher.matches($0, type: selectedType, selection: updated)
        }
        scheduleSearch()
    }

    func clearRefinements() {
        guard !refinementSelection.isEmpty else { return }
        refinementSelection = RefinementSelection()
        Self.saveRefinement(refinementSelection, for: selectedType)
        scheduleSearch()
    }

    func refinementLayoutChanged() {
        cachedRefinementDimensions = nil
        let updated = RefinementCatalog.sanitized(
            refinementSelection,
            dimensions: RefinementLayoutStore.shared.resolvedDimensions(
                for: selectedType
            )
        )
        if updated != refinementSelection {
            refinementSelection = updated
            Self.saveRefinement(updated, for: selectedType)
            scheduleSearch()
        } else {
            objectWillChange.send()
        }
    }

    func selectSortMode(_ mode: ResultSortMode) {
        guard sortMode != mode else { return }
        sortMode = mode
        UserDefaults.standard.set(mode.rawValue, forKey: "beacon.resultSortMode")
        if currentTokens.isEmpty || mode == .alphabetical {
            results = sortedForDisplay(results)
        } else {
            // Switching back to Recent mid-query: rebuild rank order, since
            // the visible rows were just alphabetized.
            results = results
                .map { (result: $0, score: score($0)) }
                .sorted(by: rankedResultPrecedes)
                .map(\.result)
        }
    }

    private static func savedRefinement(for type: FileType) -> RefinementSelection {
        let key = "beacon.refinement.\(type.rawValue)"
        guard let data = UserDefaults.standard.data(forKey: key),
              let decoded = try? JSONDecoder().decode(RefinementSelection.self, from: data) else {
            return RefinementSelection()
        }
        return RefinementCatalog.sanitized(decoded, for: type)
    }

    private static func saveRefinement(_ selection: RefinementSelection, for type: FileType) {
        let key = "beacon.refinement.\(type.rawValue)"
        if selection.isEmpty {
            UserDefaults.standard.removeObject(forKey: key)
        } else if let data = try? JSONEncoder().encode(selection) {
            UserDefaults.standard.set(data, forKey: key)
        }
    }

    private func viewSnapshotKey(type: FileType, query: String,
                                 selection: RefinementSelection) -> String {
        let choices = selection.choices.sorted {
            $0.key == $1.key ? $0.value < $1.value : $0.key < $1.key
        }
        return type.rawValue
            + "|" + query.trimmingCharacters(in: .whitespacesAndNewlines).searchFolded
            + "|" + choices.map { "\($0.key)=\($0.value)" }.joined(separator: "&")
    }

    private func cacheViewSnapshot(type: FileType? = nil,
                                   query: String? = nil,
                                   selection: RefinementSelection? = nil) {
        guard !results.isEmpty else { return }
        let key = viewSnapshotKey(
            type: type ?? selectedType,
            query: query ?? queryText,
            selection: selection ?? refinementSelection
        )
        viewSnapshots[key] = SearchViewSnapshot(
            results: results,
            refinementCandidates: refinementCandidates,
            canLoadMore: canLoadMore,
            capturedAt: Date()
        )
        if viewSnapshots.count > 24,
           let oldest = viewSnapshots.min(by: {
               $0.value.capturedAt < $1.value.capturedAt
           })?.key {
            viewSnapshots.removeValue(forKey: oldest)
        }
    }

    private func restoreViewSnapshotIfAvailable() {
        // AI mode owns `results` via aiPublish only. Restoring a cached snapshot
        // of a prior normal search (e.g. recents) would leak file/app rows into
        // the AI results area mid-run.
        if aiMode { return }
        let key = viewSnapshotKey(
            type: selectedType,
            query: queryText,
            selection: refinementSelection
        )
        guard let snapshot = viewSnapshots[key],
              Date().timeIntervalSince(snapshot.capturedAt) < 60 else {
            results = []
            canLoadMore = false
            isShowingStaleResults = false
            return
        }
        results = displayRows(snapshot.results)
        refinementCandidates = snapshot.refinementCandidates
        canLoadMore = snapshot.canLoadMore
        isShowingStaleResults = true
    }

    private func sourceReadLimit(cap: Int) -> Int {
        let base = pageLimit + 1
        guard !refinementSelection.isEmpty else { return base }
        return min(cap, max(base, pageLimit * 4))
    }

    private static let defaultSortDescriptors = [
        NSSortDescriptor(key: NSMetadataItemLastUsedDateKey, ascending: false),
        NSSortDescriptor(key: NSMetadataItemFSContentChangeDateKey, ascending: false)
    ]

    init() {
        refinementSelection = RefinementCatalog.sanitized(
            Self.savedRefinement(for: selectedType),
            dimensions: RefinementLayoutStore.shared.resolvedDimensions(
                for: selectedType
            )
        )
        calendarPermission = calendarStore.permissionState
        configureIndexQuery(nameQuery)
        configureIndexQuery(contentQuery)

        let center = NotificationCenter.default
        for name in [
            Notification.Name.NSMetadataQueryDidFinishGathering,
            Notification.Name.NSMetadataQueryGatheringProgress,
            Notification.Name.NSMetadataQueryDidUpdate
        ] {
            center.addObserver(self, selector: #selector(queryUpdated),
                               name: name, object: nil)
        }
        folderQueue.async { [folderStore] in
            folderStore.prepare()
        }
    }

    private func configureIndexQuery(_ query: NSMetadataQuery) {
        query.searchScopes = [NSMetadataQueryLocalComputerScope]
        query.sortDescriptors = Self.defaultSortDescriptors
        query.notificationBatchingInterval = 0.2
    }

    private func replaceIndexQueries() {
        nameQuery.stop()
        contentQuery.stop()
        nameQuery = NSMetadataQuery()
        contentQuery = NSMetadataQuery()
        configureIndexQuery(nameQuery)
        configureIndexQuery(contentQuery)
    }

    deinit {
        nameQuery.stop()
        contentQuery.stop()
        NotificationCenter.default.removeObserver(self)
    }

    // MARK: - Search lifecycle

    private func publishPage(_ rows: [SearchResult], preserveCandidates: Bool = false) {
        if aiMode { return }   // AI mode owns `results` via aiPublish only
        let scoped = rows.filter { matchesTopLevelType($0, type: selectedType) }
        if !preserveCandidates {
            refinementCandidates = scoped
            discoverProjectFacetsIfNeeded(in: scoped)
        }
        let refined = scoped.filter {
            RefinementMatcher.matches($0, type: selectedType,
                                      selection: refinementSelection)
        }
        let page: (rows: [SearchResult], hasMore: Bool)
        if currentTokens.isEmpty {
            page = PageWindow.slice(sortedForDisplay(refined), limit: pageLimit)
        } else {
            page = PageWindow.slice(refined, limit: pageLimit)
        }
        let visibleRows = displayRows(page.rows)
        canLoadMore = page.hasMore
        if results != visibleRows {
            results = visibleRows
        }
        isShowingStaleResults = false
        isSearching = false
        isLoadingMore = false
        cacheViewSnapshot()
    }

    private func discoverProjectFacetsIfNeeded(in rows: [SearchResult]) {
        guard selectedType == .folders,
              RefinementLayoutStore.shared.layout(for: .folders)
                .dimensionIDs.contains("project") else { return }
        let candidates = Array(rows.lazy.filter(\.isFolder).prefix(800))
        var pathHasher = Hasher()
        for row in candidates { pathHasher.combine(row.path) }
        let signature = "\(searchToken):\(candidates.count):\(pathHasher.finalize())"
        guard signature != projectDiscoverySignature else { return }
        projectDiscoverySignature = signature
        let token = searchToken

        facetQueue.async { [weak self] in
            let discovered = candidates.compactMap { row -> (String, String)? in
                guard let category = RefinementFacetBuilder.projectCategory(
                    at: row.path
                ) else { return nil }
                return (row.id, category)
            }
            DispatchQueue.main.async {
                guard let self, self.searchToken == token,
                      self.selectedType == .folders else { return }
                let categories = Dictionary(discovered,
                                            uniquingKeysWith: { first, _ in first })
                guard !categories.isEmpty else {
                    self.objectWillChange.send()
                    return
                }
                self.refinementCandidates = self.refinementCandidates.map { row in
                    guard let category = categories[row.id] else { return row }
                    var updated = row
                    updated.facets.isProject = true
                    updated.facets.category = category
                    return updated
                }
                self.objectWillChange.send()
            }
        }
    }

    private func sortedForDisplay(_ rows: [SearchResult]) -> [SearchResult] {
        rows.sorted {
            switch sortMode {
            case .alphabetical:
                let order = $0.name.localizedStandardCompare($1.name)
                if order != .orderedSame { return order == .orderedAscending }
                return $0.effectiveRecency > $1.effectiveRecency
            case .recent:
                if $0.effectiveRecency != $1.effectiveRecency {
                    return $0.effectiveRecency > $1.effectiveRecency
                }
                return $0.name.localizedStandardCompare($1.name) == .orderedAscending
            }
        }
    }

    /// With a query, upstream rank order (match quality first, recency as
    /// tie-break) IS the display order — an exact name match must never sink
    /// below a substring match that happens to have been touched today.
    /// Browsing (no tokens) and an explicit A-Z sort use plain display sorting.
    private func displayRows(_ rows: [SearchResult]) -> [SearchResult] {
        if currentTokens.isEmpty || sortMode == .alphabetical {
            return sortedForDisplay(rows)
        }
        return rows
    }

    private func relevancePreservingPage(_ rows: [SearchResult],
                                         limit: Int) -> [SearchResult] {
        guard !currentTokens.isEmpty else {
            return Array(sortedForDisplay(rows).prefix(limit))
        }
        return displayRows(Array(rows.prefix(limit)))
    }

    private func scheduleSearch() {
        // AI mode doesn't search per keystroke — it runs on submit (Send/Enter)
        // via runAIQuery. Suppress the normal live search, and clear any stale
        // normal results so the panel never looks like a normal search.
        if aiMode {
            isSearching = false
            if !aiRunning { results = [] }
            return
        }
        pendingSearch?.cancel()
        pendingIndexPublish?.cancel()
        pageLimit = pageSize
        canLoadMore = false
        isLoadingMore = false
        // Bump the generation up front so any in-flight async search is
        // invalidated immediately (the moment the query or filter changes).
        // Mirroring into `liveToken` lets background scans abort mid-loop.
        searchToken &+= 1
        liveToken.set(searchToken)
        let token = searchToken
        let trimmed = queryText.trimmingCharacters(in: .whitespacesAndNewlines)
        isShowingStaleResults = !results.isEmpty

        // Drilled into a folder: filter its already-loaded children in memory.
        if drillURL != nil {
            nameQuery.stop()
            contentQuery.stop()
            contentQueryActive = false
            currentTokens = trimmed.isEmpty ? [] : SearchText.tokens(trimmed)
            applyDrillResults()
            return
        }

        if trimmed.isEmpty {
            nameQuery.stop()
            contentQuery.stop()
            contentQueryActive = false
            activeIndexToken = 0
            currentTokens = []
            fileResults = []
            priorityFolderResults = []
            freshRecentResults = []
            scannedAppResults = []
            messageResults = []
            noteResults = []
            mailResults = []
            calendarResults = []
            isSearching = true
            runSearch(term: "", token: token)
            if selectedType.needsFullDiskAccess { checkDatabaseAccess() }
            return
        }

        freshRecentResults = []
        // Show the searching state right away so a just-cleared list doesn't
        // flash "No results" during the debounce window.
        isSearching = true

        let work = DispatchWorkItem { [weak self] in
            self?.runSearch(term: trimmed, token: token)
        }
        pendingSearch = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12, execute: work)
    }

    func loadMore() {
        guard canLoadMore, !isLoadingMore else { return }
        pageLimit += pageSize
        isLoadingMore = true
        canLoadMore = false
        if drillURL != nil {
            applyDrillResults()
            return
        }
        let token = searchToken
        let trimmed = queryText.trimmingCharacters(in: .whitespacesAndNewlines)

        if trimmed.isEmpty, selectedType == .all, refinementSelection.isEmpty {
            searchUniversalRecents(token: token)
            return
        }
        if trimmed.isEmpty, selectedType.usesFileIndex,
           refinementSelection.isEmpty {
            // The browse query is kept alive (paused only suppresses tick
            // processing), so the next page reads straight from the gathered
            // results — never restart the gather, which used to cost seconds
            // of re-scanning per page.
            indexedBrowsePaused = false
            publishIndexResults()
            return
        }
        if trimmed.isEmpty, selectedType.usesFileIndex {
            searchExpandedFileBrowse(type: selectedType, token: token)
            return
        }

        if selectedType.usesFileIndex {
            publishIndexResults()
            if selectedType == .all {
                if allIncludedTypes.contains(.apps) {
                    gatherAppsForAll(tokens: currentTokens, token: token)
                }
                if allIncludedTypes.contains(.messages)
                    || allIncludedTypes.contains(.notes)
                    || allIncludedTypes.contains(.mail) {
                    gatherDatabasesForAll(tokens: currentTokens, token: token)
                }
                if allIncludedTypes.contains(.calendar) {
                    gatherCalendarForAll(tokens: currentTokens, token: token)
                }
            }
            return
        }

        if trimmed.isEmpty {
            if selectedType.isClipboard {
                publishPage(
                    ClipboardStore.shared.recent(limit: pageLimit + 1)
                        .map { SearchResult(clip: $0) }
                )
            } else if selectedType.isHistory {
                searchHistory(tokens: [], token: token)
            } else if selectedType.isRecents {
                searchRecents(tokens: [], token: token)
            } else if selectedType.isApps {
                searchApps(tokens: [], token: token)
            } else if selectedType.isMessages {
                searchMessages(tokens: [], token: token)
            } else if selectedType.isNotes {
                searchNotes(tokens: [], token: token)
            } else if selectedType.isMail {
                searchMail(tokens: [], token: token)
            } else if selectedType.isGmail {
                searchGmail(tokens: [], token: token)
            } else if selectedType.isCalendar {
                searchCalendar(tokens: [], token: token)
            } else {
                isLoadingMore = false
            }
            return
        }
        runSearch(term: trimmed, token: token)
    }

    // MARK: - Folder drill-in

    /// Browse the immediate contents of `url` inside Beacon (Finder-style),
    /// instead of searching. Enumerates children off the main thread, then
    /// publishes them; typing afterward filters this folder in memory.
    func enterDirectory(_ url: URL) {
        let std = url.standardizedFileURL
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: std.path, isDirectory: &isDir),
              isDir.boolValue else { return }

        nameQuery.stop()
        contentQuery.stop()
        contentQueryActive = false
        drillURL = std
        drillChildren = []
        drillLoadID &+= 1
        let loadID = drillLoadID
        pageLimit = pageSize
        currentTokens = []
        canLoadMore = false
        isLoadingMore = false
        isSearching = true
        // Clear any filter text. If it was already empty the didSet won't fire,
        // so we've already reset the drill state above either way.
        if !queryText.isEmpty { queryText = "" }
        results = []

        // Keep the drilled view live: a file dropped/saved into this folder
        // shows up without reopening the panel. Coalesced + off the main thread.
        drillWatcher.watch(std)

        directoryQueue.async { [weak self] in
            let kids = SearchEngine.enumerateDirectory(std)
            DispatchQueue.main.async {
                guard let self, self.drillLoadID == loadID, self.drillURL == std else { return }
                self.drillChildren = kids
                self.applyDrillResults()
            }
        }
    }

    /// Go up one level from the current drilled folder.
    func browseUp() {
        guard let current = drillURL else { return }
        let parent = current.deletingLastPathComponent().standardizedFileURL
        guard parent.path != current.path else { return }
        enterDirectory(parent)
    }

    /// Leave drill-in mode and return to normal search/browse.
    func exitDrill() {
        guard drillURL != nil else { return }
        drillWatcher.stop()
        drillURL = nil
        drillChildren = []
        drillLoadID &+= 1
        scheduleSearch()
    }

    /// Re-read the current view after a file operation (e.g. a drop) so moved
    /// items appear/disappear. Preserves the current filter text and drill mode.
    func reloadCurrentView() {
        if let url = drillURL {
            drillLoadID &+= 1
            let loadID = drillLoadID
            directoryQueue.async { [weak self] in
                let kids = SearchEngine.enumerateDirectory(url)
                DispatchQueue.main.async {
                    guard let self, self.drillLoadID == loadID, self.drillURL == url else { return }
                    self.drillChildren = kids
                    self.applyDrillResults()
                }
            }
        } else {
            refreshForPanelShow()
        }
    }

    // MARK: - AI mode

    /// Run one source's search synchronously and map to SearchResult rows. Called
    /// off the main thread by the AI conductor (on `aiQueue`). This is the bridge
    /// the AI layer uses to reach Beacon's otherwise-private stores.
    func aiToolSearch(_ source: AISource, tokens: [String], limit: Int) -> [SearchResult] {
        guard !tokens.isEmpty else { return [] }
        switch source {
        case .messages:
            // MessageStore isn't internally synchronized — it's meant to be
            // touched only from messageQueue. This runs on aiQueue, and the
            // launch-time warm-up loads on messageQueue, so serialize here to
            // avoid racing that load. Also: the store is lazy, so ensureLoaded()
            // is required or the first AI message search hits `guard state ==
            // .ready` and silently returns nothing (the agent then reports it
            // couldn't find any messages).
            return messageQueue.sync {
                messageStore.ensureLoaded()
                contacts.ensureLoaded()
                guard !messageStore.needsFullDiskAccess else { return [] }
                let resolver: ((String) -> String?)? = contacts.isReady ? { self.contacts.name(for: $0) } : nil
                return messageStore.search(tokens: tokens, limit: limit, nameResolver: resolver)
                    .map { SearchResult(message: $0, contactName: self.contacts.name(for: $0.conversationHandle)) }
            }
        case .mail:
            return mailStore.search(tokens: tokens, limit: limit).map { SearchResult(mail: $0) }
        case .notes:
            return notesStore.search(tokens: tokens, limit: limit).map { SearchResult(note: $0) }
        case .calendar:
            return calendarStore.search(tokens: tokens, limit: limit).map { SearchResult(calendar: $0) }
        case .history:
            return historyStore.search(tokens: tokens, limit: limit).map { SearchResult(history: $0) }
        case .clipboard:
            return ClipboardStore.shared.search(tokens: tokens, limit: limit).map { SearchResult(clip: $0) }
        case .apps:
            return (appStore.search(tokens: tokens, limit: limit) ?? []).map { SearchResult(app: $0) }
        case .folders:
            return folderStore.search(tokens: tokens, limit: limit).map { SearchResult(folder: $0) }
        case .files:
            // v1: recent files (synchronous). Full Spotlight file search is a
            // follow-up (NSMetadataQuery is async / MDQuery is the sync upgrade).
            return recentsStore.search(tokens: tokens, limit: limit).map { SearchResult(recent: $0) }
        }
    }

    /// The conversation surrounding one message result, oldest→newest. Lets the
    /// AI *read a thread* the way the user would after tapping a hit — crucial
    /// because the message that actually answers a query (e.g. a raw email +
    /// password) often contains none of the search keywords and is only findable
    /// as the neighbour of a message that does. Runs on messageQueue for the
    /// same thread-safety reasons as `aiToolSearch`.
    func aiThreadContext(around rowid: Int64, radius: Int = 12) -> [SearchResult] {
        return messageQueue.sync {
            messageStore.ensureLoaded()
            contacts.ensureLoaded()
            guard !messageStore.needsFullDiskAccess else { return [] }
            return messageStore.context(around: rowid, radius: radius)
                .map { SearchResult(message: $0, contactName: self.contacts.name(for: $0.conversationHandle)) }
        }
    }

    func aiSetStatus(_ text: String) {
        DispatchQueue.main.async { self.aiStatus = text }
    }

    /// Return the enabled sources the AI can actually search right now, dropping
    /// any FDA-gated source (Messages/Mail/Notes) whose access hasn't been
    /// granted. A single locked source no longer walls the whole query — the AI
    /// searches the rest. Only when *every* enabled source is blocked do we
    /// surface the Full Disk Access prompt. Runs on aiQueue.
    func aiUsableSources(_ sources: [AISource]) -> [AISource] {
        var blocked: Set<AISource> = []
        if sources.contains(.messages) { _ = messageStore.probeAccess(); if messageStore.needsFullDiskAccess { blocked.insert(.messages) } }
        if sources.contains(.mail) { mailStore.ensureLoaded(); if mailStore.needsFullDiskAccess { blocked.insert(.mail) } }
        if sources.contains(.notes) { notesStore.ensureLoaded(); if notesStore.needsFullDiskAccess { blocked.insert(.notes) } }
        let usable = sources.filter { !blocked.contains($0) }
        let allBlocked = usable.isEmpty && !blocked.isEmpty
        DispatchQueue.main.async {
            self.needsFullDiskAccess = allBlocked
            if allBlocked, let url = URL(string:
                "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles") {
                NSWorkspace.shared.open(url)
            }
        }
        return usable
    }

    /// Publish the AI-chosen locations, preserving the agent's ranking order
    /// (no relevance re-sort, unlike normal search).
    func aiPublish(_ rows: [SearchResult]) {
        DispatchQueue.main.async {
            var seen = Set<String>()
            let deduped = rows.filter { seen.insert($0.id).inserted }
            self.aiRunning = false
            self.isSearching = false
            self.canLoadMore = false
            self.isShowingStaleResults = false
            self.results = deduped
        }
    }

    /// Entry point for an AI-mode query. Delegates to the conductor, which drives
    /// the provider's agentic loop and calls back into aiToolSearch / aiPublish.
    func runAIQuery(_ query: String) {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        aiRunning = true
        aiStatus = "Thinking…"
        isSearching = true
        results = []
        aiQueue.async { [weak self] in
            guard let self else { return }
            AIConductor.run(query: trimmed, engine: self)
        }
    }

    /// Filter the loaded children by the current tokens and publish a page.
    private func applyDrillResults() {
        if aiMode { return }   // AI mode owns `results` via aiPublish only
        let tokens = currentTokens
        let rows: [SearchResult]
        if tokens.isEmpty {
            rows = drillChildren            // already folder-first, name-sorted
        } else {
            rows = drillChildren
                .compactMap { child -> (SearchResult, SearchText.MatchQuality)? in
                    guard let quality = SearchText.matchQuality(child.name.searchFolded,
                                                                tokens: tokens) else { return nil }
                    return (child, quality)
                }
                .sorted { lhs, rhs in
                    if lhs.1 != rhs.1 { return lhs.1 < rhs.1 }
                    if lhs.0.isFolder != rhs.0.isFolder { return lhs.0.isFolder }
                    return lhs.0.name.localizedStandardCompare(rhs.0.name) == .orderedAscending
                }
                .map { $0.0 }
        }
        let page = Array(rows.prefix(pageLimit))
        canLoadMore = rows.count > page.count
        isLoadingMore = false
        isSearching = false
        isShowingStaleResults = false
        results = page
    }

    /// Immediate children of a directory as SearchResults, folders first then
    /// name-sorted (Finder's default). Hidden files are skipped.
    private static func enumerateDirectory(_ url: URL) -> [SearchResult] {
        let keys: Set<URLResourceKey> = [
            .isDirectoryKey, .fileSizeKey, .contentModificationDateKey,
            .contentTypeKey, .addedToDirectoryDateKey, .localizedNameKey, .isApplicationKey
        ]
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(
            at: url, includingPropertiesForKeys: Array(keys), options: [.skipsHiddenFiles]
        ) else { return [] }

        var rows: [SearchResult] = []
        rows.reserveCapacity(entries.count)
        for entry in entries {
            let values = try? entry.resourceValues(forKeys: keys)
            let isDir = values?.isDirectory ?? false
            let isApp = values?.isApplication ?? false
            let contentType = values?.contentType
            let size = isDir ? nil : (values?.fileSize).map(Int64.init)
            let name = values?.localizedName ?? entry.lastPathComponent
            let kind = isDir
                ? "Folder"
                : (contentType?.localizedDescription ?? entry.pathExtension.uppercased())
            let path = entry.standardizedFileURL.path
            rows.append(SearchResult(
                id: path, name: name, path: path, kind: kind, size: size,
                modified: values?.contentModificationDate, lastUsed: nil,
                dateAdded: values?.addedToDirectoryDate,
                isFolder: isDir, isApp: isApp,
                contentTypes: contentType.map { [$0.identifier] } ?? [],
                matchKind: .name))
        }
        rows.sort { lhs, rhs in
            if lhs.isFolder != rhs.isFolder { return lhs.isFolder }
            return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
        }
        return rows
    }

    private func runSearch(term: String, token: Int) {
        guard token == searchToken else { return }
        isSearching = true
        currentTokens = SearchText.tokens(term)

        if selectedType == .all, currentTokens.isEmpty, refinementSelection.isEmpty {
            searchUniversalRecents(token: token)
            return
        }
        if selectedType.usesFileIndex, currentTokens.isEmpty,
           refinementSelection.isEmpty {
            searchIndexedBrowse(type: selectedType, token: token)
            return
        }
        if selectedType.usesFileIndex, currentTokens.isEmpty {
            searchExpandedFileBrowse(type: selectedType, token: token)
            return
        }

        if selectedType.isMessages, currentTokens.isEmpty {
            nameQuery.stop()
            contentQuery.stop()
            contentQueryActive = false
            activeIndexToken = 0
            canLoadMore = false
            isLoadingMore = false
            results = []
            isShowingStaleResults = false
            isSearching = false
            return
        }
        if selectedType.isMessages {
            searchMessages(tokens: currentTokens, token: token)
            return
        }
        if selectedType.isNotes {
            searchNotes(tokens: currentTokens, token: token)
            return
        }
        if selectedType.isMail {
            searchMail(tokens: currentTokens, token: token)
            return
        }
        if selectedType.isGmail {
            searchGmail(tokens: currentTokens, token: token)
            return
        }
        if selectedType.isCalendar {
            searchCalendar(tokens: currentTokens, token: token)
            return
        }
        if selectedType.isClipboard {
            searchClipboard(tokens: currentTokens)
            return
        }
        if selectedType.isHistory {
            searchHistory(tokens: currentTokens, token: token)
            return
        }
        if selectedType.isRecents {
            needsFullDiskAccess = false
            searchRecents(tokens: currentTokens, token: token)
            return
        }
        if selectedType.isApps {
            needsFullDiskAccess = false
            searchApps(tokens: currentTokens, token: token)
            return
        }
        if selectedType.isSettings {
            nameQuery.stop()
            contentQuery.stop()
            contentQueryActive = false
            needsFullDiskAccess = false
            publishPage(
                settingsStore.search(tokens: currentTokens).map { SearchResult(setting: $0) }
            )
            return
        }
        needsFullDiskAccess = false

        let scope = indexScope(for: selectedType)

        replaceIndexQueries()
        priorityFolderResults = []
        indexedBrowsePaused = false
        lastIndexedPublishCount = 0
        contentQueryActive = term.count >= contentMinQueryLength
        if scope.searchFiles {
            activeIndexToken = token
            nameQuery.searchScopes = [NSMetadataQueryLocalComputerScope]
            nameQuery.sortDescriptors = Self.defaultSortDescriptors
            nameQuery.predicate = namePredicate(
                tokens: currentTokens, trees: scope.trees,
                extensions: scope.extensions, pathPrefixes: scope.pathPrefixes,
                excludedTrees: scope.excludedTrees
            )
            nameQuery.start()

            if contentQueryActive {
                contentQuery.searchScopes = [NSMetadataQueryLocalComputerScope]
                contentQuery.sortDescriptors = Self.defaultSortDescriptors
                contentQuery.predicate = contentPredicate(
                    tokens: currentTokens, trees: scope.trees,
                    extensions: scope.extensions, pathPrefixes: scope.pathPrefixes,
                    excludedTrees: scope.excludedTrees
                )
                contentQuery.start()
            }
            if selectedType == .all || selectedType == .folders {
                gatherPriorityFolders(tokens: currentTokens, token: token)
            }
        } else {
            activeIndexToken = 0
            fileResults = []
            priorityFolderResults = []
        }

        // In "All" mode, also fold in (best-effort) messages and notes. Clear
        // the prior buckets so stale rows don't linger until the gather lands.
        scannedAppResults = []
        messageResults = []
        noteResults = []
        mailResults = []
        calendarResults = []
        if selectedType == .all {
            if allIncludedTypes.contains(.apps) {
                gatherAppsForAll(tokens: currentTokens, token: token)
            }
            if allIncludedTypes.contains(.messages)
                || allIncludedTypes.contains(.notes)
                || allIncludedTypes.contains(.mail) {
                gatherDatabasesForAll(tokens: currentTokens, token: token)
            }
            if allIncludedTypes.contains(.calendar) {
                gatherCalendarForAll(tokens: currentTokens, token: token)
            }
        }
    }

    private func indexScope(for type: FileType) -> (
        trees: [String], extensions: [String], pathPrefixes: [String],
        excludedTrees: [String], searchFiles: Bool
    ) {
        var trees = type.contentTypeTrees
        var extensions = type.filenameExtensions
        var paths = type.pathPrefixes
        var excluded: [String] = []
        var searchFiles = true

        if type == .docs {
            trees = []
            extensions = Array(enabledDocumentExtensions()).sorted()
        }

        if let refinedPaths = refinementPathPrefixes(), !refinedPaths.isEmpty {
            paths = refinedPaths
        }

        if type == .all, let kind = refinementSelection.optionID(for: "kind") {
            switch kind {
            case "folders": trees = ["public.folder"]
            case "apps": trees = ["com.apple.application"]
            case "images": trees = ["public.image"]
            case "pdfs": trees = ["com.adobe.pdf"]
            case "files":
                trees = []
                excluded = ["public.folder", "com.apple.application"]
            case "messages", "notes", "mail":
                searchFiles = false
            default: break
            }
            extensions = []
        }
        return (trees, extensions, paths, excluded, searchFiles)
    }

    private func refinementPathPrefixes() -> [String]? {
        let home = NSHomeDirectory()
        let option = refinementSelection.optionID(for: "location")
            ?? refinementSelection.optionID(for: "photo-source")
        switch option {
        case "home": return [home]
        case "desktop":
            return [home + "/Desktop",
                    home + "/Library/Mobile Documents/com~apple~CloudDocs/Desktop"]
        case "downloads":
            return [home + "/Downloads",
                    home + "/Library/Mobile Documents/com~apple~CloudDocs/Downloads"]
        case "documents":
            return [home + "/Documents",
                    home + "/Library/Mobile Documents/com~apple~CloudDocs/Documents"]
        case "movies": return [home + "/Movies"]
        case "screenshots":
            return RecentsStore.screenshotRoots(home: home)
        case "photos-library":
            return [home + "/Pictures/Photos Library.photoslibrary"]
        default: return nil
        }
    }

    private func searchUniversalRecents(token: Int) {
        replaceIndexQueries()
        contentQueryActive = false
        activeIndexToken = token
        currentTokens = []
        let cutoff = Date(timeIntervalSinceNow: -30 * 86_400)
        nameQuery.searchScopes = [homePath]
        nameQuery.sortDescriptors = Self.defaultSortDescriptors
        nameQuery.predicate = NSCompoundPredicate(orPredicateWithSubpredicates: [
            NSPredicate(format: "kMDItemLastUsedDate >= %@", cutoff as NSDate),
            NSPredicate(format: "kMDItemFSContentChangeDate >= %@", cutoff as NSDate),
            NSPredicate(format: "kMDItemDateAdded >= %@", cutoff as NSDate)
        ])
        nameQuery.start()
        gatherFreshRecents(token: token)

        if allIncludedTypes.contains(.apps) {
            gatherAppsForAll(tokens: [], token: token)
        }

    }

    private func gatherFreshRecents(token: Int) {
        recentsQueue.async { [weak self] in
            guard let self else { return }
            let rows = self.recentsStore.freshItems(
                isCancelled: self.cancellation(for: token)
            ).map { SearchResult(recent: $0) }
            DispatchQueue.main.async {
                guard token == self.searchToken, self.selectedType == .all,
                      self.currentTokens.isEmpty else { return }
                self.freshRecentResults = rows
                var byPath = Dictionary(
                    self.fileResults.map { ($0.path, $0) },
                    uniquingKeysWith: { $0.enriched(with: $1) }
                )
                for row in rows {
                    byPath[row.path] = byPath[row.path]?
                        .enriched(with: row) ?? row
                }
                self.fileResults = byPath.values
                    .sorted {
                        if $0.effectiveRecency != $1.effectiveRecency {
                            return $0.effectiveRecency > $1.effectiveRecency
                        }
                        return $0.name.localizedStandardCompare($1.name)
                            == .orderedAscending
                    }
                self.publish()
                if !rows.isEmpty { self.isSearching = false }
            }
        }
    }

    private func searchIndexedBrowse(type: FileType, token: Int) {
        replaceIndexQueries()
        contentQueryActive = false
        currentTokens = []
        indexedBrowsePaused = false
        lastIndexedPublishCount = 0
        let scope = indexScope(for: type)
        guard scope.searchFiles else {
            activeIndexToken = 0
            publishPage([])
            return
        }
        activeIndexToken = token
        nameQuery.searchScopes = [NSMetadataQueryLocalComputerScope]
        nameQuery.sortDescriptors = Self.defaultSortDescriptors
        nameQuery.predicate = namePredicate(
            tokens: [],
            trees: scope.trees,
            extensions: scope.extensions,
            pathPrefixes: scope.pathPrefixes,
            excludedTrees: scope.excludedTrees
        )
        nameQuery.start()
        gatherFreshBrowse(type: type, token: token)
    }

    private func gatherFreshBrowse(type: FileType, token: Int) {
        recentsQueue.async { [weak self] in
            guard let self else { return }
            let rows = self.recentsStore.freshItems(
                isCancelled: self.cancellation(for: token)
            )
            .map { SearchResult(recent: $0) }
            .filter { self.matchesTopLevelType($0, type: type) }

            DispatchQueue.main.async {
                guard token == self.searchToken, self.selectedType == type,
                      self.currentTokens.isEmpty else { return }
                var byPath = Dictionary(
                    self.fileResults.map { ($0.path, $0) },
                    uniquingKeysWith: { $0.enriched(with: $1) }
                )
                for row in rows {
                    byPath[row.path] = byPath[row.path]?
                        .enriched(with: row) ?? row
                }
                self.fileResults = byPath.values
                    .sorted {
                        if $0.effectiveRecency != $1.effectiveRecency {
                            return $0.effectiveRecency > $1.effectiveRecency
                        }
                        return $0.name.localizedStandardCompare($1.name)
                            == .orderedAscending
                    }
                self.publishPage(self.fileResults)
            }
        }
    }

    private func searchExpandedFileBrowse(type: FileType, token: Int) {
        nameQuery.stop()
        contentQuery.stop()
        contentQueryActive = false
        activeIndexToken = 0
        let selection = refinementSelection
        let key = boundedBrowseCacheKey(type: type, selection: selection)
        let cached = boundedBrowseCaches[key]
        if let cached,
           cached.rows.count > pageLimit || cached.exhausted {
            fileResults = cached.rows
            publishPage(cached.rows)
            if !cached.exhausted {
                canLoadMore = true
            }
            return
        }

        let previousLimit = cached?.readLimit ?? 0
        let readLimit = SearchPerformancePolicy.metadataReadLimit(
            pageLimit: pageLimit, previousLimit: previousLimit
        )
        let query = boundedQueryString(for: type, selection: selection)
        let scopes = boundedSearchScopes(for: type, selection: selection)
        let needs = boundedMetadataNeeds(for: selection)

        metadataQueue.async { [weak self] in
            guard let self else { return }
            let records = self.boundedMetadataStore.search(
                queryString: query,
                scopes: scopes,
                limit: readLimit,
                needs: needs,
                isCancelled: self.cancellation(for: token)
            )
            let rows = records
                .map { record in
                    SearchResult(
                        metadata: record,
                        facets: self.boundedFacets(for: record, selection: selection)
                    )
                }
                .filter { self.matchesTopLevelType($0, type: type) }

            DispatchQueue.main.async {
                guard token == self.searchToken, self.selectedType == type,
                      self.refinementSelection == selection else { return }
                let exhausted = records.count < readLimit
                    || readLimit >= SearchPerformancePolicy.maximumMetadataFetch
                self.boundedBrowseCaches[key] = BoundedBrowseCacheEntry(
                    rows: rows,
                    exhausted: exhausted,
                    readLimit: readLimit,
                    cachedAt: Date()
                )
                if self.boundedBrowseCaches.count > 6,
                   let oldest = self.boundedBrowseCaches.min(by: {
                       $0.value.cachedAt < $1.value.cachedAt
                   })?.key {
                    self.boundedBrowseCaches.removeValue(forKey: oldest)
                }
                self.fileResults = rows
                self.publishPage(rows)
                if !exhausted {
                    self.canLoadMore = true
                }
            }
        }
    }

    private func boundedBrowseCacheKey(type: FileType,
                                       selection: RefinementSelection) -> String {
        let choices = selection.choices.sorted {
            $0.key == $1.key ? $0.value < $1.value : $0.key < $1.key
        }
        return type.rawValue + "|" + choices.map { "\($0.key)=\($0.value)" }
            .joined(separator: "&")
    }

    private func boundedMetadataNeeds(
        for selection: RefinementSelection
    ) -> BoundedMetadataNeeds {
        BoundedMetadataNeeds(
            dateTaken: selection.optionID(for: "photo-date") != nil,
            duration: selection.optionID(for: "duration") != nil,
            authors: selection.optionID(for: "artist") != nil,
            tags: selection.optionID(for: "favorite") != nil,
            searchableText: selection.optionID(for: "pdf-text") != nil
        )
    }

    private func boundedQueryString(for type: FileType,
                                    selection: RefinementSelection) -> String {
        var alternatives: [String] = []
        let trees = type == .docs ? [] : type.contentTypeTrees
        let extensions = type == .docs
            ? Array(enabledDocumentExtensions()).sorted()
            : type.filenameExtensions
        alternatives += trees.map {
            "kMDItemContentTypeTree == \"\(mdQueryEscaped($0))\"cd"
        }
        alternatives += extensions.map {
            "kMDItemFSName == \"*.\(mdQueryEscaped($0))\"cd"
        }
        if type == .folders {
            alternatives.append("kMDItemContentTypeTree == \"public.folder\"cd")
        }
        if alternatives.isEmpty {
            alternatives.append("kMDItemFSName == \"*\"cd")
        }
        let typeClause = alternatives.count == 1
            ? alternatives[0]
            : "(" + alternatives.joined(separator: " || ") + ")"
        var clauses = [typeClause]
        if let format = selection.optionID(for: "format"),
           let extensions = RefinementValueSets.extensions(for: format),
           !extensions.isEmpty {
            let formats = extensions.sorted().map {
                "kMDItemFSName == \"*.\(mdQueryEscaped($0))\"cd"
            }
            clauses.append(
                formats.count == 1
                    ? formats[0]
                    : "(" + formats.joined(separator: " || ") + ")"
            )
        }
        if let duration = selection.optionID(for: "duration") {
            switch duration {
            case "short":
                clauses.append("kMDItemDurationSeconds < 60")
            case "medium":
                clauses.append(
                    "(kMDItemDurationSeconds >= 60 && kMDItemDurationSeconds <= 300)"
                )
            case "long":
                clauses.append("kMDItemDurationSeconds > 300")
            default:
                break
            }
        }
        return clauses.count == 1
            ? clauses[0]
            : "(" + clauses.joined(separator: " && ") + ")"
    }

    private func mdQueryEscaped(_ value: String) -> String {
        value.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
    }

    private func boundedSearchScopes(for type: FileType,
                                     selection: RefinementSelection) -> [String] {
        let home = NSHomeDirectory()
        if let location = selection.optionID(for: "location") {
            switch location {
            case "home": return [home]
            case "desktop":
                return [home + "/Desktop",
                        home + "/Library/Mobile Documents/com~apple~CloudDocs/Desktop"]
            case "downloads":
                return [home + "/Downloads",
                        home + "/Library/Mobile Documents/com~apple~CloudDocs/Downloads"]
            case "documents":
                return [home + "/Documents",
                        home + "/Library/Mobile Documents/com~apple~CloudDocs/Documents"]
            case "movies": return [home + "/Movies"]
            default: break
            }
        }
        if !type.pathPrefixes.isEmpty { return type.pathPrefixes }
        return [home]
    }

    private func boundedFacets(for record: BoundedMetadataRecord,
                               selection: RefinementSelection) -> RefinementFacets {
        var facets = RefinementFacets()
        facets.dateTaken = record.dateTaken
        facets.duration = record.duration
        facets.artist = record.authors.first ?? ""
        facets.isFavorite = record.tags.contains {
            $0.searchFolded.contains("favorite") || $0.searchFolded.contains("favourite")
        }
        facets.account = RefinementFacetBuilder.cloudAccount(for: record.path)
        facets.container = RefinementFacetBuilder.cloudContainer(for: record.path)
        if record.path.hasPrefix(NSHomeDirectory() + "/Downloads/") {
            facets.activity = "downloaded"
        } else if record.lastUsed != nil {
            facets.activity = "opened"
        } else if record.dateAdded != nil {
            facets.activity = "added"
        } else {
            facets.activity = "modified"
        }
        if let searchable = record.hasSearchableText {
            facets.contentCategory = searchable ? "searchable" : "scanned"
        }

        if record.contentTypes.contains("public.folder"),
           selection.optionID(for: "project") != nil {
            if let category = RefinementFacetBuilder.projectCategory(at: record.path) {
                facets.isProject = true
                facets.category = category
            }
        }
        return facets
    }

    private func matchesRecentFileType(_ result: SearchResult, type: FileType) -> Bool {
        matchesTopLevelType(result, type: type)
    }

    private func matchesTopLevelType(_ result: SearchResult, type: FileType) -> Bool {
        let ext = result.url.pathExtension.lowercased()
        switch type {
        case .all:
            return true
        case .recents:
            return result.source == .file
        case .apps:
            return result.source == .file && result.isApp
        case .messages:
            return result.source == .message
        case .notes:
            return result.source == .note
        case .mail, .gmail:
            return result.source == .mail
        case .calendar:
            return result.source == .calendar
        case .clipboard:
            return result.source == .clipboard
        case .history:
            return result.source == .history
        case .settings:
            return result.source == .settings
        case .folders:
            return result.source == .file && result.isFolder
        case .photos:
            return result.source == .file
                && (result.contentTypes.contains("public.image")
                || type.filenameExtensions.contains(ext)
                )
        case .videos:
            // macOS's UTI table classifies ".ts" as MPEG-2 Transport Stream,
            // so the content-type tree happily matches TypeScript source
            // files. On any developer machine those vastly outnumber real
            // videos; genuine MPEG-TS captures are ".m2ts"/".mts", which
            // still match.
            if ext == "ts" { return false }
            return result.source == .file
                && (result.contentTypes.contains("public.movie")
                || type.filenameExtensions.contains(ext)
                )
        case .audio:
            return result.source == .file
                && (result.contentTypes.contains("public.audio")
                || type.filenameExtensions.contains(ext)
                )
        case .pdfs:
            return result.source == .file
                && (ext == "pdf" || result.contentTypes.contains("com.adobe.pdf"))
        case .docs:
            return result.source == .file
                && isUserFacingDocumentPath(result.path)
                && enabledDocumentExtensions().contains(ext)
        case .word, .excel, .powerPoint:
            return result.source == .file
                && (type.filenameExtensions.contains(ext)
                || !Set(result.contentTypes).isDisjoint(with: Set(type.contentTypeTrees))
                )
        case .googleDrive, .oneDrive, .dropbox, .iCloudDrive:
            return result.source == .file
                && type.pathPrefixes.contains(where: result.path.hasPrefix)
        }
    }

    private func isUserFacingDocumentPath(_ path: String) -> Bool {
        let home = NSHomeDirectory()
        if path.hasPrefix(home + "/Library/") {
            return path.hasPrefix(home + "/Library/Mobile Documents/")
                || path.hasPrefix(home + "/Library/CloudStorage/")
        }
        let excludedRoots = [
            "/System/", "/Library/", "/private/", "/usr/", "/opt/",
            "/bin/", "/sbin/", "/Applications/"
        ]
        if excludedRoots.contains(where: path.hasPrefix) {
            return false
        }
        let excludedComponents = [
            "/.git/", "/node_modules/", "/.build/", "/DerivedData/",
            "/Caches/", "/__pycache__/", "/.Trash/", "/.npm/",
            "/.cargo/", "/.rustup/", ".app/Contents/"
        ]
        return !excludedComponents.contains(where: path.contains)
    }

    private func enabledDocumentExtensions() -> Set<String> {
        let optionIDs = RefinementLayoutStore.shared.layout(for: .docs)
            .optionIDs["format"] ?? []
        return optionIDs.reduce(into: Set<String>()) { extensions, optionID in
            if let values = RefinementValueSets.extensions(for: optionID) {
                extensions.formUnion(values)
            }
        }
    }

    /// In All mode, supplement Spotlight with a direct app-folder scan so
    /// third-party apps show up even when Spotlight's app metadata misses them.
    private func gatherPriorityFolders(tokens: [String], token: Int) {
        guard !tokens.isEmpty else { return }
        let type = selectedType
        guard type == .all || type == .folders else { return }
        let tokenClauses = tokens.map { token in
            let escaped = mdQueryEscaped(token)
            return "(kMDItemDisplayName == \"*\(escaped)*\"cd"
                + " || kMDItemFSName == \"*\(escaped)*\"cd)"
        }
        let query = "((kMDItemContentTypeTree == \"public.folder\"cd) && "
            + tokenClauses.joined(separator: " && ") + ")"
        priorityMetadataQueue.async { [weak self] in
            guard let self else { return }
            let records = self.boundedMetadataStore.search(
                queryString: query,
                scopes: [self.homePath],
                limit: 200,
                isCancelled: self.cancellation(for: token)
            )
            let rows = records.map {
                SearchResult(metadata: $0, facets: .empty)
            }
            DispatchQueue.main.async {
                guard token == self.searchToken, self.selectedType == type,
                      self.currentTokens == tokens else { return }
                var byPath = Dictionary(
                    self.priorityFolderResults.map { ($0.path, $0) },
                    uniquingKeysWith: { $0.enriched(with: $1) }
                )
                for row in rows {
                    byPath[row.path] = byPath[row.path]?
                        .enriched(with: row) ?? row
                }
                self.priorityFolderResults = Array(byPath.values)
                self.publishIndexResults()
            }
        }
        folderQueue.async { [weak self] in
            guard let self else { return }
            let rows = self.folderStore.search(
                tokens: tokens,
                isCancelled: self.cancellation(for: token)
            ).map { SearchResult(folder: $0) }
            DispatchQueue.main.async {
                guard token == self.searchToken, self.selectedType == type,
                      self.currentTokens == tokens else { return }
                var byPath = Dictionary(
                    self.priorityFolderResults.map { ($0.path, $0) },
                    uniquingKeysWith: { $0.enriched(with: $1) }
                )
                for row in rows {
                    byPath[row.path] = byPath[row.path]?
                        .enriched(with: row) ?? row
                }
                self.priorityFolderResults = Array(byPath.values)
                self.publishIndexResults()
            }
        }
    }

    private func gatherAppsForAll(tokens: [String], token: Int) {
        let limit = effectiveAllFileCap + 1
        appQueue.async { [weak self] in
            guard let self else { return }
            guard let rows = self.appStore.search(
                tokens: tokens,
                limit: limit,
                isCancelled: self.cancellation(for: token)
            ) else { return }
            let mapped = rows.map { SearchResult(app: $0) }

            DispatchQueue.main.async {
                guard token == self.searchToken, self.selectedType == .all else { return }
                self.scannedAppResults = mapped
                self.publish()
            }
        }
    }

    private func gatherCalendarForAll(tokens: [String], token: Int) {
        let limit = effectiveAllCalendarCap + 1
        calendarQueue.async { [weak self] in
            guard let self else { return }
            let permission = self.calendarStore.permissionState
            let mapped = permission == .granted
                ? self.calendarStore.search(tokens: tokens, limit: limit,
                                            isCancelled: self.cancellation(for: token))
                    .map { SearchResult(calendar: $0) }
                : []
            DispatchQueue.main.async {
                guard token == self.searchToken, self.selectedType == .all else { return }
                self.calendarPermission = permission
                self.calendarResults = mapped
                self.publish()
            }
        }
    }

    /// Background-load and search Messages, Notes, and Mail for blended All.
    /// Skips any source that lacks Full Disk Access (no prompt in All mode -
    /// the dedicated chips own that flow).
    private func gatherDatabasesForAll(tokens: [String], token: Int) {
        let includeMessages = allIncludedTypes.contains(.messages)
        let includeNotes = allIncludedTypes.contains(.notes)
        let includeMail = allIncludedTypes.contains(.mail)
        let messageLimit = effectiveAllMessageCap + 1
        let noteLimit = effectiveAllNoteCap + 1
        let mailLimit = effectiveAllMailCap + 1
        if includeMessages {
            messageQueue.async { [weak self] in
                guard let self else { return }
                self.messageStore.ensureLoaded()
                self.contacts.ensureLoaded()
                let resolver: ((String) -> String?)? =
                    self.contacts.isReady ? { self.contacts.name(for: $0) } : nil
                var rows: [SearchResult] = []
                if !self.messageStore.needsFullDiskAccess {
                    rows = self.messageStore.search(
                        tokens: tokens,
                        limit: messageLimit,
                        nameResolver: resolver,
                        isCancelled: self.cancellation(for: token)
                    )
                        .map {
                            SearchResult(message: $0,
                                         contactName: self.contacts.name(for: $0.conversationHandle))
                        }
                }
                DispatchQueue.main.async {
                    guard token == self.searchToken, self.selectedType == .all else {
                        return
                    }
                    self.messageResults = rows
                    self.publish()
                }
            }
        }
        if includeNotes {
            notesQueue.async { [weak self] in
                guard let self else { return }
                self.notesStore.ensureLoaded()
                var rows: [SearchResult] = []
                if !self.notesStore.needsFullDiskAccess {
                    rows = self.notesStore.search(
                        tokens: tokens,
                        limit: noteLimit,
                        isCancelled: self.cancellation(for: token)
                    ).map { SearchResult(note: $0) }
                }
                DispatchQueue.main.async {
                    guard token == self.searchToken, self.selectedType == .all else {
                        return
                    }
                    self.noteResults = rows
                    self.publish()
                }
            }
        }
        if includeMail {
            mailQueue.async { [weak self] in
                guard let self else { return }
                self.mailStore.ensureLoaded()
                var rows: [SearchResult] = []
                if !self.mailStore.needsFullDiskAccess {
                    rows = self.mailStore.search(
                        tokens: tokens,
                        limit: mailLimit,
                        isCancelled: self.cancellation(for: token)
                    )
                        .map { SearchResult(mail: $0) }
                }
                DispatchQueue.main.async {
                    guard token == self.searchToken, self.selectedType == .all else {
                        return
                    }
                    self.mailResults = rows
                    self.publish()
                }
            }
        }
    }

    /// Combine the per-source buckets into the published `results`. In `.all`
    /// mode the sources are grouped (files, then messages, then notes); other
    /// file-backed modes show just their files.
    private func publish() {
        if aiMode { return }   // AI mode owns `results` via aiPublish only
        if selectedType == .all {
            let rawFileRows = mergeScannedApps(into: fileResults)
            refinementCandidates = rawFileRows + messageResults + noteResults
                + mailResults + calendarResults
            let fileRows = rawFileRows.filter {
                RefinementMatcher.matches($0, type: .all,
                                          selection: refinementSelection)
            }
            let refinedMessages = messageResults.filter {
                RefinementMatcher.matches($0, type: .all,
                                          selection: refinementSelection)
            }
            let refinedNotes = noteResults.filter {
                RefinementMatcher.matches($0, type: .all,
                                          selection: refinementSelection)
            }
            let refinedMail = mailResults.filter {
                RefinementMatcher.matches($0, type: .all,
                                          selection: refinementSelection)
            }
            let refinedCalendar = calendarResults.filter {
                RefinementMatcher.matches($0, type: .all,
                                          selection: refinementSelection)
            }
            let filesAndApps: [SearchResult]
            if currentTokens.isEmpty, !freshRecentResults.isEmpty {
                let availableIDs = Set(fileRows.map(\.id))
                let fresh = freshRecentResults.filter {
                    availableIDs.contains($0.id)
                }
                let freshIDs = Set(fresh.map(\.id))
                let retainedFresh = Array(fresh.prefix(effectiveAllFileCap))
                let remaining = fileRows.filter { !freshIDs.contains($0.id) }
                let slots = max(0, effectiveAllFileCap - retainedFresh.count)
                filesAndApps = sortedForDisplay(
                    retainedFresh + Array(remaining.prefix(slots))
                )
            } else {
                filesAndApps = relevancePreservingPage(
                    fileRows, limit: effectiveAllFileCap
                )
            }
            var combined: [SearchResult] = []
            combined += filesAndApps
            if allIncludedTypes.contains(.messages) {
                combined += relevancePreservingPage(
                    refinedMessages, limit: effectiveAllMessageCap
                )
            }
            if allIncludedTypes.contains(.notes) {
                combined += relevancePreservingPage(
                    refinedNotes, limit: effectiveAllNoteCap
                )
            }
            if allIncludedTypes.contains(.mail) {
                combined += relevancePreservingPage(
                    refinedMail, limit: effectiveAllMailCap
                )
            }
            if allIncludedTypes.contains(.calendar) {
                combined += relevancePreservingPage(
                    refinedCalendar, limit: effectiveAllCalendarCap
                )
            }
            if currentTokens.isEmpty || sortMode == .alphabetical {
                combined = sortedForDisplay(combined)
            } else {
                // Rank across sources so an exact-name hit beats a merely
                // recent substring hit regardless of which store it came from.
                combined = combined
                    .map { (result: $0, score: score($0)) }
                    .sorted(by: rankedResultPrecedes)
                    .map(\.result)
            }
            switch refinementSelection.optionID(for: "kind") {
            case "files", "folders", "apps", "images", "pdfs":
                canLoadMore = fileRows.count > effectiveAllFileCap
            case "messages":
                canLoadMore = refinedMessages.count > effectiveAllMessageCap
            case "notes":
                canLoadMore = refinedNotes.count > effectiveAllNoteCap
            case "mail":
                canLoadMore = refinedMail.count > effectiveAllMailCap
            default:
                canLoadMore = fileRows.count > effectiveAllFileCap
                    || (allIncludedTypes.contains(.messages)
                        && refinedMessages.count > effectiveAllMessageCap)
                    || (allIncludedTypes.contains(.notes)
                        && refinedNotes.count > effectiveAllNoteCap)
                    || (allIncludedTypes.contains(.mail)
                        && refinedMail.count > effectiveAllMailCap)
                    || (allIncludedTypes.contains(.calendar)
                        && refinedCalendar.count > effectiveAllCalendarCap)
            }
            let nextResults = Array(combined.prefix(pageLimit))
            if results != nextResults {
                results = nextResults
            }
            isShowingStaleResults = false
            isLoadingMore = false
            if activeIndexToken == 0 { isSearching = false }
            cacheViewSnapshot()
        } else {
            publishPage(fileResults, preserveCandidates: true)
        }
    }

    private func mergeScannedApps(into fileRows: [SearchResult]) -> [SearchResult] {
        guard !scannedAppResults.isEmpty else { return fileRows }
        var byID: [String: SearchResult] = [:]
        for row in fileRows { byID[row.id] = row }
        for row in scannedAppResults { byID[row.id] = row }
        return byID.values
            .map { (result: $0, score: score($0)) }
            .sorted(by: rankedResultPrecedes)
            .map(\.result)
    }

    // MARK: - Messages

    func messageThreadPreview(for result: SearchResult,
                              completion: @escaping (MessageThreadPreview?) -> Void) {
        guard let rowid = result.messageRowID else {
            completion(nil)
            return
        }
        messageQueue.async { [weak self] in
            guard let self else { return }
            self.messageStore.ensureLoaded()
            self.contacts.ensureLoaded()
            let records = self.messageStore.context(around: rowid)
            let items = records.map { record in
                let sender: String
                if record.isFromMe {
                    sender = "You"
                } else {
                    let handle = record.handle.isEmpty
                        ? record.conversationHandle
                        : record.handle
                    sender = self.contacts.name(for: handle)
                        ?? (handle.isEmpty ? result.name : handle)
                }
                return MessageThreadItem(
                    id: record.rowid,
                    body: record.text,
                    sender: sender,
                    date: record.date,
                    isFromMe: record.isFromMe,
                    isMatch: record.rowid == rowid
                )
            }
            let preview = items.isEmpty
                ? nil
                : MessageThreadPreview(title: result.name, result: result, items: items)
            DispatchQueue.main.async { completion(preview) }
        }
    }

    private func searchMessages(tokens: [String], token: Int) {
        nameQuery.stop()
        contentQuery.stop()
        contentQueryActive = false
        let limit = sourceReadLimit(cap: 5_000)

        messageQueue.async { [weak self] in
            guard let self else { return }
            self.messageStore.ensureLoaded()
            self.contacts.ensureLoaded()
            let needsAccess = self.messageStore.needsFullDiskAccess
            let resolver: ((String) -> String?)? =
                self.contacts.isReady ? { self.contacts.name(for: $0) } : nil
            let hits = self.messageStore.search(tokens: tokens, limit: limit,
                                                nameResolver: resolver,
                                                isCancelled: self.cancellation(for: token))
            let mapped = hits.map { rec in
                SearchResult(message: rec,
                             contactName: self.contacts.name(for: rec.conversationHandle))
            }

            DispatchQueue.main.async {
                // Drop if superseded, or if the user has since left Messages.
                guard token == self.searchToken, self.selectedType.isMessages else { return }
                self.needsFullDiskAccess = needsAccess
                self.publishPage(mapped)
            }
        }
    }

    // MARK: - Notes

    private func searchNotes(tokens: [String], token: Int) {
        nameQuery.stop()
        contentQuery.stop()
        contentQueryActive = false
        let limit = sourceReadLimit(cap: 2_000)

        notesQueue.async { [weak self] in
            guard let self else { return }
            self.notesStore.ensureLoaded()
            let needsAccess = self.notesStore.needsFullDiskAccess
            let mapped = self.notesStore.search(tokens: tokens, limit: limit,
                                                isCancelled: self.cancellation(for: token))
                .map { SearchResult(note: $0) }

            DispatchQueue.main.async {
                guard token == self.searchToken, self.selectedType.isNotes else { return }
                self.needsFullDiskAccess = needsAccess
                self.publishPage(mapped)
            }
        }
    }

    // MARK: - Mail

    private func searchMail(tokens: [String], token: Int) {
        nameQuery.stop()
        contentQuery.stop()
        contentQueryActive = false
        let limit = sourceReadLimit(cap: 1_000)

        mailQueue.async { [weak self] in
            guard let self else { return }
            self.mailStore.ensureLoaded()
            let needsAccess = self.mailStore.needsFullDiskAccess
            let needsSetup = self.mailStore.needsSetup
            let mapped = self.mailStore.search(tokens: tokens, limit: limit,
                                               isCancelled: self.cancellation(for: token))
                .map { SearchResult(mail: $0) }

            DispatchQueue.main.async {
                guard token == self.searchToken, self.selectedType.isMail else { return }
                self.needsFullDiskAccess = needsAccess
                self.mailNeedsSetup = needsSetup
                self.publishPage(mapped)
            }
        }
    }

    private func searchGmail(tokens: [String], token: Int) {
        nameQuery.stop()
        contentQuery.stop()
        contentQueryActive = false
        let limit = sourceReadLimit(cap: 1_000)

        mailQueue.async { [weak self] in
            guard let self else { return }
            self.mailStore.ensureLoaded()
            let needsAccess = self.mailStore.needsFullDiskAccess
            let needsSetup = self.mailStore.needsSetup || !self.mailStore.hasGmailAccount
            let mapped = self.mailStore.search(tokens: tokens, limit: limit,
                                               gmailOnly: true,
                                               isCancelled: self.cancellation(for: token))
                .map { SearchResult(mail: $0) }

            DispatchQueue.main.async {
                guard token == self.searchToken, self.selectedType.isGmail else { return }
                self.needsFullDiskAccess = needsAccess
                self.gmailNeedsSetup = needsSetup
                self.publishPage(mapped)
            }
        }
    }

    // MARK: - Calendar

    private func searchCalendar(tokens: [String], token: Int) {
        nameQuery.stop()
        contentQuery.stop()
        contentQueryActive = false
        let limit = sourceReadLimit(cap: 1_000)

        calendarQueue.async { [weak self] in
            guard let self else { return }
            let permission = self.calendarStore.permissionState
            let mapped = permission == .granted
                ? self.calendarStore.search(tokens: tokens, limit: limit,
                                            isCancelled: self.cancellation(for: token))
                    .map { SearchResult(calendar: $0) }
                : []
            DispatchQueue.main.async {
                guard token == self.searchToken, self.selectedType.isCalendar else { return }
                self.calendarPermission = permission
                self.publishPage(mapped)
            }
        }
    }

    func requestCalendarAccess() {
        calendarStore.requestAccess { [weak self] _ in
            DispatchQueue.main.async {
                guard let self else { return }
                self.calendarPermission = self.calendarStore.permissionState
                self.calendarStore.refresh()
                if self.selectedType.isCalendar { self.scheduleSearch() }
            }
        }
    }

    func refreshCalendarAccess() {
        calendarStore.refresh()
        calendarPermission = calendarStore.permissionState
        if selectedType.isCalendar { scheduleSearch() }
    }

    // MARK: - Clipboard

    private func searchClipboard(tokens: [String]) {
        nameQuery.stop()
        contentQuery.stop()
        contentQueryActive = false
        needsFullDiskAccess = false
        let rows = ClipboardStore.shared.search(tokens: tokens,
                                                limit: sourceReadLimit(cap: 2_000))
            .map { SearchResult(clip: $0) }
        publishPage(rows)
    }

    // MARK: - Browser history

    private func searchHistory(tokens: [String], token: Int) {
        nameQuery.stop()
        contentQuery.stop()
        contentQueryActive = false
        let limit = sourceReadLimit(cap: 5_000)

        historyQueue.async { [weak self] in
            guard let self else { return }
            self.historyStore.ensureLoaded()
            let safariDenied = self.historyStore.safariDenied
            let mapped = self.historyStore.search(tokens: tokens, limit: limit,
                                                  isCancelled: self.cancellation(for: token))
                .map { SearchResult(history: $0) }

            DispatchQueue.main.async {
                guard token == self.searchToken, self.selectedType.isHistory else { return }
                // History never blocks the whole list; Safari denial surfaces
                // as a slim footer instead.
                self.needsFullDiskAccess = false
                self.historySafariDenied = safariDenied
                self.publishPage(mapped)
            }
        }
    }

    // MARK: - Recents

    private func searchRecents(tokens: [String], token: Int) {
        nameQuery.stop()
        contentQuery.stop()
        contentQueryActive = false
        needsFullDiskAccess = false
        let limit = sourceReadLimit(cap: 2_000)
        let readLimit = refinementSelection.isEmpty ? limit : recentsReadCap
        let activeRefinement = refinementSelection

        recentsQueue.async { [weak self] in
            guard let self else { return }
            let rows = self.recentsStore.search(tokens: tokens, limit: readLimit,
                                                isCancelled: self.cancellation(for: token))
            let mapped = rows
                .map { SearchResult(recent: $0) }
                .filter {
                    RefinementMatcher.matches($0, type: .recents,
                                              selection: activeRefinement)
                }

            DispatchQueue.main.async {
                guard token == self.searchToken, self.selectedType.isRecents else { return }
                self.fileResults = mapped
                self.publishPage(mapped)
            }
        }
    }

    // MARK: - Apps

    private func searchApps(tokens: [String], token: Int) {
        nameQuery.stop()
        contentQuery.stop()
        contentQueryActive = false
        needsFullDiskAccess = false
        let limit = sourceReadLimit(cap: 2_000)

        appQueue.async { [weak self] in
            guard let self else { return }
            guard let rows = self.appStore.search(
                tokens: tokens,
                limit: limit,
                isCancelled: self.cancellation(for: token)
            ) else { return }
            let mapped = rows.map { SearchResult(app: $0) }

            DispatchQueue.main.async {
                guard token == self.searchToken, self.selectedType.isApps else { return }
                self.fileResults = mapped
                self.publishPage(mapped)
            }
        }
    }

    /// Probe the protected databases once at launch. Attempting to open them
    /// registers Beacon with macOS's privacy system, so the app shows up
    /// (toggleable) in the Full Disk Access list without the user having to add
    /// it manually with the "+" button.
    func warmMessageAccess() {
        messageQueue.async { [weak self] in
            guard let self else { return }
            _ = self.messageStore.probeAccess()
            let needsAccess = self.messageStore.needsFullDiskAccess
            DispatchQueue.main.async { self.needsFullDiskAccess = needsAccess }
            // Beacon stays resident, so pay the one-time load cost now, in the
            // background, instead of on the user's first search. When access is
            // granted this fully populates the cache; the first Messages query
            // (normal or AI) then returns instantly instead of spinning while
            // it scans the whole history.
            if !needsAccess {
                self.messageStore.ensureLoaded()
                self.contacts.ensureLoaded()
            }
        }
    }

    /// Confirm access for the active database-backed filter so the Full Disk
    /// Access prompt can appear even before the user types anything.
    private func checkDatabaseAccess() {
        guard selectedType.isMessages else { return }
        let token = searchToken
        messageQueue.async { [weak self] in
            guard let self else { return }
            _ = self.messageStore.probeAccess()
            let needsAccess = self.messageStore.needsFullDiskAccess
            DispatchQueue.main.async {
                guard token == self.searchToken, self.selectedType.isMessages else {
                    return
                }
                self.needsFullDiskAccess = needsAccess
            }
        }
    }

    /// Re-run the current query whenever the panel is summoned. Guarantees the
    /// list reflects the world *now* (fresh downloads in Recents, new messages,
    /// new clipboard entries) and self-heals any view that wedged on a stale
    /// publish - without waiting for the user to retype.
    func refreshForPanelShow() {
        // In AI mode, reopening the panel must NOT disturb an in-flight run or a
        // finished answer — the agent keeps working in the background while the
        // panel is hidden, and the results should still be here on return.
        if aiMode { return }
        recentsStore.refresh()
        folderQueue.async { [folderStore] in
            folderStore.refreshIfStale()
        }
        // Catch up the database-backed stores so messages/notes/history/mail
        // from mid-session are findable. Each refresh runs on the same serial
        // queue as that store's searches, so a search scheduled below is
        // guaranteed to see the refreshed cache. All are TTL-throttled
        // (Messages is incremental) and no-op if the store never loaded.
        messageQueue.async { [messageStore] in messageStore.refreshIfStale() }
        notesQueue.async { [notesStore] in notesStore.refreshIfStale() }
        historyQueue.async { [historyStore] in historyStore.refreshIfStale() }
        mailQueue.async { [mailStore] in mailStore.invalidateSearchCache() }
        let cutoff = Date(timeIntervalSinceNow: -30)
        boundedBrowseCaches = boundedBrowseCaches.filter {
            $0.value.cachedAt >= cutoff
        }
        if selectedType.isApps || selectedType == .all {
            appStore.refresh()
        }
        if selectedType.isCalendar {
            calendarStore.refresh()
            calendarPermission = calendarStore.permissionState
        }
        scheduleSearch()
    }

    /// Re-attempt loading the protected DBs (e.g. after the user grants access),
    /// then re-run the current search if we're in a database-backed mode.
    func retryMessageAccess() {
        let type = selectedType
        let queue: DispatchQueue
        let retry: () -> Void
        if type.isMessages {
            queue = messageQueue
            retry = { [messageStore] in messageStore.retry() }
        } else if type.isNotes {
            queue = notesQueue
            retry = { [notesStore] in notesStore.retry() }
        } else if type.isMail || type.isGmail {
            queue = mailQueue
            retry = { [mailStore] in mailStore.retry() }
        } else if type.isHistory {
            queue = historyQueue
            retry = { [historyStore] in historyStore.retry() }
        } else {
            return
        }
        queue.async { [weak self] in
            retry()
            DispatchQueue.main.async {
                guard let self, self.selectedType == type else { return }
                self.scheduleSearch()
            }
        }
    }

    // MARK: - Predicates

    /// Each token must appear in the display name OR the on-disk file name.
    private func namePredicate(tokens: [String], trees: [String], extensions: [String],
                               pathPrefixes: [String],
                               excludedTrees: [String] = []) -> NSPredicate {
        let perToken: [NSPredicate] = tokens.map { token in
            NSCompoundPredicate(orPredicateWithSubpredicates: [
                NSPredicate(format: "kMDItemDisplayName CONTAINS[cd] %@", token),
                NSPredicate(format: "kMDItemFSName CONTAINS[cd] %@", token)
            ])
        }
        return applyTypeFilter(Self.combine(perToken, type: .and),
                               trees: trees, extensions: extensions,
                               pathPrefixes: pathPrefixes,
                               excludedTrees: excludedTrees)
    }

    /// Each token must appear in the indexed text contents of the file.
    private func contentPredicate(tokens: [String], trees: [String], extensions: [String],
                                  pathPrefixes: [String],
                                  excludedTrees: [String] = []) -> NSPredicate {
        let perToken = tokens.map { NSPredicate(format: "kMDItemTextContent CONTAINS[cd] %@", $0) }
        return applyTypeFilter(Self.combine(perToken, type: .and),
                               trees: trees, extensions: extensions,
                               pathPrefixes: pathPrefixes,
                               excludedTrees: excludedTrees)
    }

    private func applyTypeFilter(_ base: NSPredicate?, trees: [String],
                                 extensions: [String],
                                 pathPrefixes: [String],
                                 excludedTrees: [String]) -> NSPredicate {
        var predicates = base.map { [$0] } ?? []
        if !trees.isEmpty || !extensions.isEmpty {
            var typePredicates = trees.map {
                NSPredicate(format: "kMDItemContentTypeTree == %@", $0)
            }
            typePredicates += extensions.map {
                NSPredicate(format: "kMDItemFSName ENDSWITH[cd] %@", "." + $0)
            }
            if let included = Self.combine(typePredicates, type: .or) {
                predicates.append(included)
            }
        }
        if !pathPrefixes.isEmpty {
            let pathPredicates = pathPrefixes.map {
                NSPredicate(format: "kMDItemPath BEGINSWITH[cd] %@", $0)
            }
            if let includedPaths = Self.combine(pathPredicates, type: .or) {
                predicates.append(includedPaths)
            }
        }
        predicates += excludedTrees.map {
            NSCompoundPredicate(notPredicateWithSubpredicate:
                NSPredicate(format: "kMDItemContentTypeTree == %@", $0))
        }
        if selectedType == .videos {
            // Keep TypeScript out of the gather itself: Spotlight types ".ts"
            // as MPEG-2 video, which on developer machines floods the Videos
            // corpus with tens of thousands of source files.
            predicates.append(NSCompoundPredicate(notPredicateWithSubpredicate:
                NSPredicate(format: "kMDItemFSName ENDSWITH[cd] %@", ".ts")))
        }
        predicates += refinementMetadataPredicates()
        return Self.combine(predicates, type: .and)
            ?? NSPredicate(format: "kMDItemFSName LIKE[cd] %@", "*")
    }

    private func refinementMetadataPredicates() -> [NSPredicate] {
        var predicates: [NSPredicate] = []
        if selectedType == .docs {
            let homeLibrary = NSHomeDirectory() + "/Library/"
            predicates.append(NSCompoundPredicate(orPredicateWithSubpredicates: [
                NSCompoundPredicate(notPredicateWithSubpredicate:
                    NSPredicate(format: "kMDItemPath BEGINSWITH[cd] %@", homeLibrary)),
                NSPredicate(
                    format: "kMDItemPath BEGINSWITH[cd] %@",
                    homeLibrary + "Mobile Documents/"
                ),
                NSPredicate(
                    format: "kMDItemPath BEGINSWITH[cd] %@",
                    homeLibrary + "CloudStorage/"
                )
            ]))
            for path in [
                "/System/", "/Library/", "/private/", "/usr/", "/opt/",
                "/bin/", "/sbin/", "/Applications/"
            ] {
                predicates.append(NSCompoundPredicate(
                    notPredicateWithSubpredicate: NSPredicate(
                        format: "kMDItemPath BEGINSWITH[cd] %@", path
                    )
                ))
            }
            for component in [
                "/node_modules/", "/.git/", "/.build/", "/DerivedData/",
                "/Caches/", "/__pycache__/", "/.Trash/", "/.npm/",
                "/.cargo/", "/.rustup/", ".app/Contents/"
            ] {
                predicates.append(NSCompoundPredicate(
                    notPredicateWithSubpredicate: NSPredicate(
                        format: "kMDItemPath CONTAINS[cd] %@", component
                    )
                ))
            }
        }
        if let format = refinementSelection.optionID(for: "format"),
           let extensions = RefinementValueSets.extensions(for: format) {
            let options = extensions.sorted().map {
                NSPredicate(format: "kMDItemFSName ENDSWITH[cd] %@", "." + $0)
            }
            if let predicate = Self.combine(options, type: .or) {
                predicates.append(predicate)
            }
        }
        if let duration = refinementSelection.optionID(for: "duration") {
            switch duration {
            case "short":
                predicates.append(NSPredicate(
                    format: "kMDItemDurationSeconds < 60"
                ))
            case "medium":
                predicates.append(NSPredicate(
                    format: "kMDItemDurationSeconds >= 60 AND kMDItemDurationSeconds <= 300"
                ))
            case "long":
                predicates.append(NSPredicate(
                    format: "kMDItemDurationSeconds > 300"
                ))
            default:
                break
            }
        }
        return predicates
    }

    /// Combine predicates without ever producing a single-element compound
    /// (which NSMetadataQuery treats as invalid and throws on).
    private static func combine(_ predicates: [NSPredicate],
                                type: NSCompoundPredicate.LogicalType) -> NSPredicate? {
        switch predicates.count {
        case 0: return nil
        case 1: return predicates[0]
        default: return NSCompoundPredicate(type: type, subpredicates: predicates)
        }
    }

    // MARK: - Results

    @objc private func queryUpdated(_ note: Notification) {
        guard let query = note.object as? NSMetadataQuery,
              query === nameQuery || query === contentQuery else { return }
        // While browse publishing is paused, drop the chatty gather-progress
        // ticks but let the final gather-finished (and later live-update)
        // notifications through so the full corpus lands exactly once.
        if indexedBrowsePaused, query === nameQuery,
           note.name == .NSMetadataQueryGatheringProgress { return }
        if note.name == .NSMetadataQueryGatheringProgress,
           query === nameQuery {
            let count = query.resultCount
            let crossedPageBoundary = lastIndexedPublishCount <= pageLimit
                && count > pageLimit
            guard crossedPageBoundary || count - lastIndexedPublishCount >= 40 else {
                return
            }
            lastIndexedPublishCount = count
        }
        pendingIndexPublish?.cancel()
        let token = activeIndexToken
        let work = DispatchWorkItem { [weak self] in
            guard let self, token == self.activeIndexToken,
                  token == self.searchToken else { return }
            self.lastIndexPublishAt = Date()
            self.publishIndexResults()
        }
        pendingIndexPublish = work
        let immediate = note.name == .NSMetadataQueryDidFinishGathering
        let elapsed = Date().timeIntervalSince(lastIndexPublishAt)
        let delay = immediate ? 0 : max(0.04, 0.12 - elapsed)
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    private func publishIndexResults() {
        if aiMode { return }   // AI mode owns `results`; ignore late index ticks
        // Ignore late file-index notifications while a database-backed filter
        // (Messages/Notes/Clipboard/History) is active, so they can't overwrite
        // that filter's results.
        guard selectedType.usesFileIndex,
              activeIndexToken == searchToken else { return }

        var merged: [String: SearchResult] = [:]
        let wanted = selectedType == .all ? effectiveAllFileCap + 1 : pageLimit + 1
        let pushedDimensions: Set<String> = [
            "location", "photo-source", "format", "duration", "kind"
        ]
        let hasClientOnlyRefinement = refinementSelection.choices.keys.contains {
            !pushedDimensions.contains($0)
        }
        let refinementReadCap = hasClientOnlyRefinement ? 2_500 : nameReadCap

        // Name matches first so they win on dedupe against content matches.
        readResults(from: nameQuery, cap: max(refinementReadCap, wanted * 2),
                    matchKind: .name, into: &merged)
        if contentQueryActive {
            readResults(from: contentQuery, cap: max(contentReadCap, wanted),
                        matchKind: .content, into: &merged)
        }
        if selectedType == .all || selectedType == .folders {
            for folder in priorityFolderResults {
                merged[folder.path] = merged[folder.path]?
                    .enriched(with: folder) ?? folder
            }
        }
        if isBrowsing {
            for existing in fileResults {
                merged[existing.path] = merged[existing.path]?
                    .enriched(with: existing) ?? existing
            }
        }

        let candidates = Array(merged.values)
        let type = selectedType
        let selection = refinementSelection
        let tokens = currentTokens
        let browsing = isBrowsing
        let priorCatalog = recentFileCatalog
        let bothDone = !nameQuery.isGathering
            && (!contentQueryActive || !contentQuery.isGathering)
        indexProcessingGeneration &+= 1
        let processingGeneration = indexProcessingGeneration
        let token = searchToken
        indexProcessingQueue.async { [weak self] in
            guard let self else { return }
            let preparedCandidates = candidates.map { result -> SearchResult in
                guard type == .folders, result.isFolder,
                      selection.optionID(for: "project") != nil,
                      let category = RefinementFacetBuilder.projectCategory(
                          at: result.path
                      ) else { return result }
                var updated = result
                updated.facets.isProject = true
                updated.facets.category = category
                return updated
            }
            let ranked = preparedCandidates
                .filter {
                    RefinementMatcher.matches(
                        $0, type: type, selection: selection
                    )
                }
                .map {
                    (
                        result: $0,
                        score: Self.score(
                            $0, tokens: tokens, homePath: self.homePath
                        )
                    )
                }
                .sorted {
                    Self.rankedResultPrecedes($0, $1, tokens: tokens)
                }
                .prefix(wanted)
                .map(\.result)
            let catalog: [SearchResult]?
            if type == .all, browsing {
                var byPath = Dictionary(
                    priorCatalog.map { ($0.path, $0) },
                    uniquingKeysWith: { $0.enriched(with: $1) }
                )
                for result in ranked {
                    byPath[result.path] = byPath[result.path]?
                        .enriched(with: result) ?? result
                }
                catalog = byPath.values
                    .sorted {
                        if $0.effectiveRecency != $1.effectiveRecency {
                            return $0.effectiveRecency > $1.effectiveRecency
                        }
                        return $0.name.localizedStandardCompare($1.name)
                            == .orderedAscending
                    }
                    .prefix(10_000)
                    .map { $0 }
            } else {
                catalog = nil
            }
            DispatchQueue.main.async {
                guard token == self.searchToken, type == self.selectedType,
                      processingGeneration == self.indexProcessingGeneration else {
                    return
                }
                if type != .all {
                    self.refinementCandidates = preparedCandidates
                }
                self.fileResults = ranked
                if let catalog { self.recentFileCatalog = catalog }
                self.publish()
                // Once browse has a full page, stop PROCESSING gather ticks
                // (each one re-reads and re-sorts everything) — but keep the
                // query itself alive and gathering. Later pages then read
                // straight from the already-gathered, Spotlight-sorted
                // results instead of restarting a multi-second re-gather of
                // the whole corpus, which is what made grids load in slow
                // 3-second batches.
                if browsing, type != .all, selection.isEmpty,
                   ranked.count > self.pageLimit {
                    self.indexedBrowsePaused = true
                }
                if bothDone || !ranked.isEmpty { self.isSearching = false }
            }
        }
    }

    private func readResults(from query: NSMetadataQuery, cap: Int,
                             matchKind: MatchKind, into merged: inout [String: SearchResult]) {
        query.disableUpdates()
        defer { query.enableUpdates() }

        // Junk rows (repo internals, caches) can occupy any number of leading
        // Spotlight rows — a developer's node_modules markdown outranks real
        // documents by last-used date. Scan well past the page cap so pages
        // fill with rows that actually survive the type filter below.
        let scanCap = selectedType == .all ? max(cap * 8, 1_200) : max(cap * 4, 1_200)
        let count = min(query.resultCount, scanCap)
        // The per-item metadata facet reads (creation date, duration, authors,
        // tags) are the most expensive part of this loop and they run on the
        // main thread. They only influence anything when a refinement is
        // active (or for Audio's artist sidebar), so plain browsing skips
        // them entirely — that was the visible first-load lag on Photos.
        let wantsMetadataFacets = !refinementSelection.isEmpty
            || selectedType == .audio
        var added = 0
        for index in 0..<count {
            guard let item = query.result(at: index) as? NSMetadataItem else { continue }
            guard let path = item.value(forAttribute: NSMetadataItemPathKey) as? String else { continue }
            if merged[path] != nil { continue } // keep the higher-priority (name) match
            if isBrowsing, !isUserFacingRecentPath(path) { continue }

            let name = (item.value(forAttribute: NSMetadataItemDisplayNameKey) as? String)
                ?? (item.value(forAttribute: NSMetadataItemFSNameKey) as? String)
                ?? (path as NSString).lastPathComponent

            let kind = item.value(forAttribute: NSMetadataItemKindKey) as? String ?? ""
            let size = item.value(forAttribute: NSMetadataItemFSSizeKey) as? Int64
            let modified = item.value(forAttribute: NSMetadataItemFSContentChangeDateKey) as? Date
            let lastUsed = item.value(forAttribute: NSMetadataItemLastUsedDateKey) as? Date
            let dateAdded = item.value(forAttribute: NSMetadataItemDateAddedKey) as? Date
            let contentType = item.value(forAttribute: NSMetadataItemContentTypeTreeKey) as? [String] ?? []
            let isFolder = contentType.contains("public.folder")
            let isApp = contentType.contains("com.apple.application")

            var result = SearchResult(id: path, name: name, path: path, kind: kind,
                                      size: size, modified: modified, lastUsed: lastUsed,
                                      dateAdded: dateAdded,
                                      isFolder: isFolder, isApp: isApp,
                                      contentTypes: contentType, matchKind: matchKind,
                                      facets: .empty)
            // Filter to the selected type BEFORE ranking caps the page (and
            // before paying for facets), so a page can never fill with rows
            // destined to be filtered out.
            if selectedType != .all {
                guard matchesTopLevelType(result, type: selectedType) else { continue }
            }
            if selectedType == .all && !isIncludedInAll(result) { continue }
            result.facets = wantsMetadataFacets
                ? metadataFacets(for: item, path: path,
                                 modified: modified, lastUsed: lastUsed,
                                 dateAdded: dateAdded)
                : cheapFacets(path: path, modified: modified,
                              lastUsed: lastUsed, dateAdded: dateAdded)
            merged[path] = result
            added += 1
            if added >= cap { break }
        }
    }

    /// Facets derivable from attributes we already read — no extra
    /// per-item metadata fetches. Enough for display and for every matcher
    /// that runs with an empty refinement selection (i.e. none).
    private func cheapFacets(path: String, modified: Date?, lastUsed: Date?,
                             dateAdded: Date?) -> RefinementFacets {
        var facets = RefinementFacets()
        facets.account = RefinementFacetBuilder.cloudAccount(for: path)
        facets.container = RefinementFacetBuilder.cloudContainer(for: path)
        if path.hasPrefix(NSHomeDirectory() + "/Downloads/") {
            facets.activity = "downloaded"
        } else if lastUsed != nil {
            facets.activity = "opened"
        } else if dateAdded != nil {
            facets.activity = "added"
        } else if modified != nil {
            facets.activity = "modified"
        }
        return facets
    }

    private func metadataFacets(for item: NSMetadataItem, path: String,
                                modified: Date?, lastUsed: Date?,
                                dateAdded: Date?) -> RefinementFacets {
        var facets = RefinementFacets()
        let url = URL(fileURLWithPath: path)
        let ext = url.pathExtension.lowercased()
        facets.dateTaken = item.value(forAttribute: "kMDItemContentCreationDate") as? Date
        facets.duration = (item.value(forAttribute: "kMDItemDurationSeconds") as? NSNumber)?
            .doubleValue
        let authors = item.value(forAttribute: "kMDItemAuthors") as? [String]
        let album = item.value(forAttribute: "kMDItemAlbum") as? String
        facets.artist = authors?.first ?? album ?? ""
        let tags = item.value(forAttribute: "kMDItemUserTags") as? [String] ?? []
        facets.isFavorite = tags.contains {
            $0.searchFolded.contains("favorite") || $0.searchFolded.contains("favourite")
        }

        facets.account = RefinementFacetBuilder.cloudAccount(for: path)
        facets.container = RefinementFacetBuilder.cloudContainer(for: path)

        if path.hasPrefix(NSHomeDirectory() + "/Downloads/") {
            facets.activity = "downloaded"
        } else if lastUsed != nil {
            facets.activity = "opened"
        } else if dateAdded != nil {
            facets.activity = "added"
        } else if modified != nil {
            facets.activity = "modified"
        }

        if ["m4a", "caf", "aiff"].contains(ext) {
            facets.contentCategory = path.searchFolded.contains("voice memo")
                ? "voice" : "recording"
        } else if ["mp3", "aac", "flac", "wav", "alac"].contains(ext) {
            facets.contentCategory = facets.artist.isEmpty ? "sound" : "music"
        }

        return facets
    }

    private func isUserFacingRecentPath(_ path: String) -> Bool {
        guard path.hasPrefix(homePath + "/") else { return false }
        if path.hasPrefix(homePath + "/Library/"),
           !path.hasPrefix(homePath + "/Library/Mobile Documents/"),
           !path.hasPrefix(homePath + "/Library/CloudStorage/") {
            return false
        }
        let excluded = ["/.git/", "/node_modules/", "/.build/", "/DerivedData/",
                        "/Caches/", "/__pycache__/"]
        return !excluded.contains(where: path.contains)
    }

    private func isIncludedInAll(_ result: SearchResult) -> Bool {
        true
    }

    // MARK: - Ranking

    /// Lower score sorts first (ties broken by most-recently-used, then name).
    ///
    /// Tiers, best to worst:
    ///   0   exact name — with or without the extension, so "report" exact-
    ///       matches "report.pdf", the way a launcher is expected to
    ///   100 name starts with the whole query ("saf" -> Safari)
    ///   200 every token is a whole word in the name ("main" beats "maintain")
    ///   250 every token starts a word in the name ("chase stat" ->
    ///       "Chase Statement.pdf")
    ///   300 every token appears somewhere in the name
    ///   400 matched only on the path / on-disk name
    ///   500 matched by text inside the file
    /// Within a tier: apps first (launcher expectation), then folders, then
    /// the user's own files over system paths.
    private func score(_ r: SearchResult) -> Int {
        Self.score(r, tokens: currentTokens, homePath: homePath)
    }

    private static func score(_ r: SearchResult, tokens: [String],
                              homePath: String) -> Int {
        let name = r.name.searchFolded
        let stem = (r.name as NSString).deletingPathExtension.searchFolded
        let query = tokens.joined(separator: " ")
        var base: Int
        if r.isApp {
            base = (AppRanking.rank(
                name: r.name, path: r.path, tokens: tokens
            )?.matchTier ?? 5) * 100
        } else if r.matchKind == .content {
            base = 500
        } else if name == query || stem == query {
            base = 0
        } else if name.hasPrefix(query) || stem.hasPrefix(query) {
            base = 100
        } else if tokens.allSatisfy({ SearchText.hasWholeWord(name, $0) }) {
            base = 200
        } else if tokens.allSatisfy({ SearchText.hasWordStart(name, $0) }) {
            base = 250
        } else if tokens.allSatisfy({ name.contains($0) }) {
            base = 300
        } else {
            base = 400
        }
        if r.isApp { base -= 50 }                     // launching apps is the top use case
        if r.isFolder { base -= 10 }                  // nudge folders up within their tier
        if r.path.hasPrefix(homePath) { base -= 30 }  // prefer the user's own files
        return base
    }

    private func rankedResultPrecedes(
        _ lhs: (result: SearchResult, score: Int),
        _ rhs: (result: SearchResult, score: Int)
    ) -> Bool {
        Self.rankedResultPrecedes(lhs, rhs, tokens: currentTokens)
    }

    private static func rankedResultPrecedes(
        _ lhs: (result: SearchResult, score: Int),
        _ rhs: (result: SearchResult, score: Int),
        tokens: [String]
    ) -> Bool {
        if tokens.isEmpty {
            if lhs.result.effectiveRecency != rhs.result.effectiveRecency {
                return lhs.result.effectiveRecency > rhs.result.effectiveRecency
            }
            return lhs.result.name.localizedStandardCompare(rhs.result.name)
                == .orderedAscending
        }
        if lhs.result.isApp, rhs.result.isApp {
            let leftRank = AppRanking.rank(
                name: lhs.result.name, path: lhs.result.path, tokens: tokens
            )
            let rightRank = AppRanking.rank(
                name: rhs.result.name, path: rhs.result.path, tokens: tokens
            )
            if leftRank != rightRank {
                if let leftRank, let rightRank { return leftRank < rightRank }
                return leftRank != nil
            }
        }
        if lhs.score != rhs.score { return lhs.score < rhs.score }
        let leftDate = lhs.result.lastUsed ?? lhs.result.modified ?? .distantPast
        let rightDate = rhs.result.lastUsed ?? rhs.result.modified ?? .distantPast
        if leftDate != rightDate { return leftDate > rightDate }
        return lhs.result.name.localizedStandardCompare(rhs.result.name) == .orderedAscending
    }
}
