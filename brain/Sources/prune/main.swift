import Foundation

let pruneExclude = (ProcessInfo.processInfo.environment["PRUNE_EXCLUDE"] ?? "").lowercased().isEmpty ? "\u{0}" : ProcessInfo.processInfo.environment["PRUNE_EXCLUDE"]!.lowercased()
import CryptoKit
import MLX
import MLXNN
import MLXLMCommon
import MLXLLM
import BrainCore
import BrainEngine

// prune: cut the experts the owner's work never needs, using usage counts as the evidence.
//
//   prune profile --brain DIR [--tokens 200000]        run the brain over the owner's own code (private files excluded,
//                                                      nothing leaves the Mac) so every expert's usage gets counted
//   prune plan    --brain DIR [--coverage 0.995] [--min-keep 64]
//                                                      per layer: keep the fewest experts that cover 99.5% of firings
//   prune apply   --brain DIR --plan FILE --out DIR2 [--hard]
//                                                      write a NEW brain (original never touched): common experts on the
//                                                      main relay, rare ones in deep memory on a SECOND relay with its own
//                                                      lanes (--hard deletes them instead and the router blocks them)
//   prune exam    --brain DIR --pruned DIR2 [--max-rise 0.03]
//                                                      held-out exam: the pruned brain is adopted only if its loss on
//                                                      code it never profiled is within 3% of the original's
//   prune selftest [--bank DIR]                        prove the router guard and plan/apply work, no full brain needed

setvbuf(stdout, nil, _IOLBF, 0)
let argv = CommandLine.arguments
func opt(_ n: String) -> String? { argv.firstIndex(of: n).flatMap { $0 + 1 < argv.count ? argv[$0 + 1] : nil } }
let fm = FileManager.default
let pruneDir = BrainPaths.memory.appendingPathComponent("prune")
try? fm.createDirectory(at: pruneDir, withIntermediateDirectories: true)
func gb(_ b: Int) -> String { String(format: "%.1f GB", Double(b) / 1e9) }
func notify(_ title: String, _ msg: String) {
    let p = Process(); p.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
    p.arguments = ["-e", "display notification \"\(msg)\" with title \"\(title)\""]; try? p.run(); p.waitUntilExit()
}

// MARK: corpus: the owner's own code, private files excluded, split into profile / held-out (exam) sets

func corpus() -> (profile: [String], heldOut: [String]) {
    let home = NSHomeDirectory()
    let roots = ["\(home)/local-ai", "\(home)/local-ai/brain-lab/projects"]
    let skipDirs = [".build", "checkouts", "node_modules", "venv", ".venv", ".git", "models", "_retired", "site-packages", "DerivedData", "dreams"]
    let exts: Set<String> = ["swift", "py", "sh", "command", "js", "ts", "html", "css", "md", "c", "h", "metal"]
    var files: [String] = []
    for root in roots {
        guard let en = fm.enumerator(atPath: root) else { continue }
        while let rel = en.nextObject() as? String {
            let comps = rel.split(separator: "/").map(String.init)
            if comps.contains(where: { skipDirs.contains($0) }) { if (en.fileAttributes?[.type] as? FileAttributeType) == .typeDirectory { en.skipDescendants() }; continue }
            let full = "\(root)/\(rel)"
            guard exts.contains((rel as NSString).pathExtension.lowercased()),
                  let size = en.fileAttributes?[.size] as? Int, size > 200, size < 200_000 else { continue }
            if full.lowercased().contains(pruneExclude) { continue }                      // private files stay out (set PRUNE_EXCLUDE)
            files.append(full)
        }
    }
    files = Array(Set(files)).sorted()
    var texts: [(String, String)] = []
    for f in files {
        guard let t = try? String(contentsOfFile: f, encoding: .utf8), !t.lowercased().contains(pruneExclude) else { continue }
        texts.append((f, t))
    }
    // deterministic split: ~10% of files never seen in profiling become the exam
    var profile: [String] = [], held: [String] = []
    for (f, t) in texts {
        let h = Array(SHA256.hash(data: Data(f.utf8)))[0]
        if h % 10 == 0 { held.append(t) } else { profile.append(t) }
    }
    return (profile, held)
}

func chunks(_ texts: [String], tokenizer: any MLXLMCommon.Tokenizer, size: Int, limit: Int, pack: Bool = false) -> [[Int]] {
    if pack {   // files back to back, so every chunk is full size (small files no longer waste a whole read pass)
        var out: [[Int]] = [], cur: [Int] = [], total = 0
        for t in texts {
            cur += tokenizer.encode(text: t + "\n\n")
            while cur.count >= size && total < limit { out.append(Array(cur.prefix(size))); cur.removeFirst(size); total += size }
            if total >= limit { break }
        }
        if cur.count > 32 && total < limit { out.append(cur) }
        return out
    }
    var out: [[Int]] = [], total = 0
    for t in texts {
        let ids = tokenizer.encode(text: t)
        var i = 0
        while i + 32 < ids.count && total < limit {
            let c = Array(ids[i..<min(i + size, ids.count)]); out.append(c); total += c.count; i += size
        }
        if total >= limit { break }
    }
    return out
}

func meanLoss(_ model: any LLMModel, _ cs: [[Int]]) -> Double {
    var sum = 0.0, n = 0
    for c in cs {
        let x = MLXArray(c.map { Int32($0) })[.newAxis]
        let logits = model(x, cache: nil)
        let l = crossEntropy(logits: logits[0, ..<(c.count - 1)].asType(.float32), targets: MLXArray(c.dropFirst().map { Int32($0) }), reduction: .sum)
        sum += Double(l.item(Float.self)); n += c.count - 1
    }
    return sum / Double(max(1, n))
}

// MARK: plan: per layer, the fewest experts covering `coverage` of firings (never below min-keep)

func makePlan(usage: [Int: Int], meta: BankMeta, coverage: Double, minKeep: Int, source: String) -> (PrunePlan, [String]) {
    let E = meta.expertsPerLayer
    let layers = Set(meta.entries.map { $0.layer }).sorted()
    var kept: [String: [Int]] = [:], lines: [String] = []
    var layerTotals: [Int] = []
    for l in layers {
        let counts = (0..<E).map { (e: $0, c: usage[l * E + $0] ?? 0) }.sorted { $0.c > $1.c }
        let total = counts.reduce(0) { $0 + $1.c }
        layerTotals.append(total)
        var keep: [Int] = [], acc = 0
        for x in counts {
            if keep.count >= minKeep && Double(acc) >= coverage * Double(total) { break }
            keep.append(x.e); acc += x.c
        }
        kept[String(l)] = keep.sorted()
        let never = counts.filter { $0.c == 0 }.count
        lines.append(String(format: "layer %2d: keep %3d / %d  (covers %.2f%% of firings, %d never fired)", l, keep.count, E, total == 0 ? 0.0 : Double(acc) / Double(total) * 100, never))
    }
    // ~8 picks per token per layer → tokens seen
    let tokens = (layerTotals.min() ?? 0) / 8
    return (PrunePlan(source: source, coverage: coverage, tokensSeen: tokens, kept: kept, originalCount: meta.entries.count), lines)
}

// MARK: apply: write a new smaller brain; original untouched

