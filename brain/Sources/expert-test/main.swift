import Foundation
import MLX
import MLXNN
import MLXLMCommon
import BrainEngine
import BrainCore
import BrainMind

// expert-test --bank <laid dir> --source <original model dir> [--layers 10,21] [--cache-gb 2]
// For each layer: the stock SwitchGLU (all 256 experts in RAM, Apple's code) vs StreamingSwitchGLU (experts pulled
// from bank.bin). Same input, same router picks → the outputs must match. Then speed: cold SSD reads vs warm RAM hits.

setvbuf(stdout, nil, _IOLBF, 0)
let argv = CommandLine.arguments
func opt(_ n: String) -> String? { argv.firstIndex(of: n).flatMap { $0 + 1 < argv.count ? argv[$0 + 1] : nil } }
// full-brain mode: expert-test --brain <laid dir> [--cache-gb 10] → load the whole streamed brain and generate
if let brain = opt("--brain") {
    let engine = Engine()
    let t0 = Date()
    if let g = opt("--cache-gb") { setenv("TETI_EXPERT_CACHE_GB", g, 1) }   // default: auto
    do { try await engine.load(directory: URL(fileURLWithPath: brain), name: "code-smash-teti") } catch { print("✗ load failed: \(error)"); exit(1) }
    print(String(format: "✓ whole brain loaded in %.1fs", Date().timeIntervalSince(t0)))
    for q in ["What is 17 * 23? Answer with just the number.", "Write a Swift function that reverses a string. Code only."] {
        print("\n> \(q)")
        var text = ""
        for await ev in await engine.generate(GenerateRequest(messages: [BrainMessage(role: .user, content: q)], maxTokens: 160, temperature: 0, think: false)) {
            switch ev {
            case .token(let t): text += t; print(t, terminator: "")
            case .done(let st): print(String(format: "\n[%d tokens · %.2f tok/s · prompt %.1f tok/s]", st.generatedTokens, st.tokensPerSecond, st.promptTokensPerSecond))
            case .failure(let f): print("\n✗ \(f)"); exit(1)
            }
        }
        if q.contains("17 * 23") { print(text.contains("391") ? "✅ correct (391)" : "❌ expected 391") }
    }
    if let st = await engine.streamStats { print("\nstream: \(st.line)") }

    guard await engine.streamStats != nil else { await engine.unload(); exit(0) }   // the race only means something for a streamed brain
    // the race: what-if guessing off vs on, same prompt, alternating so neither side gets a warmer cache
    print("\nrace: what-if guessing off vs on")
    var speed: [Bool: [Double]] = [false: [], true: []]
    for round in 0..<4 {
        let on = round % 2 == 1
        await engine.setGuessing(on)
        let q = "Write a Swift struct for a 2D vector with add, subtract, dot product and length. Code only. (round \(round))"
        for await ev in await engine.generate(GenerateRequest(messages: [BrainMessage(role: .user, content: q)], maxTokens: 96, temperature: 0, think: false)) {
            if case .done(let st) = ev { speed[on]!.append(st.tokensPerSecond); print(String(format: "  guessing %@: %.2f tok/s", on ? "on " : "off", st.tokensPerSecond)) }
        }
    }
    let off = speed[false]!.reduce(0, +) / Double(max(1, speed[false]!.count)), onS = speed[true]!.reduce(0, +) / Double(max(1, speed[true]!.count))
    let winner = onS > off * 1.03 ? "on" : "off"        // guessing must earn its place: at least 3% faster
    print(String(format: "  average: off %.2f · on %.2f tok/s → guessing %@", off, onS, winner == "on" ? "ON (it earned it)" : "OFF (didn't pay)"))
    if let st = await engine.streamStats { print("  \(st.line)") }
    try? JSONSerialization.data(withJSONObject: ["off": off, "on": onS, "winner": winner, "date": Date().description]).write(to: ExpertBank.guessFile)
    await engine.setGuessing(winner == "on")

    // race 2: draft model off vs on (3 words ahead), same rules: it must be ≥ 5% faster to stay
    if await engine.draftName != nil {
        print("\nrace 2: draft model off vs on")
        var sp: [Bool: [Double]] = [false: [], true: []]
        for round in 0..<4 {
            let on = round % 2 == 1
            await engine.setSpeculation(on ? 3 : 0)
            let q = "Write a Swift function that parses a CSV line into fields, handling quoted commas. Code only. (round \(round))"
            for await ev in await engine.generate(GenerateRequest(messages: [BrainMessage(role: .user, content: q)], maxTokens: 96, temperature: 0, think: false)) {
                if case .done(let st) = ev { sp[on]!.append(st.tokensPerSecond); print(String(format: "  draft %@: %.2f tok/s", on ? "on " : "off", st.tokensPerSecond)) }
            }
            if on, let s = await engine.lastSpec { print(String(format: "    %.0f%% of draft words accepted · %.2f words per big-brain pass", s.acceptRate * 100, s.wordsPerPass)) }
        }
        let a = sp[false]!.reduce(0, +) / Double(max(1, sp[false]!.count)), b = sp[true]!.reduce(0, +) / Double(max(1, sp[true]!.count))
        let w = b > a * 1.05 ? "on" : "off"
        print(String(format: "  average: off %.2f · on %.2f tok/s → draft %@", a, b, w == "on" ? "ON (it earned it)" : "OFF (didn't pay)"))
        try? JSONSerialization.data(withJSONObject: ["off": a, "on": b, "winner": w, "date": Date().description])
            .write(to: BrainPaths.memory.appendingPathComponent("spec-ab.json"))
    }
    await engine.unload()
    exit(0)
}

