import Foundation
import Darwin
import MLX
import MLXNN
import MLXLMCommon
import MLXLLM
import MLXHuggingFace
import Tokenizers
import BrainCore

// Expert streaming: the SSD is the subconscious, RAM is the consciousness.
//
// The 122B brain is ~65 GB of experts, which doesn't fit in 32 GB of RAM. Everything except the experts lives
// in RAM (hot.safetensors, ~3 GB). Each layer's router picks 8 of 256 experts per token. Only those experts get
// pulled from bank.bin on the SSD, over parallel one-way read lanes, into a RAM cache (the conscious mind). Experts
// that keep getting used stay in RAM (habits). Ones that stop being used fall out of RAM, back to the SSD only.
// Every use is counted (memory/expert-usage.json). That count is the evidence for later pruning and for lay --order.

public struct BankMeta: Codable, Sendable {
    public struct Part: Codable, Sendable {
        public var name: String; public var dtype: String; public var shape: [Int]; public var offset: Int; public var length: Int
        public init(name: String, dtype: String, shape: [Int], offset: Int, length: Int) { self.name = name; self.dtype = dtype; self.shape = shape; self.offset = offset; self.length = length }
    }
    public struct Entry: Codable, Sendable {
        public var block: Int; public var layer: Int; public var expert: Int; public var sha256: String
        public init(block: Int, layer: Int, expert: Int, sha256: String) { self.block = block; self.layer = layer; self.expert = expert; self.sha256 = sha256 }
    }
    public var source: String
    public var expertsPerLayer: Int
    public var blockLength: Int
    public var parts: [Part]
    public var tensorPrefix: String
    public var entries: [Entry]
    /// Precision of this bank's experts. nil = the model's own (4-bit). A slimmed deep-memory bank is 2 or 3 bits.
    public var bits: Int? = nil
}

/// One expert in RAM: gate/up/down × weight/scales/biases (9 arrays), ready for the GPU.
public final class ExpertWeights: @unchecked Sendable {
    let arrays: [String: MLXArray]
    public let bits: Int?   // nil = the model's own precision
    public init(_ a: [String: MLXArray], bits: Int? = nil) { arrays = a; self.bits = bits }

    /// Exact up-conversion of a slimmed (2/3-bit) expert to 4-bit, so it runs on the same single path as the common
    /// experts (no second pass for mixed layers). Exact because every 2-bit level sits on the 4-bit grid (one 2-bit
    /// step = 4 four-bit steps; one 3-bit step = 2): q4 = q·m, scale4 = scale/m, bias unchanged. The SSD still reads
    /// the small version; only the copy in RAM is 4-bit.
    public func as4bit() -> ExpertWeights {
        guard let b = bits, b == 2 || b == 3 else { return self }
        let m: Float = b == 2 ? 4 : 2   // powers of two, so scale/m is exact in bf16 (÷5 would round)
        var out = arrays
        for name in ["gate_proj", "up_proj", "down_proj"] {
            guard let w = arrays["\(name).weight"], let sc = arrays["\(name).scales"], let bi = arrays["\(name).biases"] else { continue }
            let groupSize = (w.dim(-1) * 32 / b) / sc.dim(-1)   // from the shapes: packed width → columns → per group
            let s32 = sc.asType(.float32), b32 = bi.asType(.float32)
            let deq = MLX.dequantized(w, scales: s32, biases: b32, groupSize: groupSize, bits: b, mode: .affine)
            let rows = deq.dim(0), cols = deq.dim(-1)
            let g = deq.reshaped([rows, cols / groupSize, groupSize])
            let sE = MLX.expandedDimensions(s32, axis: -1), bE = MLX.expandedDimensions(b32, axis: -1)
            var q = MLX.round((g - bE) / MLX.where(sE .== 0, MLXArray(Float(1)), sE))
            q = MLX.where(sE .== 0, MLXArray(Float(0)), MLX.clip(q, min: 0, max: Float((1 << b) - 1)))
            let q4 = (q * m).asType(.uint32).reshaped([rows, cols / 8, 8])
            let shifts = MLXArray((0..<8).map { UInt32($0 * 4) })
            out["\(name).weight"] = MLX.leftShift(q4, shifts).sum(axis: -1).asType(.uint32)
            out["\(name).scales"] = (s32 / m).asType(sc.dtype)
            out["\(name).biases"] = bi
        }
        return ExpertWeights(out, bits: nil)   // nil = the model's own precision (4-bit)
    }
    public subscript(_ k: String) -> MLXArray { arrays[k]! }
}

public struct StreamStats: Sendable, Codable {
    public var hits = 0, misses = 0, bytesRead = 0, readSeconds = 0.0, resident = 0, capacity = 0, rareReads = 0
    public var prefetchReads = 0, prefetchUsed = 0, prefetchWasted = 0, guesses = 0, guessHits = 0, guessNeeded = 0
    public var waitSeconds = 0.0, guessRests = 0
    public var admissionSkips = 0, prefetchYieldTimeouts = 0     // Tesla valves 2 and 1 at work
    public var gpuWaitSeconds = 0.0, fetchSeconds = 0.0, guessWaitSeconds = 0.0, layerCalls = 0   // TETI_PROFILE
    public var guessRecall: Double { guessNeeded == 0 ? 0 : Double(guessHits) / Double(guessNeeded) }
    public var hitRate: Double { hits + misses == 0 ? 0 : Double(hits) / Double(hits + misses) }
    public var readGBps: Double { readSeconds == 0 ? 0 : Double(bytesRead) / readSeconds / 1e9 }
    public var line: String {
        String(format: "experts in RAM %d/%d · hit rate %.1f%% · %d SSD reads · %.2f GB/s", resident, capacity, hitRate * 100, misses, readGBps)
            + (rareReads > 0 ? " · \(rareReads) from the deep-memory relay" : "")
            + (admissionSkips > 0 ? " · valve 2 kept the regulars \(admissionSkips)×" : "")
            + (prefetchYieldTimeouts > 0 ? " · valve 1 yield timeouts \(prefetchYieldTimeouts)" : "")
            + (layerCalls > 0 ? String(format: " · PROFILE per layer: GPU wait %.2f ms · expert fetch %.2f ms · guess wait %.2f ms (%d layer calls)",
                                       gpuWaitSeconds / Double(layerCalls) * 1000, fetchSeconds / Double(layerCalls) * 1000,
                                       guessWaitSeconds / Double(layerCalls) * 1000, layerCalls) : "")
            + (guessNeeded > 0 ? String(format: " · what-if guesses caught %.0f%% of picks (%d prefetched, %d used, %d wasted)", guessRecall * 100, prefetchReads, prefetchUsed, prefetchWasted) : "")
    }
}

