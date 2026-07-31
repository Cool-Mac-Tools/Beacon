import Foundation

/// A user-facing filter category. Each maps to one or more Uniform Type
/// Identifiers that Spotlight records in `kMDItemContentTypeTree`, so matching
/// any descendant type (e.g. PNG, JPEG -> public.image) just works.
enum FileType: String, CaseIterable, Identifiable {
    case all
    case recents
    case apps
    case messages
    case notes
    case history
    case docs
    case word
    case excel
    case powerPoint
    case mail
    case gmail
    case calendar
    case googleDrive
    case oneDrive
    case dropbox
    case iCloudDrive
    case pdfs
    case audio
    case folders
    case photos
    case videos
    case clipboard
    case settings
    case developer

    var id: String { rawValue }

    /// Recents is a recency-ordered view of the file index: recently opened or
    /// added documents, browsable with an empty query and filterable by name.
    var isRecents: Bool { self == .recents }

    /// Apps are scanned directly from application folders because Spotlight can
    /// miss third-party/external installs.
    var isApps: Bool { self == .apps }

    /// Messages are searched from the Messages database, not the file index.
    var isMessages: Bool { self == .messages }

    /// Notes are searched from the Apple Notes database, not the file index.
    var isNotes: Bool { self == .notes }

    /// Apple Mail is searched from its local Envelope Index database.
    var isMail: Bool { self == .mail }
    var isGmail: Bool { self == .gmail }
    var isCalendar: Bool { self == .calendar }

    /// Clipboard history is searched from Beacon's own capture store.
    var isClipboard: Bool { self == .clipboard }

    /// Browser history is searched from Safari/Chromium history databases.
    var isHistory: Bool { self == .history }

    /// System Settings shortcuts are a focused store-backed source.
    var isSettings: Bool { self == .settings }

    /// True for filters backed by the Spotlight file index (All and the file
    /// type chips). Store-backed filters (Apps, Messages, Notes, Recents,
    /// Clipboard, History, Settings) handle their own results and must ignore file-index updates.
    var usesFileIndex: Bool {
        !(isApps || isMessages || isNotes || isMail || isGmail || isCalendar || isRecents
          || isClipboard || isHistory || isSettings)
    }

    /// Whether this source's content appears in the blended "All" view. Files,
    /// apps, messages, and notes do; Clipboard and History are opt-in via their
    /// own chips (and `all` itself isn't marked).
    var includedInAll: Bool {
        switch self {
        // Gmail is already represented by Mail in All; its dedicated chip is
        // a provider-scoped convenience and must not duplicate those rows.
        // Developer is an opt-in code search — it must NOT blend source files
        // back into the everyday All view we just cleared them out of.
        case .all, .recents, .clipboard, .history, .settings, .gmail, .developer: return false
        default: return true
        }
    }

    /// Sources that fully require Full Disk Access (we block with a prompt until
    /// granted). History is intentionally excluded: Chromium browsers read
    /// without it, so History shows what it can and surfaces Safari's lock as a
    /// slim footer instead of blocking.
    var needsFullDiskAccess: Bool {
        self == .messages || self == .notes || self == .mail || self == .gmail
    }

    var title: String {
        switch self {
        case .all: return "Recents"
        case .recents: return "Recents"
        case .apps: return "Apps"
        case .photos: return "Photos"
        case .videos: return "Videos"
        case .docs: return "Docs"
        case .word: return "Word"
        case .excel: return "Excel"
        case .powerPoint: return "PowerPoint"
        case .mail: return "Mail"
        case .gmail: return "Gmail"
        case .calendar: return "Calendar"
        case .googleDrive: return "Google Drive"
        case .oneDrive: return "OneDrive"
        case .dropbox: return "Dropbox"
        case .iCloudDrive: return "iCloud Drive"
        case .pdfs: return "PDFs"
        case .audio: return "Audio"
        case .folders: return "Folders"
        case .messages: return "Messages"
        case .notes: return "Notes"
        case .clipboard: return "Clipboard"
        case .history: return "History"
        case .settings: return "Settings"
        case .developer: return "Developer"
        }
    }

    /// SF Symbol used on the filter chip.
    var symbol: String {
        switch self {
        case .all: return "clock"
        case .recents: return "clock"
        case .apps: return "app.badge"
        case .photos: return "photo"
        case .videos: return "film"
        case .docs: return "doc.text"
        case .word: return "w.square.fill"
        case .excel: return "x.square.fill"
        case .powerPoint: return "p.square.fill"
        case .mail: return "envelope.fill"
        case .gmail: return "envelope.fill"
        case .calendar: return "calendar"
        case .googleDrive: return "externaldrive.connected.to.line.below"
        case .oneDrive: return "cloud.fill"
        case .dropbox: return "shippingbox.fill"
        case .iCloudDrive: return "icloud.fill"
        case .pdfs: return "doc.richtext"
        case .audio: return "music.note"
        case .folders: return "folder"
        case .messages: return "message"
        case .notes: return "note.text"
        case .clipboard: return "doc.on.clipboard"
        case .history: return "clock.arrow.circlepath"
        case .settings: return "gearshape"
        case .developer: return "chevron.left.forwardslash.chevron.right"
        }
    }

