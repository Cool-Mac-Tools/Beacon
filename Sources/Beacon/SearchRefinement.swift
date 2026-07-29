import Foundation

struct RefinementOption: Identifiable, Hashable, Codable {
    let id: String
    let title: String
    let symbol: String?
    let isEnabled: Bool

    init(_ id: String, _ title: String, symbol: String? = nil,
         isEnabled: Bool = true) {
        self.id = id
        self.title = title
        self.symbol = symbol
        self.isEnabled = isEnabled
    }
}

struct RefinementDimension: Identifiable, Hashable {
    let id: String
    let title: String
    let options: [RefinementOption]
    let unavailableReason: String?

    init(_ id: String, _ title: String, options: [RefinementOption],
         unavailableReason: String? = nil) {
        self.id = id
        self.title = title
        self.options = options
        self.unavailableReason = unavailableReason
    }
}

struct RefinementSelection: Codable, Equatable {
    var choices: [String: String] = [:]

    func optionID(for dimensionID: String) -> String? {
        choices[dimensionID]
    }

    var isEmpty: Bool { choices.isEmpty }
}

struct RefinementFacets {
    var account = ""
    var container = ""
    var category = ""
    var contentCategory = ""
    var activity = ""
    var domain = ""
    var artist = ""
    var sourceApp = ""
    var duration: Double?
    var dateTaken: Date?
    var isUnread = false
    var isFlagged = false
    var isFavorite = false
    var isProject = false

    static let empty = RefinementFacets()

    /// Field-wise union of two facet sets describing the same item. Values
    /// already present win; the other side only fills gaps. Lets a metadata-
    /// rich Spotlight row and a metadata-poor fast-lane row (FolderStore,
    /// fresh recents) combine instead of one clobbering the other.
    func merged(with other: RefinementFacets) -> RefinementFacets {
        var merged = self
        if merged.account.isEmpty { merged.account = other.account }
        if merged.container.isEmpty { merged.container = other.container }
        if merged.category.isEmpty { merged.category = other.category }
        if merged.contentCategory.isEmpty {
            merged.contentCategory = other.contentCategory
        }
        if merged.activity.isEmpty { merged.activity = other.activity }
        if merged.domain.isEmpty { merged.domain = other.domain }
        if merged.artist.isEmpty { merged.artist = other.artist }
        if merged.sourceApp.isEmpty { merged.sourceApp = other.sourceApp }
        if merged.duration == nil { merged.duration = other.duration }
        if merged.dateTaken == nil { merged.dateTaken = other.dateTaken }
        merged.isUnread = merged.isUnread || other.isUnread
        merged.isFlagged = merged.isFlagged || other.isFlagged
        merged.isFavorite = merged.isFavorite || other.isFavorite
        merged.isProject = merged.isProject || other.isProject
        return merged
    }
}

enum RefinementValueSets {
    static func extensions(for option: String) -> Set<String>? {
        let groups: [String: Set<String>] = [
            "text": ["txt", "rtf", "md"], "word": ["doc", "docx", "docm"],
            "spreadsheet": ["xls", "xlsx", "csv", "numbers"],
            "presentation": ["ppt", "pptx", "key"], "pages": ["pages"],
            "markdown": ["md", "markdown"], "rtf": ["rtf", "rtfd"],
            "odf": ["odt", "ods", "odp"],
            "latex": ["tex", "latex", "bib"], "notebook": ["ipynb"],
            "ebook": ["epub", "mobi", "azw", "azw3"],
            "publishing": ["indd", "idml"],
            "web": ["html", "htm"],
            "data": ["json", "jsonl", "yaml", "yml", "xml"],
            "template": ["dot", "dotx", "xlt", "xltx", "pot", "potx"],
            "macro": ["docm", "xlsm", "pptm"], "slideshow": ["pps", "ppsx"],
            "png": ["png"], "jpeg": ["jpg", "jpeg"], "heic": ["heic", "heif"],
            "gif": ["gif"], "raw": ["raw", "dng", "cr2", "cr3", "nef", "arw"],
            "svg": ["svg"], "webp": ["webp"], "tiff": ["tif", "tiff"],
            "psd": ["psd", "psb"], "ai": ["ai"], "sketch": ["sketch"],
            "afphoto": ["afphoto"], "exr": ["exr"],
            "mov": ["mov", "qt"], "mp4": ["mp4"], "m4v": ["m4v"],
            "mkv": ["mkv"], "webm": ["webm"], "avi": ["avi"],
            "mpeg": ["mpg", "mpeg"], "mts": ["mts", "m2ts"],
            "aiff": ["aif", "aiff"],
            "image": Set(FileType.photos.filenameExtensions),
            "video": Set(FileType.videos.filenameExtensions),
            "audio": Set(FileType.audio.filenameExtensions),
            "archive": ["zip", "rar", "7z", "tar", "gz"]
        ]
        return groups[option]
    }

