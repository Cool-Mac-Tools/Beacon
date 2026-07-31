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
}