/// The bridge between subconscious (bank.bin on SSD) and consciousness (RAM cache).
public final class ExpertBank: @unchecked Sendable {
    public let meta: BankMeta
    public let dir: URL
    let lanes: Int
    let fds: [Int32]                         // one file handle per lane: lanes never wait on each other
    let blockOf: [Int: Int]                  // layer*E + expert → block (main bank: common experts)
    // Second relay: deep memory. Pruning moves rarely-used experts to rare.bin, served by its OWN lanes and file
    // handles, so a rare fetch never blocks the common experts' lanes (one-way, nobody waits their turn).
    public let rareMeta: BankMeta?
    let rareFds: [Int32]
    let rareBlockOf: [Int: Int]
    let lock = NSCondition()
    var inflight: Set<Int> = []             // being read right now (by a fetch or a guess)
    var prefetched: [Int: UInt64] = [:]     // brought in by a guess, not used yet → clock when loaded
    let prefetchQueue = DispatchQueue(label: "teti.prefetch", qos: .userInitiated, attributes: .concurrent)
    var cache: [Int: ExpertWeights] = [:]
    var lastUse: [Int: UInt64] = [:]
    var clock: UInt64 = 0
    public private(set) var capacity: Int
    public let expertBytes: Int
    var pressureSource: DispatchSourceMemoryPressure?
    var ceiling = Int.max, ceilingUntil = Date.distantPast
    /// Evicted experts wait here and are released OUTSIDE the lock (freeing GPU memory calls into MLX).
    var graveyard: [ExpertWeights] = []
    func bury(_ k: Int) { if let w = cache.removeValue(forKey: k) { graveyard.append(w); cacheLoad -= unit(k) }; lastUse[k] = nil }
    /// RAM is budgeted in bytes, counted in "4-bit expert" units: a slimmed deep-memory expert costs less than one.
    var cacheLoad = 0.0
    var rareUnit = 1.0
    /// TETI_RARE_AS4=1: slimmed experts are converted to 4-bit as they come off the SSD (one compute path, full size in
    /// RAM). Off by default until the speed race shows it wins.
    public static let rareAs4 = ProcessInfo.processInfo.environment["TETI_RARE_AS4"] != nil
    /// Tesla valves (user's idea, 11/10): information flows easily the way it's needed and meets resistance the other way.
    /// Each is off by default until its own race shows it wins. TETI_VALVES=1,2 (or "all") turns them on.
    ///   1 = "needed now" beats "might need soon": guesses (prefetch) yield the SSD while a real read is running.
    ///   2 = easy to stay, hard to push in: a newcomer seen fewer times than the expert it would evict is used once
    ///       but not kept, so one-off experts can't push out the regulars (an admission filter).
    static let valves: Set<String> = {
        let v = ProcessInfo.processInfo.environment["TETI_VALVES"] ?? ""
        return v == "all" ? ["1", "2", "x"] : Set(v.split(separator: ",").map { String($0).trimmingCharacters(in: .whitespaces) })
    }()
    public static var valve1: Bool { valves.contains("1") }
    /// Lessons from Flash-MoE (danveloper/flash-moe, ideas only, our own code), each its own switch, off by default:
    ///   TETI_PROFILE=1   time where every word goes: GPU wait, SSD reads, guess waits (measure before fixing)
    ///   TETI_NO_GUESS=1  no guessing ahead (they found prediction slows a Mac: SSD and GPU share one memory path)
    ///   TETI_OS_CACHE=1  let macOS cache expert reads too ("trust the OS"); pair with a smaller --cache-gb
    ///   TETI_ALIGN2M=1   2 MB-aligned read buffers (they measured +5%)
    ///   TETI_ASYNC=1     start the experts' GPU work right away instead of at the next layer's wait (deferred submit)
    static let env = ProcessInfo.processInfo.environment
    public static let profile = env["TETI_PROFILE"] != nil
    public static let noGuess = env["TETI_NO_GUESS"] != nil
    public static let osCache = env["TETI_OS_CACHE"] != nil
    public static let align2M = env["TETI_ALIGN2M"] != nil
    public static let asyncExperts = env["TETI_ASYNC"] != nil
    ///   TETI_ZEROCOPY=1  read each expert straight into memory MLX uses directly (no second copy)
    ///   TETI_MIXFIX=1    mixed 4-bit/2-bit layers compute each group's own picks only (not all 8 twice)
    public static let zeroCopy = env["TETI_ZEROCOPY"] != nil
    public static let mixFix = env["TETI_MIXFIX"] != nil
    public static var valve2: Bool { valves.contains("2") }
    var demandReading = 0                    // valve 1: real reads in flight right now
    func unit(_ k: Int) -> Double { blockOf[k] == nil && rareBlockOf[k] != nil ? rareUnit : 1 }
    /// Put an expert in the cache (call with lock held).
    func put(_ k: Int, _ w: ExpertWeights) { if cache[k] == nil { cacheLoad += unit(k) }; cache[k] = w }
    func releaseDead() { let dead = lock.withLock { () -> [ExpertWeights] in let d = graveyard; graveyard = []; return d }; _ = dead.count }
    var growTimer: DispatchSourceTimer?
    var stats = StreamStats()
    var usage: [Int: Int] = [:]              // evidence: how often each expert fires
    var usageSinceSave = 0
    public let usageFile: URL