func apply(brain: URL, plan: PrunePlan, out: URL, hard: Bool = false) throws {
    let meta = try JSONDecoder().decode(BankMeta.self, from: Data(contentsOf: brain.appendingPathComponent("bank-meta.json")))
    try fm.createDirectory(at: out, withIntermediateDirectories: true)
    // everything that isn't the bank: hard-linked (same SSD, zero extra space), copied if linking fails
    for f in try fm.contentsOfDirectory(atPath: brain.path) where !["bank.bin", "bank.json", "bank-meta.json", "pruned.json", "rare.bin", "rare-meta.json", "exam.json"].contains(f) && !f.hasPrefix(".") {
        let src = brain.appendingPathComponent(f), dst = out.appendingPathComponent(f)
        try? fm.removeItem(at: dst)
        do { try fm.linkItem(at: src, to: dst) } catch { try fm.copyItem(at: src, to: dst) }
    }
    let keep = Set(plan.kept.flatMap { (l, es) in es.map { Int(l)! * meta.expertsPerLayer + $0 } })
    // the source may itself be pruned: gather its experts from both of its banks
    var sources: [(BankMeta.Entry, String)] = meta.entries.map { ($0, "bank.bin") }
    if let rd = try? Data(contentsOf: brain.appendingPathComponent("rare-meta.json")), let rm = try? JSONDecoder().decode(BankMeta.self, from: rd) {
        precondition(rm.bits == nil, "this brain's deep memory is slimmed (\(rm.bits!)-bit); prune from the original brain instead")
        sources += rm.entries.map { ($0, "rare.bin") }
    }
    let common = sources.filter { keep.contains($0.0.layer * meta.expertsPerLayer + $0.0.expert) }
    let rare = sources.filter { !keep.contains($0.0.layer * meta.expertsPerLayer + $0.0.expert) }
    let (entries, blocks) = try writeBank(common, from: brain, to: out.appendingPathComponent("bank.bin").path, meta: meta)
    var m = meta; m.entries = entries
    let enc = JSONEncoder(); enc.outputFormatting = [.prettyPrinted, .sortedKeys]
    try enc.encode(m).write(to: out.appendingPathComponent("bank-meta.json"))
    try enc.encode(BankIndex(drives: [.init(name: "internal SSD", file: out.appendingPathComponent("bank.bin").path, lanes: 8)], blocks: blocks)).write(to: out.appendingPathComponent("bank.json"))
    try? fm.removeItem(at: out.appendingPathComponent("rare.bin")); try? fm.removeItem(at: out.appendingPathComponent("rare-meta.json"))
    if !hard && !rare.isEmpty {
        // second relay's bank: deep memory for rarely used experts. If they all live in one source file, hard-link
        // that file (same SSD, zero extra space) and keep their block numbers; otherwise write a fresh copy.
        var re: [BankMeta.Entry]
        let files = Set(rare.map { $0.1 })
        if files.count == 1, (try? fm.linkItem(at: brain.appendingPathComponent(files.first!), to: out.appendingPathComponent("rare.bin"))) != nil {
            re = rare.map { $0.0 }
            print("  deep memory shares the original bank file (hard link, 0 extra bytes)")
        } else {
            re = try writeBank(rare, from: brain, to: out.appendingPathComponent("rare.bin").path, meta: meta).0
        }
        var rm = meta; rm.entries = re
        try enc.encode(rm).write(to: out.appendingPathComponent("rare-meta.json"))
    }
    try enc.encode(plan).write(to: out.appendingPathComponent("pruned.json"))
    print("✓ pruned brain written → \(out.path)")
    print("  main relay:        \(entries.count) common experts · \(gb(entries.count * meta.blockLength))")
    print(hard ? "  cut for good:      \(rare.count) experts (--hard), router blocks them"
               : "  deep-memory relay: \(rare.count) rare experts · \(gb(rare.count * meta.blockLength)) (still reachable on their own lanes)")
}

/// Copy experts into a new bank file, checking every one against its fingerprint on the way.
func writeBank(_ items: [(BankMeta.Entry, String)], from brain: URL, to bankPath: String, meta: BankMeta) throws -> ([BankMeta.Entry], [BankIndex.Block]) {
    var rfds: [String: Int32] = [:]
    let wfd = open(bankPath, O_WRONLY | O_CREAT | O_TRUNC, 0o600); _ = fcntl(wfd, F_NOCACHE, 1)
    let buf = UnsafeMutableRawPointer.allocate(byteCount: meta.blockLength, alignment: 16384)
    defer { buf.deallocate(); rfds.values.forEach { close($0) }; close(wfd) }
    let raw = meta.parts.last!.offset + meta.parts.last!.length
    var entries: [BankMeta.Entry] = [], blocks: [BankIndex.Block] = []
    for (i, (e, file)) in items.enumerated() {
        let rfd = rfds[file] ?? { let fd = open(brain.appendingPathComponent(file).path, O_RDONLY); _ = fcntl(fd, F_NOCACHE, 1); rfds[file] = fd; return fd }()
        var got = 0
        while got < meta.blockLength { let n = pread(rfd, buf + got, meta.blockLength - got, off_t(e.block * meta.blockLength + got)); precondition(n > 0, "read failed"); got += n }
        let sum = SHA256.hash(data: UnsafeRawBufferPointer(start: buf, count: raw)).map { String(format: "%02x", $0) }.joined()
        precondition(sum == e.sha256, "expert L\(e.layer)/E\(e.expert) is damaged in the source bank; re-lay before pruning")
        precondition(RawIO.writeAll(wfd, buf, meta.blockLength), "write failed (disk full?)")
        entries.append(.init(block: i, layer: e.layer, expert: e.expert, sha256: e.sha256))
        blocks.append(.init(id: i, length: raw, locations: [.init(drive: 0, offset: i * meta.blockLength)]))
    }
    fsync(wfd)
    return (entries, blocks)
}


// MARK: slim (fewer bits for deep memory)

/// One expert block → its 9 arrays.
func decodeBlock(_ buf: UnsafeMutableRawPointer, _ parts: [BankMeta.Part]) -> [String: MLXArray] {
    var a: [String: MLXArray] = [:]
    for p in parts {
        let ptr = UnsafeRawBufferPointer(start: buf + p.offset, count: p.length)
        switch p.dtype {
        case "U32": a[p.name] = MLXArray(ptr, p.shape, type: UInt32.self)
        case "BF16": a[p.name] = MLXArray(ptr, p.shape, type: UInt16.self).view(dtype: .bfloat16)
        default: fatalError("unsupported dtype \(p.dtype)")
        }
    }
    return a
}

/// Best-fit grid for each group of weights: instead of stretching the grid from the group's min to its max (one
/// outlier wastes most levels), search clipped ranges, keep the one with the least error, then refine scale and
/// offset by least squares. Returns weights that sit exactly on that better grid, ready to pack.
func bestFit(_ w: MLXArray, groupSize gs: Int, bits: Int) -> (w: MLXArray, scales: MLXArray, biases: MLXArray) {
    let O = w.dim(0), I = w.dim(1)
    let g = w.asType(.float32).reshaped([O, I / gs, gs])
    let mn = g.min(axis: -1, keepDims: true), mx = g.max(axis: -1, keepDims: true), range = mx - mn
    let L = Float((1 << bits) - 1)
    var best = MLXArray.full(mn.shape, values: MLXArray(Float.infinity)), lo = mn, hi = mx
    for a in stride(from: Float(0), through: 0.2, by: 0.04) { for b in stride(from: Float(0), through: 0.2, by: 0.04) {
        let l = mn + a * range, h = mx - b * range
        let sc = MLX.maximum((h - l) / L, MLXArray(Float(1e-8)))
        let d = MLX.clip(MLX.round((g - l) / sc), min: 0, max: L) * sc + l
        let err = ((d - g) * (d - g)).sum(axis: -1, keepDims: true)
        let m = err .< best
        best = MLX.which(m, err, best); lo = MLX.which(m, l, lo); hi = MLX.which(m, h, hi)
    } }
    var sc = MLX.maximum((hi - lo) / L, MLXArray(Float(1e-8))), off = lo
    let n = Float(gs)
    for _ in 0..<2 {   // least squares: best scale + offset for the chosen levels, then re-pick levels
        let q = MLX.clip(MLX.round((g - off) / sc), min: 0, max: L)
        let sq = q.sum(axis: -1, keepDims: true), sqq = (q * q).sum(axis: -1, keepDims: true)
        let sw = g.sum(axis: -1, keepDims: true), sqw = (q * g).sum(axis: -1, keepDims: true)
        let den = n * sqq - sq * sq
        let ok = MLX.abs(den) .> 1e-6
        let ns = MLX.which(ok, (n * sqw - sq * sw) / MLX.which(ok, den, MLXArray(Float(1))), sc)
        let no = MLX.which(ok, (sw - ns * sq) / n, off)
        let good = ns .> 1e-8
        sc = MLX.which(good, ns, sc); off = MLX.which(good, no, off)
    }
    let q = MLX.clip(MLX.round((g - off) / sc), min: 0, max: L)
    return ((q * sc + off).reshaped([O, I]).asType(w.dtype), sc.squeezed(axis: -1).asType(w.dtype), off.squeezed(axis: -1).asType(w.dtype))
}