// auto-RAM mode: expert-test --auto <laid dir> → size the cache to free RAM, fill it, show hit rate, test shrink/grow
if let dir = opt("--auto") {
    MLX.compile(enable: false)
    let b = try ExpertBank(directory: URL(fileURLWithPath: dir), cacheGB: 1)
    let gb = { (n: Int) in String(format: "%.1f GB", Double(n) / 1e9) }
    print("RAM: \(gb(ExpertBank.physicalBytes)) physical · \(gb(ExpertBank.availableBytes())) free right now")
    let n = b.autoSize()
    var t = Date(); let filled = b.fill()
    print(String(format: "auto size: %d experts (%@) = %.0f%% of the %d in this bank · filled in %.1fs", n, gb(n * 5308416), Double(n) / Double(b.meta.entries.count) * 100, b.meta.entries.count, Date().timeIntervalSince(t)))
    print("after fill: \(gb(ExpertBank.availableBytes())) still free for macOS + everything else")
    let laid = Set(b.meta.entries.map { $0.layer }).sorted()
    let s0 = b.snapshot(); t = Date()
    for _ in 0..<200 { for l in laid { _ = b.fetch(layer: l, experts: Array((0..<256).shuffled().prefix(8))) } }
    let s1 = b.snapshot()
    print(String(format: "200 random tokens: hit rate %.1f%% (%d of %d experts already in RAM) in %.2fs", Double(s1.hits - s0.hits) / Double(s1.hits - s0.hits + s1.misses - s0.misses) * 100, s1.hits - s0.hits, (s1.hits - s0.hits) + (s1.misses - s0.misses), Date().timeIntervalSince(t)))
    b.setCapacity(n / 2); print("pressure drill: shrank to \(b.snapshot().resident) experts → \(gb(ExpertBank.availableBytes())) free")
    let regrow = b.autoSize(); let added = b.fill(); print("RAM freed: grew back to \(regrow), reloaded \(added) → resident \(b.snapshot().resident)")
    exit(0)
}