    public init(directory: URL, cacheGB: Double, lanes: Int = 8) throws {
        dir = directory
        meta = try JSONDecoder().decode(BankMeta.self, from: Data(contentsOf: directory.appendingPathComponent("bank-meta.json")))
        self.lanes = max(1, lanes)
        let path = directory.appendingPathComponent("bank.bin").path
        fds = try (0..<self.lanes).map { _ in
            let fd = open(path, O_RDONLY)
            guard fd >= 0 else { throw NSError(domain: "ExpertBank", code: 1, userInfo: [NSLocalizedDescriptionKey: "cannot open \(path)"]) }
            if !ExpertBank.osCache { _ = fcntl(fd, F_NOCACHE, 1) }  // our cache decides what stays in RAM, unless "trust the OS" is on
            return fd
        }
        var m: [Int: Int] = [:]
        for e in meta.entries { m[e.layer * meta.expertsPerLayer + e.expert] = e.block }
        blockOf = m
        if let d = try? Data(contentsOf: directory.appendingPathComponent("rare-meta.json")), let rm = try? JSONDecoder().decode(BankMeta.self, from: d) {
            rareMeta = rm
            let rp = directory.appendingPathComponent("rare.bin").path
            rareFds = (0..<4).compactMap { _ in let fd = open(rp, O_RDONLY); if fd >= 0 && !ExpertBank.osCache { _ = fcntl(fd, F_NOCACHE, 1) }; return fd >= 0 ? fd : nil }
            var r: [Int: Int] = [:]
            for e in rm.entries { r[e.layer * meta.expertsPerLayer + e.expert] = e.block }
            rareBlockOf = r
        } else { rareMeta = nil; rareFds = []; rareBlockOf = [:] }
        let raw = meta.parts.last!.offset + meta.parts.last!.length
        expertBytes = raw
        if let rm = rareMeta, rm.bits != nil, !Self.rareAs4 { rareUnit = Double(rm.parts.last!.offset + rm.parts.last!.length) / Double(raw) }
        capacity = max(64, Int(cacheGB * 1e9) / raw)
        stats.capacity = capacity
        usageFile = BrainPaths.memory.appendingPathComponent("expert-usage-\(directory.lastPathComponent).json")
        // a new pruned/slim brain starts from a COPY of its parent's habits (copy, not shared: what it sees later,
        // like the exam's held-out code, must not leak back into the parent's profiling evidence)
        if !FileManager.default.fileExists(atPath: usageFile.path) {
            let base = directory.lastPathComponent.replacingOccurrences(of: #"-(c\d+-b\d|pruned|active)$"#, with: "", options: .regularExpression)
            let parent = BrainPaths.memory.appendingPathComponent("expert-usage-\(base).json")
            if base != directory.lastPathComponent { try? FileManager.default.copyItem(at: parent, to: usageFile) }
        }
        if let d = try? Data(contentsOf: usageFile), let u = try? JSONDecoder().decode([String: Int].self, from: d) {
            for (k, v) in u { if let i = Int(k) { usage[i] = v } }
        }
    }
    deinit { pressureSource?.cancel(); growTimer?.cancel(); fds.forEach { close($0) }; rareFds.forEach { close($0) }; saveUsage() }

    public func has(layer: Int) -> Bool { meta.entries.contains { $0.layer == layer } }
    public func has(layer: Int, expert: Int) -> Bool { let k = layer * meta.expertsPerLayer + expert; return blockOf[k] != nil || rareBlockOf[k] != nil }
    public var rareCount: Int { rareBlockOf.count }

    /// Evidence for pruning: count every token's pick (a batch of 32 tokens choosing expert 5 ten times = 10).
    /// Off for exams: held-out code must never become profiling evidence (TETI_NO_USAGE=1).
    static let usageOff = ProcessInfo.processInfo.environment["TETI_NO_USAGE"] == "1"
    public func record(layer: Int, counts: [Int: Int]) {
        if Self.usageOff { return }
        lock.withLock {
            for (e, c) in counts { usage[layer * meta.expertsPerLayer + e, default: 0] += c }
            usageSinceSave += counts.values.reduce(0, +)
        }
    }
    public func usageSnapshot() -> [Int: Int] { lock.withLock { usage } }

    /// RAM in use, in 4-bit-expert units (slim experts count as less than one).
    public var loadUnits: Double { lock.withLock { cacheLoad } }
    public var slimUnit: Double { rareUnit }
    public func snapshot() -> StreamStats { lock.withLock { var s = stats; s.resident = cache.count; return s } }

    // MARK: use as much RAM as is truly free (owner 11/05: "most of them loaded in usable RAM")

    public static let physicalBytes = Int(ProcessInfo.processInfo.physicalMemory)

    /// RAM macOS could hand out right now: free + inactive + purgeable + speculative pages.
    public static func availableBytes() -> Int {
        var info = vm_statistics64(); var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64>.size / MemoryLayout<integer_t>.size)
        let r = withUnsafeMutablePointer(to: &info) { $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count) } }
        guard r == KERN_SUCCESS else { return 0 }
        let page = Int(vm_kernel_page_size)
        return (Int(info.free_count) + Int(info.inactive_count) + Int(info.purgeable_count) + Int(info.speculative_count)) * page
    }

    /// Size the conscious mind to the RAM that's really free: everything available minus a safety reserve
    /// (macOS, a small always-on model, the KV cache), never more than physical RAM minus 13 GB, never more than the whole bank.
    @discardableResult
    /// growOnly: the 60 s timer may only GROW the cache. Shrinking is the memory-warning handler's job; a brief dip
    /// in free RAM (a compile, a browser tab) must not collapse it (seen 11/08: cache stuck at 64).
    public func autoSize(reserveGB: Double = 5, growOnly: Bool = false) -> Int {
        let mine = Int(lock.withLock { cacheLoad } * Double(expertBytes))
        let usable = min(Self.availableBytes() + mine - Int(reserveGB * 1e9), Self.physicalBytes - 13_000_000_000)
        var n = min(meta.entries.count, max(64, usable / expertBytes))
        // learned ceiling: after a memory warning, don't grow back past 85% of the size that caused it (for 30 min)
        if Date() < ceilingUntil { n = min(n, ceiling) }
        if growOnly && n <= capacity { return capacity }
        setCapacity(n)
        return n
    }

    /// Who leaves RAM first (call with lock held): the experts used LEAST OFTEN overall; recency only breaks ties.
    /// The most common experts stay conscious; rare ones go back to the subconscious.
    /// Enough victims to free `load` units (least used first).
    func victims(load: Double, protect: Set<Int>) -> [Int] {
        var out: [Int] = [], freed = 0.0
        for k in victims(cache.count, protect: protect) { if freed >= load - 1e-9 { break }; out.append(k); freed += unit(k) }
        return out
    }
    func victims(_ n: Int, protect: Set<Int>) -> [Int] {
        cache.keys.filter { !protect.contains($0) }
            .sorted { (usage[$0] ?? 0, lastUse[$0] ?? 0) < (usage[$1] ?? 0, lastUse[$1] ?? 0) }
            .prefix(n).map { $0 }
    }

    public func setCapacity(_ n: Int) {
        lock.withLock {
            // NOTE: never call into MLX while holding this lock: the GPU thread may need MLX at the same moment, and
            // each would wait on the other forever (deadlock seen 11/05). The engine's 2 GB MLX buffer cap already
            // returns freed expert memory to macOS on its own.
            capacity = n; stats.capacity = n
            if cacheLoad > Double(n) { for k in victims(load: cacheLoad - Double(n), protect: []) { bury(k) } }
        }
        releaseDead()
    }

    /// Fill every free cache slot: most-used experts first (habits), then the rest spread evenly over all layers.
    @discardableResult
    public func fill() -> Int {
        let E = meta.expertsPerLayer
        let (free, resident) = lock.withLock { (Double(capacity) - cacheLoad, Set(cache.keys)) }
        guard free >= 1 else { return 0 }
        var order = usage.sorted { $0.value > $1.value }.map { $0.key }.filter { !resident.contains($0) && (blockOf[$0] != nil || rareBlockOf[$0] != nil) }
        let seen = Set(order)
        let layers = Set(meta.entries.map { $0.layer }).sorted()
        for e in 0..<E { for l in layers { let k = l * E + e; if blockOf[k] != nil && !resident.contains(k) && !seen.contains(k) { order.append(k) } } }
        var pick: [Int] = [], room = free
        for k in order { let u = unit(k); if room < u { break }; pick.append(k); room -= u }
        var byLayer: [Int: [Int]] = [:]
        for k in pick { byLayer[k / E, default: []].append(k % E) }
        for (l, ex) in byLayer { for chunk in stride(from: 0, to: ex.count, by: 64) { _ = fetch(layer: l, experts: Array(ex[chunk..<min(chunk + 64, ex.count)]), countUse: false) } }
        return pick.count
    }

    /// Breathe with the Mac: shrink when macOS signals memory pressure (e.g. another app loads a model),
    /// grow back and refill when RAM frees up again. Checked every 60 s.
    public func startAdaptive(log: @escaping @Sendable (String) -> Void = { print($0) }) {
        let src = DispatchSource.makeMemoryPressureSource(eventMask: [.warning, .critical], queue: .global(qos: .utility))
        src.setEventHandler { [weak self] in
            guard let self else { return }
            let critical = src.data.contains(.critical)
            // macOS sends brief warnings during short spikes (a big batch, a compile). If RAM is actually fine right
            // now, it's a blip: don't shrink (seen 11/08: repeated blips walked the cache down to its floor).
            let free = Self.availableBytes()
            if !critical && free > max(8_000_000_000, Self.physicalBytes / 4) {
                log(String(format: "🧠 memory warning ignored: %.1f GB is actually free (a short spike)", Double(free) / 1e9))
                return
            }
            // a warning never pushes the cache below a working floor (512 experts ≈ 2.7 GB); only critical can go lower
            let floor = critical ? 64 : min(512, self.capacity)
            self.ceiling = max(floor, Int(Double(self.capacity) * 0.85)); self.ceilingUntil = Date().addingTimeInterval(critical ? 1800 : 600)
            let n = max(floor, Int(Double(self.capacity) * (critical ? 0.5 : 0.75)))
            self.setCapacity(n)
            log("🧠 memory pressure (\(critical ? "critical" : "warning")): expert cache shrunk to \(n), ceiling \(self.ceiling) for 30 min")
        }
        src.resume(); pressureSource = src
        let t = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
        t.schedule(deadline: .now() + 60, repeating: 60)
        t.setEventHandler { [weak self] in
            guard let self else { return }
            let before = self.capacity
            let n = self.autoSize(growOnly: true)
            if n > before { let added = self.fill(); if added > 0 { log("🧠 RAM freed up: expert cache grew to \(n), loaded \(added) more") } }
        }
        t.resume(); growTimer = t
    }

    /// Get these experts for one layer, reading any missing ones from the SSD over parallel lanes.
    public func fetch(layer: Int, experts: [Int], countUse: Bool = true) -> [ExpertWeights] {
        let E = meta.expertsPerLayer
        let keys = experts.map { layer * E + $0 }
        var have: [Int: ExpertWeights] = [:]
        var missing: [Int] = [], waiting: [Int] = []
        let enter = Date()
        defer { lock.withLock { lastFetchEnd = Date() } }
        lock.withLock {
            // the time since the last fetch ended is GPU work: the window a guess can use for free
            if let e = lastFetchEnd { let w = enter.timeIntervalSince(e); if w < 0.5 { windowEWMA = 0.9 * windowEWMA + 0.1 * w } }
            clock += 1
            for k in keys {
                if countUse { usage[k, default: 0] += 1 }
                if let w = cache[k] {
                    have[k] = w; lastUse[k] = clock; stats.hits += 1
                    if prefetched.removeValue(forKey: k) != nil { stats.prefetchUsed += 1 }   // the guess paid off
                } else if inflight.contains(k) {
                    waiting.append(k)                         // a guess is already bringing it: wait, don't read twice
                } else if !missing.contains(k) { missing.append(k); inflight.insert(k); stats.misses += 1 }
            }
            usageSinceSave += countUse ? keys.count : 0
        }
        if !missing.isEmpty {
            let t0 = Date()
            if Self.valve1 { lock.withLock { demandReading += 1 } }
            let loaded = readExperts(missing)
            let dt = Date().timeIntervalSince(t0)
            lock.withLock {
                if Self.valve1 { demandReading -= 1; if demandReading == 0 { lock.broadcast() } }
                stats.readSeconds += dt
                stats.bytesRead += missing.count * meta.blockLength
                if dt > 0 { bwEWMA = 0.9 * bwEWMA + 0.1 * Double(missing.count * meta.blockLength) / dt }
                for (k, w) in zip(missing, loaded) {
                    have[k] = w; inflight.remove(k)
                    if Self.valve2 && cacheLoad + unit(k) > Double(capacity) + 1e-9,
                       let victim = victims(1, protect: Set(keys).union(prefetched.keys)).first,
                       (usage[k] ?? 0) < 2 && (usage[k] ?? 0) < (usage[victim] ?? 0) {
                        stats.admissionSkips += 1           // used for this word, not kept: the regular stays
                        continue
                    }
                    put(k, w); lastUse[k] = clock
                }
                evictIfFull(protect: Set(keys))
                lock.broadcast()
            }
        }
        if !waiting.isEmpty {
            let t0 = Date()
            var reread: [Int] = []
            lock.withLock {
                while waiting.contains(where: { inflight.contains($0) }) { lock.wait() }
                for k in waiting {
                    if let w = cache[k] { have[k] = w; lastUse[k] = clock; stats.hits += 1; stats.prefetchUsed += 1; prefetched[k] = nil }
                    else { reread.append(k) }                // evicted in the meantime (rare): read it ourselves
                }
                stats.waitSeconds += Date().timeIntervalSince(t0)
            }
            if !reread.isEmpty { for (k, w) in zip(reread, readExperts(reread)) { have[k] = w; lock.withLock { put(k, w); lastUse[k] = clock } } }
        }
        releaseDead()
        if usageSinceSave > 200_000 {
            lock.withLock { usageSinceSave = 0 }
            DispatchQueue.global(qos: .background).async { [self] in saveUsage() }   // valve 3: bookkeeping never blocks a word
        }
        return keys.map { have[$0]! }
    }

    /// Call with lock held. Experts brought in by a guess are protected until used or until a full pass of the
    /// layers has gone by without them (then the guess was wrong, and it counts as wasted).
    func evictIfFull(protect: Set<Int>) {
        guard cacheLoad > Double(capacity) + 1e-9 else { return }
        let horizon = UInt64(max(4, Set(meta.entries.map { $0.layer }).count * 2))
        for (k, t) in prefetched where clock > t + horizon { prefetched[k] = nil; stats.prefetchWasted += 1 }
        for k in victims(load: cacheLoad - Double(capacity), protect: protect.union(prefetched.keys)) { bury(k) }
    }

    // MARK: Ne "what if": guess the next layer's experts and pull them from the SSD before they're asked for

    /// How many experts to guess per layer. Learns from results: misses widen it, waste narrows it.
    public private(set) var guessWidth = 12
    var lastGuess: [Int: Set<Int>] = [:]
    var recallEWMA = 0.8, precisionEWMA = 0.6
    var windowEWMA = 0.0015, bwEWMA = 5e9          // GPU time per layer (s) · SSD speed (bytes/s), both measured live
    var lastFetchEnd: Date?
    /// How many guessed experts fit in the GPU window without slowing the real reads (at least 1).
    public var guessBudget: Int { lock.withLock { max(1, Int(windowEWMA * bwEWMA / Double(expertBytes))) } }
    let minWidth = 4
    public private(set) var guessingOn = true
    /// Master switch, set from evidence: memory/guess-ab.json (the real brain's off-vs-on race) decides the default.
    public var guessingAllowed = true
    public static var guessFile: URL { BrainPaths.memory.appendingPathComponent("guess-ab.json") }
    var scored = 0, restUntil: UInt64 = 0, windowReads = 0, windowUsed = 0

    /// Start loading guessed experts of `layer` in the background (no waiting). `experts` is ordered most-likely first;
    /// only as many as fit in the GPU window get read (the rest are just scored), so guesses never flood the SSD.
    public func prefetch(layer: Int, experts: [Int]) {
        let E = meta.expertsPerLayer
        let budget = guessBudget
        let keys: [Int] = lock.withLock {
            lastGuess[layer] = Set(experts)
            stats.guesses += experts.count
            let ks = Array(experts.map { layer * E + $0 }.filter { cache[$0] == nil && !inflight.contains($0) && has(layer: layer, expert: $0 % E) }.prefix(budget))
            for k in ks { inflight.insert(k) }
            return ks
        }
        guard !keys.isEmpty else { return }
        prefetchQueue.async { [self] in
            if Self.valve1 {
                // yield to real reads: wait while one is running (up to 50 ms), then go
                lock.withLock {
                    let until = Date().addingTimeInterval(0.05)
                    while demandReading > 0 && Date() < until { _ = lock.wait(until: until) }
                    if demandReading > 0 { stats.prefetchYieldTimeouts += 1 }
                }
            }
            let t0 = Date()
            let loaded = readExperts(keys, guess: true)
            lock.withLock {
                stats.prefetchReads += keys.count
                stats.readSeconds += Date().timeIntervalSince(t0); stats.bytesRead += keys.count * meta.blockLength
                for (k, w) in zip(keys, loaded) { put(k, w); lastUse[k] = clock; prefetched[k] = clock; inflight.remove(k) }
                evictIfFull(protect: Set(keys))
                lock.broadcast()
            }
            releaseDead()
        }
    }

    /// Score the guess made for this layer against what the router actually chose; adapt the guess width
    /// (reinforcement: a path that keeps winning gets trusted, one that misses gets widened).
    public func scoreGuess(layer: Int, actual: Set<Int>) {
        lock.withLock {
            guard let g = lastGuess.removeValue(forKey: layer), !actual.isEmpty else { return }
            let right = actual.intersection(g).count
            let recall = Double(right) / Double(actual.count), precision = Double(right) / Double(max(1, g.count))
            stats.guessHits += right; stats.guessNeeded += actual.count
            recallEWMA = 0.95 * recallEWMA + 0.05 * recall
            precisionEWMA = 0.95 * precisionEWMA + 0.05 * precision
            // wasted guesses steal SSD bandwidth from real reads: narrow fast when they miss, widen only while they land
            if precisionEWMA < 0.4 { guessWidth = max(minWidth, guessWidth - 2) }
            else if recallEWMA < 0.85 && precisionEWMA > 0.6 && guessWidth < 16 { guessWidth += 1 }
            else if recallEWMA > 0.95 && guessWidth > minWidth { guessWidth -= 1 }
            // Payoff check: of the experts guesses actually READ, how many got used? Under half = guessing is costing
            // more than it saves → rest it, then try again later (Ne retries after a break).
            scored += 1
            if !guessingOn && clock > restUntil { guessingOn = true; windowReads = stats.prefetchReads; windowUsed = stats.prefetchUsed }
            if guessingOn && scored % 200 == 0 {
                let reads = stats.prefetchReads - windowReads, used = stats.prefetchUsed - windowUsed
                if reads >= 40 && Double(used) / Double(reads) < 0.5 { guessingOn = false; restUntil = clock + 3000; stats.guessRests += 1 }
                windowReads = stats.prefetchReads; windowUsed = stats.prefetchUsed
            }
        }
    }

    /// Parallel one-way lanes: each lane has its own file handle and buffer and takes the next expert off the shared
    /// queue, so a fast lane automatically takes more (path of least resistance).
    /// Express lanes (valve "x", user 11/10): guesses (prefetch) may use only the last 2 lanes; real reads use all 8.
    /// Like an HOV lane: the urgent traffic always has open road.
    public static var expressLanes: Bool { valves.contains("x") || valves.contains("all") }
    func readExperts(_ keys: [Int], guess: Bool = false) -> [ExpertWeights] {
        let laneSet = (guess && Self.expressLanes && fds.count > 2) ? Array(fds.suffix(2)) : fds
        let rareLanes = (guess && Self.expressLanes && rareFds.count > 1) ? Array(rareFds.suffix(1)) : rareFds
        let rare = keys.filter { blockOf[$0] == nil && rareBlockOf[$0] != nil }
        if rare.isEmpty { return relay(keys, fds: laneSet, map: blockOf, meta: meta) }
        let common = keys.filter { blockOf[$0] != nil }
        var got: [Int: ExpertWeights] = [:]
        let gl = NSLock()
        // both relays at once, each on its own lanes
        DispatchQueue.concurrentPerform(iterations: 2) { side in
            let ks = side == 0 ? common : rare
            guard !ks.isEmpty else { return }
            let ws = side == 0 ? relay(ks, fds: laneSet, map: blockOf, meta: meta) : relay(ks, fds: rareLanes, map: rareBlockOf, meta: rareMeta!)
            gl.withLock { for (k, w) in zip(ks, ws) { got[k] = w } }
        }
        lock.withLock { stats.rareReads += rare.count }
        return keys.map { got[$0]! }
    }

    func relay(_ keys: [Int], fds: [Int32], map blockOf: [Int: Int], meta: BankMeta) -> [ExpertWeights] {
        let lanes = fds.count
        var out = [ExpertWeights?](repeating: nil, count: keys.count)
        let next = ManagedAtomicCounter()
        let nLanes = min(lanes, keys.count)
        let raw = meta.parts.last!.offset + meta.parts.last!.length
        let outLock = NSLock()
        if ExpertBank.zeroCopy {
            // one buffer per expert, read straight from the SSD, handed to MLX without copying; MLX frees it when done
            let page = 16384, size = (meta.blockLength + page - 1) / page * page
            DispatchQueue.concurrentPerform(iterations: nLanes) { lane in
                while true {
                    let i = next.increment()
                    if i >= keys.count { break }
                    guard let block = blockOf[keys[i]] else { fatalError("expert \(keys[i]) not in the bank (partial lay?)") }
                    let buf = UnsafeMutableRawPointer.allocate(byteCount: size, alignment: ExpertBank.align2M ? 2 << 20 : page)
                    var got = 0
                    while got < raw {
                        let n = pread(fds[lane], buf + got, meta.blockLength - got, off_t(block * meta.blockLength + got))
                        if n <= 0 { fatalError("SSD read failed for block \(block): \(String(cString: strerror(errno)))") }
                        got += n
                    }
                    let whole = MLXArray(rawPointer: buf, [size], dtype: .uint8, finalizer: { buf.deallocate() })
                    var arrays: [String: MLXArray] = [:]
                    for p in meta.parts {
                        let bytes = whole[p.offset ..< (p.offset + p.length)]
                        let dt: DType
                        switch p.dtype {
                        case "U32": dt = .uint32
                        case "BF16": dt = .bfloat16
                        case "F16": dt = .float16
                        case "F32": dt = .float32
                        default: fatalError("unsupported dtype \(p.dtype)")
                        }
                        arrays[p.name] = bytes.view(dtype: dt).reshaped(p.shape)
                    }
                    var ew = ExpertWeights(arrays, bits: meta.bits)
                    if ExpertBank.rareAs4 { ew = ew.as4bit() }
                    outLock.withLock { out[i] = ew }
                }
            }
            return out.map { $0! }
        }
        DispatchQueue.concurrentPerform(iterations: nLanes) { lane in
            let buf = UnsafeMutableRawPointer.allocate(byteCount: meta.blockLength, alignment: ExpertBank.align2M ? 2 << 20 : 16384)
            defer { buf.deallocate() }
            while true {
                let i = next.increment()
                if i >= keys.count { break }
                guard let block = blockOf[keys[i]] else { fatalError("expert \(keys[i]) not in the bank (partial lay?)") }
                var got = 0
                while got < raw {
                    let n = pread(fds[lane], buf + got, meta.blockLength - got, off_t(block * meta.blockLength + got))
                    if n <= 0 { fatalError("SSD read failed for block \(block): \(String(cString: strerror(errno)))") }
                    got += n
                }
                var arrays: [String: MLXArray] = [:]
                for p in meta.parts {
                    let ptr = UnsafeRawBufferPointer(start: buf + p.offset, count: p.length)
                    switch p.dtype {
                    case "U32": arrays[p.name] = MLXArray(ptr, p.shape, type: UInt32.self)
                    case "BF16": arrays[p.name] = MLXArray(ptr, p.shape, type: UInt16.self).view(dtype: .bfloat16)
                    case "F16": arrays[p.name] = MLXArray(ptr, p.shape, type: Float16.self)
                    case "F32": arrays[p.name] = MLXArray(ptr, p.shape, type: Float.self)
                    default: fatalError("unsupported dtype \(p.dtype)")
                    }
                }
                var ew = ExpertWeights(arrays, bits: meta.bits)
                if ExpertBank.rareAs4 { ew = ew.as4bit() }
                outLock.withLock { out[i] = ew }
            }
        }
        return out.map { $0! }
    }

    public func saveUsage() {
        if Self.usageOff { return }
        let snap: [String: Int] = lock.withLock { usageSinceSave = 0; return Dictionary(uniqueKeysWithValues: usage.map { (String($0.key), $0.value) }) }
        try? JSONEncoder().encode(snap).write(to: usageFile, options: .atomic)
    }
}

