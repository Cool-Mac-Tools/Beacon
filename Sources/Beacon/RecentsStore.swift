import Foundation
import UniformTypeIdentifiers

/// A file discovered by Beacon's filesystem-backed Recents scanner.
struct RecentFileRecord {
    let path: String
    let name: String
    let kind: String
    let size: Int64?
    let modified: Date?
    let dateAdded: Date?
    let isFolder: Bool
    let isApp: Bool
    let contentTypes: [String]
    let recency: Date
    let matchQuality: SearchText.MatchQuality
}

/// A deterministic Recents backend that does not rely on Spotlight/Finder's
/// "recents" behavior. Spotlight can lag or miss freshly saved/downloaded
/// files; the filesystem does not. We scan visible user folders, ignore app
/// internals, and sort by the newest touch we can observe.
final class RecentsStore {
    private let home: String
    private let fm = FileManager.default
    private let windowDays = 30.0
    private let freshLaneHours = 48.0
    private let maxVisitedFilesPerRoot = 20_000
    private var lastSearchTokens: [String] = []
    private var lastSearchMatches: [RecentFileRecord] = []
    private var hasCachedSearch = false
    private let cacheLock = NSLock()
    private var cacheGeneration = 0
    private var lastScanAt = Date.distantPast
    private var freshCache: [RecentFileRecord] = []
    private var freshCachedAt = Date.distantPast

    private let resourceKeys: Set<URLResourceKey> = [
        .isDirectoryKey,
        .isRegularFileKey,
        .isPackageKey,
        .contentModificationDateKey,
        .creationDateKey,
        .addedToDirectoryDateKey,
        .fileSizeKey,
        .contentTypeKey
    ]

    init(home: String = NSHomeDirectory()) {
        self.home = home
    }

    func search(tokens: [String], limit: Int = 200,
                isCancelled: (() -> Bool)? = nil) -> [RecentFileRecord] {
        cacheLock.lock()
        if hasCachedSearch && tokens == lastSearchTokens {
            let cached = Array(lastSearchMatches.prefix(limit))
            cacheLock.unlock()
            return cached
        }
        let generation = cacheGeneration
        cacheLock.unlock()
        let cutoff = Date(timeIntervalSinceNow: -windowDays * 86_400)
        let freshCutoff = Date(timeIntervalSinceNow: -freshLaneHours * 3_600)
        var visited = 0
        var out: [RecentFileRecord] = []
        var seenPaths = Set<String>()
        out.reserveCapacity(limit * 2)

        // Code projects (git repos and marker folders like ~/coolmac-license)
        // are noise in Recents and slow the crawl. Compute their roots once,
        // then skip any root that is (or sits under) one and prune matching
        // subtrees during enumeration — all cheap string prefix checks.
        let projectRoots = JunkPath.projectRoots(under: home)
        func isInProject(_ path: String) -> Bool {
            projectRoots.contains { path.hasPrefix($0) || $0 == path + "/" }
        }
        let scanRoots = roots().filter { !isInProject($0.path) }

        // Fast lane: screenshots/downloads are usually top-level files. Grab
        // fresh files from those folders before any deep crawl can be slowed by
        // a huge Downloads/Documents tree.
        for root in freshRoots() {
            guard isCancelled?() != true else { return [] }
            guard let urls = try? fm.contentsOfDirectory(
                at: root,
                includingPropertiesForKeys: Array(resourceKeys),
                options: [.skipsHiddenFiles]
            ) else { continue }

            for url in urls {
                visited += 1
                if visited & 0xFF == 0, isCancelled?() == true { return [] }
                guard let record = record(for: url, tokens: tokens, cutoff: freshCutoff) else { continue }
                guard seenPaths.insert(record.path).inserted else { continue }
                out.append(record)
            }
        }

        for root in scanRoots {
            guard isCancelled?() != true else { return [] }
            var rootVisited = 0
            guard let enumerator = fm.enumerator(
                at: root,
                includingPropertiesForKeys: Array(resourceKeys),
                options: [.skipsHiddenFiles, .skipsPackageDescendants],
                errorHandler: { url, error in
                    Log.write("RecentsStore: skip \(url.path) err=\(error.localizedDescription)")
                    return true
                }
            ) else { continue }

            for case let url as URL in enumerator {
                visited += 1
                rootVisited += 1
                if visited & 0x3FF == 0, isCancelled?() == true { return [] }
                if rootVisited > maxVisitedFilesPerRoot {
                    Log.write("RecentsStore: root cap hit \(root.path) (\(maxVisitedFilesPerRoot))")
                    break
                }

                if shouldSkipComponent(url.lastPathComponent) {
                    enumerator.skipDescendants()
                    continue
                }
                // Prune code-project subtrees nested deeper (e.g.
                // ~/Documents/some-project). Pure string check against the
                // precomputed roots — no per-item syscall.
                if isInProject(url.path) {
                    enumerator.skipDescendants()
                    continue
                }

                guard let record = record(for: url, tokens: tokens, cutoff: cutoff) else { continue }
                guard seenPaths.insert(record.path).inserted else { continue }
                out.append(record)
            }
        }

        let matches = out
            .sorted {
                if $0.matchQuality != $1.matchQuality {
                    return $0.matchQuality < $1.matchQuality
                }
                if $0.recency != $1.recency { return $0.recency > $1.recency }
                return $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
            }
            .map { $0 }
        cacheLock.lock()
        if generation == cacheGeneration {
            lastSearchTokens = tokens
            lastSearchMatches = matches
            hasCachedSearch = true
            lastScanAt = Date()
        }
        cacheLock.unlock()
        let results = Array(matches.prefix(limit))

        Log.debug("RecentsStore: scanned=\(visited) roots=\(scanRoots.count) matched=\(out.count) returned=\(results.count) tokens=\(tokens)")
        return results
    }