    static func durationBounds(for option: String) -> (minimum: Double?,
                                                        maximum: Double?)? {
        switch option {
        case "short": return (nil, 60)
        case "medium": return (60, 300)
        case "long": return (300, nil)
        default: return nil
        }
    }
}

enum RefinementCatalog {
    private static let hiddenTimeRangeDimensions: Set<String> = [
        "time", "photo-date", "recent-use", "recent-open"
    ]

    static func sidebarDimensions(for type: FileType) -> [RefinementDimension] {
        dimensions(for: type).filter {
            !hiddenTimeRangeDimensions.contains($0.id)
        }
    }

    static func catalogDimensions(for type: FileType) -> [RefinementDimension] {
        sidebarDimensions(for: type) + optionalDimensions(for: type)
    }

    static func defaultDimensionIDs(for type: FileType) -> [String] {
        sidebarDimensions(for: type).map(\.id)
    }

    static func defaultOptionIDs(for type: FileType,
                                 dimension: RefinementDimension) -> [String] {
        let optional: Set<String>
        switch (type, dimension.id) {
        case (.photos, "format"):
            optional = ["svg", "webp", "tiff", "psd", "ai", "sketch", "afphoto", "exr"]
        case (.docs, "format"):
            optional = [
                "markdown", "rtf", "odf", "latex", "notebook",
                "ebook", "publishing", "web", "data"
            ]
        default:
            optional = []
        }
        return dimension.options.filter { !optional.contains($0.id) }.map(\.id)
    }

    private static func optionalDimensions(for type: FileType) -> [RefinementDimension] {
        switch type {
        case .videos:
            return [videoFormat()]
        case .audio:
            return [audioFormat()]
        case .googleDrive, .oneDrive, .dropbox, .iCloudDrive:
            return [cloudFormat()]
        default:
            return []
        }
    }

