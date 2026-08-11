import Foundation

/// Watches a single directory for changes to its contents (files added,
/// removed, or renamed) and fires a debounced callback. Used to keep the
/// folder drill-in view live — drop a file into the folder you're browsing and
/// it appears without reopening the panel. Dependency-free (GCD vnode source).
final class DirectoryWatcher {
    private var source: DispatchSourceFileSystemObject?
    private var debounce: DispatchWorkItem?
    private let onChange: () -> Void

    init(onChange: @escaping () -> Void) {
        self.onChange = onChange
    }

    /// Start watching `url`, replacing any previous watch.
    func watch(_ url: URL) {
        stop()
        let openFD = open(url.path, O_EVTONLY)
        guard openFD >= 0 else { return }
        let src = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: openFD,
            eventMask: [.write, .delete, .rename, .link],
            queue: DispatchQueue.global(qos: .utility)
        )
        src.setEventHandler { [weak self] in self?.scheduleFire() }
        // Capture THIS source's own fd. Reading a shared `self.fd` here raced a
        // rapid re-watch: the new watch() overwrote self.fd before this stale
        // handler ran, so it closed the live fd and killed the new watcher.
        src.setCancelHandler { close(openFD) }
        source = src
        src.resume()
    }

    func stop() {
        debounce?.cancel()
        debounce = nil
        source?.cancel()   // cancel handler closes the fd
        source = nil
    }

    /// Coalesce bursts (e.g. a multi-file copy) into a single refresh.
    private func scheduleFire() {
        debounce?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.onChange() }
        debounce = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: work)
    }

    deinit { stop() }
}
