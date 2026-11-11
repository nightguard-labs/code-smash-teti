import Foundation
import BrainCore
import MLX
import MLXNN
import MLXOptimizers
import MLXLLM
import MLXLMCommon
import MLXHuggingFace
import Tokenizers
import BrainEngine
import CryptoKit

/// Overnight training: learn from rewarded wins only (Te-verified). LoRA = small add-on weights; the base model is
/// never changed. A new adapter is adopted ONLY if it measurably improves on held-out wins (evidence, like Te).
enum Trainer {
    struct Outcome { var trained: Bool; var adopted: Bool; var summary: String }

    /// Turn saved winning runs into training examples: each Ti step that led to a pass (prompt → Ti's reply).
    static func buildDataset() -> [String] {
        let dir = BrainPaths.memory.appendingPathComponent("rewards")
        var out: [String] = []
        for f in ((try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []).sorted() where f.hasSuffix(".jsonl") {
            let text = (try? String(contentsOfFile: dir.appendingPathComponent(f).path, encoding: .utf8)) ?? ""
            for line in text.split(separator: "\n") {
                guard let d = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                      let phase = d["phase"] as? String, let ask = d["ask"] as? String, let reply = d["reply"] as? String,
                      phase.hasPrefix("ti-") || phase == "te-frame", !reply.isEmpty else { continue }
                // Qwen chat format (the base and the test model are both Qwen 3.5)
                let ex = "<|im_start|>user\n\(ask.prefix(6000))<|im_end|>\n<|im_start|>assistant\n\(reply.prefix(6000))<|im_end|>\n"
                out.append(ex)
            }
        }
        return out
    }

    /// Do-no-harm exam: fixed general questions with known-good answers. Training that makes these worse is rejected,
    /// even if it got better at the brain's own past work (it must not trade old skills for new ones).
    static let doNoHarm: [String] = [
        ("What is 17 * 23? Answer with just the number.", "391"),
        ("Write a Swift function that returns the larger of two Ints.", "func larger(_ a: Int, _ b: Int) -> Int {\n    return a > b ? a : b\n}"),
        ("What does `ls -la` do in a terminal?", "It lists every file in the current directory, including hidden ones, in long format with permissions, owner, size and date."),
        ("Reverse a string in Python.", "def reverse(s):\n    return s[::-1]"),
        ("What is the capital of France?", "Paris."),
        ("Convert 100 degrees Celsius to Fahrenheit.", "212 degrees Fahrenheit."),
        ("What is the time complexity of binary search?", "O(log n)."),
        ("Write a bash one-liner that counts the lines in file.txt.", "wc -l < file.txt"),
        ("In Swift, how do you declare a constant?", "Use let, for example: let name = \"TeTi\""),
        ("What is 2 to the power of 10?", "1024"),
        ("Explain a race condition in one sentence.", "A race condition is a bug where the result depends on the unpredictable timing of threads or processes touching shared data."),
        ("Write a JSON object with the key ok set to true.", "{\"ok\": true}"),
    ].map { "<|im_start|>user\n\($0.0)<|im_end|>\n<|im_start|>assistant\n\($0.1)<|im_end|>\n" }

    static func train(modelDir: URL, examples: [String], iterations: Int, log: (String) -> Void) async throws -> Outcome {
        guard examples.count >= 2 else { return Outcome(trained: false, adopted: false, summary: "not enough examples") }
        // Held-out exam, FIXED by fingerprint: an example held out once is held out every night, so no later night
        // can train on its own exam. ~20%, at least 1.
        func fp(_ t: String) -> UInt8 { Array(SHA256.hash(data: Data(t.utf8)))[0] }
        var valid = examples.filter { fp($0) % 5 == 0 }
        if valid.isEmpty, let pick = examples.min(by: { fp($0) < fp($1) }) { valid = [pick] }
        let held = Set(valid)
        let train = examples.filter { !held.contains($0) }

        MLX.GPU.set(cacheLimit: 2 << 30)
        let streamed = StreamingLoader.isLaid(modelDir)
        let model: any LanguageModel, tokenizer: any MLXLMCommon.Tokenizer
        if streamed {
            // the full brain: hot weights in RAM, experts streamed; a smaller expert cache leaves room for training
            let r = try await StreamingLoader.loadRaw(directory: modelDir, cacheGB: 8, log: { print($0) })
            model = r.model; tokenizer = r.tokenizer
        } else {
            let ctx = try await LLMModelFactory.shared.load(from: modelDir, using: #huggingFaceTokenizerLoader())
            model = ctx.model; tokenizer = ctx.tokenizer
        }
        // continue from what it already learned (the adopted adapter), so each night builds on the last
        var config = LoRAConfiguration(numLayers: streamed ? 4 : 8,
                                       loraParameters: .init(rank: 8, scale: 10, keys: streamed ? Adapters.streamedKeys : nil))
        if let cur = Adapters.current(for: modelDir) {
            let prior = try LoRAContainer.from(directory: cur)
            try prior.load(into: model)
            config = prior.configuration
            log("continuing from adapter \((try? FileManager.default.destinationOfSymbolicLink(atPath: cur.path)) ?? "current")")
        } else {
            _ = try LoRAContainer.from(model: model, configuration: config)
        }
        let before = LoRATrain.evaluate(model: model, dataset: valid, tokenizer: tokenizer, batchSize: 1, batchCount: 0)
        let harmBefore = LoRATrain.evaluate(model: model, dataset: doNoHarm, tokenizer: tokenizer, batchSize: 1, batchCount: 0)
        log(String(format: "held-out loss before training: %.4f (%d train / %d held-out examples) · do-no-harm exam %.4f", before, train.count, valid.count, harmBefore))

        let stamp = { () -> String in let f = DateFormatter(); f.dateFormat = "yyyyMMdd-HHmm"; return f.string(from: Date()) }()
        let outDir = Adapters.root(for: modelDir).appendingPathComponent(stamp)
        try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
        let weights = outDir.appendingPathComponent("adapters.safetensors")
        try LoRATrain.train(model: model, train: train, validate: valid, optimizer: Adam(learningRate: 1e-5),
                            tokenizer: tokenizer,
                            parameters: .init(batchSize: 1, iterations: iterations, stepsPerReport: max(1, iterations / 5),
                                              stepsPerEval: iterations, validationBatches: 0, saveEvery: iterations,
                                              adapterURL: weights)) { p in
            log("  \(p)"); return .more
        }
        let after = LoRATrain.evaluate(model: model, dataset: valid, tokenizer: tokenizer, batchSize: 1, batchCount: 0)
        let harmAfter = LoRATrain.evaluate(model: model, dataset: doNoHarm, tokenizer: tokenizer, batchSize: 1, batchCount: 0)
        log(String(format: "held-out loss after training:  %.4f · do-no-harm exam %.4f", after, harmAfter))
        let enc = JSONEncoder(); enc.outputFormatting = .prettyPrinted
        try enc.encode(config).write(to: outDir.appendingPathComponent("adapter_config.json"))

        // Adopt only on evidence: its own held-out work must improve ≥ 1% AND general skills must not slip > 3%.
        let harmed = harmAfter > harmBefore * 1.03
        if after < before * 0.99 && !harmed {
            let current = outDir.deletingLastPathComponent().appendingPathComponent("current")
            try? FileManager.default.removeItem(at: current)
            try FileManager.default.createSymbolicLink(at: current, withDestinationURL: outDir)
            return Outcome(trained: true, adopted: true, summary: String(format: "adopted new adapter (held-out loss %.4f → %.4f)", before, after))
        }
        try? FileManager.default.removeItem(at: outDir)
        if harmed {
            return Outcome(trained: true, adopted: false, summary: String(format: "trained but NOT adopted: it would lose general skills (do-no-harm exam %.4f → %.4f), discarded", harmBefore, harmAfter))
        }
        return Outcome(trained: true, adopted: false, summary: String(format: "trained but NOT adopted: no real improvement (%.4f → %.4f), discarded", before, after))
    }
}