    func freshItems(limit: Int = 500,
                    isCancelled: (() -> Bool)? = nil) -> [RecentFileRecord] {
        cacheLock.lock()
        if Date().timeIntervalSince(freshCachedAt) < 3 {
            let cached = Array(freshCache.prefix(limit))
            cacheLock.unlock()
            return cached
        }
        cacheLock.unlock()
        let cutoff = Date(timeIntervalSinceNow: -freshLaneHours * 3_600)
        var rows: [RecentFileRecord] = []
        var seenPaths = Set<String>()

        for root in freshRoots() {
            guard isCancelled?() != true else { return [] }
            guard let urls = try? fm.contentsOfDirectory(
                at: root,
                includingPropertiesForKeys: Array(resourceKeys),
                options: [.skipsHiddenFiles]
            ) else { continue }
            for (index, url) in urls.enumerated() {
                if index & 0xFF == 0, isCancelled?() == true { return [] }
                guard let record = record(for: url, tokens: [], cutoff: cutoff),
                      seenPaths.insert(record.path).inserted else { continue }
                rows.append(record)
            }
        }

        let sorted = rows
            .sorted {
                if $0.recency != $1.recency { return $0.recency > $1.recency }
                return $0.name.localizedStandardCompare($1.name) == .orderedAscending
            }
        cacheLock.lock()
        freshCache = sorted
        freshCachedAt = Date()
        cacheLock.unlock()
        return Array(sorted.prefix(limit))
    }

    func refresh() {
        cacheLock.lock()
        freshCache = []
        freshCachedAt = .distantPast
        guard Date().timeIntervalSince(lastScanAt) >= 300 else {
            cacheLock.unlock()
            return
        }
        cacheGeneration &+= 1
        hasCachedSearch = false
        lastSearchMatches = []
        cacheLock.unlock()
    }

    private func record(for url: URL, tokens: [String], cutoff: Date) -> RecentFileRecord? {
        let name = url.lastPathComponent
        guard !shouldSkipComponent(name) else { return nil }

        guard let values = try? url.resourceValues(forKeys: resourceKeys) else { return nil }
        let isFolder = values.isDirectory == true
        guard isFolder || values.isRegularFile == true else { return nil }
        guard values.isPackage != true else { return nil }

        let foldedName = name.searchFolded
        let matchQuality = SearchText.matchQuality(foldedName, tokens: tokens)
        if !tokens.isEmpty, matchQuality == nil { return nil }

        let modified = values.contentModificationDate
        let added = values.addedToDirectoryDate
        let created = values.creationDate
        let recency = [added, modified, created].compactMap { $0 }.max() ?? .distantPast
        guard recency >= cutoff else { return nil }

        let type = values.contentType
        let ext = url.pathExtension.lowercased()
        var contentTypes = type.map { [$0.identifier] } ?? []
        if FileType.photos.filenameExtensions.contains(ext) {
            contentTypes.append("public.image")
        }
        if FileType.videos.filenameExtensions.contains(ext) {
            contentTypes.append("public.movie")
        }
        if FileType.audio.filenameExtensions.contains(ext) {
            contentTypes.append("public.audio")
        }
        if ext == "pdf" { contentTypes.append("com.adobe.pdf") }
        if isFolder { contentTypes.append("public.folder") }
        return RecentFileRecord(
            path: url.standardizedFileURL.path,
            name: name,
            kind: isFolder ? "Folder" : (type?.localizedDescription ?? "File"),
            size: isFolder ? nil : values.fileSize.map(Int64.init),
            modified: modified,
            dateAdded: added ?? created,
            isFolder: isFolder,
            isApp: false,
            contentTypes: contentTypes,
            recency: recency,
            matchQuality: matchQuality ?? .substring
        )
    }

