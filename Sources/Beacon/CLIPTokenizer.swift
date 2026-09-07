import Foundation

/// Byte-Pair-Encoding tokenizer matching OpenAI CLIP's `SimpleTokenizer` (the
/// same scheme MobileCLIP uses). Loads the standard merges file
/// (`bpe_simple_vocab_16e6.txt`) from the app bundle; initialization fails (and
/// the CLIP feature stays disabled) if it isn't present.
///
/// This is a faithful port of the reference implementation — the byte↔unicode
/// map, the merge ranks, the `</w>` end-of-word marker, the token regex, and the
/// <|startoftext|>/<|endoftext|> sentinels must all match exactly, or the text
/// embeddings won't line up with the image embeddings.
final class CLIPTokenizer {
    private let byteEncoder: [UInt8: String]
    private let bpeRanks: [Pair: Int]
    private let encoder: [String: Int]        // token string -> id
    private let pattern: NSRegularExpression
    private let sotToken: Int
    private let eotToken: Int
    private var cache: [String: [String]] = [:]

    private struct Pair: Hashable { let a: String; let b: String }

    init?(url explicitURL: URL? = nil) {
        guard let url = explicitURL ?? Bundle.main.url(forResource: "bpe_simple_vocab_16e6", withExtension: "txt"),
              let raw = try? String(contentsOf: url, encoding: .utf8) else { return nil }

        // Byte <-> unicode table (reversible, avoids control/whitespace bytes).
        var bytes: [UInt8] = []
        bytes += Array(UInt8(ascii: "!")...UInt8(ascii: "~"))
        bytes += Array(UInt8(0xA1)...UInt8(0xAC))
        bytes += Array(UInt8(0xAE)...UInt8(0xFF))
        var cs = bytes.map { Int($0) }
        var n = 0
        for b in 0...255 where !bytes.contains(UInt8(b)) {
            bytes.append(UInt8(b))
            cs.append(256 + n)
            n += 1
        }
        var byteEnc: [UInt8: String] = [:]
        for (b, c) in zip(bytes, cs) {
            byteEnc[b] = String(UnicodeScalar(c)!)
        }
        byteEncoder = byteEnc

        // Merges: drop the header line, keep the canonical slice (48894 merges).
        var lines = raw.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        if !lines.isEmpty { lines.removeFirst() }
        let upper = min(lines.count, 49152 - 256 - 2)
        let merges = lines[0..<upper].compactMap { line -> Pair? in
            let parts = line.split(separator: " ")
            guard parts.count == 2 else { return nil }
            return Pair(a: String(parts[0]), b: String(parts[1]))
        }
        guard merges.count == 48894 else { return nil }
        var ranks: [Pair: Int] = [:]
        for (i, m) in merges.enumerated() { ranks[m] = i }
        bpeRanks = ranks

        // Vocabulary: 256 base chars, their `</w>` variants, the merges joined,
        // then the two sentinels — in exactly this order.
        var vocab: [String] = cs.map { String(UnicodeScalar($0)!) }
        vocab += vocab.map { $0 + "</w>" }
        for m in merges { vocab.append(m.a + m.b) }
        vocab.append("<|startoftext|>")
        vocab.append("<|endoftext|>")
        var enc: [String: Int] = [:]
        for (i, tok) in vocab.enumerated() { enc[tok] = i }
        encoder = enc
        sotToken = enc["<|startoftext|>"] ?? vocab.count - 2
        eotToken = enc["<|endoftext|>"] ?? vocab.count - 1

        let patternStr = "<\\|startoftext\\|>|<\\|endoftext\\|>|'s|'t|'re|'ve|'m|'ll|'d|[\\p{L}]+|[\\p{N}]|[^\\s\\p{L}\\p{N}]+"
        guard let re = try? NSRegularExpression(pattern: patternStr, options: [.caseInsensitive]) else { return nil }
        pattern = re
    }

    /// Encode `text` into a fixed-length token-id sequence (SOT … EOT, zero-padded).
    func encode(_ text: String, contextLength: Int) -> [Int] {
        guard contextLength >= 2 else { return [] }
        var ids: [Int] = [sotToken]
        let clean = Self.whitespaceClean(text.precomposedStringWithCanonicalMapping).lowercased()
        let ns = clean as NSString
        for match in pattern.matches(in: clean, range: NSRange(location: 0, length: ns.length)) {
            let token = ns.substring(with: match.range)
            if token == "<|startoftext|>" { ids.append(sotToken); continue }
            if token == "<|endoftext|>" { ids.append(eotToken); continue }
            // Map the token's UTF-8 bytes through the byte encoder.
            let mapped = Array(token.utf8).compactMap { byteEncoder[$0] }.joined()
            for piece in bpe(mapped) {
                if let id = encoder[piece] { ids.append(id) }
            }
        }
        ids.append(eotToken)
        if ids.count > contextLength {
            ids = Array(ids.prefix(contextLength))
            ids[contextLength - 1] = eotToken
        } else {
            ids += Array(repeating: 0, count: contextLength - ids.count)
        }
        return ids
    }

    // MARK: - BPE

    private func bpe(_ token: String) -> [String] {
        if let cached = cache[token] { return cached }
        guard !token.isEmpty else { return [] }
        // Start from characters; mark the last with the end-of-word suffix.
        var word = token.map { String($0) }
        if let last = word.last { word[word.count - 1] = last + "</w>" }

        while word.count > 1 {
            // Find the adjacent pair with the best (lowest) merge rank.
            var best: (rank: Int, index: Int)?
            for i in 0..<(word.count - 1) {
                if let r = bpeRanks[Pair(a: word[i], b: word[i + 1])] {
                    if best == nil || r < best!.rank { best = (r, i) }
                }
            }
            guard let (_, idx) = best else { break }
            word[idx] = word[idx] + word[idx + 1]
            word.remove(at: idx + 1)
        }
        if cache.count > 8192 { cache.removeAll(keepingCapacity: true) }
        cache[token] = word
        return word
    }

    private static func whitespaceClean(_ s: String) -> String {
        let collapsed = s.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
        return collapsed.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