// stress mode: expert-test --stress <laid dir> → GPU work + fetches + guesses + shrink/grow all at once, 60 s.
// A deadlock shows up as the heartbeat stopping.
if let dir = opt("--stress") {
    MLX.compile(enable: false)
    let b = try ExpertBank(directory: URL(fileURLWithPath: dir), cacheGB: 2)
    let layers = Array(Set(b.meta.entries.map { $0.layer })).sorted()
    let stop = Date().addingTimeInterval(60)
    let beat = ManagedBox()
    // shrink/grow storm, like macOS memory warnings arriving mid-thought
    Thread.detachNewThread { while Date() < stop { b.setCapacity(Int.random(in: 64...400)); usleep(50_000); _ = b.autoSize(reserveGB: 25) } }
    // guesses in the background
    Thread.detachNewThread { while Date() < stop { b.prefetch(layer: layers.randomElement()!, experts: Array((0..<256).shuffled().prefix(6))); usleep(20_000) } }
    // the "thinking" thread: fetch experts and run real GPU math on them
    Thread.detachNewThread {
        while Date() < stop {
            let l = layers.randomElement()!
            let w = b.fetch(layer: l, experts: Array((0..<256).shuffled().prefix(8)))
            let s = MLX.stacked(w.map { $0["gate_proj.scales"] }).sum(); eval(s)
            beat.tick()
        }
    }
    var last = -1, frozen = 0
    while Date() < stop.addingTimeInterval(3) {
        sleep(5)
        let n = beat.value
        print("heartbeat: \(n) thoughts · \(b.snapshot().line)")
        if n == last { frozen += 1 } else { frozen = 0 }
        if frozen >= 3 { print("❌ FROZEN (deadlock)"); exit(1) }
        last = n
    }
    print("STRESS ✅ no deadlock in 60 s of fetch + guess + shrink/grow + GPU work")
    exit(0)
}

final class ManagedBox: @unchecked Sendable { private var v = 0; private let l = NSLock(); func tick() { l.withLock { v += 1 } }; var value: Int { l.withLock { v } } }

// socket mode: expert-test --socket → the brain's own door vs the HTTP edge, same question
if argv.contains("--socket") {
    let msgs = [BrainMessage(role: .user, content: "Name three Swift collection types. One line.")]
    var t = Date()
    let viaSocket = try await BrainSocketClient(temperature: 0).complete(msgs, maxTokens: 60, think: false)
    let ts = Date().timeIntervalSince(t)
    t = Date()
    let viaHTTP = try await LocalChatClient(host: "http://127.0.0.1:\(BrainPorts.edgeHTTP)", model: "code-smash-teti").complete(msgs, maxTokens: 60, think: false)
    let th = Date().timeIntervalSince(t)
    print(String(format: "socket door: %.2fs · %@", ts, viaSocket.trimmingCharacters(in: .whitespacesAndNewlines).prefix(100) as CVarArg))
    print(String(format: "HTTP edge:   %.2fs · %@", th, viaHTTP.trimmingCharacters(in: .whitespacesAndNewlines).prefix(100) as CVarArg))
    let b = await BrainLink.best()
    print("front desk / loop / sleep would use: \(b.name)")
    print(viaSocket.isEmpty ? "SOCKET ❌" : "SOCKET DOOR ✅")
    exit(viaSocket.isEmpty ? 1 : 0)
}

