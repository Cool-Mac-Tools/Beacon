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

    /// True when `dirPath` is the root of a code project / repository. Detected
    /// by a `.git` entry (a directory for a normal clone, a file for a worktree
    /// or submodule) — the generic, language-agnostic marker that catches
    /// essentially every serious dev project without guessing by extension.
    ///
    /// Beacon prunes these trees from the Recents scan so a developer's source
    /// files (index.html, LicenseStore.swift, sitemap.xml…) don't bury the real
    /// documents you actually reach for — and so the scan stays fast instead of
    /// walking and thumbnailing thousands of project files.
    static func isProjectRoot(_ dirPath: String, _ fm: FileManager = .default) -> Bool {
        fm.fileExists(atPath: dirPath + "/.git")
    }

    /// The root paths — each with a trailing "/" for prefix matching — of code
    /// repositories under `home`. A shallow, bounded scan for `.git`: covers
    /// repos that sit directly in home (the common case) and one level of
    /// grouping folder (~/dev/foo, ~/Projects/bar) without walking a large home
    /// tree. The Spotlight-backed views prefix-check results against this to
    /// keep project files out of everything except the Developer pill.
    static func projectRoots(under home: String, maxDepth: Int = 2,
                             _ fm: FileManager = .default) -> [String] {
        var roots: [String] = []
        func scan(_ dir: String, _ depth: Int) {
            guard let entries = try? fm.contentsOfDirectory(atPath: dir) else { return }
            if entries.contains(".git") { roots.append(dir + "/"); return } // a repo — don't descend
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