    static func dimensions(for type: FileType) -> [RefinementDimension] {
        switch type {
        case .all:
            return [location(), time(), kind()]
        case .recents:
            return [location(), recentTime(), activity()]
        case .apps:
            return [recentlyUsed(), appCategory(), installedLocation()]
        case .messages:
            return [messageContent()]
        case .notes:
            return [folder(), modifiedDate(), account()]
        case .history:
            return [browser(), time(title: "Date"), domain()]
        case .docs:
            return [documentFormat(), documentLocation(), modifiedDate()]
        case .word:
            return [documentLocation(), modifiedDate(), format(
                [.init("docx", "DOCX"), .init("doc", "DOC"), .init("template", "Templates"),
                 .init("macro", "Macro-enabled")]
            )]
        case .excel:
            return [documentLocation(), modifiedDate(), format(
                [.init("xlsx", "XLSX"), .init("xls", "XLS"), .init("csv", "CSV"),
                 .init("macro", "Macro-enabled")]
            )]
        case .powerPoint:
            return [documentLocation(), modifiedDate(), format(
                [.init("presentation", "Presentations"), .init("slideshow", "Slide shows"),
                 .init("template", "Templates"), .init("macro", "Macro-enabled")]
            )]
        case .mail:
            return [account(), folder(title: "Mailbox"), mailState(starred: false)]
        case .gmail:
            return [account(title: "Gmail account"), folder(title: "Mailbox"),
                    mailState(starred: true)]
        case .calendar:
            return [calendarWindow(), calendarName(), temporalDirection()]
        case .pdfs:
            return [documentLocation(), modifiedDate()]
        case .photos:
            return [photoSource(), photoDate(), format(
                [.init("png", "PNG"), .init("jpeg", "JPEG"), .init("heic", "HEIC"),
                 .init("gif", "GIF"), .init("raw", "RAW"), .init("svg", "SVG"),
                 .init("webp", "WebP"), .init("tiff", "TIFF"), .init("psd", "PSD"),
                 .init("ai", "Illustrator"), .init("sketch", "Sketch"),
                 .init("afphoto", "Affinity Photo"), .init("exr", "OpenEXR")]
            )]
        case .videos:
            return [mediaLocation(), modifiedDate(title: "Date"), duration()]
        case .audio:
            return [audioType(), artist(), duration()]
        case .folders:
            return [rootLocation(), favorites(), projects()]
        case .clipboard:
            return [clipboardContent(), sourceApp(), time(title: "Date")]
        case .settings:
            return [settingsCategory(), favorites(), recentlyOpened()]
        case .googleDrive, .oneDrive:
            return [account(), cloudFolder(), kind()]
        case .dropbox:
            return [account(title: "Account or root"), cloudFolder(), kind()]
        case .iCloudDrive:
            return [cloudFolder(), kind(), modifiedDate()]
        }
    }

    static func sanitized(_ selection: RefinementSelection,
                          for type: FileType) -> RefinementSelection {
        sanitized(selection, dimensions: catalogDimensions(for: type))
    }

    static func sanitized(_ selection: RefinementSelection,
                          dimensions: [RefinementDimension]) -> RefinementSelection {
        let valid = Dictionary(uniqueKeysWithValues: dimensions.map {
            ($0.id, Set($0.options.map(\.id)))
        })
        var choices: [String: String] = [:]
        for (dimension, option) in selection.choices {
            if valid[dimension]?.contains(option) == true
                || (valid[dimension] != nil && option.hasPrefix("exact:")) {
                choices[dimension] = option
            }
        }
        return RefinementSelection(choices: choices)
    }

    static func enriched(_ dimensions: [RefinementDimension],
                         with results: [SearchResult]) -> [RefinementDimension] {
        dimensions.compactMap { dimension -> RefinementDimension? in
            if dimension.id == "project" {
                let available = Set(results.compactMap {
                    $0.facets.isProject ? $0.facets.category : nil
                })
                guard !available.isEmpty else { return nil }
                return RefinementDimension(
                    dimension.id, dimension.title,
                    options: dimension.options.filter { available.contains($0.id) }
                )
            }
            guard let value = dynamicValue(for: dimension.id) else { return dimension }
            var counts: [String: (title: String, count: Int)] = [:]
            for result in results {
                let title = value(result).trimmingCharacters(in: .whitespacesAndNewlines)
                guard !title.isEmpty else { continue }
                let folded = title.searchFolded
                let current = counts[folded]
                counts[folded] = (current?.title ?? title, (current?.count ?? 0) + 1)
            }
            let options = counts
                .sorted {
                    if $0.value.count != $1.value.count {
                        return $0.value.count > $1.value.count
                    }
                    return $0.value.title.localizedStandardCompare($1.value.title)
                        == .orderedAscending
                }
                .prefix(8)
                .map { RefinementOption("exact:" + $0.key, $0.value.title) }
            guard !options.isEmpty else { return dimension }
            return RefinementDimension(dimension.id, dimension.title,
                                       options: options,
                                       unavailableReason: dimension.unavailableReason)
        }
    }

    private static func dynamicValue(for dimensionID: String)
        -> ((SearchResult) -> String)? {
        switch dimensionID {
        case "container": return { $0.facets.container }
        case "account": return { $0.facets.account }
        case "domain": return { $0.facets.domain }
        case "artist": return { $0.facets.artist }
        case "source-app": return { $0.facets.sourceApp }
        default: return nil
        }
    }