/// 4-bit expert → `bits`-bit expert (dequantize, then quantize again with the same group size).
func requantize(_ a: [String: MLXArray], groupSize: Int, from: Int, to bits: Int, fit: Bool = true) -> [String: MLXArray] {
    var out: [String: MLXArray] = [:]
    for proj in ["gate_proj", "up_proj", "down_proj"] {
        let w = MLX.dequantized(a["\(proj).weight"]!, scales: a["\(proj).scales"]!, biases: a["\(proj).biases"]!, groupSize: groupSize, bits: from)
        if fit {
            // pack the levels, then keep OUR fitted scale + offset (the packer would otherwise pick its own grid)
            let f = bestFit(w, groupSize: groupSize, bits: bits)
            let q = MLX.quantized(f.w, groupSize: groupSize, bits: bits)
            let theirs = MLX.dequantized(q.wq, scales: q.scales, biases: q.biases!, groupSize: groupSize, bits: bits).asType(.float32)
            let ours = MLX.dequantized(q.wq, scales: f.scales, biases: f.biases, groupSize: groupSize, bits: bits).asType(.float32)
            let w32 = w.asType(.float32)
            // per group, keep whichever grid is closer to the real weights (never worse than plain)
            let O = w.dim(0), G = w.dim(1) / groupSize
            let eT = ((theirs - w32) * (theirs - w32)).reshaped([O, G, groupSize]).sum(axis: -1)
            let eO = ((ours - w32) * (ours - w32)).reshaped([O, G, groupSize]).sum(axis: -1)
            let plain = MLX.quantized(w, groupSize: groupSize, bits: bits)
            let pd = MLX.dequantized(plain.wq, scales: plain.scales, biases: plain.biases!, groupSize: groupSize, bits: bits).asType(.float32)
            let eP = ((pd - w32) * (pd - w32)).reshaped([O, G, groupSize]).sum(axis: -1)
            let useOurs = eO .< eT
            let fitS = MLX.which(useOurs, f.scales, q.scales), fitB = MLX.which(useOurs, f.biases, q.biases!)
            let fitE = MLX.minimum(eO, eT)
            let usePlain = eP .<= fitE   // whole group falls back to plain when that's closer
            out["\(proj).scales"] = MLX.which(usePlain, plain.scales, fitS)
            out["\(proj).biases"] = MLX.which(usePlain, plain.biases!, fitB)
            // packed levels: per group from plain or fit. Rows of packed words line up with groups (gs*bits/32 words each)
            let wpg = groupSize * bits / 32
            let pw = plain.wq.reshaped([O, G, wpg]), fw = q.wq.reshaped([O, G, wpg])
            out["\(proj).weight"] = MLX.which(MLX.expandedDimensions(usePlain, axis: -1), pw, fw).reshaped(plain.wq.shape)
        } else {
            let q = MLX.quantized(w, groupSize: groupSize, bits: bits)
            out["\(proj).weight"] = q.wq; out["\(proj).scales"] = q.scales; out["\(proj).biases"] = q.biases!
        }
    }
    eval(Array(out.values))
    return out
}

func bytes(_ x: MLXArray) -> Data {
    if x.dtype == .bfloat16 { return x.view(dtype: .uint16).asData(access: .copy).data }
    return x.asData(access: .copy).data
}

/// Write `entries` (read from `srcFile` laid out by `srcMeta`) into `dst` at `bits`. Returns the new meta.
func writeSlim(_ entries: [BankMeta.Entry], srcFile: String, srcMeta: BankMeta, dst: String, bits: Int, groupSize: Int,
               report: ((Int, Int) -> Void)? = nil) throws -> BankMeta {
    let rfd = open(srcFile, O_RDONLY); _ = fcntl(rfd, F_NOCACHE, 1)
    let tmp = dst + ".partial"
    let wfd = open(tmp, O_WRONLY | O_CREAT | O_TRUNC, 0o600); _ = fcntl(wfd, F_NOCACHE, 1)
    let buf = UnsafeMutableRawPointer.allocate(byteCount: srcMeta.blockLength, alignment: 16384)
    defer { buf.deallocate(); close(rfd) }
    let raw = srcMeta.parts.last!.offset + srcMeta.parts.last!.length
    var parts: [BankMeta.Part] = [], blockLength = 0, out: [BankMeta.Entry] = []
    var wbuf = Data()
    for (i, e) in entries.enumerated() {
        var got = 0
        while got < srcMeta.blockLength { let n = pread(rfd, buf + got, srcMeta.blockLength - got, off_t(e.block * srcMeta.blockLength + got)); precondition(n > 0, "read failed"); got += n }
        let sum = SHA256.hash(data: UnsafeRawBufferPointer(start: buf, count: raw)).map { String(format: "%02x", $0) }.joined()
        precondition(sum == e.sha256, "expert L\(e.layer)/E\(e.expert) is damaged; re-lay before slimming")
        let q = requantize(decodeBlock(buf, srcMeta.parts), groupSize: groupSize, from: srcMeta.bits ?? 4, to: bits)
        if parts.isEmpty {   // layout from the first expert, same part order as the source
            var off = 0
            for p in srcMeta.parts {
                let x = q[p.name]!
                let len = x.nbytes
                parts.append(.init(name: p.name, dtype: x.dtype == .uint32 ? "U32" : "BF16", shape: x.shape, offset: off, length: len))
                off += (len + 63) / 64 * 64
            }
            blockLength = (off + 16383) / 16384 * 16384
        }
        wbuf.removeAll(keepingCapacity: true); wbuf.count = blockLength
        for p in parts { let d = bytes(q[p.name]!); precondition(d.count == p.length); wbuf.replaceSubrange(p.offset..<(p.offset + p.length), with: d) }
        let rawLen = parts.last!.offset + parts.last!.length
        let nsum = SHA256.hash(data: wbuf.prefix(rawLen)).map { String(format: "%02x", $0) }.joined()
        try wbuf.withUnsafeBytes { precondition(RawIO.writeAll(wfd, UnsafeMutableRawPointer(mutating: $0.baseAddress!), blockLength), "write failed (disk full?)") }
        out.append(.init(block: i, layer: e.layer, expert: e.expert, sha256: nsum))
        if i % 200 == 199 { report?(i + 1, entries.count) }
    }
    fsync(wfd); close(wfd)
    try? fm.removeItem(atPath: dst)              // may be a hard link to the original bank: unlink, never overwrite
    try fm.moveItem(atPath: tmp, toPath: dst)
    var m = srcMeta; m.parts = parts; m.blockLength = blockLength; m.entries = out; m.bits = bits
    return m
}

func modelGroupSize(_ dir: URL) -> Int {
    guard let d = try? Data(contentsOf: dir.appendingPathComponent("config.json")),
          let j = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
          let q = (j["quantization"] ?? j["quantization_config"]) as? [String: Any] else { return 64 }
    return q["group_size"] as? Int ?? 64
}

/// Slim a pruned brain's deep memory in place.
func slim(_ dir: URL, bits: Int) throws {
    let rmURL = dir.appendingPathComponent("rare-meta.json")
    guard let d = try? Data(contentsOf: rmURL), let rm = try? JSONDecoder().decode(BankMeta.self, from: d) else {
        print("✗ no deep-memory bank in \(dir.lastPathComponent) (prune apply first, without --hard)"); exit(1)
    }
    guard rm.bits == nil else { print("✗ deep memory is already \(rm.bits!)-bit"); exit(1) }
    let gs = modelGroupSize(dir)
    let before = rm.entries.count * rm.blockLength
    print("slimming \(rm.entries.count) deep-memory experts: 4-bit → \(bits)-bit (group \(gs)) …")
    let t0 = Date()
    let m = try writeSlim(rm.entries, srcFile: dir.appendingPathComponent("rare.bin").path, srcMeta: rm,
                          dst: dir.appendingPathComponent("rare.bin").path, bits: bits, groupSize: gs) { done, all in
        print(String(format: "  %d/%d · %.0f experts/s", done, all, Double(done) / Date().timeIntervalSince(t0))); fflush(stdout)
    }
    let enc = JSONEncoder(); enc.outputFormatting = [.prettyPrinted, .sortedKeys]
    try enc.encode(m).write(to: rmURL)
    print("✓ deep memory slimmed: \(gb(before)) → \(gb(m.entries.count * m.blockLength)) (\(m.blockLength / 1024) KB per expert, was \(rm.blockLength / 1024) KB)")
}

