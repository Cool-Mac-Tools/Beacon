import Foundation

/// Minimal file logger so we can diagnose startup/hotkey behavior even when
/// the app is launched as a bundle (where stdout/stderr go nowhere).
/// Writes to ~/Library/Logs/Beacon.log.
enum Log {
    private static let url: URL = {
        let dir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs", isDirectory: true)
        return dir.appendingPathComponent("Beacon.log")
    }()

    private static let formatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss.SSS"
        return f
    }()

    private static let maxBytes = 5 * 1_024 * 1_024

    /// All file work happens on this serial queue so `write` never blocks the
    /// caller (it was previously opening/seeking/closing a FileHandle on the
    /// main thread on every call — a real hitch in hot paths like search).
    private static let queue = DispatchQueue(label: "com.beacon.log", qos: .utility)

    /// A single handle kept open for the process lifetime, rotating once at
    /// startup. Lazily created on the log queue.
    private static var handle: FileHandle? = {
        let fm = FileManager.default
        // Rotate once: if the log is oversized, move it to Beacon.log.old so at
        // most ~2×maxBytes of logs exist.
        if let size = try? fm.attributesOfItem(atPath: url.path)[.size] as? Int,
           size > maxBytes {
            let old = url.deletingLastPathComponent().appendingPathComponent("Beacon.log.old")
            try? fm.removeItem(at: old)
            try? fm.moveItem(at: url, to: old)
        }
        if !fm.fileExists(atPath: url.path) {
            fm.createFile(atPath: url.path, contents: nil)
        }
        let handle = try? FileHandle(forWritingTo: url)
        _ = try? handle?.seekToEnd()
        return handle
    }()

    /// Verbose logging is opt-in via `defaults write com.beacon.search
    /// beacon.debug.logging -bool YES`. It stays OFF in shipped builds so we
    /// don't write the user's search terms and AI prompts to a plaintext file
    /// on every keystroke. Read once at launch — a debug switch doesn't need to
    /// react mid-session, and this keeps `debug` free on the hot path.
    static let verbose = UserDefaults.standard.bool(forKey: "beacon.debug.logging")

    static func write(_ message: String) {
        queue.async {
            let line = "[\(formatter.string(from: Date()))] \(message)\n"
            guard let data = line.data(using: .utf8) else { return }
            try? handle?.write(contentsOf: data)
        }
    }

    /// Chatty, per-keystroke, or query-term-bearing diagnostics. No-ops (and
    /// never builds the string) unless verbose logging is enabled. Use this for
    /// anything that fires on the search hot path or embeds user content.
    static func debug(_ message: @autoclosure () -> String) {
        guard verbose else { return }
        write(message())
    }
}