    private static func location() -> RefinementDimension {
        .init("location", "Location", options: [
            .init("desktop", "Desktop"), .init("downloads", "Downloads"),
            .init("documents", "Documents"), .init("screenshots", "Screenshots")
        ])
    }

    private static func rootLocation() -> RefinementDimension {
        .init("location", "Root location", options: [
            .init("home", "Home"), .init("desktop", "Desktop"),
            .init("documents", "Documents"), .init("downloads", "Downloads")
        ])
    }

    private static func documentLocation() -> RefinementDimension {
        .init("location", "Location", options: [
            .init("desktop", "Desktop"), .init("downloads", "Downloads"),
            .init("documents", "Documents"), .init("projects", "Projects")
        ])
    }

    private static func mediaLocation() -> RefinementDimension {
        .init("location", "Location", options: [
            .init("photos-library", "Photo Library"),
            .init("movies", "Movies"), .init("desktop", "Desktop"),
            .init("downloads", "Downloads"), .init("projects", "Projects")
        ])
    }

    private static func time(title: String = "Time window") -> RefinementDimension {
        .init("time", title, options: [
            .init("today", "Today"), .init("week", "This Week"),
            .init("month", "This Month"), .init("older", "Older")
        ])
    }

    private static func recentTime() -> RefinementDimension {
        .init("time", "Time window", options: [
            .init("today", "Today"), .init("yesterday", "Yesterday"),
            .init("week", "Last 7 Days"), .init("month", "Last 30 Days")
        ])
    }

    private static func modifiedDate(title: String = "Modified date") -> RefinementDimension {
        time(title: title)
    }

    private static func kind() -> RefinementDimension {
        .init("kind", "Result kind", options: [
            .init("files", "Files"), .init("folders", "Folders"), .init("apps", "Apps"),
            .init("images", "Images"), .init("pdfs", "PDFs"), .init("messages", "Messages"),
            .init("notes", "Notes"), .init("mail", "Mail")
        ])
    }

    private static func activity() -> RefinementDimension {
        .init("activity", "Activity type", options: [
            .init("added", "Added"), .init("modified", "Modified"),
            .init("opened", "Opened"), .init("downloaded", "Downloaded")
        ])
    }

    private static func recentlyUsed() -> RefinementDimension {
        .init("recent-use", "Recently used", options: [
            .init("today", "Today"), .init("week", "This Week"), .init("month", "This Month")
        ])
    }

    private static func appCategory() -> RefinementDimension {
        .init("app-category", "App category", options: [
            .init("productivity", "Productivity"), .init("creative", "Creative"),
            .init("development", "Development"), .init("communication", "Communication"),
            .init("utilities", "Utilities")
        ])
    }

    private static func installedLocation() -> RefinementDimension {
        .init("installed-location", "Installed location", options: [
            .init("applications", "Applications"), .init("user", "User Apps"),
            .init("system", "System Apps"), .init("utilities", "Utilities")
        ])
    }

    private static func messageContent() -> RefinementDimension {
        .init("content", "Message type", options: [
            .init("text", "Text"), .init("links", "Links"), .init("photos", "Photos"),
            .init("videos", "Videos"), .init("files", "Files"), .init("audio", "Voice & Audio")
        ])
    }

    private static func folder(title: String = "Folder") -> RefinementDimension {
        .init("container", title, options: [
            .init("inbox", "Inbox"), .init("sent", "Sent"), .init("archive", "Archive"),
            .init("drafts", "Drafts"), .init("trash", "Trash")
        ])
    }

    private static func cloudFolder() -> RefinementDimension {
        .init("container", "Top folder", options: [
            .init("desktop", "Desktop"), .init("documents", "Documents"),
            .init("shared", "Shared"), .init("projects", "Projects")
        ])
    }