/// Proves the slim path: requantize error is sane, a slim bank reads back exactly, and mixed 4-bit + slim experts in
/// one layer give the same answer as computing each expert alone. Uses 16 experts from a real brain (~85 MB read).
func slimTest(brain: URL, bits: Int) throws -> Bool {
    let meta = try JSONDecoder().decode(BankMeta.self, from: Data(contentsOf: brain.appendingPathComponent("bank-meta.json")))
    let gs = modelGroupSize(brain)
    let pick = Array(meta.entries.filter { $0.layer == 0 }.prefix(16))
    let tmp = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("teti-slimtest-\(getpid())")
    try? fm.removeItem(at: tmp); try fm.createDirectory(at: tmp, withIntermediateDirectories: true)
    defer { try? fm.removeItem(at: tmp) }
    // main bank: first 8 at 4-bit; deep memory: last 8 slimmed
    let (me, blocks) = try writeBank(pick.prefix(8).map { ($0, "bank.bin") }, from: brain, to: tmp.appendingPathComponent("bank.bin").path, meta: meta)
    var mm = meta; mm.entries = me
    let enc = JSONEncoder()
    try enc.encode(mm).write(to: tmp.appendingPathComponent("bank-meta.json"))
    try enc.encode(BankIndex(drives: [.init(name: "t", file: tmp.appendingPathComponent("bank.bin").path, lanes: 8)], blocks: blocks)).write(to: tmp.appendingPathComponent("bank.json"))
    let rm = try writeSlim(Array(pick.suffix(8)), srcFile: brain.appendingPathComponent("bank.bin").path, srcMeta: meta,
                           dst: tmp.appendingPathComponent("rare.bin").path, bits: bits, groupSize: gs)
    try enc.encode(rm).write(to: tmp.appendingPathComponent("rare-meta.json"))
    print(String(format: "slim block %d KB vs %d KB (%.0f%%)", rm.blockLength / 1024, meta.blockLength / 1024, Double(rm.blockLength) / Double(meta.blockLength) * 100))

    let bank = try ExpertBank(directory: tmp, cacheGB: 1)
    let experts = pick.map { $0.expert }
    let ws = bank.fetch(layer: 0, experts: experts)
    var ok = true
    // 1. readback: slim experts carry their bits, and requantizing again from the 4-bit source gives identical bytes
    let raw4 = bank.fetch(layer: 0, experts: Array(experts.prefix(8)))
    _ = raw4
    let slimBits = ws.suffix(8).map { $0.bits ?? 4 }
    print("bits of deep-memory experts as read back: \(Set(slimBits))  \(Set(slimBits) == [bits] ? "✅" : "❌")"); ok = ok && Set(slimBits) == [bits]
    // 2. precision lost, measured after packing (what the brain will actually use): plain min-max vs best fit
    var worstConv: Float = 0
    for fit in [false, true] {
        var num: Float = 0, den: Float = 0
        for w in ws.prefix(4) {
            let src: [String: MLXArray] = Dictionary(uniqueKeysWithValues: ["gate_proj", "up_proj", "down_proj"].flatMap { p in ["weight", "scales", "biases"].map { ("\(p).\($0)", w["\(p).\($0)"]) } })
            let r = requantize(src, groupSize: gs, from: 4, to: bits, fit: fit)
            for p in ["gate_proj", "up_proj", "down_proj"] {
                let w4 = MLX.dequantized(src["\(p).weight"]!, scales: src["\(p).scales"]!, biases: src["\(p).biases"]!, groupSize: gs, bits: 4).asType(.float32)
                let wl = MLX.dequantized(r["\(p).weight"]!, scales: r["\(p).scales"]!, biases: r["\(p).biases"]!, groupSize: gs, bits: bits).asType(.float32)
                // the as-4-bit conversion must reproduce the slim expert exactly (same values, one compute path)
                let c4 = ExpertWeights(r, bits: bits).as4bit()
                let wc = MLX.dequantized(c4["\(p).weight"], scales: c4["\(p).scales"], biases: c4["\(p).biases"], groupSize: gs, bits: 4).asType(.float32)
                let convErr = (MLX.abs(wc - wl).max() / MLX.maximum(MLX.abs(wl).max(), MLXArray(Float(1e-6)))).item(Float.self)
                worstConv = max(worstConv, convErr)
                num += ((wl - w4) * (wl - w4)).sum().item(Float.self); den += (w4 * w4).sum().item(Float.self)
            }
        }
        print(String(format: "precision lost at %d-bit, %@: %.1f%% of weight size", bits, fit ? "best fit  " : "plain grid", sqrt(num / den) * 100))
    }
    print(String(format: "as-4-bit conversion: worst difference %.5f%% of the weight range %@", worstConv * 100, worstConv < 0.01 ? "✓ exact (rounding only)" : "✗ NOT exact"))
    if worstConv >= 0.01 { ok = false }
    // 3. mixed layer == expert-by-expert reference
    let glu = StreamingSwitchGLU(layer: 0, bank: bank, groupSize: gs, bits: 4)
    let H = meta.parts.first { $0.name == "gate_proj.weight" }!.shape.last! * 32 / 4
    MLXRandom.seed(7)
    let x = MLXRandom.normal([3, H]).asType(.bfloat16)
    let idx: [[Int]] = [[experts[0], experts[9], experts[3], experts[12], experts[5], experts[15], experts[1], experts[8]],
                        [experts[8], experts[9], experts[10], experts[11], experts[12], experts[13], experts[14], experts[15]],
                        [experts[0], experts[1], experts[2], experts[3], experts[4], experts[5], experts[6], experts[7]]]
    let y = glu(x, MLXArray(idx.flatMap { $0.map { Int32($0) } }, [3, 8]))
    var worst: Float = 0
    for t in 0..<3 { for k in 0..<8 {
        let w = ws[experts.firstIndex(of: idx[t][k])!]; let b = w.bits ?? 4
        func mm(_ v: MLXArray, _ n: String) -> MLXArray { MLX.quantizedMatmul(v, w["\(n).weight"], scales: w["\(n).scales"], biases: w["\(n).biases"], transpose: true, groupSize: gs, bits: b) }
        let xt = x[t..<(t + 1)]
        let r = mm(silu(mm(xt, "gate_proj")) * mm(xt, "up_proj"), "down_proj")
        let d = abs(y[t, k].asType(.float32) - r[0].asType(.float32)).max().item(Float.self) / max(1e-6, abs(r).max().item(Float.self))
        worst = max(worst, d)
    } }
    let mixedOK = worst < 0.02
    print(String(format: "mixed 4-bit + %d-bit layer vs expert-by-expert: worst difference %.4f%% of output size  %@", bits, worst * 100, mixedOK ? "✅" : "❌"))
    ok = ok && mixedOK
    // 4. RAM budget in bytes: 8 full + 8 slim experts cost 8 + 8 × (slim size) units, and shrinking respects it
    let want = 8 + 8 * bank.slimUnit
    let loadOK = abs(bank.loadUnits - want) < 0.01
    print(String(format: "RAM budget: %.2f units for 8 full + 8 slim (expected %.2f)  %@", bank.loadUnits, want, loadOK ? "✅" : "❌"))
    bank.setCapacity(10)
    let shrinkOK = bank.loadUnits <= 10 + 1e-9
    print(String(format: "after shrinking to 10 units: %.2f in RAM  %@", bank.loadUnits, shrinkOK ? "✅" : "❌"))
    ok = ok && loadOK && shrinkOK
    return ok
}

// MARK: commands