final class ManagedAtomicCounter: @unchecked Sendable {
    private var v = -1; private let l = NSLock()
    func increment() -> Int { l.withLock { v += 1; return v } }
}

/// Drop-in replacement for a MoE layer's experts: same math as SwitchGLU, but the experts come from ExpertBank.
public final class StreamingSwitchGLU: SwitchGLU, @unchecked Sendable {
    let layer: Int
    let bank: ExpertBank
    let groupSize: Int, bits: Int
    /// The next layer's router, used only to guess ahead (set by the loader). Kept in a plain box so MLX's module
    /// scan doesn't count that router twice in the weight tree.
    final class GateBox { var gate: Linear? }
    let gateBox = GateBox()
    public var nextGate: Linear? { get { gateBox.gate } set { gateBox.gate = newValue } }

    public init(layer: Int, bank: ExpertBank, groupSize: Int, bits: Int) {
        self.layer = layer; self.bank = bank; self.groupSize = groupSize; self.bits = bits
        super.init(inputDims: 1, hiddenDims: 1, numExperts: 1)   // tiny placeholders: the real experts live in the bank
        freeze()
    }

    func proj(_ x: MLXArray, _ w: [ExpertWeights], _ name: String, _ idx: MLXArray, bits b: Int? = nil) -> MLXArray {
        let weight = MLX.stacked(w.map { $0["\(name).weight"] })
        let scales = MLX.stacked(w.map { $0["\(name).scales"] })
        let biases = MLX.stacked(w.map { $0["\(name).biases"] })
        return MLX.gatherQuantizedMM(x, weight, scales: scales, biases: biases, rhsIndices: idx,
                                     transpose: true, groupSize: groupSize, bits: b ?? bits, mode: .affine)
    }