    /// Scan user-facing folders first. This catches Downloads/Desktop/Pictures
    /// immediately, while still including other visible home folders.
    private func roots() -> [URL] {
        let preferred = ["Desktop", "Downloads", "Pictures", "Documents", "Movies", "Music"]
        var seen = Set<String>()
        var urls: [URL] = []

        func add(_ path: String) {
            let expanded = (path as NSString).expandingTildeInPath
            let standardized = URL(fileURLWithPath: expanded, isDirectory: true).standardizedFileURL.path
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: standardized, isDirectory: &isDir), isDir.boolValue else { return }
            guard seen.insert(standardized).inserted else { return }
            urls.append(URL(fileURLWithPath: standardized, isDirectory: true))
        }

        for path in screenshotRoots() { add(path) }
        for name in preferred { add(home + "/" + name) }

        let entries = (try? fm.contentsOfDirectory(atPath: home)) ?? []
        for entry in entries.sorted() {
            guard !entry.hasPrefix("."), entry != "Library", entry != "Applications" else { continue }
            guard !shouldSkipComponent(entry) else { continue }
            add(home + "/" + entry)
        }

        // iCloud Drive is real user content even though it lives under Library.
        let cloudDocs = home + "/Library/Mobile Documents/com~apple~CloudDocs"
        add(cloudDocs + "/Desktop")
        add(cloudDocs + "/Downloads")
        add(cloudDocs + "/Pictures")
        add(cloudDocs)
        return urls
    }

    private func freshRoots() -> [URL] {
        var seen = Set<String>()
        var urls: [URL] = []
        for path in screenshotRoots()
            + [
                home + "/Desktop",
                home + "/Downloads",
                home + "/Pictures/Screenshots",
                home + "/Library/Mobile Documents/com~apple~CloudDocs/Desktop",
                home + "/Library/Mobile Documents/com~apple~CloudDocs/Downloads",
                home + "/Library/Mobile Documents/com~apple~CloudDocs/Pictures/Screenshots"
            ] {
            let expanded = (path as NSString).expandingTildeInPath
            let standardized = URL(fileURLWithPath: expanded, isDirectory: true).standardizedFileURL.path
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: standardized, isDirectory: &isDir), isDir.boolValue else { continue }
            guard seen.insert(standardized).inserted else { continue }
            urls.append(URL(fileURLWithPath: standardized, isDirectory: true))
        }
        return urls
    }

    private func screenshotRoots() -> [String] {
        Self.screenshotRoots(home: home)
    }

    /// Every place screenshots can land, honoring the user's configured
    /// `com.apple.screencapture location`. Single source of truth — the
    /// refinement path prefixes and matcher must use this too, so a custom
    /// screenshot folder behaves identically everywhere.
    static func screenshotRoots(home: String = NSHomeDirectory()) -> [String] {
        var roots: [String] = []
        if let configured = configuredScreenshotLocation(), !configured.isEmpty {
            roots.append((configured as NSString).expandingTildeInPath)
        }
        roots += [
            home + "/Desktop",
            home + "/Pictures/Screenshots",
            home + "/Library/Mobile Documents/com~apple~CloudDocs/Desktop",
            home + "/Library/Mobile Documents/com~apple~CloudDocs/Pictures/Screenshots"
        ]
        return roots
    }

    static func configuredScreenshotLocation() -> String? {
        if let configured = UserDefaults.standard
            .persistentDomain(forName: "com.apple.screencapture")?["location"] as? String,
           !configured.isEmpty {
            return configured
        }
        if let configured = UserDefaults(suiteName: "com.apple.screencapture")?
            .string(forKey: "location"), !configured.isEmpty {
            return configured
        }
        return nil
    }

    private func shouldSkipComponent(_ name: String) -> Bool {
        if name.hasPrefix(".") { return true }
        let skipped: Set<String> = [
            "node_modules",
            ".git",
            ".build",
            "build",
            "dist",
            "DerivedData",
            "Caches",
            "__pycache__"
        ]
        return skipped.contains(name)
    }
}