    private static func account(title: String = "Account") -> RefinementDimension {
        .init("account", title, options: [
            .init("icloud", "iCloud"), .init("gmail", "Gmail"),
            .init("outlook", "Outlook / Exchange"), .init("local", "On My Mac")
        ])
    }

    private static func browser() -> RefinementDimension {
        .init("browser", "Browser", options: [
            .init("safari", "Safari"), .init("chrome", "Chrome"), .init("arc", "Arc"),
            .init("brave", "Brave"), .init("edge", "Edge")
        ])
    }

    private static func domain() -> RefinementDimension {
        .init("domain", "Website / domain", options: [
            .init("work", "Work & Docs"), .init("social", "Social"),
            .init("video", "Video"), .init("shopping", "Shopping"),
            .init("development", "Development")
        ])
    }

    private static func documentFormat() -> RefinementDimension {
        format([
            .init("text", "Text & RTF"), .init("word", "Word"),
            .init("spreadsheet", "Spreadsheets"), .init("presentation", "Presentations"),
            .init("pages", "Pages"), .init("markdown", "Markdown"),
            .init("rtf", "RTF"), .init("odf", "OpenDocument"),
            .init("latex", "LaTeX & BibTeX"),
            .init("notebook", "Jupyter Notebooks"),
            .init("ebook", "eBooks"), .init("publishing", "InDesign"),
            .init("web", "HTML"), .init("data", "JSON, YAML & XML")
        ], title: "Format")
    }

    private static func videoFormat() -> RefinementDimension {
        format([
            .init("mov", "MOV"), .init("mp4", "MP4"), .init("m4v", "M4V"),
            .init("mkv", "MKV"), .init("webm", "WebM"), .init("avi", "AVI"),
            .init("mpeg", "MPEG"), .init("mts", "MTS / M2TS")
        ])
    }

    private static func audioFormat() -> RefinementDimension {
        format([
            .init("mp3", "MP3"), .init("m4a", "M4A"), .init("wav", "WAV"),
            .init("aiff", "AIFF"), .init("flac", "FLAC"), .init("ogg", "OGG"),
            .init("opus", "Opus"), .init("caf", "CAF")
        ])
    }

    private static func cloudFormat() -> RefinementDimension {
        format([
            .init("pdf", "PDF"), .init("word", "Word"), .init("spreadsheet", "Spreadsheet"),
            .init("presentation", "Presentation"), .init("image", "Image"),
            .init("video", "Video"), .init("audio", "Audio"), .init("archive", "Archive")
        ])
    }

    private static func format(_ options: [RefinementOption],
                               title: String = "Format") -> RefinementDimension {
        .init("format", title, options: options)
    }

    private static func mailState(starred: Bool) -> RefinementDimension {
        .init("mail-state", starred ? "Unread or starred" : "Unread or flagged", options: [
            .init("unread", "Unread"), .init(starred ? "starred" : "flagged",
                                             starred ? "Starred" : "Flagged"),
            .init("read", "Read")
        ])
    }

    private static func calendarWindow() -> RefinementDimension {
        .init("time", "Time window", options: [
            .init("today", "Today"), .init("tomorrow", "Tomorrow"),
            .init("week", "This Week"), .init("month", "Next 30 Days")
        ])
    }

    private static func calendarName() -> RefinementDimension {
        .init("container", "Calendar", options: [
            .init("work", "Work"), .init("personal", "Personal"),
            .init("birthdays", "Birthdays"), .init("shared", "Shared")
        ])
    }

    private static func temporalDirection() -> RefinementDimension {
        .init("temporal", "Upcoming or past", options: [
            .init("upcoming", "Upcoming"), .init("past", "Past")
        ])
    }


    private static func photoSource() -> RefinementDimension {
        .init("photo-source", "Source", options: [
            .init("photos-library", "Photo Library"),
            .init("screenshots", "Screenshots"), .init("downloads", "Downloads"),
            .init("desktop", "Desktop")
        ])
    }

    private static func photoDate() -> RefinementDimension {
        .init("photo-date", "Date taken or added", options: [
            .init("today", "Today"), .init("week", "This Week"),
            .init("month", "This Month"), .init("year", "This Year"), .init("older", "Older")
        ])
    }