    /// The three projections for one group of experts that share a precision.
    func experts(_ xe: MLXArray, _ w: [ExpertWeights], _ local: MLXArray, bits b: Int?) -> MLXArray {
        let up = proj(xe, w, "up_proj", local, bits: b)
        let gate = proj(xe, w, "gate_proj", local, bits: b)
        return proj(silu(gate) * up, w, "down_proj", local, bits: b)
    }

    public override func callAsFunction(_ x: MLXArray, _ indices: MLXArray) -> MLXArray {
        // the router's choice has to be known before we can fetch: this is where thought waits on memory
        let tWait = Date()
        let flat = indices.asType(.uint32).asArray(UInt32.self).map { Int($0) }
        let gpuWait = Date().timeIntervalSince(tWait)
        var slot: [Int: Int] = [:], unique: [Int] = []
        for e in flat where slot[e] == nil { slot[e] = unique.count; unique.append(e) }
        var counts: [Int: Int] = [:]
        for e in flat { counts[e, default: 0] += 1 }
        bank.record(layer: layer, counts: counts)
        bank.scoreGuess(layer: layer, actual: Set(unique))
        let tFetch = Date()
        let w = bank.fetch(layer: layer, experts: unique, countUse: false)
        let fetchTime = Date().timeIntervalSince(tFetch)
        var guessTime = 0.0
        defer { if ExpertBank.profile { bank.lock.withLock { bank.stats.gpuWaitSeconds += gpuWait; bank.stats.fetchSeconds += fetchTime
                                                                 bank.stats.guessWaitSeconds += guessTime; bank.stats.layerCalls += 1 } } }
        // Ne: while this layer computes, guess the next layer's picks by asking ITS router about this hidden state
        // (it changes little from one layer to the next) and start pulling those experts off the SSD now.
        if let g = nextGate, indices.dim(0) <= 4, bank.guessingAllowed, bank.guessingOn, !ExpertBank.noGuess {
            let tGuess = Date(); defer { guessTime = Date().timeIntervalSince(tGuess) }
            let k = bank.guessWidth
            let logits = g(x)
            // most likely first (summed over the tokens), so the read budget goes to the best guesses
            let order = argSort(-logits.sum(axis: 0), axis: -1)[..<k].asArray(Int32.self).map { Int($0) }
            bank.prefetch(layer: layer + 1, experts: order)
        }
        let xe = MLX.expandedDimensions(x, axes: [-2, -3])
        let precisions = Set(w.map { $0.bits ?? bits })
        if precisions.count == 1 {   // the usual case: every picked expert has the same precision
            let local = MLXArray(flat.map { UInt32(slot[$0]!) }, indices.shape)
            let out = MLX.squeezed(experts(xe, w, local, bits: precisions.first!), axis: -2)
            if ExpertBank.asyncExperts { MLX.asyncEval(out) }   // GPU starts now while the CPU builds the next layer
            return out
        }
        // mixed: common experts at 4-bit, slimmed deep-memory experts at 2/3-bit. Run each precision group on its own
        // and keep, for every pick, the answer from the group that expert belongs to.
        if ExpertBank.mixFix && indices.dim(0) == 1 {
            // one word: each precision group computes only its own picks, then the answers go back in the router's order
            var parts: [MLXArray] = [], order: [Int] = []
            for b in precisions.sorted() {
                var gslot: [Int: Int] = [:], gw: [ExpertWeights] = []
                for (e, i) in slot.sorted(by: { $0.value < $1.value }) where (w[i].bits ?? bits) == b { gslot[e] = gw.count; gw.append(w[i]) }
                let picks = flat.indices.filter { gslot[flat[$0]] != nil }
                guard !picks.isEmpty else { continue }
                let local = MLXArray(picks.map { UInt32(gslot[flat[$0]]!) }, [1, picks.count])
                parts.append(experts(xe, gw, local, bits: b)); order += picks
            }
            var inverse = [Int32](repeating: 0, count: order.count)
            for (pos, pick) in order.enumerated() { inverse[pick] = Int32(pos) }
            let out = MLX.squeezed(MLX.concatenated(parts, axis: 1).take(MLXArray(inverse), axis: 1), axis: -2)
            if ExpertBank.asyncExperts { MLX.asyncEval(out) }
            return out
        }
        var total: MLXArray? = nil
        for b in precisions.sorted() {
            var gslot: [Int: Int] = [:], gw: [ExpertWeights] = []
            for (e, i) in slot.sorted(by: { $0.value < $1.value }) where (w[i].bits ?? bits) == b { gslot[e] = gw.count; gw.append(w[i]) }
            let local = MLXArray(flat.map { UInt32(gslot[$0] ?? 0) }, indices.shape)
            let mask = MLXArray(flat.map { gslot[$0] != nil ? Float(1) : 0 }, indices.shape + [1, 1])
            let part = experts(xe, gw, local, bits: b) * mask.asType(x.dtype)
            total = total.map { $0 + part } ?? part
        }
        let out = MLX.squeezed(total!, axis: -2)
        if ExpertBank.asyncExperts { MLX.asyncEval(out) }
        return out
    }
}