// speculative mode: expert-test --spec <model dir> [--draft <dir>] → same words with a draft, and the speed
if let dir = opt("--spec") {
    let engine = Engine()
    try await engine.loadDraft(URL(fileURLWithPath: opt("--draft") ?? dir), tokens: 3)
    try await engine.load(directory: URL(fileURLWithPath: dir), name: "spec-test")
    let q = [BrainMessage(role: .user, content: "Write a Swift function that checks whether a string is a palindrome, ignoring case and spaces. Code only.")]
    var outs: [Int: String] = [:], speed: [Int: [Double]] = [:]
    for (round, n) in [0, 3, 0, 3, 5].enumerated() {
        await engine.setSpeculation(n); await engine.forgetPrompts()
        var text = ""
        for await ev in await engine.generate(GenerateRequest(messages: q, maxTokens: 120, temperature: 0, think: false)) {
            switch ev {
            case .token(let t): text += t
            case .done(let st): speed[n, default: []].append(st.tokensPerSecond)
                print(String(format: "round %d · draft %@: %6.1f tok/s, %d words", round, n == 0 ? "off  " : "\(n) ahead" as NSString, st.tokensPerSecond, st.generatedTokens))
            case .failure(let f): print("✗ \(f)"); exit(1)
            }
        }
        if let o = outs[n], o != text { print("  (round-to-round difference at draft \(n))") }
        outs[n] = text
    }
    if let sp = await engine.lastSpec { print(String(format: "last draft round stats: %.0f%% of draft words accepted · %.2f words per big-brain pass (%d passes for %d words)", sp.acceptRate * 100, sp.wordsPerPass, sp.mainPasses, sp.generated)) }
    let same3 = outs[0] == outs[3], same5 = outs[0] == outs[5]
    func avg(_ n: Int) -> Double { (speed[n] ?? []).reduce(0, +) / Double(max(1, speed[n]?.count ?? 0)) }
    print(String(format: "\nsame words as without a draft: 3 ahead %@, 5 ahead %@ · speed off %.1f, 3 ahead %.1f, 5 ahead %.1f tok/s",
                 same3 ? "yes" : "NO", same5 ? "yes" : "NO", avg(0), avg(3), avg(5)))
    if !same3, let a = outs[0], let b = outs[3] {
        let i = zip(a, b).prefix { $0 == $1 }.count
        print("  first difference at character \(i) of \(a.count): off \"\(a.dropFirst(i).prefix(30))\" vs draft \"\(b.dropFirst(i).prefix(30))\"")
    }
    exit(0)
}

// prompt-memory mode: expert-test --prompt-memory <model dir> → reuse earlier turns, same answers, less reading
if let dir = opt("--prompt-memory") {
    let engine = Engine()
    try await engine.load(directory: URL(fileURLWithPath: dir), name: "pm-test")
    let design = String((try String(contentsOfFile: BrainPaths.root.appendingPathComponent("DESIGN.md").path, encoding: .utf8)).prefix(9000))
    let system = BrainMessage(role: .system, content: "You are a helpful engineer. Reference document:\n" + design)
    func ask(_ msgs: [BrainMessage]) async -> (String, GenerateStats?) {
        var text = "", st: GenerateStats?
        for await ev in await engine.generate(GenerateRequest(messages: msgs, maxTokens: 40, temperature: 0, think: false)) {
            switch ev { case .token(let t): text += t; case .done(let d): st = d; case .failure(let f): print("✗ \(f)"); exit(1) }
        }
        return (text, st)
    }
    func show(_ label: String, _ r: (String, GenerateStats?)) {
        let s = r.1!
        print(String(format: "%-34@ prompt %5d tokens, %5d remembered, %5.2fs total · \"%@\"", label as NSString, s.promptTokens, s.reusedPromptTokens, s.seconds,
                     String(r.0.prefix(60)).replacingOccurrences(of: "\n", with: " ") as NSString))
    }
    let u1 = BrainMessage(role: .user, content: "In one sentence, what is the relay for?")
    let r1 = await ask([system, u1]); show("turn 1 (fresh)", r1)
    let turn2 = [system, u1, BrainMessage(role: .assistant, content: r1.0), BrainMessage(role: .user, content: "Now say it in five words.")]
    let r2 = await ask(turn2); show("turn 2 (remembers turn 1)", r2)
    let r3 = await ask([system, BrainMessage(role: .user, content: "What does sleep mode do? One sentence.")]); show("new question, same instructions", r3)
    await engine.forgetPrompts()
    let r2cold = await ask(turn2); show("turn 2 again, memory wiped", r2cold)
    // same split points as the remembered run → if saved memory is exact, the answer must match word for word
    await engine.forgetPrompts(); await engine.setTestSplits([r2.1!.reusedPromptTokens])
    let r2split = await ask(turn2); show("turn 2, wiped, same split points", r2split)
    await engine.setTestSplits([])
    let exact = r2.0 == r2split.0
    print("saved memory exact (same answer when split at the same points): \(exact ? "yes ✅" : "NO ❌")")
    let same = exact
    let reused = (r2.1?.reusedPromptTokens ?? 0) > 0 && (r3.1?.reusedPromptTokens ?? 0) > 0
    print(String(format: "\nturn 2: %.2fs with memory vs %.2fs without · same answer as a fresh read: %@ · reuse happened: %@",
                 r2.1!.seconds, r2cold.1!.seconds, r2.0 == r2cold.0 ? "yes" : "no (rounding)", reused ? "yes" : "NO"))
    if !same { print("  with memory: \(r2.0)\n  without:     \(r2cold.0)") }
    print(same && reused ? "PROMPT MEMORY ✅" : "PROMPT MEMORY ❌")
    exit(same && reused ? 0 : 1)
}

