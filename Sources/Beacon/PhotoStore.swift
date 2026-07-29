import Foundation
import Photos
import AVFoundation

/// Reads the user's Photos library via PhotoKit and resolves each matching
/// asset to its on-disk original file URL. That lets photo-library images and
/// videos be searched and opened like any other file — Beacon's existing file
/// pipeline (thumbnails, open, reveal, drag-out) handles the rest, so no new
/// result type is needed.
///
/// Photos are matched by media type and date range, not keywords: a photo's
/// content is visual, and its filename is usually a UUID or "IMG_1234". Visual
/// matching ("a hooded figure") is a later, vision-based step.
enum PhotoStore {

    struct Hit {
        let url: URL
        let name: String
        let creationDate: Date?
        let isVideo: Bool
    }

    /// True if we can read the library right now without prompting.
    static var isAuthorized: Bool {
        let s = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        return s == .authorized || s == .limited
    }

    /// Synchronous search — safe on a background queue (never the main thread,
    /// since it blocks on PhotoKit completions). `tokens` (already folded) filter
    /// on the original filename; they're checked BEFORE the expensive URL
    /// resolution so a typed query stays fast.
    static func search(wantImage: Bool, wantVideo: Bool,
                       after: Date?, before: Date?, limit: Int,
                       tokens: [String] = []) -> [Hit] {
        guard limit > 0, ensureAuthorized() else { return [] }

        let opts = PHFetchOptions()
        var preds: [NSPredicate] = []
        if wantImage && !wantVideo {
            preds.append(NSPredicate(format: "mediaType == %d", PHAssetMediaType.image.rawValue))
        } else if wantVideo && !wantImage {
            preds.append(NSPredicate(format: "mediaType == %d", PHAssetMediaType.video.rawValue))
        } else {
            preds.append(NSPredicate(format: "mediaType == %d OR mediaType == %d",
                                     PHAssetMediaType.image.rawValue, PHAssetMediaType.video.rawValue))
        }
        if let after { preds.append(NSPredicate(format: "creationDate >= %@", after as NSDate)) }
        if let before { preds.append(NSPredicate(format: "creationDate <= %@", before as NSDate)) }
        opts.predicate = NSCompoundPredicate(andPredicateWithSubpredicates: preds)
        opts.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
        // Over-fetch: some assets are iCloud-only with no local original.
        opts.fetchLimit = min(max(limit, 1) * 4, 500)

        let assets = PHAsset.fetchAssets(with: opts)
        var hits: [Hit] = []
        assets.enumerateObjects { asset, _, stop in
            if hits.count >= limit { stop.pointee = true; return }
            let name = originalName(for: asset)
            // Cheap filename filter first — avoids resolving URLs for non-matches.
            if !tokens.isEmpty {
                let folded = (name ?? "").searchFolded
                guard tokens.allSatisfy({ folded.contains($0) }) else { return }
            }
            guard let url = resolveLocalURL(for: asset),
                  FileManager.default.fileExists(atPath: url.path) else { return }
            hits.append(Hit(url: url, name: name ?? url.lastPathComponent,
                            creationDate: asset.creationDate,
                            isVideo: asset.mediaType == .video))
        }
        return hits
    }

    // MARK: - Authorization

    private static func ensureAuthorized() -> Bool {
        switch PHPhotoLibrary.authorizationStatus(for: .readWrite) {
        case .authorized, .limited:
            return true
        case .notDetermined:
            let sem = DispatchSemaphore(value: 0)
            var granted = false
            PHPhotoLibrary.requestAuthorization(for: .readWrite) { status in
                granted = (status == .authorized || status == .limited)
                sem.signal()
            }
            _ = sem.wait(timeout: .now() + 120)   // waits on the system prompt
            return granted
        default:
            return false
        }
    }

    // MARK: - Resolve the on-disk original (public API only)

    private static func originalName(for asset: PHAsset) -> String? {
        PHAssetResource.assetResources(for: asset).first?.originalFilename
    }

    private static func resolveLocalURL(for asset: PHAsset) -> URL? {
        let options = PHContentEditingInputRequestOptions()
        options.isNetworkAccessAllowed = false   // local originals only; skip iCloud fetches

        var found: URL?
        let sem = DispatchSemaphore(value: 0)
        asset.requestContentEditingInput(with: options) { input, _ in
            if let imageURL = input?.fullSizeImageURL {
                found = imageURL
            } else if let av = input?.audiovisualAsset as? AVURLAsset {
                found = av.url
            }
            sem.signal()
        }
        _ = sem.wait(timeout: .now() + 5)
        return found
    }
}
