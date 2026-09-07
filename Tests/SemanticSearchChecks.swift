import Foundation
import SQLite3
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

@main struct SemanticSearchChecks {
    static func main() throws {
        var checks = 0
        func expect(_ value: @autoclosure () -> Bool, _ message: String) {
            checks += 1
            guard value() else { fatalError(message) }
        }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        expect(AIMediaKind.classify("a screenshot") == .image, "screenshot synonym")
        expect(AIMediaKind.classify("a screen recording") == .video, "video synonym")
        expect(AIMediaKind.classify("application") == nil, "short media synonyms must respect words")
        let old = ImageSemanticIndex.Record(path: "/old.jpg", mtime: 1, date: 10, vec: [1, 0])
        let new = ImageSemanticIndex.Record(path: "/new.jpg", mtime: 2, date: 20, vec: [0.6, 0.8])
        let wrongShape = ImageSemanticIndex.Record(path: "/bad.jpg", mtime: 3, date: 20, vec: [1])
        let nan = ImageSemanticIndex.Record(path: "/nan.jpg", mtime: 3, date: 20, vec: [.nan, 0])
        expect(ImageSemanticIndex.rank([new, old, wrongShape, nan], query: [1, 0], limit: 1, after: nil, before: nil).first?.path == "/old.jpg", "old visual match must beat new weak match")
        expect(ImageSemanticIndex.rank([old, new], query: [1, 0], limit: 1, after: Date(timeIntervalSince1970: 15), before: nil).first?.path == "/new.jpg", "dates filter before top-k")
        expect(ImageSemanticIndex.rank([old, new], query: [1, 0], limit: 3, after: nil, before: Date(timeIntervalSince1970: 10)).map(\.path) == ["/old.jpg"], "date endpoints are inclusive")
        expect(ImageSemanticIndex.rank([old], query: [1, 0], limit: 0, after: nil, before: nil).isEmpty, "zero result limit")
        let long = String(repeating: "unrelated content ", count: 1000) + "unique invoice zebra amount" + String(repeating: " trailing", count: 100)
        let excerpt = DocumentText.centered(long, query: "zebra", limit: 300)
        expect(excerpt.contains("zebra") && excerpt.count <= 305 && excerpt.hasPrefix("…"), "excerpts center on late content matches")
        let document = root.appendingPathComponent("invoice.txt")
        try Data(long.utf8).write(to: document)
        expect(DocumentText.excerpt(path: document.path, query: "zebra")?.contains("zebra") == true, "read actual document excerpt")
        expect(DocumentText.excerpt(path: root.path, query: "zebra") == nil, "directories must never be read as documents")
        expect(DocumentText.centered("😀 café receipt", query: "cafe", limit: 5).contains("café"), "unicode-safe excerpt boundaries")
        // Regression: later specific evidence beats a generic word near the start.
        let dense = DocumentText.centered("invoice " + String(repeating: "padding ", count: 200) + "invoice zebra shipment", query: "invoice zebra shipment", limit: 180)
        expect(dense.contains("zebra") && dense.contains("shipment"), "document excerpts prefer the most matching terms")
        let oldHit = SpotlightFileSearch.Hit(path: "/docs/travel invoice.pdf", name: "travel invoice.pdf", modified: .distantPast, contentType: "com.adobe.pdf", kind: "PDF")
        let recentHit = SpotlightFileSearch.Hit(path: "/docs/other.pdf", name: "other.pdf", modified: Date(), contentType: "com.adobe.pdf", kind: "PDF")
        expect(SpotlightFileSearch.ranked([recentHit, oldHit, oldHit], tokens: ["travel", "invoice"], limit: 5).map(\.path) == [oldHit.path, recentHit.path], "old filename evidence beats recency and merged lanes deduplicate")
        let predicate = SpotlightFileSearch.predicate(tokens: ["invoice"], fileType: "pdf", after: Date(timeIntervalSince1970: 1_700_000_000), before: nil)!
        expect(predicate.contains("com.adobe.pdf") && predicate.contains("kMDItemFSContentChangeDate >=") && predicate.contains("kMDItemTextContent"), "type and date filters survive content retrieval")
        expect(SpotlightFileSearch.predicate(tokens: ["invoice"], fileType: nil, after: nil, before: nil, nameOnly: true)?.contains("kMDItemTextContent") == false, "filename lane does not mix content matches")
        expect(SpotlightFileSearch.predicate(tokens: [], fileType: nil, after: nil, before: nil) == nil, "reject unbounded Spotlight query")
        var trace = AISearchTrace(); trace.reset(query: "invoice", generation: 4)
        let pending = AISearchStep(title: "Search Files", state: .running)
        trace.record(pending, generation: 4)
        trace.record(AISearchStep(title: "Stale data"), generation: 3)
        expect(trace.steps.count == 1, "old query callbacks cannot contaminate the log")
        trace.record(AISearchStep(id: pending.id, title: "Search Files", detail: "2 candidates", startedAt: pending.startedAt), generation: 4)
        expect(trace.steps.count == 1 && trace.steps[0].detail == "2 candidates", "a finished operation updates its existing row")
        trace.record(AISearchStep(title: "Read document", state: .running), generation: 4)
        trace.finishRunning(state: .warning, detail: "Stopped")
        expect(!trace.steps.contains { $0.state == .running }, "cancellation leaves no indefinite spinners")
        for _ in 0..<205 { trace.record(AISearchStep(title: "Step"), generation: 4) }
        expect(trace.steps.count == 200, "log memory is bounded")
        let safeLog = AISearchTraceDetails.parameters(["keywords": "invoice", "Authorization": "secret-token", "apiKey": "secret-key"])
        expect(safeLog.contains("invoice") && !safeLog.contains("secret"), "trace uses a search-parameter whitelist")
        // A local SQLite fixture exercises sender/date filters before the candidate cap.
        let dbURL = root.appendingPathComponent("MailFixture.sqlite")
        var db: OpaquePointer?
        guard sqlite3_open(dbURL.path, &db) == SQLITE_OK else { fatalError("fixture DB") }
        let schema = "CREATE TABLE messages (subject INTEGER, sender INTEGER, date_received REAL, snippet TEXT, deleted INTEGER); CREATE TABLE subjects (subject TEXT); CREATE TABLE addresses (address TEXT, comment TEXT); INSERT INTO subjects VALUES ('invoice from Alice'); INSERT INTO addresses VALUES ('alice@example.test', 'Alice'); INSERT INTO addresses VALUES ('bob@example.test', 'Bob');"
        expect(sqlite3_exec(db, schema, nil, nil, nil) == SQLITE_OK, "create isolated mail fixture")
        sqlite3_exec(db, "BEGIN", nil, nil, nil)
        for n in 0..<550 { sqlite3_exec(db, "INSERT INTO messages VALUES (1, 2, \(1_800_000_000 + n), 'invoice', 0)", nil, nil, nil) }
        sqlite3_exec(db, "INSERT INTO messages VALUES (1, 1, 1700000000, 'invoice', 0); COMMIT;", nil, nil, nil)
        sqlite3_close(db)
        let mail = MailStore(databaseURL: dbURL); mail.ensureLoaded()
        expect(mail.search(tokens: ["invoice"], limit: 1, sender: "Alice").first?.senderAddress == "alice@example.test", "sender constraint survives hundreds of newer messages mentioning Alice")
        expect(mail.search(tokens: ["invoice"], limit: 1, before: Date(timeIntervalSince1970: 1_750_000_000)).first?.senderAddress == "alice@example.test", "date filter runs before the SQL limit")
        expect(mail.search(tokens: ["invoice"], limit: 1).first?.senderAddress == "bob@example.test", "filtered queries do not pollute ordinary search cache")
        if CommandLine.arguments.contains("--models") || CommandLine.arguments.contains("--text-models") {
            let resources = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("Resources")
            let tokenizer = CLIPTokenizer(url: resources.appendingPathComponent("bpe_simple_vocab_16e6.txt"))!
            let tokens = tokenizer.encode("a photo of a cat", contextLength: 77)
            expect(Array(tokens.prefix(7)) == [49406, 320, 1125, 539, 320, 2368, 49407], "match CLIP reference token IDs")
            expect(tokens.count == 77 && tokens.last == 0, "fixed context padding")
            expect(tokenizer.encode("a photo of a cat", contextLength: 4).last == 49407, "truncation keeps end token")
            expect(tokenizer.encode("cat", contextLength: 0).isEmpty, "invalid context does not crash")
            expect(tokenizer.encode("  CAT\n", contextLength: 77) == tokenizer.encode("cat", contextLength: 77), "case and whitespace normalization")
            let model = CLIPModel(resourceDirectory: resources, computeUnits: .cpuOnly)
            expect(model.isAvailable && model.dimension == 512, "both real models must load")
            guard let cat = model.encodeText("a photo of a cat"), let dog = model.encodeText("a photo of a dog") else { fatalError("Text inference failed") }
            expect(cat.count == 512 && cat.allSatisfy(\.isFinite), "finite text embedding")
            expect(abs(CLIPModel.cosineSimilarity(cat, cat) - 1) < 0.001, "embedding normalization")
            expect(CLIPModel.cosineSimilarity(cat, cat) > CLIPModel.cosineSimilarity(cat, dog), "different prompts must produce different vectors")
            if CommandLine.arguments.contains("--text-models") {
                print("Semantic search checks passed: \(checks) (including real text encoder)")
                return
            }
            func square(_ red: Bool) throws -> URL {
                let ctx = CGContext(data: nil, width: 300, height: 300, bitsPerComponent: 8, bytesPerRow: 1200,
                    space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
                ctx.setFillColor(CGColor(red: red ? 1 : 0, green: 0, blue: red ? 0 : 1, alpha: 1))
                ctx.fill(CGRect(x: 0, y: 0, width: 300, height: 300))
                let url = root.appendingPathComponent(red ? "red.png" : "blue.png")
                let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)!
                CGImageDestinationAddImage(destination, ctx.makeImage()!, nil)
                guard CGImageDestinationFinalize(destination) else { throw CocoaError(.fileWriteUnknown) }
                return url
            }
            let redFile = try square(true), blueFile = try square(false)
            guard let red = model.encodeImage(path: redFile.path), let blue = model.encodeImage(path: blueFile.path),
                  let redQuery = model.encodeText("a solid red square"), let blueQuery = model.encodeText("a solid blue square") else { fatalError("Image inference failed") }
            expect(red.count == 512 && blue.count == 512, "image embeddings match text dimension")
            expect(CLIPModel.cosineSimilarity(redQuery, red) > CLIPModel.cosineSimilarity(redQuery, blue), "red text query ranks red image first")
            expect(CLIPModel.cosineSimilarity(blueQuery, blue) > CLIPModel.cosineSimilarity(blueQuery, red), "blue text query ranks blue image first")
        }
        print("Semantic search checks passed: \(checks)")
    }
}