/// Router guard for a pruned brain: cut experts get -infinity, so the router can never pick them; the 8 it picks
/// are always experts that still exist, and their weights renormalize among themselves.
public final class MaskedRouter: Linear, @unchecked Sendable {
    let inner: Linear
    let mask: MLXArray
    public init(inner: Linear, numExperts: Int, kept: Set<Int>) {
        self.inner = inner
        mask = MLXArray((0..<numExperts).map { kept.contains($0) ? Float(0) : -Float.infinity })
        super.init(weight: MLXArray.zeros([1, 1]))
        freeze()
    }
    public override func callAsFunction(_ x: MLXArray) -> MLXArray {
        let logits = inner(x)
        return logits + mask.asType(logits.dtype)
    }
}

/// Feeds the chat template like the stock loader does (its own processor type isn't public).
struct TeTiInputProcessor: UserInputProcessor {
    let tokenizer: any MLXLMCommon.Tokenizer
    let generator: any MessageGenerator = DefaultMessageGenerator()
    func prepare(input: UserInput) async throws -> LMInput {
        let tokens = try tokenizer.applyChatTemplate(messages: generator.generate(from: input), tools: input.tools,
                                                     additionalContext: input.additionalContext)
        return LMInput(tokens: MLXArray(tokens))
    }
}

