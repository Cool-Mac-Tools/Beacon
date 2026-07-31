import Foundation

struct FolderRecord {
    let path: String
    let name: String
    let modified: Date?
}

final class FolderStore {
    private let home: URL
    private let fm = FileManager.default
    private var cache: [FolderRecord] = []
    private var builtAt: Date?

    init(home: URL = FileManager.default.homeDirectoryForCurrentUser) {
        self.home = home
    }

    func prepare(isCancelled: (() -> Bool)? = nil) {
        guard cache.isEmpty else { return }
        let rows = buildIndex(isCancelled: isCancelled)
        guard isCancelled?() != true else { return }
        cache = rows
        builtAt = Date()
    }

    /// Rebuild the index when it's older than `ttl`, so folders created or
    /// deleted mid-session show up without an app restart. Searches issued
    /// while a rebuild runs still see the previous cache (all access is
    /// confined to the engine's folderQueue).
    func refreshIfStale(olderThan ttl: TimeInterval = 300,
                        isCancelled: (() -> Bool)? = nil) {
        if let builtAt, Date().timeIntervalSince(builtAt) < ttl { return }
        let rows = buildIndex(isCancelled: isCancelled)
        guard isCancelled?() != true else { return }
        cache = rows
        builtAt = Date()
    }

    func search(tokens: [String], limit: Int = 400,
                isCancelled: (() -> Bool)? = nil) -> [FolderRecord] {
        guard !tokens.isEmpty else { return [] }
        if cache.isEmpty {
            prepare(isCancelled: isCancelled)
        }

        return cache
            .filter { record in
                let foldedName = record.name.searchFolded
                return tokens.allSatisfy(foldedName.contains)
            }
            .map { record -> (FolderRecord, Int) in
                let foldedName = record.name.searchFolded
                let query = tokens.joined(separator: " ")
                let score: Int
                if foldedName == query {
                    score = 0
                } else if foldedName.hasPrefix(query) {
                    score = 1
                } else if tokens.allSatisfy({
                    SearchText.hasWholeWord(foldedName, $0)
                }) {
                    score = 2
                } else if tokens.allSatisfy({
                    SearchText.hasWordStart(foldedName, $0)
                }) {
                    score = 3
                } else {
                    score = 4
                }
                return (record, score)
            }
            .sorted {
                if $0.1 != $1.1 { return $0.1 < $1.1 }
                if $0.0.modified != $1.0.modified {
                    return ($0.0.modified ?? .distantPast)
                        > ($1.0.modified ?? .distantPast)
                }
                return $0.0.name.localizedStandardCompare($1.0.name)
                    == .orderedAscending
            }
            .prefix(limit)
            .map(\.0)
            .filter { record in
                // Drop folders deleted since the index was built so ghosts
                // never reach the results list; prune them from the cache too.
                if fm.fileExists(atPath: record.path) { return true }
                cache.removeAll { $0.path == record.path }
                return false
            }
    }

    func refresh() {
        cache = []
        builtAt = nil
    }

    private func buildIndex(isCancelled: (() -> Bool)?) -> [FolderRecord] {
        let startedAt = Date()
        var rows: [FolderRecord] = []
        var seen = Set<String>()
        let keys: [URLResourceKey] = [
            .isDirectoryKey,
            .isPackageKey,
            .nameKey,
            .contentModificationDateKey
        ]

        rootLoop: for root in roots() {
            guard isCancelled?() != true else { return [] }
            if seen.insert(root.path).inserted {
                let values = try? root.resourceValues(
                    forKeys: [.nameKey, .contentModificationDateKey]
                )
                rows.append(
                    FolderRecord(
                        path: root.path,
                        name: values?.name ?? root.lastPathComponent,
                        modified: values?.contentModificationDate
                    )
                )
            }
            guard let enumerator = fm.enumerator(
                at: root,
                includingPropertiesForKeys: keys,
                options: [.skipsHiddenFiles, .skipsPackageDescendants],
                errorHandler: { _, _ in true }
            ) else { continue }

            for case let url as URL in enumerator {
                if rows.count & 0xFF == 0, isCancelled?() == true { return [] }
                guard let values = try? url.resourceValues(
                    forKeys: Set(keys)
                ), values.isDirectory == true else { continue }

                if shouldSkip(url: url, isPackage: values.isPackage == true) {
                    enumerator.skipDescendants()
                    continue
                }
                guard seen.insert(url.path).inserted else { continue }
                rows.append(
                    FolderRecord(
                        path: url.path,
                        name: values.name ?? url.lastPathComponent,
                        modified: values.contentModificationDate
                    )
                )
                if rows.count >= 100_000 { break rootLoop }
            }
        }
        Log.write(
            "FolderStore: indexed \(rows.count) folders in "
                + String(format: "%.2fs", Date().timeIntervalSince(startedAt))
        )
        return rows
    }

    private func roots() -> [URL] {
        var roots = homeChildren()
        let cloudStorage = home
            .appendingPathComponent("Library/CloudStorage", isDirectory: true)
        let iCloud = home.appendingPathComponent(
            "Library/Mobile Documents/com~apple~CloudDocs",
            isDirectory: true
        )
        for root in [cloudStorage, iCloud] where fm.fileExists(atPath: root.path) {
            roots.append(root)
        }
        return roots
    }

    private func homeChildren() -> [URL] {
        guard let children = try? fm.contentsOfDirectory(
            at: home,
            includingPropertiesForKeys: [.isDirectoryKey, .isPackageKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }
        return children.filter { url in
            guard url.lastPathComponent != "Library",
                  let values = try? url.resourceValues(
                      forKeys: [.isDirectoryKey, .isPackageKey]
                  ) else { return false }
            return values.isDirectory == true && values.isPackage != true
        }
    }

    private func shouldSkip(url: URL, isPackage: Bool) -> Bool {
        if isPackage { return true }
        return JunkPath.components.contains(url.lastPathComponent)
    }
}