    private static func duration() -> RefinementDimension {
        .init("duration", "Duration", options: [
            .init("short", "Under 1 minute"), .init("medium", "1–5 minutes"),
            .init("long", "Over 5 minutes")
        ])
    }

    private static func audioType() -> RefinementDimension {
        .init("audio-type", "Type", options: [
            .init("music", "Music"), .init("voice", "Voice memos"),
            .init("podcast", "Podcasts"), .init("recording", "Recordings"),
            .init("sound", "Sound effects")
        ])
    }

    private static func artist() -> RefinementDimension {
        .init("artist", "Artist or album", options: [
            .init("known", "Tagged music"), .init("unknown", "Unknown artist"),
            .init("recordings", "Personal recordings")
        ])
    }

    private static func favorites() -> RefinementDimension {
        .init("favorite", "Favorites", options: [.init("favorite", "Favorites only")])
    }

    private static func projects() -> RefinementDimension {
        .init("project", "Project Type", options: [
            .init("git", "Git repositories"), .init("xcode", "Xcode projects"),
            .init("package", "Package projects")
        ])
    }

    private static func clipboardContent() -> RefinementDimension {
        .init("clipboard-content", "Content type", options: [
            .init("text", "Text"), .init("url", "URLs"), .init("code", "Code"),
            .init("email", "Email addresses"), .init("phone", "Phone numbers"),
            .init("path", "File paths")
        ])
    }

    private static func sourceApp() -> RefinementDimension {
        .init("source-app", "Source app", options: [
            .init("browser", "Browsers"), .init("editor", "Editors"),
            .init("messages", "Messages"), .init("terminal", "Terminal")
        ])
    }

    private static func settingsCategory() -> RefinementDimension {
        .init("settings-category", "Category", options: [
            .init("network", "Network"), .init("display", "Displays"),
            .init("sound", "Sound"), .init("privacy", "Privacy"),
            .init("keyboard", "Keyboard"), .init("accounts", "Accounts")
        ])
    }

    private static func recentlyOpened() -> RefinementDimension {
        .init("recent-open", "Recently opened", options: [
            .init("today", "Today"), .init("week", "This Week"), .init("month", "This Month")
        ])
    }
}

enum RefinementMatcher {
    static func matches(_ result: SearchResult, type: FileType,
                        selection: RefinementSelection, now: Date = Date()) -> Bool {
        selection.choices.allSatisfy { dimension, option in
            matches(result, type: type, dimension: dimension, option: option, now: now)
        }
    }

    private static func matches(_ result: SearchResult, type: FileType,
                                dimension: String, option: String, now: Date) -> Bool {
        if option.hasPrefix("exact:") {
            let expected = String(option.dropFirst(6))
            let value: String
            switch dimension {
            case "container": value = result.facets.container
            case "account": value = result.facets.account
            case "domain": value = result.facets.domain
            case "artist": value = result.facets.artist
            case "source-app": value = result.facets.sourceApp
            default: return true
            }
            return value.searchFolded == expected
        }
        switch dimension {
        case "location":
            return matchesLocation(result.path, option)
        case "time", "photo-date", "recent-use", "recent-open":
            if type == .calendar {
                return matchesCalendarWindow(result.modified ?? .distantPast,
                                             option: option, now: now)
            }
            return matchesTime(result.facets.dateTaken ?? result.effectiveRecency,
                               option: option, now: now)
        case "kind":
            return matchesKind(result, option)
        case "activity":
            return matchesActivity(result, option)
        case "app-category":
            return result.facets.category.searchFolded.contains(option)
        case "installed-location":
            return matchesInstalledLocation(result.path, option)
        case "content":
            return matchesMessageContent(result, option)
        case "container":
            return result.facets.container.searchFolded.contains(option.searchFolded)
        case "account":
            return result.facets.account.searchFolded.contains(option.searchFolded)
        case "browser":
            return result.kind.searchFolded.contains(option)
        case "domain":
            return matchesDomain(result.facets.domain, option)
        case "format":
            return matchesFormat(result, option)
        case "mail-state":
            if option == "unread" { return result.facets.isUnread }
            if option == "read" { return !result.facets.isUnread }
            return result.facets.isFlagged
        case "temporal":
            let date = result.modified ?? .distantPast
            return option == "upcoming" ? date >= now : date < now
        case "photo-source":
            return matchesPhotoSource(result, option)
        case "duration":
            return matchesDuration(result.facets.duration, option)
        case "audio-type":
            return result.facets.contentCategory == option
        case "artist":
            if option == "known" { return !result.facets.artist.isEmpty }
            if option == "unknown" { return result.facets.artist.isEmpty }
            return result.facets.contentCategory == option
        case "favorite":
            return result.facets.isFavorite
        case "project":
            return result.facets.isProject
                && (result.facets.category.isEmpty || result.facets.category == option)
        case "clipboard-content":
            return result.facets.contentCategory == option
        case "source-app":
            return result.facets.sourceApp.searchFolded.contains(option)
        case "settings-category":
            return result.facets.category == option
        default:
            return true
        }
    }

