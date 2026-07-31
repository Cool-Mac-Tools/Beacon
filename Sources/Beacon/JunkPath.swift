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
        // VCS + editor/IDE project folders
        ".git", ".gitignore", ".hg", ".svn", ".vscode", ".idea",
        // JS / TS / Node / Deno / Bun
        "package.json", "node_modules", "tsconfig.json", "jsconfig.json",
        "deno.json", "deno.jsonc", "bun.lockb",
        // Rust / Go / Swift
        "Cargo.toml", "go.mod", "Package.swift",
        // Python
        "pyproject.toml", "Pipfile", "requirements.txt", "setup.py", "setup.cfg",
        // Ruby
        "Gemfile", "Rakefile", "Podfile",
        // JVM (Java / Kotlin / Scala)
        "pom.xml", "build.gradle", "build.gradle.kts",
        "settings.gradle", "settings.gradle.kts", "build.sbt",
        // PHP
        "composer.json",
        // Cloudflare / web
        "wrangler.toml", "wrangler.jsonc",
        // C / C++ / Make / Meson / Bazel
        "CMakeLists.txt", "Makefile", "makefile", "GNUmakefile", "meson.build",
        "configure.ac", "Makefile.am",
        "WORKSPACE", "WORKSPACE.bazel", "MODULE.bazel", "BUILD.bazel",
        // Elixir / Erlang, Dart, Nix, Haskell, OCaml, Zig
        "mix.exs", "rebar.config", "pubspec.yaml",
        "flake.nix", "default.nix", "shell.nix",
        "stack.yaml", "dune-project", "build.zig",
        // Containers / dev infra
        "Dockerfile", "docker-compose.yml", "docker-compose.yaml",
        "compose.yaml", "compose.yml", "Vagrantfile"
    ]
    /// Suffix markers (glob-shaped) checked in addition to the exact names —
    /// Xcode, .NET, Haskell Cabal, RubyGems.
    private static let projectMarkerSuffixes = [
        ".xcodeproj", ".xcworkspace",
        ".sln", ".csproj", ".fsproj", ".vbproj",
        ".cabal", ".gemspec"
    ]

    /// True when a directory's entries include any project marker.
    static func hasProjectMarker(_ entries: [String]) -> Bool {
        for name in entries {
            if projectMarkers.contains(name) { return true }
            if projectMarkerSuffixes.contains(where: name.hasSuffix) { return true }
        }
        return false
    }

    /// The root paths — each with a trailing "/" for prefix matching — of code
    /// projects under `home`. A bounded scan for a project marker: covers
    /// projects directly in home and up to three levels of grouping folder
    /// (~/dev/foo, ~/dev/org/repo, ~/dev/org/team/repo) without walking a large
    /// home tree. Every file-index view except the Developer pill prefix-checks
    /// results against this so a developer's project files (index.html,
    /// LicenseStore.swift, wrangler.toml…) don't bury the real documents you
    /// actually reach for.
    static func projectRoots(under home: String, maxDepth: Int = 4,
                             _ fm: FileManager = .default) -> [String] {
        var roots: [String] = []
        var scanned = 0
        let scanCap = 6000   // safety valve against a pathological home tree
        func scan(_ dir: String, _ depth: Int) {
            guard scanned < scanCap else { return }
            scanned += 1
            guard let entries = try? fm.contentsOfDirectory(atPath: dir) else { return }
            // NEVER treat home itself as a project. A dotfiles-tracked ~/.git or
            // a stray ~/.vscode would otherwise mark "/Users/you/" as a root and
            // exclude every file in Beacon. Only depth >= 1 dirs can be projects.
            if depth > 0, hasProjectMarker(entries) {
                roots.append(dir + "/")   // a project — don't descend into it
                return
            }
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
