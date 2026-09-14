import CoreGraphics
import CoreML
import Foundation
import ImageIO

/// On-device CLIP encoder: turns a text description and an image into vectors in
/// a shared embedding space so we can rank a whole photo library by how well
/// each image matches a query — instantly, locally, and for free per query.
///
/// Backed by a bundled MobileCLIP CoreML model (image + text encoders) plus the
/// standard CLIP BPE tokenizer. If any of those resources are missing the model
/// reports `isAvailable == false` and callers fall back to the older
/// scan-recent-images sweep — so the app is fully functional without it.
///
/// The CoreML input/output feature names are discovered from each model's
/// description rather than hard-coded, so a range of MobileCLIP conversions work
/// without code changes.
final class CLIPModel {
    static let shared = CLIPModel()

    private let imageModel: MLModel?
    private let textModel: MLModel?
    private let tokenizer: CLIPTokenizer?
    private let textLock = NSLock()
    private let imageLock = NSLock()

    /// Discovered I/O contract (per the loaded models).
    private let imageInputName: String?
    private let imageInputSize: Int          // square side the image encoder wants
    private let imageOutputName: String?
    private let textInputName: String?
    private let textContextLength: Int        // token sequence length (usually 77)
    private let textOutputName: String?

    /// Embedding dimension (from the image encoder's output), 0 if unavailable.
    let dimension: Int

    var isAvailable: Bool {
        imageModel != nil && textModel != nil && tokenizer != nil
            && imageInputName != nil && imageOutputName != nil
            && textInputName != nil && textOutputName != nil && dimension > 0
    }

    init(resourceDirectory: URL? = nil, computeUnits: MLComputeUnits = .all) {
        let bundle = Bundle.main
        func modelURL(_ base: String) -> URL? {
            if let resourceDirectory { return resourceDirectory.appendingPathComponent(base + ".mlmodelc") }
            return bundle.url(forResource: base, withExtension: "mlmodelc")
        }
        let config = MLModelConfiguration()
        config.computeUnits = computeUnits

        let img = modelURL("MobileCLIPImage").flatMap { try? MLModel(contentsOf: $0, configuration: config) }
        let txt = modelURL("MobileCLIPText").flatMap { try? MLModel(contentsOf: $0, configuration: config) }
        imageModel = img
        textModel = txt
        tokenizer = CLIPTokenizer(url: resourceDirectory?.appendingPathComponent("bpe_simple_vocab_16e6.txt"))

        // Image encoder I/O.
        var inName: String?, inSize = 0, outName: String?, dim = 0
        if let d = img?.modelDescription {
            if let (name, feat) = d.inputDescriptionsByName.first(where: { $0.value.type == .image }) {
                inName = name
                if let c = feat.imageConstraint { inSize = c.pixelsWide }
            }
            if let (name, feat) = d.outputDescriptionsByName.first(where: { $0.value.type == .multiArray }) {
                outName = name
                if let shape = feat.multiArrayConstraint?.shape {
                    dim = shape.map { $0.intValue }.reduce(1, *)
                }
            }
        }
        imageInputName = inName
        imageInputSize = inSize > 0 ? inSize : 256
        imageOutputName = outName
        dimension = dim

        // Text encoder I/O.
        var tInName: String?, tCtx = 0, tOutName: String?
        if let d = txt?.modelDescription {
            if let (name, feat) = d.inputDescriptionsByName.first(where: { $0.value.type == .multiArray }) {
                tInName = name
                if let shape = feat.multiArrayConstraint?.shape, let last = shape.last {
                    tCtx = last.intValue
                }
            }
            if let (name, _) = d.outputDescriptionsByName.first(where: { $0.value.type == .multiArray }) {
                tOutName = name
            }
        }
        textInputName = tInName
        textContextLength = tCtx > 0 ? tCtx : 77
        textOutputName = tOutName
    }

    // MARK: - Encoding