// gradient mode: expert-test --grad <laid dir> --source <model dir> → training signal through streamed experts
if let dir = opt("--grad"), let source = opt("--source") {
    MLX.compile(enable: false)
    let b = try ExpertBank(directory: URL(fileURLWithPath: dir), cacheGB: 2)
    let E = b.meta.expertsPerLayer
    let shape = b.meta.parts.first { $0.name == "gate_proj.weight" }!.shape
    let ff = shape[0], H = shape[1] * 8
    let wmap = (try JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: source + "/model.safetensors.index.json"))) as! [String: Any])["weight_map"] as! [String: String]
    var ok = true
    for L in [10, 47] {
        let prefix = b.meta.tensorPrefix.replacingOccurrences(of: "{L}", with: "\(L)")
        let src = try loadArrays(url: URL(fileURLWithPath: source + "/" + wmap[prefix + "gate_proj.weight"]!))
        var p: [String: MLXArray] = [:]
        for part in b.meta.parts { p[part.name] = src[prefix + part.name]! }
        let ref = SwitchGLU(inputDims: H, hiddenDims: ff, numExperts: E)
        quantize(model: ref, groupSize: 64, bits: 4, mode: .affine)
        try ref.update(parameters: ModuleParameters.unflattened(p), verify: .all); eval(ref)
        let stream = StreamingSwitchGLU(layer: L, bank: b, groupSize: 64, bits: 4)
        for tokens in [1, 16] {
            let x = (MLXRandom.normal([tokens, H]) * 0.5).asType(.float32)
            var picks: [UInt32] = []
            for _ in 0..<tokens { picks += Array((0..<E).shuffled().prefix(8)).map { UInt32($0) } }
            let idx = MLXArray(picks, [tokens, 8])
            let w = MLXRandom.normal([tokens, 8, H])
            let gRef = grad({ (x: MLXArray) -> MLXArray in (ref(x, idx) * w).sum() })(x)
            let gStr = grad({ (x: MLXArray) -> MLXArray in (stream(x, idx) * w).sum() })(x)
            let diff = abs(gRef - gStr).max().item(Float.self), size = abs(gRef).max().item(Float.self)
            let pass = diff <= max(1e-3, size * 1e-3)
            ok = ok && pass
            print(String(format: "layer %2d, %2d token(s): gradient max diff %.6f (gradient size %.3f)  %@", L, tokens, diff, size, pass ? "✅" : "❌"))
        }
    }
    print(ok ? "\nGRADIENTS MATCH ✅ training can learn through streamed experts" : "\nGRADIENT MISMATCH ❌")
    exit(ok ? 0 : 1)
}

