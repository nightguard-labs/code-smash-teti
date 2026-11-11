import Foundation
import BrainCore
import MLX
import MLXLLM
import MLXLMCommon
import MLXHuggingFace
import Tokenizers

/// The engine organ: runs the model on the GPU (Metal) through Apple's MLX.
/// One actor = one owner of the model, so requests queue up safely instead of fighting over memory.
public actor Engine {
    public private(set) var modelName = "none"
    private var container: ModelContainer?
    private var bank: ExpertBank?
    // Speculative decoding: a small, fast draft model (same tokenizer) writes a few words ahead; the big brain checks
    // them all in ONE pass, so one trip to the SSD for experts can produce several words. Output is identical.
    private var draft: ModelContainer?
    public private(set) var draftName: String?
    public private(set) var draftTokens = 0          // words the draft proposes per round (0 = off)
    public func setSpeculation(_ n: Int) { draftTokens = draft == nil ? 0 : max(0, n) }

    public init() {}

    public var isLoaded: Bool { container != nil }

    /// Load an MLX model folder from local disk (no network).
    public func load(directory: URL, name: String? = nil) async throws {
        // Leave headroom for macOS, a small always-on model, and the SSD relay (32 GB machine).
        MLX.GPU.set(cacheLimit: 2 << 30)
        if StreamingLoader.isLaid(directory) {
            // load the draft first, so the expert cache sizes itself to the RAM that's left
            // each brain can name its own draft (a "draft-model" link in its folder): the draft must share the brain's
            // vocabulary (Qwen3-Next → Qwen3-1.7B; Code Smash TeTi → Qwen3.5-2B, the default)
            let own = directory.appendingPathComponent("draft-model")
            let draftDir = URL(fileURLWithPath: ProcessInfo.processInfo.environment["TETI_DRAFT"]
                               ?? (FileManager.default.fileExists(atPath: own.appendingPathComponent("config.json").path) ? own.path
                                   : BrainPaths.models.appendingPathComponent("test/Qwen3.5-2B-4bit").path))
            // the first-brain race decides: if the draft didn't pay, don't spend RAM on it
            let specLost = (try? JSONSerialization.jsonObject(with: Data(contentsOf: BrainPaths.memory.appendingPathComponent("spec-ab.json"))) as? [String: Any])?["winner"] as? String == "off"
            let ownDraft = draftDir.path == own.path   // the 122B's draft race doesn't decide another brain's draft
            if ProcessInfo.processInfo.environment["TETI_NO_DRAFT"] == nil, !specLost || ownDraft,
               FileManager.default.fileExists(atPath: draftDir.appendingPathComponent("config.json").path) {
                try await loadDraft(draftDir)
            }
            // a laid brain: hot weights in RAM, experts streamed from the SSD bank
            // default: auto (as much RAM as is truly free); TETI_EXPERT_CACHE_GB=<n> pins a fixed size
            let gb = Double(ProcessInfo.processInfo.environment["TETI_EXPERT_CACHE_GB"] ?? "") ?? 0
            (container, bank) = try await StreamingLoader.load(directory: directory, cacheGB: gb)
        } else {
            container = try await LLMModelFactory.shared.loadContainer(from: directory, using: #huggingFaceTokenizerLoader())
        }
        modelName = name ?? directory.lastPathComponent
        await checkDraft()
        // what it learned in its sleep: the latest adopted adapter rides on top of the base weights
        if let c = Adapters.current(for: directory), let container {
            let lora = try LoRAContainer.from(directory: c)
            try await container.perform { ctx in try lora.load(into: ctx.model) }
            adapter = (try? FileManager.default.destinationOfSymbolicLink(atPath: c.path)).map { URL(fileURLWithPath: $0).lastPathComponent } ?? "current"
            print("✓ learned adapter loaded: \(adapter!)")
        }
    }
    public private(set) var adapter: String?

    /// Turn what-if guessing on/off at runtime (for the off-vs-on race).
    public func setGuessing(_ on: Bool) { bank?.guessingAllowed = on }

    /// Load a draft model. It only stays if its tokenizer matches the brain's (checked after the brain loads).
    public func loadDraft(_ dir: URL, tokens: Int = 3) async throws {
        draft = try await LLMModelFactory.shared.loadContainer(from: dir, using: #huggingFaceTokenizerLoader())
        draftName = dir.lastPathComponent; draftTokens = tokens
    }

    /// Same tokenizer or no deal: drafts in a different "alphabet" would all be rejected (or worse, misread).
    func checkDraft() async {
        guard let draft, let container else { return }
        let sample = "func swap(_ a: inout Int, _ b: inout Int) { (a, b) = (b, a) } // Code Smash TeTi ✓ 123"
        let a = await container.perform { $0.tokenizer.encode(text: sample) }
        let b = await draft.perform { $0.tokenizer.encode(text: sample) }
        if a != b { print("draft \(draftName ?? "?") has a different tokenizer, not used"); self.draft = nil; draftName = nil; draftTokens = 0 }
        else { print("✓ draft model: \(draftName ?? "?") proposes \(draftTokens) words per round") }
    }

    /// Expert streaming stats (nil for a model that fits in RAM whole).
    public var streamStats: StreamStats? { bank?.snapshot() }

    public func unload() {
        bank?.saveUsage()
        container = nil; bank = nil; draft = nil; draftName = nil; draftTokens = 0
        modelName = "none"
        MLX.GPU.clearCache()
    }

    // MARK: prompt memory (owner 11/05: "build the next part" → prompt speed)
    // The thinking loop resends the whole conversation each turn. The brain remembers where each prompt ended
    // (a copy of its attention + recurrent state), so a new request that starts with an old prompt only reads the
    // new part. Qwen 3.5's recurrent layers can't be rewound, so only exact extensions are reused.
    /// `draft`: the draft model's state at the same point, so it doesn't re-read the whole conversation either.
    struct PromptSnapshot { var tokens: [Int32]; var cache: [KVCache]; var used: Date; var draft: [KVCache]? = nil }
    private var snapshots: [PromptSnapshot] = []
    private let maxSnapshots = 8
    public private(set) var reusedTokens = 0, readTokens = 0

    func takeSnapshot(for tokens: [Int32]) -> (cache: [KVCache], count: Int, draft: [KVCache]?)? {
        guard let i = snapshots.indices.filter({ tokens.count > snapshots[$0].tokens.count && tokens.starts(with: snapshots[$0].tokens) })
            .max(by: { snapshots[$0].tokens.count < snapshots[$1].tokens.count }) else {
            // 80B diagnosis (11/10): say why nothing matched, so a miss is never silent
            if !snapshots.isEmpty {
                let best = snapshots.map { s in zip(s.tokens, tokens).prefix { $0 == $1 }.count }.max() ?? 0
                print("🧩 prompt memory miss: \(snapshots.count) saved, closest shares \(best) of \(tokens.count) tokens"); fflush(stdout)
            }
            return nil
        }
        snapshots[i].used = Date()
        return (snapshots[i].cache.map { $0.copy() }, snapshots[i].tokens.count, snapshots[i].draft?.map { $0.copy() })
    }
    func storeSnapshot(_ tokens: [Int32], _ cache: [KVCache], draft: [KVCache]? = nil) {
        snapshots.removeAll { $0.tokens == tokens }
        snapshots.append(PromptSnapshot(tokens: tokens, cache: cache.map { $0.copy() }, used: Date(), draft: draft?.map { $0.copy() }))
        if snapshots.count > maxSnapshots { snapshots.sort { $0.used > $1.used }; snapshots.removeLast(snapshots.count - maxSnapshots) }
    }
    func count(reused: Int, read: Int) { reusedTokens += reused; readTokens += read }
    public private(set) var lastSpec: SpecStats?
    func noteSpec(_ s: SpecStats) { lastSpec = s }
    public func forgetPrompts() { snapshots.removeAll() }
    /// Test hook only: extra places to split the prompt (to prove saved state = recomputed state).
    public var testSplits: [Int] = []
    public func setTestSplits(_ s: [Int]) { testSplits = s }

    /// Stream tokens for a request.
    public func generate(_ req: GenerateRequest) -> AsyncStream<BrainEvent> {
        AsyncStream { continuation in
            let task = Task {
                guard let container = self.container else {
                    continuation.yield(.failure("no model loaded")); continuation.finish(); return
                }
                // a streamed brain reads the prompt in big steps: each step pulls the experts off the SSD once
                let step = self.bank != nil ? 2048 : 512
                do {
                    let chat: [Chat.Message] = req.messages.map {
                        switch $0.role {
                        case .system: return .system($0.content)
                        case .assistant: return .assistant($0.content)
                        case .tool: return .tool($0.content)
                        case .user: return .user($0.content)
                        }
                    }
                    let input = UserInput(chat: chat, additionalContext: ["enable_thinking": req.think])
                    let prepared = try await container.prepare(input: input)
                    let tokens = prepared.text.tokens.asType(.int32).asArray(Int32.self)
                    let prior = await self.takeSnapshot(for: tokens)
                    let nDraft = await self.draftTokens
                    let draftModel: (any LanguageModel)? = nDraft > 0 ? await self.draft?.perform { $0.model } : nil
                    let params = GenerateParameters(maxTokens: req.maxTokens, temperature: req.temperature, topP: 0.95, prefillStepSize: step)
                    let t0 = Date()
                    let stream: AsyncStream<Generation> = try await container.perform { context in
                        let cache = try prior?.cache ?? context.model.newCache(parameters: params)
                        let start = prior?.count ?? 0
                        // Save points at message boundaries that replay identically next turn: after the system message,
                        // and just before the final "assistant" header (the end of the conversation so far).
                        let imStart = context.tokenizer.encode(text: "<|im_start|>", addSpecialTokens: false)
                        var marks: [Int] = []
                        if let raw = context.tokenizer.convertTokenToId("<|im_start|>") ?? (imStart.count == 1 ? imStart[0] : nil) {
                            let id = Int32(raw)
                            let starts = tokens.indices.filter { tokens[$0] == id }
                            if starts.count >= 2 { marks.append(starts[1]) }            // end of the system message
                            if let last = starts.last, last > 0 { marks.append(last) }   // end of the conversation so far
                        }
                        if marks.isEmpty { print("🧩 no save points in this prompt (im_start pieces: \(imStart.count))"); fflush(stdout) }
                        marks += await self.testSplits         // test hook: force extra split points
                        marks = Array(Set(marks.filter { $0 > start && $0 < tokens.count - 1 })).sorted()
                        var saves: [([Int32], [KVCache])] = []
                        // read everything but the last token ourselves, stopping at each save point
                        var i = start
                        for stop in marks + [tokens.count - 1] {
                            while i < stop {
                                let j = min(i + step, stop)
                                let logits = context.model(MLXArray(Array(tokens[i..<j]))[.newAxis], cache: cache)
                                eval(logits); eval(cache.flatMap { $0.state })
                                i = j
                            }
                            if stop != tokens.count - 1 { saves.append((Array(tokens[..<stop]), cache.map { $0.copy() })) }
                        }
                        let toSave = saves
                        if let dm = draftModel {
                            // the draft reads the whole prompt too (it's small and fast), then they write together
                            // resumes from its own saved state when the snapshot has one (else reads from the start)
                            let d0 = Date()
                            let dcache = try prior?.draft ?? dm.newCache(parameters: params)
                            var k = prior?.draft != nil ? start : 0
                            let dStart = k
                            var dSaves: [Int: [KVCache]] = [:]
                            for stop in marks + [tokens.count - 1] where stop > k {
                                while k < stop {
                                    let j = min(k + 512, stop)
                                    let lg = dm(MLXArray(Array(tokens[k..<j]))[.newAxis], cache: dcache)
                                    eval(lg); eval(dcache.flatMap { $0.state }); k = j
                                }
                                if stop != tokens.count - 1 { dSaves[stop] = dcache.map { $0.copy() } }
                            }
                            let draftSecs = Date().timeIntervalSince(d0)
                            let dSavesFinal = dSaves
                            Task { for (t, c) in toSave { await self.storeSnapshot(t, c, draft: dSavesFinal[t.count]) }
                                   await self.count(reused: start, read: tokens.count - start) }
                            // our own speculative loop (Apple's needs rewindable caches; Qwen 3.5's recurrent layers aren't)
                            var stop = Set(context.configuration.eosTokenIds)
                            if let e = context.tokenizer.eosTokenId { stop.insert(e) }
                            for m in ["<|im_end|>", "<|endoftext|>"] { let t = context.tokenizer.encode(text: m, addSpecialTokens: false); if t.count == 1 { stop.insert(t[0]) } }
                            let (s2, c2) = AsyncStream<Generation>.makeStream()
                            var out: [Int] = [], shown = ""
                            let g0 = Date()
                            let st = Speculator.run(main: context.model, draft: dm, mainCache: cache, draftCache: dcache, first: Int(tokens.last!),
                                                    k: nDraft, maxTokens: req.maxTokens, temperature: req.temperature, stop: stop) { t in
                                if stop.contains(t) { return false }
                                out.append(t)
                                let text = context.tokenizer.decode(tokenIds: out)
                                if text.count > shown.count, !text.hasSuffix("\u{FFFD}") { c2.yield(.chunk(String(text.dropFirst(shown.count)))); shown = text }
                                return !Task.isCancelled
                            }
                            let gt = Date().timeIntervalSince(g0)
                            let readSecs = g0.timeIntervalSince(t0) - draftSecs
                            print(String(format: "📝 step: prompt %d tokens (%d remembered, %d read in %.1f s) · draft read %d in %.1f s · wrote %d tokens in %.1f s (%.2f/s)",
                                         tokens.count, start, tokens.count - start, readSecs, tokens.count - dStart, draftSecs, out.count, gt, Double(out.count) / max(0.001, gt)))
                            fflush(stdout)
                            Task { await self.noteSpec(st) }
                            c2.yield(.info(GenerateCompletionInfo(promptTokenCount: tokens.count, generationTokenCount: out.count,
                                                                  promptTime: 0, generationTime: gt)))
                            c2.finish()
                            return s2
                        }
                        Task { for (t, c) in toSave { await self.storeSnapshot(t, c) }
                               await self.count(reused: start, read: tokens.count - start) }
                        return try MLXLMCommon.generate(input: LMInput(tokens: MLXArray([tokens.last!])), cache: cache,
                                                        parameters: params, context: context)
                    }
                    for await g in stream {
                        if Task.isCancelled { break }
                        switch g {
                        case .chunk(let s): continuation.yield(.token(s))
                        case .info(let i):
                            if draftModel == nil {
                                print(String(format: "📝 step: prompt %d tokens (%d remembered, %d read in %.1f s) · wrote %d tokens in %.1f s (%.2f/s)",
                                             tokens.count, prior?.count ?? 0, tokens.count - (prior?.count ?? 0), Date().timeIntervalSince(t0) - i.generateTime,
                                             i.generationTokenCount, i.generateTime, i.tokensPerSecond)); fflush(stdout)
                            }
                            continuation.yield(.done(GenerateStats(
                                promptTokens: tokens.count, generatedTokens: i.generationTokenCount,
                                promptTokensPerSecond: Double(tokens.count - (prior?.count ?? 0)) / max(0.001, Date().timeIntervalSince(t0) - i.generateTime),
                                tokensPerSecond: i.tokensPerSecond,
                                seconds: Date().timeIntervalSince(t0), reusedPromptTokens: prior?.count ?? 0)))
                        default: break
                        }
                    }
                } catch {
                    continuation.yield(.failure("\(error)"))
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}