    private static func matchesLocation(_ path: String, _ option: String) -> Bool {
        let home = NSHomeDirectory()
        let prefixes: [String]
        switch option {
        case "home": prefixes = [home]
        case "desktop": prefixes = [home + "/Desktop",
                                    home + "/Library/Mobile Documents/com~apple~CloudDocs/Desktop"]
        case "downloads": prefixes = [home + "/Downloads",
                                      home + "/Library/Mobile Documents/com~apple~CloudDocs/Downloads"]
        case "documents": prefixes = [home + "/Documents",
                                      home + "/Library/Mobile Documents/com~apple~CloudDocs/Documents"]
        case "screenshots": return matchesScreenshot(path)
        case "movies": prefixes = [home + "/Movies"]
        case "photos-library": return path.searchFolded.contains(".photoslibrary/")
        case "projects":
            return path.searchFolded.contains("/projects/")
                || path.searchFolded.contains("/developer/")
        default: return true
        }
        return prefixes.contains { path == $0 || path.hasPrefix($0 + "/") }
    }

    /// The user's custom screenshot folder, resolved once per launch. Files
    /// there rarely keep the "Screenshot" name prefix after renaming, so the
    /// location itself must count as a match.
    private static let configuredScreenshotRoot: String? =
        RecentsStore.configuredScreenshotLocation()
            .map { ($0 as NSString).expandingTildeInPath }

    private static func matchesScreenshot(_ path: String) -> Bool {
        let name = URL(fileURLWithPath: path).lastPathComponent.searchFolded
        if name.hasPrefix("screenshot") || name.hasPrefix("screen shot")
            || path.contains("/Pictures/Screenshots/") {
            return true
        }
        guard let root = configuredScreenshotRoot else { return false }
        return path.hasPrefix(root + "/")
    }

    private static func matchesTime(_ date: Date, option: String, now: Date) -> Bool {
        guard date != .distantPast else { return false }
        let calendar = Calendar.current
        if option == "today" { return calendar.isDate(date, inSameDayAs: now) }
        if option == "yesterday" {
            guard let yesterday = calendar.date(byAdding: .day, value: -1, to: now) else {
                return false
            }
            return calendar.isDate(date, inSameDayAs: yesterday)
        }
        if option == "tomorrow" {
            guard let tomorrow = calendar.date(byAdding: .day, value: 1, to: now) else { return false }
            return calendar.isDate(date, inSameDayAs: tomorrow)
        }
        let days = option == "week" ? 7 : option == "month" ? 30 : option == "year" ? 365 : nil
        if let days {
            return date >= now.addingTimeInterval(-Double(days) * 86_400)
        }
        if option == "older" { return date < now.addingTimeInterval(-30 * 86_400) }
        return true
    }