    /// L2-normalized embedding for a text query, or nil if unavailable.
    func encodeText(_ text: String) -> [Float]? {
        textLock.lock(); defer { textLock.unlock() }
        guard isAvailable, let textModel, let tokenizer,
              let inName = textInputName, let outName = textOutputName else { return nil }
        let ids = tokenizer.encode(text, contextLength: textContextLength)
        guard let arr = try? MLMultiArray(shape: [1, NSNumber(value: textContextLength)],
                                          dataType: .int32) else { return nil }
        for (i, id) in ids.enumerated() { arr[i] = NSNumber(value: Int32(id)) }
        guard let input = try? MLDictionaryFeatureProvider(dictionary: [inName: arr]),
              let out = try? textModel.prediction(from: input),
              let vec = out.featureValue(for: outName)?.multiArrayValue else { return nil }
        let floats = Self.floats(from: vec)
        guard floats.count == dimension, floats.allSatisfy({ $0.isFinite }) else { return nil }
        return Self.normalize(floats)
    }

    /// L2-normalized embedding for an image file, or nil if unavailable/unreadable.
    func encodeImage(path: String) -> [Float]? {
        imageLock.lock(); defer { imageLock.unlock() }
        guard isAvailable, let imageModel,
              let inName = imageInputName, let outName = imageOutputName else { return nil }
        guard let pixels = pixelBuffer(path: path, side: imageInputSize) else {
            NSLog("Beacon: image pixel buffer could not be created")
            return nil
        }
        let value = MLFeatureValue(pixelBuffer: pixels)
        let vec: MLMultiArray
        do {
            let input = try MLDictionaryFeatureProvider(dictionary: [inName: value])
            let out = try imageModel.prediction(from: input)
            guard let result = out.featureValue(for: outName)?.multiArrayValue else { return nil }
            vec = result
        } catch {
            NSLog("Beacon image encoder: %@", error.localizedDescription)
            return nil
        }
        let floats = Self.floats(from: vec)
        guard floats.count == dimension, floats.allSatisfy({ $0.isFinite }) else { return nil }
        return Self.normalize(floats)
    }

    // MARK: - Helpers

    static func cosineSimilarity(_ a: [Float], _ b: [Float]) -> Float {
        guard a.count == b.count, !a.isEmpty else { return -1 }
        var dot: Float = 0
        for i in a.indices { dot += a[i] * b[i] }
        return dot   // inputs are already L2-normalized
    }

    private static func floats(from arr: MLMultiArray) -> [Float] {
        // MLMultiArray may be strided; scalar indexing honors its layout.
        (0..<arr.count).map { arr[$0].floatValue }
    }

    private static func normalize(_ v: [Float]) -> [Float] {
        var norm: Float = 0
        for x in v { norm += x * x }
        norm = norm.squareRoot()
        guard norm > 0 else { return v }
        return v.map { $0 / norm }
    }

    /// Decode `path` to a square RGB pixel buffer of `side`×`side`, downscaled by
    /// ImageIO so large originals stay cheap. MobileCLIP's CoreML image input
    /// performs its own mean/std normalization, so we only need correct size.
    private func pixelBuffer(path: String, side: Int) -> CVPixelBuffer? {
        let url = URL(fileURLWithPath: path) as CFURL
        guard let src = CGImageSourceCreateWithURL(url, nil) else { return nil }
        let opts: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: side * 3,
        ]
        guard let cg = CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary) else { return nil }

        var pb: CVPixelBuffer?
        let attrs: [CFString: Any] = [
            kCVPixelBufferCGImageCompatibilityKey: true,
            kCVPixelBufferCGBitmapContextCompatibilityKey: true,
        ]
        guard CVPixelBufferCreate(kCFAllocatorDefault, side, side,
                                  kCVPixelFormatType_32ARGB, attrs as CFDictionary, &pb) == kCVReturnSuccess,
              let buffer = pb else { return nil }
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        guard let base = CVPixelBufferGetBaseAddress(buffer),
              let ctx = CGContext(
                data: base, width: side, height: side, bitsPerComponent: 8,
                bytesPerRow: CVPixelBufferGetBytesPerRow(buffer),
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue) else { return nil }
        // Match Apple’s reference preprocessing: centered square crop, then resize.
        let w = CGFloat(cg.width), h = CGFloat(cg.height)
        let scale = CGFloat(side) / min(w, h)
        let dw = w * scale, dh = h * scale
        let rect = CGRect(x: (CGFloat(side) - dw) / 2, y: (CGFloat(side) - dh) / 2, width: dw, height: dh)
        ctx.setFillColor(CGColor(red: 0, green: 0, blue: 0, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: side, height: side))
        ctx.draw(cg, in: rect)
        return buffer
    }
}