    /// Content-type tree UTIs to match. Empty means "no type restriction".
    var contentTypeTrees: [String] {
        switch self {
        case .all:
            return []
        case .recents:
            return [] // no type restriction; the recency window does the filtering
        case .apps:
            return ["com.apple.application"]
        case .photos:
            return ["public.image"]
        case .videos:
            return ["public.movie"]
        case .docs:
            return [
                "public.presentation",
                "public.spreadsheet",
                "com.microsoft.word.doc",
                "com.microsoft.excel.xls",
                "com.microsoft.powerpoint.ppt",
                "com.apple.iwork.pages.sffpages",
                "com.apple.iwork.numbers.sffnumbers",
                "com.apple.iwork.keynote.sffkey"
            ]
        case .word:
            return [
                "com.microsoft.word.doc",
                "org.openxmlformats.wordprocessingml.document",
                "org.openxmlformats.wordprocessingml.template"
            ]
        case .excel:
            return [
                "com.microsoft.excel.xls",
                "org.openxmlformats.spreadsheetml.sheet",
                "org.openxmlformats.spreadsheetml.template"
            ]
        case .powerPoint:
            return [
                "com.microsoft.powerpoint.ppt",
                "org.openxmlformats.presentationml.presentation",
                "org.openxmlformats.presentationml.template",
                "org.openxmlformats.presentationml.slideshow"
            ]
        case .mail, .gmail, .calendar,
             .googleDrive, .oneDrive, .dropbox, .iCloudDrive,
             .messages, .notes, .clipboard, .history, .settings:
            return []
        case .pdfs:
            return ["com.adobe.pdf"]
        case .audio:
            return ["public.audio"]
        case .folders:
            return ["public.folder"]
        case .developer:
            // Spotlight tags most recognized languages as public.source-code;
            // web/config files (html/css/json/yaml…) aren't, so the extension
            // list below supplements this.
            return ["public.source-code"]
        }
    }

    /// Extensions supplement UTIs for providers whose Spotlight metadata is
    /// incomplete (notably cloud-hosted Office documents).
    var filenameExtensions: [String] {
        switch self {
        case .word:
            return ["doc", "docx", "docm", "dot", "dotx", "dotm"]
        case .excel:
            return ["xls", "xlsx", "xlsm", "xlt", "xltx", "xltm", "csv"]
        case .powerPoint:
            return ["ppt", "pptx", "pptm", "pot", "potx", "potm", "pps", "ppsx", "ppsm"]
        case .docs:
            return [
                "txt", "rtf", "rtfd", "md", "markdown", "pages", "numbers", "key",
                "doc", "docx", "docm", "xls", "xlsx", "xlsm", "csv",
                "ppt", "pptx", "pptm", "odt", "ods", "odp",
                "tex", "latex", "bib", "ipynb", "epub", "mobi", "azw", "azw3",
                "indd", "idml", "html", "htm", "json", "jsonl", "yaml", "yml", "xml"
            ]
        case .photos:
            return [
                "png", "jpg", "jpeg", "heic", "heif", "gif", "tif", "tiff",
                "bmp", "webp", "svg", "dng", "raw", "cr2", "cr3", "nef", "arw",
                "psd", "psb", "ai", "sketch", "afphoto", "exr"
            ]
        case .audio:
            return [
                "mp3", "m4a", "aac", "wav", "aiff", "aif", "flac", "alac",
                "ogg", "opus", "caf"
            ]
        case .videos:
            return [
                "mov", "mp4", "m4v", "avi", "mkv", "webm", "mpg", "mpeg",
                "mts", "m2ts", "3gp", "3g2", "ogv", "dv", "vob", "qt",
                "wmv", "flv", "divx", "asf", "mxf"
            ]
        case .developer:
            return [
                // Compiled / systems
                "swift", "h", "hpp", "m", "mm", "c", "cc", "cpp", "cxx",
                "rs", "go", "java", "kt", "kts", "scala", "cs", "dart",
                "zig", "nim", "v",
                // Scripting
                "js", "mjs", "cjs", "jsx", "ts", "tsx", "py", "rb", "php",
                "pl", "pm", "lua", "r", "sh", "bash", "zsh", "fish", "ps1",
                "ex", "exs", "erl", "hs", "clj", "cljs", "jl", "el", "sql",
                // Web / markup / style
                "html", "htm", "css", "scss", "sass", "less", "styl",
                "vue", "svelte", "astro",
                // Config / data / IaC
                "json", "jsonc", "json5", "yaml", "yml", "toml", "xml",
                "gradle", "groovy", "proto", "graphql", "gql", "tf", "hcl",
                "ipynb"
            ]
        default:
            return []
        }
    }

    /// Optional sources begin in Edit → Add rather than crowding the default row.
    var isOptionalSource: Bool {
        switch self {
        case .word, .excel, .powerPoint, .mail, .gmail, .calendar,
             .googleDrive, .oneDrive, .dropbox, .iCloudDrive, .developer: return true
        default: return false
        }
    }

    /// Local roots used by cloud providers. Prefix matching supports both
    /// current File Provider storage and older top-level sync folders.
    var pathPrefixes: [String] {
        let home = NSHomeDirectory()
        switch self {
        case .googleDrive:
            return [
                home + "/Library/CloudStorage/GoogleDrive-",
                home + "/Google Drive"
            ]
        case .oneDrive:
            return [
                home + "/Library/CloudStorage/OneDrive-",
                home + "/OneDrive"
            ]
        case .dropbox:
            return [
                home + "/Library/CloudStorage/Dropbox",
                home + "/Dropbox"
            ]
        case .iCloudDrive:
            return [
                home + "/Library/Mobile Documents/com~apple~CloudDocs",
                home + "/Library/CloudStorage/iCloud Drive"
            ]
        default:
            return []
        }
    }
}