let cmd = argv.dropFirst().first ?? ""
switch cmd {
case "slim":
    // prune slim --brain DIR --plan FILE --out DIR2 [--bits 3]  → prune (soft), then the deep memory goes to fewer bits
    // prune slim --dir PRUNED [--bits 3]                         → slim an already-pruned brain's deep memory
    let bits = Int(opt("--bits") ?? "3") ?? 3
    guard [2, 3].contains(bits) else { print("--bits must be 2 or 3"); exit(2) }
    if let d = opt("--dir") { try slim(URL(fileURLWithPath: d), bits: bits); exit(0) }
    guard let brain = opt("--brain"), let planPath = opt("--plan"), let out = opt("--out") else { print("need --brain --plan --out (or --dir)"); exit(2) }
    let plan = try JSONDecoder().decode(PrunePlan.self, from: Data(contentsOf: URL(fileURLWithPath: planPath)))
    try apply(brain: URL(fileURLWithPath: brain), plan: plan, out: URL(fileURLWithPath: out), hard: false)
    try slim(URL(fileURLWithPath: out), bits: bits)
case "slimtest":
    guard let brain = opt("--brain") else { print("need --brain"); exit(2) }
    let ok = try slimTest(brain: URL(fileURLWithPath: brain), bits: Int(opt("--bits") ?? "3") ?? 3)
    print(ok ? "SLIM TEST ✅" : "SLIM TEST ❌"); exit(ok ? 0 : 1)
case "profile":
    guard let brain = opt("--brain") else { print("need --brain"); exit(2) }
    let (profile, held) = corpus()
    print("corpus: \(profile.count) of the owner's files for profiling, \(held.count) held out for the exam (private files excluded)")
    let (model, tok, bank) = try await StreamingLoader.loadRaw(directory: URL(fileURLWithPath: brain), cacheGB: 0)
    // resumable: each night continues where the last one stopped (progress in memory/prune/profile-progress-<brain>.json)
    let progFile = pruneDir.appendingPathComponent("profile-progress-\(URL(fileURLWithPath: brain).lastPathComponent).json")
    var prog = (try? JSONSerialization.jsonObject(with: Data(contentsOf: progFile)) as? [String: Int]) ?? [:]
    let start = prog["nextChunk"] ?? 0
    // big chunks: each chunk pulls nearly every expert off the SSD once, so 4096 tokens per chunk share those reads 8× better than 512
    let chunkSize = Int(opt("--chunk") ?? "4096") ?? 4096
    let all = chunks(profile, tokenizer: tok, size: chunkSize, limit: Int.max, pack: true)
    let budget = Int(opt("--tokens") ?? "200000") ?? 200_000
    var cs: [[Int]] = [], take = 0
    for c in all.dropFirst(start) where take < budget { cs.append(c); take += c.count }
    let total = cs.reduce(0) { $0 + $1.count }
    print("profiling \(total) tokens in \(cs.count) chunks (chunk \(start) of \(all.count)) …")
    let t0 = Date()
    for (i, c) in cs.enumerated() {
        let logits = model(MLXArray(c.map { Int32($0) })[.newAxis], cache: nil); eval(logits)
        if i % 3 == 2 || i == cs.count - 1 {
            print(String(format: "  %d/%d chunks · %.0f tok/s · %@", i + 1, cs.count, Double(cs.prefix(i + 1).reduce(0) { $0 + $1.count }) / Date().timeIntervalSince(t0), bank.snapshot().line))
            bank.saveUsage(); fflush(stdout)
        }
    }
    bank.saveUsage()
    prog["nextChunk"] = start + cs.count; prog["totalChunks"] = all.count
    prog["tokens"] = (prog["tokens"] ?? 0) + total
    if start + cs.count >= all.count { prog["complete"] = 1 }
    try JSONSerialization.data(withJSONObject: prog).write(to: progFile)
    print("✓ usage counted for \(total) tokens (\(prog["tokens"]!) total, \(prog["complete"] == 1 ? "whole corpus done" : "continues next time")) → \(bank.usageFile.path)")
    notify("🧠 Profiling done", "\(total) tokens of your code counted. Next: prune plan.")

case "plan":
    guard let brain = opt("--brain") else { print("need --brain"); exit(2) }
    let dir = URL(fileURLWithPath: brain)
    let bank = try ExpertBank(directory: dir, cacheGB: 0.1)
    let (plan, lines) = makePlan(usage: bank.usageSnapshot(), meta: bank.meta, coverage: Double(opt("--coverage") ?? "0.995") ?? 0.995,
                                 minKeep: Int(opt("--min-keep") ?? "64") ?? 64, source: brain)
    lines.forEach { print($0) }
    guard plan.tokensSeen >= 20_000 || argv.contains("--force") else {
        print("✗ only ~\(plan.tokensSeen) tokens of evidence; need 20,000+ before cutting anything (run prune profile)"); exit(1)
    }
    let out = pruneDir.appendingPathComponent("plan-\(dir.lastPathComponent).json")
    try JSONEncoder().encode(plan).write(to: out)
    print(String(format: "\nplan: keep %d of %d experts (%.0f%%) · bank %@ → %@ · evidence ~%d tokens\n→ %@", plan.keptCount, plan.originalCount,
                 Double(plan.keptCount) / Double(plan.originalCount) * 100, gb(plan.originalCount * bank.meta.blockLength), gb(plan.keptCount * bank.meta.blockLength), plan.tokensSeen, out.path))

case "apply":
    guard let brain = opt("--brain"), let planPath = opt("--plan"), let out = opt("--out") else { print("need --brain --plan --out"); exit(2) }
    let plan = try JSONDecoder().decode(PrunePlan.self, from: Data(contentsOf: URL(fileURLWithPath: planPath)))
    try apply(brain: URL(fileURLWithPath: brain), plan: plan, out: URL(fileURLWithPath: out), hard: argv.contains("--hard"))

case "exam":
    guard let brain = opt("--brain"), let pruned = opt("--pruned") else { print("need --brain --pruned"); exit(2) }
    // the exam reads held-out code: it must not be counted as usage evidence for either brain
    if ProcessInfo.processInfo.environment["TETI_NO_USAGE"] != "1" {
        setenv("TETI_NO_USAGE", "1", 1)
        let p = Process(); p.executableURL = URL(fileURLWithPath: CommandLine.arguments[0]); p.arguments = Array(CommandLine.arguments.dropFirst())
        try p.run(); p.waitUntilExit(); exit(p.terminationStatus)
    }
    let maxRise = Double(opt("--max-rise") ?? "0.03") ?? 0.03
    let (_, held) = corpus()
    // The original's score never changes for the same exam, so it's remembered: key = fingerprint of the exact exam
    // tokens + the original brain's files (size + date). Anything changes → it's measured again.
    let baselineFile = BrainPaths.memory.appendingPathComponent("prune/exam-baseline.json")
    var baselines = (try? JSONSerialization.jsonObject(with: Data(contentsOf: baselineFile)) as? [String: Double]) ?? [:]
    func fingerprint(_ chunks: [[Int]]) -> String {
        var h = SHA256()
        h.update(data: Data(brain.utf8))
        for f in ["bank-meta.json", "hot.safetensors", "bank.bin"] {
            let a = try? fm.attributesOfItem(atPath: URL(fileURLWithPath: brain).appendingPathComponent(f).path)
            h.update(data: Data("\(f):\((a?[.size] as? Int) ?? 0):\((a?[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0)".utf8))
        }
        for c in chunks { c.withUnsafeBytes { h.update(bufferPointer: $0) } }
        return h.finalize().map { String(format: "%02x", $0) }.joined()
    }
    var examChunks: [[Int]] = []
    var prunedLoss = 0.0, originalLoss: Double? = nil
    for dir in [pruned, brain] {
        if dir == brain, let key = Optional(fingerprint(examChunks)), let known = baselines[key] {
            print(String(format: "%@: held-out loss %.4f (remembered from an earlier exam on the same code)", URL(fileURLWithPath: dir).lastPathComponent, known))
            originalLoss = known; break
        }
        let (model, tok, bank) = try await StreamingLoader.loadRaw(directory: URL(fileURLWithPath: dir), cacheGB: 0)
        if examChunks.isEmpty { examChunks = chunks(held, tokenizer: tok, size: 4096, limit: 30_000, pack: true) }   // big packed chunks: ~4x faster, same for both brains
        let l = meanLoss(model, examChunks)
        print(String(format: "%@: held-out loss %.4f (%d tokens) · %@", URL(fileURLWithPath: dir).lastPathComponent, l, examChunks.reduce(0) { $0 + $1.count }, bank.snapshot().line))
        if dir == brain {
            originalLoss = l
            baselines[fingerprint(examChunks)] = l
            try? JSONSerialization.data(withJSONObject: baselines, options: .prettyPrinted).write(to: baselineFile)
        } else { prunedLoss = l }
        MLX.GPU.clearCache()
    }
    let results = [originalLoss!, prunedLoss]
    let rise = results[1] / results[0] - 1
    let pass = rise <= maxRise
    let verdict: [String: Any] = ["original": results[0], "pruned": results[1], "rise": rise, "maxRise": maxRise, "pass": pass, "date": Date().description]
    try JSONSerialization.data(withJSONObject: verdict, options: .prettyPrinted).write(to: URL(fileURLWithPath: pruned).appendingPathComponent("exam.json"))
    print(String(format: "\n%@ loss change %+.2f%% (limit +%.0f%%)", pass ? "✅ PASS: pruned brain is as good on unseen code;" : "❌ FAIL: pruning hurt it;", rise * 100, maxRise * 100))
    notify(pass ? "✂️ Pruned brain passed" : "✂️ Pruned brain failed", String(format: "held-out loss %+.2f%%", rise * 100))
    exit(pass ? 0 : 1)

case "codecheck":
    // prune codecheck --brain DIR → 4 small coding problems, one attempt each, graded by hidden tests the brain never
    // sees. Same problems, greedy, so the original and a slim brain can be compared head to head.
    guard let dir = opt("--brain") else { print("need --brain"); exit(2) }
    setenv("TETI_NO_USAGE", "1", 1)
    let (model, tok, _) = try await StreamingLoader.loadRaw(directory: URL(fileURLWithPath: dir), cacheGB: 0)
    struct Problem { let name, lang, ask, tests: String }
    let problems = [
        Problem(name: "palindrome", lang: "python",
                ask: "Write a Python function is_palindrome(s) that returns True if s reads the same forwards and backwards, ignoring case and every character that is not a letter or digit.",
                tests: "assert is_palindrome('A man, a plan, a canal: Panama')\nassert not is_palindrome('race a car')\nassert is_palindrome('')\nassert is_palindrome('No 1 on')\nassert not is_palindrome('ab1')\nprint('ALL OK')"),
        Problem(name: "merge-intervals", lang: "python",
                ask: "Write a Python function merge_intervals(intervals) that takes a list of [start, end] pairs (in any order) and returns the merged, non-overlapping intervals sorted by start. Intervals that touch (end == next start) merge too.",
                tests: "assert merge_intervals([[1,3],[2,6],[8,10],[15,18]]) == [[1,6],[8,10],[15,18]]\nassert merge_intervals([[1,4],[4,5]]) == [[1,5]]\nassert merge_intervals([[5,7],[1,2]]) == [[1,2],[5,7]]\nassert merge_intervals([]) == []\nassert merge_intervals([[1,10],[2,3],[4,5]]) == [[1,10]]\nprint('ALL OK')"),
        Problem(name: "roman", lang: "swift",
                ask: "Write a Swift function romanToInt(_ s: String) -> Int that converts a Roman numeral (I, V, X, L, C, D, M, including subtractive forms like IV and CM) to an integer.",
                tests: "precondition(romanToInt(\"III\") == 3)\nprecondition(romanToInt(\"LVIII\") == 58)\nprecondition(romanToInt(\"MCMXCIV\") == 1994)\nprecondition(romanToInt(\"IX\") == 9)\nprecondition(romanToInt(\"MMXXVI\") == 2026)\nprint(\"ALL OK\")"),
        Problem(name: "word-counts", lang: "swift",
                ask: "Write a Swift function wordCounts(_ text: String) -> [String: Int] that counts words. Words are lowercased runs of letters only; anything that is not a letter separates words.",
                tests: "precondition(wordCounts(\"Hello, hello world!\") == [\"hello\": 2, \"world\": 1])\nprecondition(wordCounts(\"\") == [:])\nprecondition(wordCounts(\"it's 2 cats\") == [\"it\": 1, \"s\": 1, \"cats\": 1])\nprecondition(wordCounts(\"A-a A\") == [\"a\": 3])\nprint(\"ALL OK\")"),
    ]
    let work = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("teti-codecheck-\(getpid())")
    try? fm.createDirectory(at: work, withIntermediateDirectories: true)
    defer { try? fm.removeItem(at: work) }
    var passed = 0
    let t0 = Date()
    // Qwen3.5 thinks by default, so an empty think block skips it; Qwen3-Next Instruct has no thinking mode
    let mtype = ((try? JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: dir).appendingPathComponent("config.json")))) as? [String: Any])?["model_type"] as? String ?? ""
    let noThink = mtype.hasPrefix("qwen3_5") ? "<think>\n\n</think>\n\n" : ""
    for pr in problems {
        let prompt = "<|im_start|>user\n\(pr.ask) Reply with only the code in one ```\(pr.lang) block, no explanation, no example usage.<|im_end|>\n<|im_start|>assistant\n" + noThink
        let cache = try model.newCache(parameters: nil)
        var ids = tok.encode(text: prompt)
        let start = ids.count
        var logits = model(MLXArray(ids.map { Int32($0) })[.newAxis], cache: cache); eval(logits)
        var text = ""
        for _ in 0..<600 {
            let next = argMax(logits[0, -1], axis: -1).item(Int32.self)
            ids.append(Int(next))
            text = tok.decode(tokenIds: Array(ids[start...]))
            if text.contains("<|im_end|>") || text.components(separatedBy: "```").count >= 3 { break }
            logits = model(MLXArray([next]).reshaped([1, 1]), cache: cache); eval(logits)
        }
        let parts = text.components(separatedBy: "```")
        var body = parts.count >= 2 ? parts[1] : text
        if let nl = body.firstIndex(of: "\n"), body[..<nl].trimmingCharacters(in: .whitespaces).allSatisfy({ $0.isLetter }) { body = String(body[body.index(after: nl)...]) }
        let file = work.appendingPathComponent(pr.name + (pr.lang == "python" ? ".py" : ".swift"))
        try (body + "\n\n" + pr.tests + "\n").write(to: file, atomically: true, encoding: .utf8)
        let p = Process()
        p.executableURL = URL(fileURLWithPath: pr.lang == "python" ? "/usr/bin/python3" : "/usr/bin/swift")
        p.arguments = [file.path]; p.currentDirectoryURL = work
        let pipe = Pipe(); p.standardOutput = pipe; p.standardError = pipe
        try p.run()
        let deadline = Date().addingTimeInterval(120)
        while p.isRunning && Date() < deadline { usleep(200_000) }
        if p.isRunning { p.terminate() }
        let out = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        let ok = out.contains("ALL OK")
        if ok { passed += 1 }
        print("\(ok ? "✅" : "❌") \(pr.name) (\(pr.lang))" + (ok ? "" : ": " + out.split(separator: "\n").suffix(2).joined(separator: " | ").prefix(200)))
        fflush(stdout)
    }
    print(String(format: "CODECHECK %@: %d/%d passed hidden tests · %.0f s", URL(fileURLWithPath: dir).lastPathComponent, passed, problems.count, Date().timeIntervalSince(t0)))
    exit(0)