/// Which experts a pruned brain kept (written by `prune apply` as pruned.json).
public struct PrunePlan: Codable, Sendable {
    public var source: String
    public var coverage: Double
    public var tokensSeen: Int
    public var kept: [String: [Int]]          // layer → kept expert ids
    public var originalCount: Int
    public var keptCount: Int { kept.values.reduce(0) { $0 + $1.count } }
    public init(source: String, coverage: Double, tokensSeen: Int, kept: [String: [Int]], originalCount: Int) {
        self.source = source; self.coverage = coverage; self.tokensSeen = tokensSeen; self.kept = kept; self.originalCount = originalCount
    }
    public static func load(_ dir: URL) -> PrunePlan? {
        guard let d = try? Data(contentsOf: dir.appendingPathComponent("pruned.json")) else { return nil }
        return try? JSONDecoder().decode(PrunePlan.self, from: d)
    }
}

/// Where a brain's trained adapters live. A pruned/active copy shares its base brain's adapters (same attention weights).
public enum Adapters {
    public static func root(for brainDir: URL) -> URL {
        var name = brainDir.lastPathComponent
        for suf in ["-pruned", "-active"] where name.hasSuffix(suf) { name = String(name.dropLast(suf.count)) }
        return BrainPaths.models.appendingPathComponent("adapters/\(name)")
    }
    public static func current(for brainDir: URL) -> URL? {
        let c = root(for: brainDir).appendingPathComponent("current")
        return FileManager.default.fileExists(atPath: c.appendingPathComponent("adapters.safetensors").path) ? c : nil
    }
    /// Layers the overnight training may change on a streamed MoE brain: attention + the always-on shared expert.
    /// Never the routers (that would scramble which experts get picked) and never the streamed experts themselves.
    public static let streamedKeys = ["self_attn.q_proj", "self_attn.k_proj", "self_attn.v_proj", "self_attn.o_proj",
                                      "linear_attn.in_proj_qkv", "linear_attn.in_proj_z", "linear_attn.out_proj",
                                      "linear_attn.in_proj_qkvz",   // Qwen3-Next names its fused projection this way
                                      "mlp.shared_expert.gate_proj", "mlp.shared_expert.up_proj", "mlp.shared_expert.down_proj"]
}

public enum StreamingLoader {
    public static func isLaid(_ dir: URL) -> Bool {
        FileManager.default.fileExists(atPath: dir.appendingPathComponent("bank-meta.json").path)
            && FileManager.default.fileExists(atPath: dir.appendingPathComponent("hot.safetensors").path)
    }