// prefetch mode: expert-test --prefetch <laid dir> → what-if guesses: correctness + speed simulation
if let dir = opt("--prefetch") {
    MLX.compile(enable: false)
    let url = URL(fileURLWithPath: dir)
    // A) a guess, then the real ask: no second read, identical weights
    let b = try ExpertBank(directory: url, cacheGB: 1)
    let ref = try ExpertBank(directory: url, cacheGB: 1)
    let want = [3, 17, 42, 99, 128, 200, 222, 255]
    b.prefetch(layer: 10, experts: want)
    let got = b.fetch(layer: 10, experts: want)          // arrives while the guess is still reading → must wait, not reread
    let st = b.snapshot()
    let truth = ref.fetch(layer: 10, experts: want)
    var same = true
    for (x, y) in zip(got, truth) { for p in b.meta.parts where !MLX.arrayEqual(x[p.name], y[p.name]).item(Bool.self) { same = false } }
    let okA = st.misses + st.prefetchReads == 8 && st.bytesRead == 8 * b.meta.blockLength && same
    print("guess then ask: \(st.prefetchReads) read by the guess (budget), \(st.misses) by the ask, each expert read exactly once: \(st.bytesRead == 8 * b.meta.blockLength), weights identical: \(same)  \(okA ? "✅" : "❌")")

    // B) speed: one token through every laid layer, cold SSD (tiny cache), GPU work simulated per layer
    let layers = Set(b.meta.entries.map { $0.layer }).sorted()
    let computeMs = Double(opt("--compute-ms") ?? "1.5") ?? 1.5
    // skewed usage like real work: a few experts per layer fire a lot (Zipf-like), most rarely
    let weights = (0..<256).map { 1.0 / pow(Double($0 + 1), 1.1) }
    let wsum = weights.reduce(0, +)
    func pick8(_ rng: inout SystemRandomNumberGenerator, _ layerSalt: Int) -> [Int] {
        var out: [Int] = []
        while out.count < 8 {
            var r = Double.random(in: 0..<wsum, using: &rng), i = 0
            while r > weights[i] { r -= weights[i]; i += 1 }
            let e = (i * 37 + layerSalt * 11) % 256          // different hot experts per layer
            if !out.contains(e) { out.append(e) }
        }
        return out
    }
    var warm = false, cacheGB = 0.3
    var rngShared = SystemRandomNumberGenerator()
    var tokenPlan: [[[Int]]] = []
    for _ in 0..<70 { tokenPlan.append(layers.map { pick8(&rngShared, $0) }) }
    func run(_ name: String, accuracy: Double?) -> Double {
        let bank = try! ExpertBank(directory: url, cacheGB: cacheGB)
        let tokens = 40
        if warm { for t in 40..<70 { for (i, l) in layers.enumerated() { _ = bank.fetch(layer: l, experts: tokenPlan[t][i]) } } }
        let s0 = bank.snapshot()
        let plan = warm ? tokenPlan : (0..<tokens).map { _ in layers.map { _ in Array((0..<256).shuffled().prefix(8)) } }
        let t0 = Date()
        for t in 0..<tokens {
            for (i, l) in layers.enumerated() {
                let picks = plan[t][i]
                bank.scoreGuess(layer: l, actual: Set(picks))
                _ = bank.fetch(layer: l, experts: picks, countUse: false)
                if let acc = accuracy, i + 1 < layers.count {
                    let next = plan[t][i + 1]
                    let right = Int((Double(next.count) * acc).rounded())
                    // a real router ranks its guesses; with accuracy a, right answers are spread through the ranking
                    let guess = (Array(next.prefix(right)) + Array((0..<256).filter { !next.contains($0) }.shuffled().prefix(max(0, bank.guessWidth - right)))).shuffled()
                    bank.prefetch(layer: layers[i + 1], experts: guess)
                }
                Thread.sleep(forTimeInterval: computeMs / 1000)      // the layer's GPU work
            }
        }
        let ms = Date().timeIntervalSince(t0) * 1000 / Double(tokens)
        let s = bank.snapshot()
        print(String(format: "%-20@ %6.1f ms/token  (hit rate %.0f%%, %d asked-for reads, %d guessed reads, guess width %d, rests %d)", name as NSString, ms,
                     Double(s.hits - s0.hits) / Double(max(1, s.hits - s0.hits + s.misses - s0.misses)) * 100, s.misses - s0.misses, s.prefetchReads, bank.guessWidth, s.guessRests))
        return ms
    }
    for (label, w, gbs) in [("COLD SSD, random picks (worst case)", false, 0.3), ("WARM RAM (1/3 of experts), skewed picks like real work", true, Double(b.meta.entries.count) / 3 * 5.308416e-3)] {
        warm = w; cacheGB = gbs
        print("\n\(label) · \(layers.count) layers · \(computeMs) ms GPU work per layer:")
        let base = run("no guessing", accuracy: nil)
        let p50 = run("guesses 50% right", accuracy: 0.5)
        let p80 = run("guesses 80% right", accuracy: 0.8)
        let p100 = run("guesses 100% right", accuracy: 1.0)
        print(String(format: "  speed-up: %.2fx at 50%% · %.2fx at 80%% · %.2fx perfect", base / p50, base / p80, base / p100))
    }
    exit(okA ? 0 : 1)
}

