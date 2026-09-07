import Foundation
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