    private static func matchesCalendarWindow(_ date: Date, option: String,
                                              now: Date) -> Bool {
        guard date != .distantPast else { return false }
        let calendar = Calendar.current
        if option == "today" { return calendar.isDate(date, inSameDayAs: now) }
        if option == "tomorrow" {
            guard let tomorrow = calendar.date(byAdding: .day, value: 1, to: now) else {
                return false
            }
            return calendar.isDate(date, inSameDayAs: tomorrow)
        }
        let days = option == "week" ? 7 : 30
        guard let end = calendar.date(byAdding: .day, value: days, to: now) else {
            return false
        }
        return date >= calendar.startOfDay(for: now) && date <= end
    }

    private static func matchesKind(_ result: SearchResult, _ option: String) -> Bool {
        switch option {
        case "files": return result.source == .file && !result.isFolder && !result.isApp
        case "folders": return result.isFolder
        case "apps": return result.isApp
        case "images":
            // Match the Photos chip's rule: content-type tree OR known
            // extension, so files agree across All→Images and Photos.
            return result.contentTypes.contains("public.image")
                || FileType.photos.filenameExtensions.contains(
                    URL(fileURLWithPath: result.path).pathExtension.lowercased()
                )
        case "pdfs":
            return result.contentTypes.contains("com.adobe.pdf")
                || result.path.lowercased().hasSuffix(".pdf")
        case "messages": return result.source == .message
        case "notes": return result.source == .note
        case "mail": return result.source == .mail
        default: return matchesFormat(result, option)
        }
    }

    private static func matchesActivity(_ result: SearchResult, _ option: String) -> Bool {
        if !result.facets.activity.isEmpty { return result.facets.activity == option }
        if option == "downloaded" { return matchesLocation(result.path, "downloads") }
        if option == "opened" { return result.lastUsed != nil }
        if option == "added" { return result.dateAdded != nil }
        return result.modified != nil
    }

    private static func matchesInstalledLocation(_ path: String, _ option: String) -> Bool {
        if option == "user" { return path.hasPrefix(NSHomeDirectory() + "/Applications/") }
        if option == "system" { return path.hasPrefix("/System/Applications/") }
        if option == "utilities" { return path.contains("/Utilities/") }
        return path.hasPrefix("/Applications/") && !path.contains("/Utilities/")
    }

    private static func matchesMessageContent(_ result: SearchResult, _ option: String) -> Bool {
        if !result.facets.contentCategory.isEmpty {
            return result.facets.contentCategory == option
        }
        let text = result.messageBody ?? ""
        if option == "links" { return text.contains("http://") || text.contains("https://") }
        return option == "text"
    }

    private static func matchesDomain(_ domain: String, _ option: String) -> Bool {
        let value = domain.searchFolded
        let groups: [String: [String]] = [
            "work": ["docs.", "notion.", "linear.", "slack.", "figma."],
            "social": ["twitter.", "x.com", "facebook.", "instagram.", "reddit."],
            "video": ["youtube.", "vimeo.", "twitch."],
            "shopping": ["amazon.", "ebay.", "etsy."],
            "development": ["github.", "gitlab.", "localhost", "stackoverflow."]
        ]
        return groups[option]?.contains(where: value.contains) == true
    }

    private static func matchesFormat(_ result: SearchResult, _ option: String) -> Bool {
        let ext = result.url.pathExtension.lowercased()
        if let allowed = RefinementValueSets.extensions(for: option) {
            return allowed.contains(ext)
        }
        return ext == option
    }

    private static func matchesPhotoSource(_ result: SearchResult, _ option: String) -> Bool {
        if option == "photos-library" {
            return result.facets.sourceApp == "photos-library"
                || result.path.searchFolded.contains(".photoslibrary/")
        }
        if option == "screenshots" { return matchesScreenshot(result.path) }
        return matchesLocation(result.path, option)
    }

    private static func matchesDuration(_ duration: Double?, _ option: String) -> Bool {
        guard let duration else { return false }
        if option == "short" { return duration < 60 }
        if option == "medium" { return duration >= 60 && duration <= 300 }
        return option == "long" && duration > 300
    }
}