guard let bankDir = opt("--bank"), let source = opt("--source") else { print("usage: expert-test --bank DIR --source DIR [--layers 10,21]"); exit(2) }
MLX.compile(enable: false)

let bank = try ExpertBank(directory: URL(fileURLWithPath: bankDir), cacheGB: Double(opt("--cache-gb") ?? "2") ?? 2)
let meta = bank.meta, E = meta.expertsPerLayer
let laid = Set(meta.entries.map { $0.layer }).sorted()
let layers = opt("--layers").map { $0.split(separator: ",").compactMap { Int($0) } } ?? Array(laid.prefix(2))
print("bank: \(laid.count) laid layers \(laid) · testing \(layers)")

let index = try JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: source + "/model.safetensors.index.json"))) as! [String: Any]
let wmap = index["weight_map"] as! [String: String]
let hidden = meta.parts.first { $0.name == "gate_proj.weight" }!.shape   // [ff, hidden/8] packed
let ff = hidden[0], H = hidden[1] * 8
var allOK = true

for L in layers {
    let prefix = meta.tensorPrefix.replacingOccurrences(of: "{L}", with: "\(L)")
    let shard = wmap[prefix + "gate_proj.weight"]!
    let src = try loadArrays(url: URL(fileURLWithPath: source + "/" + shard))
    var p: [String: MLXArray] = [:]
    for part in meta.parts { p[part.name] = src[prefix + part.name]! }

    // reference: Apple's own SwitchGLU with every expert in RAM
    let ref = SwitchGLU(inputDims: H, hiddenDims: ff, numExperts: E)
    quantize(model: ref, groupSize: 64, bits: 4, mode: .affine)
    try ref.update(parameters: ModuleParameters.unflattened(p), verify: .all)
    eval(ref)
    let stream = StreamingSwitchGLU(layer: L, bank: bank, groupSize: 64, bits: 4)

    for (label, tokens) in [("decode (1 token)", 1), ("prefill (32 tokens)", 32)] {
        let x = (MLXRandom.normal([tokens, H]) * 0.5).asType(.bfloat16)
        // 8 distinct experts per token, like the router
        var picks: [UInt32] = []
        for _ in 0..<tokens { picks += Array((0..<E).shuffled().prefix(8)).map { UInt32($0) } }
        let idx = MLXArray(picks, [tokens, 8])
        let a = ref(x, idx), b = stream(x, idx)
        let diff = abs(a.asType(.float32) - b.asType(.float32)).max().item(Float.self)
        let scale = abs(a.asType(.float32)).max().item(Float.self)
        let ok = diff <= max(1e-2, scale * 1e-2)
        allOK = allOK && ok
        print(String(format: "layer %2d %-20@ max diff %.5f (output size %.3f)  %@", L, label as NSString, diff, scale, ok ? "✅ match" : "❌ MISMATCH"))
    }
}

// speed: one decode token's worth (8 experts) per layer, cold from SSD then warm from RAM
let s0 = bank.snapshot()
var t = Date()
let coldL = layers.last!
let fresh = Array((0..<E).shuffled().prefix(8))
_ = bank.fetch(layer: coldL, experts: fresh)
let cold = Date().timeIntervalSince(t)
t = Date()
for _ in 0..<100 { _ = bank.fetch(layer: coldL, experts: fresh) }
let warm = Date().timeIntervalSince(t) / 100
let s1 = bank.snapshot()
print(String(format: "\nspeed: 8 experts cold from SSD %.1f ms · warm from RAM %.3f ms", cold * 1000, warm * 1000))
print("stream: \(s1.line) (reads this test: \(s1.misses - s0.misses))")
print(allOK ? "\nALL MATCH ✅ streamed experts = in-RAM experts" : "\nFAILED ❌")
exit(allOK ? 0 : 1)