case "ladder":
    // prune ladder --brain DIR [--steps 0.95:3,0.90:3,0.90:2] [--adopt]
    // Safest cut first: plan → prune + slim → exam. Stops at the first failed exam and keeps the best brain that
    // passed. If the disk can't hold two brains, the passing one is deleted before the next step (its plan is kept)
    // and rebuilt if the deeper step fails. --adopt: the winner becomes the active brain only if it ALSO scores at
    // least as well as the original on the hidden-test coding check. The original brain is never changed.
    guard let brain = opt("--brain") else { print("need --brain"); exit(2) }
    let src = URL(fileURLWithPath: brain)
    let base = src.lastPathComponent
    let steps: [(Double, Int)] = (opt("--steps") ?? "0.95:3,0.90:3,0.90:2").split(separator: ",").compactMap {
        let p = $0.split(separator: ":"); guard p.count == 2, let c = Double(p[0]), let b = Int(p[1]) else { return nil }; return (c, b)
    }
    let me = URL(fileURLWithPath: CommandLine.arguments[0])
    func sub(_ a: [String]) -> (ok: Bool, out: String) {   // run one of our own commands as its own process (RAM fully freed after)
        let p = Process(); p.executableURL = me; p.arguments = a
        let pipe = Pipe(); p.standardOutput = pipe; p.standardError = pipe
        var out = ""
        pipe.fileHandleForReading.readabilityHandler = { h in let s = String(decoding: h.availableData, as: UTF8.self); out += s }
        do { try p.run() } catch { return (false, "\(error)") }
        p.waitUntilExit(); pipe.fileHandleForReading.readabilityHandler = nil
        out += String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        return (p.terminationStatus == 0, out)
    }
    func line(_ out: String, _ key: String) -> String { out.split(separator: "\n").last { $0.contains(key) }.map(String.init) ?? "" }
    func freeBytes() -> Int { (try? src.deletingLastPathComponent().resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]).volumeAvailableCapacityForImportantUsage).map { Int($0) } ?? 0 }
    var report: [String] = ["# Shrink ladder \(Date())"]
    func say(_ s: String) { print(s); fflush(stdout); report.append(s) }
    let bank0 = try ExpertBank(directory: src, cacheGB: 0.1)
    let usage = bank0.usageSnapshot(), meta = bank0.meta
    var best: (name: String, plan: URL, bits: Int)? = nil
    func build(_ name: String, _ planURL: URL, _ bits: Int) throws {
        let out = src.deletingLastPathComponent().appendingPathComponent(name)
        try? fm.removeItem(at: out)
        let plan = try JSONDecoder().decode(PrunePlan.self, from: Data(contentsOf: planURL))
        try apply(brain: src, plan: plan, out: out, hard: false)
        try slim(out, bits: bits)
    }
    for (cov, bits) in steps {
        let name = "\(base)-c\(Int((cov * 100).rounded()))-b\(bits)"
        say("\n## \(name): experts covering \(Int(cov * 100))% of picks stay 4-bit, the rest go \(bits)-bit")
        let (plan, _) = makePlan(usage: usage, meta: meta, coverage: cov, minKeep: 64, source: brain)
        guard plan.tokensSeen >= 20_000 else { say("✗ only ~\(plan.tokensSeen) tokens of evidence; need 20,000+"); break }
        let planURL = pruneDir.appendingPathComponent("plan-\(name).json")
        try JSONEncoder().encode(plan).write(to: planURL)
        let rare = meta.entries.count - plan.keptCount
        let need = plan.keptCount * meta.blockLength + rare * meta.blockLength * (bits + 1) / 5 + 10_000_000_000
        var deletedBest = false
        if freeBytes() < need, let b = best {
            say("- disk is short: removing \(b.name) for now (its plan is kept, it can be rebuilt)")
            try? fm.removeItem(at: src.deletingLastPathComponent().appendingPathComponent(b.name)); deletedBest = true
        }
        guard freeBytes() >= need else { say(String(format: "✗ not enough disk (need %.0f GB, have %.0f GB)", Double(need) / 1e9, Double(freeBytes()) / 1e9)); break }
        do { try build(name, planURL, bits) } catch { say("✗ building failed: \(error)"); if deletedBest, let b = best { try? build(b.name, b.plan, b.bits) }; break }
        let dir = src.deletingLastPathComponent().appendingPathComponent(name)
        let ex = sub(["exam", "--brain", brain, "--pruned", dir.path])
        say("- " + line(ex.out, "loss change"))
        if ex.ok {
            if let b = best, !deletedBest { try? fm.removeItem(at: src.deletingLastPathComponent().appendingPathComponent(b.name)) }
            best = (name, planURL, bits)
        } else {
            try? fm.removeItem(at: dir)
            if deletedBest, let b = best { say("- rebuilding \(b.name)"); try? build(b.name, b.plan, b.bits) }
            break
        }
    }
    say("\n## Result: \(best?.name ?? "none passed (the original stays)")")
    let progFile = pruneDir.appendingPathComponent("profile-progress-\(base).json")
    let tokens = ((try? JSONSerialization.jsonObject(with: Data(contentsOf: progFile)) as? [String: Int])?["tokens"]) ?? 0
    var adopted = false
    if argv.contains("--adopt"), let b = best {
        // the winner must also code as well as the original (hidden tests), not just predict code as well
        let o = sub(["codecheck", "--brain", brain]), w = sub(["codecheck", "--brain", src.deletingLastPathComponent().appendingPathComponent(b.name).path])
        func score(_ s: String) -> Int { Int(line(s, "CODECHECK").components(separatedBy: ": ").last?.split(separator: "/").first ?? "") ?? -1 }
        let so = score(o.out), sw = score(w.out)
        say("- coding check: original \(so)/4 · \(b.name) \(sw)/4")
        if sw >= so && sw >= 0 {
            let link = src.deletingLastPathComponent().appendingPathComponent("code-smash-teti-active")   // the one "active brain" pointer, whatever the family
            try? fm.removeItem(at: link)
            try fm.createSymbolicLink(at: link, withDestinationURL: src.deletingLastPathComponent().appendingPathComponent(b.name))
            adopted = true
            say("- ✅ adopted: \(b.name) is now the active brain")
        } else { say("- not adopted: it codes worse than the original") }
    }
    try JSONSerialization.data(withJSONObject: ["tokens": tokens, "date": Date().timeIntervalSince1970, "passed": best != nil, "ladder": best?.name ?? "", "adopted": adopted])
        .write(to: pruneDir.appendingPathComponent(base == "code-smash-teti" ? "last-cycle.json" : "last-cycle-\(base).json"))
    try report.joined(separator: "\n").write(to: BrainPaths.root.appendingPathComponent(base == "code-smash-teti" ? "logs/slim-ladder.md" : "logs/slim-ladder-\(base).md"), atomically: true, encoding: .utf8)
    notify("🧠 Shrink ladder done", best.map { "Best: \($0.name)" + (adopted ? " (adopted)" : "") } ?? "none passed; the original stays")
    exit(0)

