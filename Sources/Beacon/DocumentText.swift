import Foundation
import PDFKit
import CoreServices

/// Bounded document excerpts for AI relevance checks. Only runs for a file that
/// the enabled files source already returned; never accepts an arbitrary model path.
enum DocumentText {
    static func excerpt(path: String, query: String, limit: Int = 1800) -> String? {
        let url = URL(fileURLWithPath: path)
        guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]),
              values.isRegularFile == true, (values.fileSize ?? Int.max) <= 25 * 1024 * 1024 else { return nil }
        let ext = url.pathExtension.lowercased()
        var text: String?
        if ext == "pdf" {
            if let document = PDFDocument(url: url), !document.isLocked {
                var pieces: [String] = []; var size = 0
                for i in 0..<min(document.pageCount, 40) {
                    if let page = document.page(at: i)?.string {
                        pieces.append("[Page \(i + 1)] " + page); size += page.count
                    }
                    if size >= 80_000 { break }
                }
                text = pieces.joined(separator: "\n")
            }
        } else if ["txt", "md", "csv", "json", "log", "swift", "py", "js", "ts", "tsx", "jsx", "html", "css", "yaml", "yml"].contains(ext) {
            guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
            defer { try? handle.close() }
            if let data = try? handle.read(upToCount: 262_144) { text = String(data: data, encoding: .utf8) }
        } else if ["doc", "docx", "pages", "rtf", "pptx", "xlsx", "numbers", "key"].contains(ext) {
            if let item = MDItemCreate(nil, path as CFString) { text = MDItemCopyAttribute(item, kMDItemTextContent) as? String }
        }
        guard let text, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return centered(String(text.prefix(80_000)), query: query, limit: limit)
    }
    static func centered(_ text: String, query: String, limit: Int) -> String {
        guard limit > 0 else { return "" }
        let source = text as NSString
        let tokens = SearchText.tokens(query).filter { $0.count >= 3 }
        let position = tokens.compactMap { token -> Int? in
            let range = source.range(of: token, options: [.caseInsensitive, .diacriticInsensitive])
            return range.location == NSNotFound ? nil : range.location
        }.min() ?? 0
        let start = max(0, position - limit / 4)
        let range = source.rangeOfComposedCharacterSequences(for: NSRange(location: start, length: min(limit, source.length - start)))
        return (range.location > 0 ? "…" : "") + source.substring(with: range) + (NSMaxRange(range) < source.length ? "…" : "")
    }
}
