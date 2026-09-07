import Foundation

/// Classifies a free-text file-type hint (from the AI model, which may say
/// "picture", "screenshot", "clip", "img"… not just the tool-spec enum) into a
/// canonical media kind. Centralized so the conductor, SearchEngine, and
/// Spotlight all agree on what counts as an image/video search. Word-based (not
/// substring) so short synonyms like "pic"/"img" can't false-match inside other
/// words.
enum AIMediaKind {
    case image
    case video

    private static let imageWords: Set<String> = [
        "image", "images", "img", "imgs", "picture", "pictures", "pic", "pics",
        "photo", "photos", "photograph", "photographs", "pix", "snap", "snaps",
        "snapshot", "snapshots", "screenshot", "screenshots", "screengrab",
        "selfie", "selfies", "headshot", "headshots", "wallpaper", "wallpapers",
        "meme", "memes", "gif", "gifs", "drawing", "drawings", "artwork",
        "graphic", "graphics", "icon", "logo", "scan", "scans"
    ]
    private static let videoWords: Set<String> = [
        "video", "videos", "movie", "movies", "film", "films", "clip", "clips",
        "footage", "recording", "recordings", "reel", "reels", "screencast",
        "screencasts", "screenrecording", "mov", "mp4"
    ]

    static func classify(_ fileType: String?) -> AIMediaKind? {
        guard let raw = fileType?.lowercased(), !raw.isEmpty else { return nil }
        let words = Set(raw.split { !$0.isLetter && !$0.isNumber }.map(String.init))
        // "screen recording" -> {screen, recording}; check video first so a
        // phrase mentioning both leans to the more specific media.
        if !words.isDisjoint(with: videoWords) { return .video }
        if !words.isDisjoint(with: imageWords) { return .image }
        return nil
    }

    /// The canonical fileType string downstream code (SearchEngine, Spotlight)
    /// expects — so any synonym normalizes to exactly one recognized value.
    var canonical: String { self == .image ? "image" : "video" }
}