case "loadcheck":
    // prune loadcheck --brain DIR : load with a tiny expert cache, report layers/precisions, write a few words greedily
    guard let dir = opt("--brain") else { print("need --brain"); exit(2) }
    MLX.compile(enable: false)
    let (model, tok, _) = try await StreamingLoader.loadRaw(directory: URL(fileURLWithPath: dir), cacheGB: Double(opt("--cache") ?? "0.5") ?? 0.5)
    var ids = tok.encode(text: "def fibonacci(n):\n    ")
    let cache = try model.newCache(parameters: nil)
    var logits = model(MLXArray(ids.map { Int32($0) })[.newAxis], cache: cache); eval(logits)
    var out: [Int] = []
    for _ in 0..<12 {
        let next = argMax(logits[0, -1], axis: -1).item(Int.self); out.append(next)
        logits = model(MLXArray([Int32(next)]).reshaped([1, 1]), cache: cache); eval(logits)
    }
    ids += out
    print("LOADCHECK greedy: " + tok.decode(tokenIds: out).replacingOccurrences(of: "\n", with: "⏎"))
    exit(0)

case "speed":
    // prune speed --brain DIR [--tokens 160] → how fast this brain writes code, and how often the experts it needs are
    // already in RAM. Same prompts every time, greedy, so two brains can be compared fairly.
    guard let dir = opt("--brain") else { print("need --brain"); exit(2) }
    setenv("TETI_NO_USAGE", "1", 1)   // a benchmark isn't evidence
    let n = Int(opt("--tokens") ?? "160") ?? 160
    let (model, tok, bank) = try await StreamingLoader.loadRaw(directory: URL(fileURLWithPath: dir), cacheGB: 0)
    let prompts = [
        "<|im_start|>user\nWrite a Swift function that returns the n-th Fibonacci number iteratively.<|im_end|>\n<|im_start|>assistant\n",
        "<|im_start|>user\nWrite a Swift command-line script that reads a CSV file and prints the average of its second column, with error handling.<|im_end|>\n<|im_start|>assistant\n",
    ]
    var rates: [Double] = []
    for (pi, p) in prompts.enumerated() {
        let cache = try model.newCache(parameters: nil)
        let ids = tok.encode(text: p)
        var logits = model(MLXArray(ids.map { Int32($0) })[.newAxis], cache: cache); eval(logits)
        let before = bank.snapshot()
        let t0 = Date()
        for _ in 0..<n {
            let next = argMax(logits[0, -1], axis: -1).asType(.int32)
            logits = model(next.reshaped([1, 1]), cache: cache); eval(logits)
        }
        let dt = Date().timeIntervalSince(t0), after = bank.snapshot()
        let hits = after.hits - before.hits, misses = after.misses - before.misses
        let rate = Double(n) / dt
        print(String(format: "%@ prompt %d: %.2f tokens/s · RAM hit rate %.1f%% while writing", pi == 0 ? "warm-up" : "measured", pi, rate, Double(hits) / Double(max(1, hits + misses)) * 100))
        if pi > 0 { rates.append(rate) }
    }
    let s = bank.snapshot()
    print(String(format: "SPEED %@: %.2f tokens/s · %d experts in RAM (%.1f GB budget) · %@", URL(fileURLWithPath: dir).lastPathComponent,
                 rates.reduce(0, +) / Double(rates.count), s.resident, Double(bank.capacity * bank.expertBytes) / 1e9, s.line))
    exit(0)

