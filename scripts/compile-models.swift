import Foundation
import CoreML

let args = CommandLine.arguments
for (source, name) in [("mobileclip_s0_image", "MobileCLIPImage"), ("mobileclip_s0_text", "MobileCLIPText")] {
    let input = URL(fileURLWithPath: args[1]).appendingPathComponent(source + ".mlpackage")
    let output = URL(fileURLWithPath: args[2]).appendingPathComponent(name + ".mlmodelc")
    let compiled = try MLModel.compileModel(at: input)
    if FileManager.default.fileExists(atPath: output.path) { try FileManager.default.removeItem(at: output) }
    try FileManager.default.copyItem(at: compiled, to: output)
    let model = try MLModel(contentsOf: output)
    print(name, model.modelDescription)
}