    /// Build the brain: hot weights in RAM, every MoE layer's experts streamed from the bank.
    /// cacheGB <= 0 means auto: fill the RAM that's really free, and shrink/grow with the Mac.
    public static func load(directory: URL, cacheGB: Double, lanes: Int = 8, log: @escaping @Sendable (String) -> Void = { print($0) }) async throws
        -> (ModelContainer, ExpertBank)
    {
        MLX.compile(enable: false)   // expert choice depends on live router output, which a frozen compiled trace can't follow
        let cfgData = try Data(contentsOf: directory.appendingPathComponent("config.json"))
        let raw = try JSONSerialization.jsonObject(with: cfgData) as? [String: Any] ?? [:]
        let q = raw["quantization"] as? [String: Any] ?? [:]
        let groupSize = q["group_size"] as? Int ?? 64, bits = q["bits"] as? Int ?? 4
        let text = raw["text_config"] as? [String: Any] ?? raw
        let nLayers = text["num_hidden_layers"] as? Int ?? 0

        let bank = try ExpertBank(directory: directory, cacheGB: cacheGB, lanes: lanes)
        // the model's own class, from config.json (Code Smash TeTi = qwen3_5_moe, the second big brain = qwen3_next)
        let modelType = raw["model_type"] as? String ?? "qwen3_5_moe"
        let model: any LLMModel
        switch modelType {
        case "qwen3_next": model = Qwen3NextModel(try JSONDecoder().decode(Qwen3NextConfiguration.self, from: cfgData))
        default: model = Qwen35MoEModel(try JSONDecoder().decode(Qwen35Configuration.self, from: cfgData))
        }
        func layerOf(_ path: String) -> Int? { Int(path.components(separatedBy: ".layers.").last?.split(separator: ".").first ?? "") }
        // every expert layer, found by name, whatever the model calls its outer wrapper
        let moe: [(Int, String)] = model.namedModules().compactMap { p, _ in p.hasSuffix(".mlp.switch_mlp") ? layerOf(p).map { ($0, p) } : nil }
        guard !moe.isEmpty else { throw NSError(domain: "StreamingLoader", code: 5, userInfo: [NSLocalizedDescriptionKey: "\(modelType): no expert layers found"]) }
        let missingLayers = moe.map { $0.0 }.filter { !bank.has(layer: $0) }.sorted()
        _ = nLayers
        let pruned = PrunePlan.load(directory)
        guard missingLayers.isEmpty else { throw NSError(domain: "StreamingLoader", code: 2, userInfo: [NSLocalizedDescriptionKey:
            "bank is missing expert layers \(missingLayers) (partial lay); can't run the whole brain"]) }

        let swaps = moe.map { l, path in (path, StreamingSwitchGLU(layer: l, bank: bank, groupSize: groupSize, bits: bits) as Module) }
        try model.update(modules: ModuleChildren.unflattened(swaps), verify: .none)

        let (loaded, _) = try loadArraysAndMetadata(url: directory.appendingPathComponent("hot.safetensors"))
        let weights = model.sanitize(weights: loaded)
        // each layer's precision from its own stored weights (Qwen3-Next keeps its routers at 8-bit, the rest 4-bit)
        var precisions: [Int: Int] = [:]
        quantize(model: model) { path, _ in
            guard let w = weights["\(path).weight"], let sc = weights["\(path).scales"], sc.dim(-1) > 0 else { return nil }
            let b = w.dim(-1) * 32 / (sc.dim(-1) * groupSize)
            precisions[b, default: 0] += 1
            return (groupSize, b, .affine)
        }
        log("\(modelType): \(moe.count) expert layers (e.g. \(moe.first!.1)) · hot layers by precision: " +
            precisions.sorted { $0.key < $1.key }.map { "\($0.key)-bit ×\($0.value)" }.joined(separator: ", "))
        try model.update(parameters: ModuleParameters.unflattened(weights), verify: [.noUnusedKeys, .shapeMismatch])
        // every non-expert weight must have come from the file (nothing left random)
        let unset = model.parameters().flattened().map { $0.0 }.filter { !$0.contains(".switch_mlp.") && weights[$0] == nil }
        guard unset.isEmpty else { throw NSError(domain: "StreamingLoader", code: 3, userInfo: [NSLocalizedDescriptionKey:
            "hot.safetensors is missing \(unset.count) weights, e.g. \(unset.prefix(3))"]) }
        if let pruned {
            // a pruned brain: block the cut experts at every router
            let E = bank.meta.expertsPerLayer
            var gates: [(String, Module)] = []
            for (path, m) in model.namedModules() where path.hasSuffix(".mlp.gate") {
                guard let lin = m as? Linear, let l = Int(path.components(separatedBy: ".layers.").last?.split(separator: ".").first ?? "") else { continue }
                for e in pruned.kept[String(l)] ?? [] where !bank.has(layer: l, expert: e) { throw NSError(domain: "StreamingLoader", code: 4, userInfo: [NSLocalizedDescriptionKey: "prune plan keeps layer \(l) expert \(e) but it isn't in the bank"]) }
                // only experts that truly no longer exist (--hard) get blocked; deep-memory ones stay reachable
                let present = Set((0..<E).filter { bank.has(layer: l, expert: $0) })
                if present.count < E { gates.append((path, MaskedRouter(inner: lin, numExperts: E, kept: present))) }
            }
            try model.update(modules: ModuleChildren.unflattened(gates), verify: .none)
            log("pruned brain: \(pruned.keptCount) common experts on the main relay · \(bank.rareCount) rare in deep memory (second relay)" + (gates.isEmpty ? "" : " · \(gates.count) routers block cut experts"))
        }
        // wire the what-if guesser: each layer gets the next layer's router
        var gateOf: [Int: Linear] = [:], glus: [Int: StreamingSwitchGLU] = [:]
        for (path, m) in model.namedModules() {
            guard let l = Int(path.components(separatedBy: ".layers.").last?.split(separator: ".").first ?? "") else { continue }
            if path.hasSuffix(".mlp.gate"), let g = m as? Linear { gateOf[l] = g }
            if path.hasSuffix(".mlp.switch_mlp"), let s = m as? StreamingSwitchGLU { glus[l] = s }
        }
        for (l, s) in glus { s.nextGate = gateOf[l + 1] }
        if let d = try? Data(contentsOf: ExpertBank.guessFile), let j = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
           (j["winner"] as? String) == "off" {
            bank.guessingAllowed = false
            log("what-if guessing: off (the real race showed it was slower on this Mac)")
        }
        if ProcessInfo.processInfo.environment["TETI_NO_GUESS"] != nil { bank.guessingAllowed = false }
        try model.prepare()
        eval(model)
        if cacheGB <= 0 {
            // a brain that just quit hands its RAM back over several seconds: wait until free memory stops climbing
            // (max 30 s), or this brain sizes itself to a fraction of what it will really have
            var last = ExpertBank.availableBytes(), t = Date()
            while Date().timeIntervalSince(t) < 30 {
                Thread.sleep(forTimeInterval: 2)
                let now = ExpertBank.availableBytes()
                if now - last < 300_000_000 { break }
                last = now
            }
            _ = t; t = Date()
            bank.autoSize()   // auto: as much as is truly free
        }
        let t0 = Date()
        let filled = bank.fill()
        log(String(format: "hot weights in RAM: %d tensors · experts in RAM: %d of %d (%.1f GB, %.0f%% of all experts) loaded in %.1fs · %d lanes",
                   weights.count, filled, bank.meta.entries.count, Double(bank.capacity * bank.expertBytes) / 1e9,
                   Double(bank.capacity) / Double(bank.meta.entries.count) * 100, Date().timeIntervalSince(t0), lanes))
        if cacheGB <= 0 { bank.startAdaptive(log: log) }

        let tokenizer = try await #huggingFaceTokenizerLoader().load(from: directory)
        let ctx = ModelContext(configuration: ModelConfiguration(directory: directory), model: model,
                               processor: TeTiInputProcessor(tokenizer: tokenizer), tokenizer: tokenizer)
        return (ModelContainer(context: ctx), bank)
    }

    /// Same brain, handed back raw (for profiling and the pruning exam, which need the logits directly).
    public static func loadRaw(directory: URL, cacheGB: Double, log: @escaping @Sendable (String) -> Void = { print($0) }) async throws
        -> (model: any LLMModel, tokenizer: any MLXLMCommon.Tokenizer, bank: ExpertBank)
    {
        let (container, bank) = try await load(directory: directory, cacheGB: cacheGB, log: log)
        let (m, t) = await container.perform { ctx in (ctx.model as! any LLMModel, ctx.tokenizer) }
        return (m, t, bank)
    }
}