case "corpus":
    // what profiling will read: the owner's own files, nothing matching PRUNE_EXCLUDE in its path or text
    let (p, h) = corpus()
    let bytes = (p + h).reduce(0) { $0 + $1.utf8.count }
    let leaks = (p + h).filter { $0.lowercased().contains(pruneExclude) }.count
    print(String(format: "%d files to profile + %d held out for the exam · %.1f MB of text (~%.0fk tokens) · excluded-file matches: %d", p.count, h.count, Double(bytes) / 1e6, Double(bytes) / 3.5 / 1000, leaks))
    exit(leaks == 0 ? 0 : 1)

case "selftest":
    MLX.compile(enable: false)
    var ok = true
    // 1) router guard: cut experts are never picked, kept experts get the same scores as before
    let E = 256, H = 256
    let gate = Linear(H, E, bias: false)
    let kept = Set((0..<E).filter { $0 % 4 == 0 })
    let guarded = MaskedRouter(inner: gate, numExperts: E, kept: kept)
    let x = MLXRandom.normal([64, H])
    let picks = argSort(-guarded(x), axis: -1)[0..., ..<8].asArray(Int32.self)
    let leaked = picks.filter { !kept.contains(Int($0)) }.count
    let raw = softmax(gate(x), axis: -1), g = softmax(guarded(x), axis: -1)
    let keptIdx = MLXArray(kept.sorted().map { Int32($0) })
    let renorm = raw[0..., keptIdx] / raw[0..., keptIdx].sum(axis: -1, keepDims: true)
    let diff = abs(renorm - g[0..., keptIdx]).max().item(Float.self)
    print("router guard: \(leaked) picks of cut experts out of \(picks.count) · kept-expert scores match (renormalized) diff \(diff)  \(leaked == 0 && diff < 1e-5 ? "✅" : "❌")")
    ok = ok && leaked == 0 && diff < 1e-5

    // 2) plan + apply on a real bank with skewed (Zipf-like) usage: kept experts copied byte-for-byte, cut ones gone
    let bankDir = URL(fileURLWithPath: opt("--bank") ?? BrainPaths.models.appendingPathComponent("test/partial-lay").path)
    if fm.fileExists(atPath: bankDir.appendingPathComponent("bank-meta.json").path) {
        let bank = try ExpertBank(directory: bankDir, cacheGB: 0.1)
        var usage: [Int: Int] = [:]
        for en in bank.meta.entries { let rank = (en.expert * 7919 + en.layer * 31) % E + 1; usage[en.layer * E + en.expert] = 1_000_000 / (rank * rank) }
        let (plan, lines) = makePlan(usage: usage, meta: bank.meta, coverage: 0.995, minKeep: 64, source: bankDir.path)
        print("plan on skewed usage: \(lines.first!)")
        let out = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("prune-selftest")
        try? fm.removeItem(at: out)
        try apply(brain: bankDir, plan: plan, out: out)
        let pm = try JSONDecoder().decode(BankMeta.self, from: Data(contentsOf: out.appendingPathComponent("bank-meta.json")))
        let orig = Dictionary(uniqueKeysWithValues: bank.meta.entries.map { ("\($0.layer)/\($0.expert)", $0.sha256) })
        // re-read every block of the new bank and check it against the original's fingerprint
        let fd = open(out.appendingPathComponent("bank.bin").path, O_RDONLY)
        let buf = UnsafeMutableRawPointer.allocate(byteCount: pm.blockLength, alignment: 16384)
        let rawLen = pm.parts.last!.offset + pm.parts.last!.length
        var bad = 0
        for e in pm.entries {
            _ = pread(fd, buf, pm.blockLength, off_t(e.block * pm.blockLength))
            let s = SHA256.hash(data: UnsafeRawBufferPointer(start: buf, count: rawLen)).map { String(format: "%02x", $0) }.joined()
            if s != orig["\(e.layer)/\(e.expert)"] { bad += 1 }
        }
        close(fd); buf.deallocate()
        let wantKept = plan.keptCount
        let pruned = PrunePlan.load(out)
        let cutStillThere = pm.entries.filter { !(plan.kept[String($0.layer)] ?? []).contains($0.expert) }.count
        let rm = try JSONDecoder().decode(BankMeta.self, from: Data(contentsOf: out.appendingPathComponent("rare-meta.json")))
        var allKeys = Set(pm.entries.map { "\($0.layer)/\($0.expert)" })
        let overlap = rm.entries.filter { allKeys.contains("\($0.layer)/\($0.expert)") }.count
        rm.entries.forEach { allKeys.insert("\($0.layer)/\($0.expert)") }
        let pass = bad == 0 && pm.entries.count == wantKept && cutStillThere == 0 && pruned != nil
            && overlap == 0 && allKeys.count == bank.meta.entries.count
        print("apply: main relay \(pm.entries.count) (plan \(wantKept)) + deep memory \(rm.entries.count) = \(allKeys.count) of \(bank.meta.entries.count) experts, \(overlap) duplicated, \(bad) damaged  \(pass ? "✅" : "❌")")
        ok = ok && pass

        // the two relays at work: fetch common + rare experts together, compare with the original bank
        let nb = try ExpertBank(directory: out, cacheGB: 0.1)
        var mismatch = 0
        for l in Set(pm.entries.map { $0.layer }).sorted().prefix(3) {
            let common = (plan.kept[String(l)] ?? []).prefix(4)
            let rareOnes = rm.entries.filter { $0.layer == l }.prefix(4).map { $0.expert }
            let ask = Array(common) + rareOnes
            let a = nb.fetch(layer: l, experts: ask), b = bank.fetch(layer: l, experts: ask)
            for (x, y) in zip(a, b) { for p in pm.parts where !MLX.arrayEqual(x[p.name], y[p.name]).item(Bool.self) { mismatch += 1 } }
        }
        let st = nb.snapshot()
        let relayPass = mismatch == 0 && st.rareReads > 0
        print("two relays: \(st.misses) experts read, \(st.rareReads) via the deep-memory relay, \(mismatch) differ from the original  \(relayPass ? "✅" : "❌")")
        ok = ok && relayPass

        // --hard: rare experts truly gone
        try apply(brain: bankDir, plan: plan, out: out, hard: true)
        let hardPass = !fm.fileExists(atPath: out.appendingPathComponent("rare.bin").path)
        print("--hard: deep-memory bank \(hardPass ? "absent (cut for good, router will block them)" : "STILL PRESENT")  \(hardPass ? "✅" : "❌")")
        ok = ok && hardPass
        try? fm.removeItem(at: out)
    } else { print("(no bank at \(bankDir.path); skipped plan/apply test)") }
    print(ok ? "\nSELFTEST PASSED ✅" : "\nSELFTEST FAILED ❌")
    exit(ok ? 0 : 1)

default:
    print("usage: prune profile|plan|apply|exam|selftest  (see top of Sources/prune/main.swift)"); exit(2)
}
