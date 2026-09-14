import Foundation
import Combine
import Photos

/// Persistent on-device image embeddings. Includes ordinary image files and
/// already-authorized, locally available Photos originals. No cloud downloads.
final class ImageSemanticIndex: ObservableObject {
    static let shared = ImageSemanticIndex()
    static let modelID = "apple-mobileclip-s0-3e0a7bfb-center-crop-v2"
    @Published private(set) var status = "Local image index is off"
    struct Record: Codable {
        let path: String
        let mtime: Double
        let date: Double
        let vec: [Float]
    }
    struct Snapshot: Codable {
        let model: String
        let records: [Record]
    }
    private let lock = NSLock()
    private var records: [String: Record] = [:]
    private var enabled = UserDefaults.standard.bool(forKey: "beacon.imageIndex.enabled")
    private var queued = false
    private var scanning = false
    private var loaded = false
    private let queue = DispatchQueue(label: "com.beacon.imageindex", qos: .utility)
    private var timer: DispatchSourceTimer?
    private let fm = FileManager.default
    private let extensions: Set<String> = ["jpg","jpeg","png","gif","heic","heif","webp","tiff","tif","bmp","avif","dng","cr2","cr3","arw","nef","raf","orf","rw2"]
    var count: Int { lock.lock(); defer { lock.unlock() }; return records.count }
    var isIndexing: Bool { lock.lock(); defer { lock.unlock() }; return scanning || queued }
    var isEnabled: Bool { lock.lock(); defer { lock.unlock() }; return enabled }
    private init() {}
    private func report(_ text: String) { DispatchQueue.main.async { self.status = text } }
    func start() {
        refresh()
        // Incremental refresh is coalesced, and only runs while explicitly enabled.
        guard timer == nil else { return }
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 120, repeating: 120)
        timer.setEventHandler { [weak self] in self?.refresh() }
        self.timer = timer; timer.resume()
    }
    func setEnabled(_ value: Bool) {
        lock.lock(); enabled = value; lock.unlock()
        UserDefaults.standard.set(value, forKey: "beacon.imageIndex.enabled")
        if value { refresh() } else { report("Paused · existing index stays on this Mac") }
    }
    func refresh() {
        lock.lock()
        guard enabled, !queued, !scanning else { lock.unlock(); return }
        queued = true; lock.unlock()
        queue.async { [weak self] in self?.scan() }
    }
    func topPaths(matching description: String, limit: Int, after: Date? = nil, before: Date? = nil) -> [String] {
        guard isEnabled, limit > 0 else { return [] }
        lock.lock(); let snapshot = Array(records.values); lock.unlock()
        guard !snapshot.isEmpty, let query = CLIPModel.shared.encodeText(description) else { return [] }
        return Self.rank(snapshot, query: query, limit: limit, after: after, before: before).map(\.path)
    }
    static func rank(_ records: [Record], query: [Float], limit: Int, after: Date?, before: Date?) -> [Record] {
        guard limit > 0 else { return [] }
        guard !query.isEmpty, query.allSatisfy({ $0.isFinite }) else { return [] }
        let candidates: [Record] = records.filter { record in
            guard record.vec.count == query.count, record.vec.allSatisfy({ $0.isFinite }) else { return false }
            if let after, record.date < after.timeIntervalSince1970 { return false }
            if let before, record.date > before.timeIntervalSince1970 { return false }
            return true
        }
        var scored: [(record: Record, score: Float)] = candidates.map {
            (record: $0, score: CLIPModel.cosineSimilarity(query, $0.vec))
        }
        scored.sort { lhs, rhs in
            if lhs.score == rhs.score { return lhs.record.path < rhs.record.path }
            return lhs.score > rhs.score
        }
        return scored.prefix(limit).map { $0.record }
    }
    private func scan() {
        lock.lock(); queued = false; scanning = true; lock.unlock()
        defer { lock.lock(); scanning = false; lock.unlock() }
        guard isEnabled else { return }
        report("Loading local image model…")
        guard CLIPModel.shared.isAvailable else { report("Image search model unavailable — reinstall Beacon to restore it"); return }
        load()
        var processed = 0
        var skipped = 0
        var interrupted = false
        func canContinue() -> Bool {
            if !isEnabled { interrupted = true; return false }
            let thermal = ProcessInfo.processInfo.thermalState
            if thermal == .serious || thermal == .critical { interrupted = true; return false }
            return true
        }
        func embed(_ url: URL, date: Date?) {
            guard let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .isRegularFileKey, .isUbiquitousItemKey, .ubiquitousItemDownloadingStatusKey]),
                  values.isRegularFile == true else { skipped += 1; return }
            if values.isUbiquitousItem == true && values.ubiquitousItemDownloadingStatus == .notDownloaded { skipped += 1; return }
            let mtime = values.contentModificationDate?.timeIntervalSince1970 ?? 0
            lock.lock(); let existing = records[url.path]; lock.unlock()
            if let existing, existing.mtime == mtime { return }
            guard let vector = autoreleasepool(invoking: { CLIPModel.shared.encodeImage(path: url.path) }) else { skipped += 1; return }
            let record = Record(path: url.path, mtime: mtime,
                date: (date ?? values.contentModificationDate ?? .distantPast).timeIntervalSince1970, vec: vector)
            lock.lock(); records[url.path] = record; lock.unlock()
            processed += 1
            if processed % 50 == 0 { report("Indexing locally · \(count.formatted()) images ready") }
            if processed % 250 == 0 { save() }
            Thread.sleep(forTimeInterval: 0.015) // yield CPU during large libraries
        }
        for root in roots() {
            guard canContinue() else { break }
            guard let walker = fm.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey, .contentModificationDateKey],
                options: [.skipsHiddenFiles, .skipsPackageDescendants], errorHandler: { _, _ in skipped += 1; return true }) else { continue }
            for case let url as URL in walker {
                guard canContinue() else { break }
                if JunkPath.contains(url.path) { walker.skipDescendants(); continue }
                guard extensions.contains(url.pathExtension.lowercased()) else { continue }
                embed(url, date: nil)
            }
        }
        // Photos is a package skipped by the ordinary filesystem walk. Enumerate its
        // assets through PhotoKit, with no fetchLimit and no implicit permission prompt.
        if canContinue(), PhotoStore.isAuthorized {
            let assets = PHAsset.fetchAssets(with: .image, options: nil)
            assets.enumerateObjects { asset, _, stop in
                guard canContinue() else { stop.pointee = true; return }
                autoreleasepool {
                    if let url = PhotoStore.localURL(for: asset) { embed(url, date: asset.creationDate) }
                    else { skipped += 1 }
                }
            }
        }
        // A partial/permission-limited scan must not erase previously indexed items.
        // Stale paths are filtered at query time; changed files are replaced next scan.
        save()
        if !isEnabled { report("Paused · \(count.formatted()) images stored locally") }
        else if interrupted { report("Paused while Mac is hot · \(count.formatted()) images ready") }
        else {
            let photos = PhotoStore.isAuthorized ? "including local Photos originals" : "Photos not connected"
            report("\(count.formatted()) images indexed · \(photos) · \(skipped) skipped")
        }
    }
    private func roots() -> [URL] {
        let home = fm.homeDirectoryForCurrentUser
        return ["Desktop", "Downloads", "Documents", "Pictures", "Movies"].map {
            home.appendingPathComponent($0, isDirectory: true)
        }.filter { fm.fileExists(atPath: $0.path) }
    }
    private var storeURL: URL? {
        guard let base = try? fm.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true) else { return nil }
        let dir = base.appendingPathComponent("Beacon", isDirectory: true)
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("image-index.v2.json")
    }
    private func load() {
        guard !loaded else { return }; loaded = true
        guard let url = storeURL, let data = try? Data(contentsOf: url, options: .mappedIfSafe),
              let snapshot = try? JSONDecoder().decode(Snapshot.self, from: data), snapshot.model == Self.modelID else { return }
        let valid = snapshot.records.filter { $0.vec.count == CLIPModel.shared.dimension && $0.vec.allSatisfy(\.isFinite) }
        lock.lock(); records = Dictionary(valid.map { ($0.path, $0) }, uniquingKeysWith: { _, new in new }); lock.unlock()
    }
    private func save() {
        guard let url = storeURL else { return }
        lock.lock(); let snapshot = Snapshot(model: Self.modelID, records: Array(records.values)); lock.unlock()
        do { try JSONEncoder().encode(snapshot).write(to: url, options: .atomic) }
        catch { Log.write("Image index save failed: \(error.localizedDescription)") }
    }
}
