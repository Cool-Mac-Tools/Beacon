import Foundation

/// Single source of truth for the developer/system directories Beacon hides
/// from results — build artifacts, package caches, VCS internals, and Trash.
///
/// These lists were previously duplicated across three call sites in
/// `SearchEngine` plus one in `FolderStore`, and had already drifted apart: the
/// recents-path check was missing half the entries the document-path check had,
/// so a stray file under `~/.cargo/` or an app-bundle icon could surface while
/// browsing even though a normal type search would have hidden it. Every
/// consumer now points here.
enum JunkPath {
    /// Bare directory names. A path is junk when any of these is a full path
    /// component. Used for exact last-component matches (folder indexing).
    static let components: [String] = [
        ".git", "node_modules", ".build", "DerivedData",
        "Caches", "__pycache__", ".Trash", ".npm", ".cargo", ".rustup"
    ]

    /// Slash-wrapped forms for substring matching against a full path
    /// (`"/node_modules/"`). Includes `.app/Contents/` so app-bundle internals
    /// (embedded icons, frameworks) never surface as user files.
    static let pathFragments: [String] =
        components.map { "/\($0)/" } + [".app/Contents/"]

    /// True when `path` runs through any excluded directory.
    static func contains(_ path: String) -> Bool {
        pathFragments.contains(where: path.contains)
    }

    /// Filenames whose presence in a directory marks it as a code project —
    /// broader than `.git` alone, because not every project folder is a git
    /// repo (a fresh Cloudflare Worker, a downloaded sample, a de-initialized
    /// clone). These are high-signal: a normal document folder doesn't contain
    /// a package.json or a wrangler.toml.
    static let projectMarkers: Set<String> = [
        ".git", ".gitignore", ".hg", ".svn",
        "package.json", "node_modules", "tsconfig.json", "jsconfig.json",
        "Cargo.toml", "go.mod", "Package.swift",
        "pyproject.toml", "Pipfile", "requirements.txt", "setup.py",
        "Gemfile", "pom.xml", "build.gradle", "build.gradle.kts",
        "composer.json", "wrangler.toml", "wrangler.jsonc", "CMakeLists.txt"
    ]
    /// Suffix markers (glob-shaped) checked in addition to the exact names.
    private static let projectMarkerSuffixes = [".xcodeproj", ".xcworkspace"]

    /// True when a directory's entries include any project marker.
    static func hasProjectMarker(_ entries: [String]) -> Bool {
        for name in entries {
            if projectMarkers.contains(name) { return true }
            if projectMarkerSuffixes.contains(where: name.hasSuffix) { return true }
        }
        return false
    }

    /// The root paths — each with a trailing "/" for prefix matching — of code
    /// projects under `home`. A shallow, bounded scan for a project marker:
    /// covers projects that sit directly in home (the common case) and one
    /// level of grouping folder (~/dev/foo, ~/Projects/bar) without walking a
    /// large home tree. Every file-index view except the Developer pill
    /// prefix-checks results against this so a developer's project files
    /// (index.html, LicenseStore.swift, wrangler.toml…) don't bury the real
    /// documents you actually reach for.
    static func projectRoots(under home: String, maxDepth: Int = 2,
                             _ fm: FileManager = .default) -> [String] {
        var roots: [String] = []
        func scan(_ dir: String, _ depth: Int) {
            guard let entries = try? fm.contentsOfDirectory(atPath: dir) else { return }
            if hasProjectMarker(entries) { roots.append(dir + "/"); return } // a project — don't descend
            guard depth < maxDepth else { return }
            for name in entries where !name.hasPrefix(".") && !components.contains(name) {
                if depth == 0, name == "Library" || name == "Applications" { continue }
                let child = dir + "/" + name
                var isDir: ObjCBool = false
                if fm.fileExists(atPath: child, isDirectory: &isDir), isDir.boolValue {
                    scan(child, depth + 1)
                }
            }
        }
        scan(home, 0)
        return roots
    }
}
