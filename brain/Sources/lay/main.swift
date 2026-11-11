import Foundation
import CryptoKit
import BrainCore

// lay: writes a downloaded MLX model onto the drive in Code Smash TeTi's own layout.
//
//   lay build  --source <mlx model dir> --out <dir> [--keep-vision] [--available-only] [--order order.json]
//   lay verify --source <mlx model dir> --out <dir> [--samples 200]
//
// Output:
//   hot.safetensors  everything the brain needs in RAM: attention, routers, shared experts, norms, embeddings
//   bank.bin         every routed expert as one 16 KB-aligned block → one direct SSD read per expert
//   bank.json        BankIndex for brain-relay (block → drive/offset/length)
//   bank-meta.json   block → (layer, expert), per-tensor layout inside a block, sha256 per block
//   + config/tokenizer files copied so the brain is self-contained
//
// Cut on purpose: vision_tower (image input; not used for coding; Apple's on-device model covers images).

setvbuf(stdout, nil, _IOLBF, 0)
let argv = CommandLine.arguments
func opt(_ n: String) -> String? { argv.firstIndex(of: n).flatMap { $0 + 1 < argv.count ? argv[$0 + 1] : nil } }
let fm = FileManager.default

// MARK: safetensors reading

struct TensorInfo { let name: String; let dtype: String; let shape: [Int]; let file: String; let start: Int; let length: Int }

func readHeader(_ path: String) throws -> [TensorInfo] {
    guard let h = FileHandle(forReadingAtPath: path) else { throw WireError.system("can't open \(path)") }
    defer { try? h.close() }
    let n = Int(h.readData(ofLength: 8).withUnsafeBytes { $0.loadUnaligned(as: UInt64.self).littleEndian })
    let json = try JSONSerialization.jsonObject(with: h.readData(ofLength: n)) as? [String: Any] ?? [:]
    return json.compactMap { k, v in
        guard k != "__metadata__", let d = v as? [String: Any], let off = d["data_offsets"] as? [Int] else { return nil }
        return TensorInfo(name: k, dtype: d["dtype"] as? String ?? "", shape: d["shape"] as? [Int] ?? [],
                          file: path, start: 8 + n + off[0], length: off[1] - off[0])
    }
}

func pread(_ fd: Int32, _ p: UnsafeMutableRawPointer, _ len: Int, _ off: Int) {
    var got = 0
    while got < len {
        let r = Darwin.pread(fd, p + got, len - got, off_t(off + got))
        precondition(r > 0, "read failed")
        got += r
    }
}

var fds: [String: Int32] = [:]
func fd(_ path: String) -> Int32 {
    if let f = fds[path] { return f }
    let f = open(path, O_RDONLY); precondition(f >= 0, "open \(path)"); fds[path] = f; return f
}

// MARK: classify

let expertRx = try NSRegularExpression(pattern: #"\.layers\.(\d+)\.mlp\.switch_mlp\.(gate_proj|up_proj|down_proj)\.(weight|scales|biases)$"#)
let partOrder = ["gate_proj.weight", "gate_proj.scales", "gate_proj.biases",
                 "up_proj.weight", "up_proj.scales", "up_proj.biases",
                 "down_proj.weight", "down_proj.scales", "down_proj.biases"]

struct Meta: Codable {
    struct Part: Codable { var name: String; var dtype: String; var shape: [Int]; var offset: Int; var length: Int }
    struct Entry: Codable { var block: Int; var layer: Int; var expert: Int; var sha256: String }
    var source: String
    var expertsPerLayer: Int
    var blockLength: Int
    var parts: [Part]               // layout inside every block
    var tensorPrefix: String        // e.g. language_model.model.layers.{L}.mlp.switch_mlp.
    var entries: [Entry]
    var dropped: [String: Int]      // what was cut and how many bytes
}

func loadAll(_ source: String, availableOnly: Bool) throws -> [TensorInfo] {
    let idx = try JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: source + "/model.safetensors.index.json"))) as? [String: Any]
    let shards = Set((idx?["weight_map"] as? [String: String] ?? [:]).values)
    var all: [TensorInfo] = [], missing: [String] = []
    for s in shards.sorted() {
        let p = source + "/" + s
        if fm.fileExists(atPath: p) { all += try readHeader(p) } else { missing.append(s) }
    }
    if !missing.isEmpty {
        if availableOnly { print("⚠ skipping \(missing.count) shard(s) not downloaded yet: \(missing.joined(separator: ", "))") }
        else { print("✗ shards missing (download not finished): \(missing.joined(separator: ", "))\n  use --available-only for a partial test lay"); exit(1) }
    }
    return all
}

func layerExpertGroups(_ all: [TensorInfo]) -> (experts: [Int: [String: TensorInfo]], prefix: String) {
    var groups: [Int: [String: TensorInfo]] = [:]
    var prefix = ""
    for t in all {
        let r = NSRange(t.name.startIndex..., in: t.name)
        guard let m = expertRx.firstMatch(in: t.name, range: r) else { continue }
        let layer = Int(t.name[Range(m.range(at: 1), in: t.name)!])!
        let part = t.name[Range(m.range(at: 2), in: t.name)!] + "." + t.name[Range(m.range(at: 3), in: t.name)!]
        groups[layer, default: [:]][String(part)] = t
        if prefix.isEmpty { prefix = t.name.replacingOccurrences(of: ".layers.\(layer).", with: ".layers.{L}.")
            .replacingOccurrences(of: String(part), with: "") }
    }
    return (groups.filter { $0.value.count == partOrder.count }, prefix)   // only layers with all 9 parts present
}

// MARK: build

func build() throws {
    guard let source = opt("--source"), let out = opt("--out") else { print("need --source and --out"); exit(2) }
    let keepVision = argv.contains("--keep-vision")
    try fm.createDirectory(atPath: out, withIntermediateDirectories: true)
    let all = try loadAll(source, availableOnly: argv.contains("--available-only"))
    let (groups, prefix) = layerExpertGroups(all)
    let layers = groups.keys.sorted()
    guard let first = groups[layers.first ?? -1] else { print("no complete expert layers found"); exit(1) }
    let E = first["gate_proj.weight"]!.shape[0]

    // per-expert layout (same for every layer)
    var parts: [Meta.Part] = []
    var off = 0
    for p in partOrder {
        let t = first[p]!
        let len = t.length / E
        parts.append(.init(name: p, dtype: t.dtype, shape: Array(t.shape.dropFirst()), offset: off, length: len))
        off += len
    }
    let raw = off
    let blockLen = (raw + 16383) / 16384 * 16384
    print("experts: \(layers.count) layers × \(E) = \(layers.count * E) blocks, \(raw) bytes each → \(blockLen) aligned")

    // block order: owner's profile order if given (co-firing experts side by side), else layer by layer
    var order: [(Int, Int)] = layers.flatMap { l in (0..<E).map { (l, $0) } }
    if let o = opt("--order"), let d = fm.contents(atPath: o), let pairs = try? JSONDecoder().decode([[Int]].self, from: d) {
        let want = pairs.compactMap { $0.count == 2 && groups[$0[0]] != nil ? ($0[0], $0[1]) : nil }
        let seen = Set(want.map { "\($0.0):\($0.1)" })
        order = want + order.filter { !seen.contains("\($0.0):\($0.1)") }
        print("order: using profile \(o) (\(want.count) placed first)")
    }

    // ---- bank.bin
    let bankPath = out + "/bank.bin"
    try? fm.removeItem(atPath: bankPath)   // new file, never rewrite in place: a pruned brain's deep memory may hard-link the old one
    let wfd = open(bankPath, O_WRONLY | O_CREAT | O_TRUNC, 0o600); _ = fcntl(wfd, F_NOCACHE, 1)
    var buf: UnsafeMutableRawPointer?; posix_memalign(&buf, 16384, blockLen)
    var entries: [Meta.Entry] = [], blocks: [BankIndex.Block] = []
    let t0 = Date()
    for (i, (l, e)) in order.enumerated() {
        memset(buf!, 0, blockLen)
        for p in parts {
            let t = groups[l]![p.name]!
            pread(fd(t.file), buf! + p.offset, p.length, t.start + e * p.length)
        }
        let digest = SHA256.hash(data: UnsafeRawBufferPointer(start: buf!, count: raw)).map { String(format: "%02x", $0) }.joined()
        precondition(RawIO.writeAll(wfd, buf!, blockLen), "write failed (disk full?)")
        entries.append(.init(block: i, layer: l, expert: e, sha256: digest))
        blocks.append(.init(id: i, length: raw, locations: [.init(drive: 0, offset: i * blockLen)]))
        if i % 512 == 511 || i == order.count - 1 {
            let gb = Double((i + 1) * blockLen) / 1e9, s = Date().timeIntervalSince(t0)
            print(String(format: "  bank: %d/%d blocks  %.1f GB  %.2f GB/s", i + 1, order.count, gb, gb / s))
        }
    }
    fsync(wfd); close(wfd); free(buf)

    // ---- hot.safetensors (everything else that the brain keeps in RAM)
    let expertNames = Set(groups.values.flatMap { $0.values.map { $0.name } })
    var dropped: [String: Int] = [:]
    var hot: [TensorInfo] = []
    for t in all where !expertNames.contains(t.name) {
        if !keepVision && t.name.hasPrefix("vision_tower.") { dropped["vision_tower", default: 0] += t.length; continue }
        if expertRx.firstMatch(in: t.name, range: NSRange(t.name.startIndex..., in: t.name)) != nil {
            dropped["incomplete expert layers (partial lay)", default: 0] += t.length; continue
        }
        hot.append(t)
    }
    hot.sort { $0.name < $1.name }
    var header: [String: Any] = ["__metadata__": ["format": "mlx", "producer": "code-smash-teti lay"]]
    var dataOff = 0
    for t in hot { header[t.name] = ["dtype": t.dtype, "shape": t.shape, "data_offsets": [dataOff, dataOff + t.length]]; dataOff += t.length }
    var hjson = try JSONSerialization.data(withJSONObject: header, options: [.sortedKeys])
    while hjson.count % 8 != 0 { hjson.append(0x20) }
    let hfd = open(out + "/hot.safetensors", O_WRONLY | O_CREAT | O_TRUNC, 0o600)
    var n = UInt64(hjson.count).littleEndian
    _ = withUnsafeBytes(of: &n) { RawIO.writeAll(hfd, $0.baseAddress!, 8) }
    _ = hjson.withUnsafeBytes { RawIO.writeAll(hfd, $0.baseAddress!, hjson.count) }
    let chunk = UnsafeMutableRawPointer.allocate(byteCount: 64 << 20, alignment: 16384)
    for t in hot {
        var done = 0
        while done < t.length {
            let c = min(64 << 20, t.length - done)
            pread(fd(t.file), chunk, c, t.start + done)
            precondition(RawIO.writeAll(hfd, chunk, c), "write failed")
            done += c
        }
    }
    fsync(hfd); close(hfd); chunk.deallocate()
    print(String(format: "hot.safetensors: %d tensors, %.2f GB", hot.count, Double(dataOff) / 1e9))
    for (k, v) in dropped { print(String(format: "cut: %@ (%.2f GB)", k, Double(v) / 1e9)) }

    // ---- indexes + config
    let enc = JSONEncoder(); enc.outputFormatting = [.prettyPrinted, .sortedKeys]
    try enc.encode(BankIndex(drives: [.init(name: "internal SSD", file: bankPath, lanes: 8)], blocks: blocks))
        .write(to: URL(fileURLWithPath: out + "/bank.json"))
    try enc.encode(Meta(source: source, expertsPerLayer: E, blockLength: blockLen, parts: parts, tensorPrefix: prefix,
                        entries: entries, dropped: dropped))
        .write(to: URL(fileURLWithPath: out + "/bank-meta.json"))
    for f in ["config.json", "generation_config.json", "tokenizer.json", "tokenizer_config.json", "vocab.json",
              "chat_template.jinja", "merges.txt", "special_tokens_map.json", "added_tokens.json"] where fm.fileExists(atPath: source + "/" + f) {
        try? fm.removeItem(atPath: out + "/" + f); try fm.copyItem(atPath: source + "/" + f, toPath: out + "/" + f)
    }
    print(String(format: "✓ laid in %.0fs → %@", Date().timeIntervalSince(t0), out))
}

// MARK: verify (every sampled block must match the original model byte for byte, and its checksum)

func verify() throws {
    guard let source = opt("--source"), let out = opt("--out") else { print("need --source and --out"); exit(2) }
    let meta = try JSONDecoder().decode(Meta.self, from: Data(contentsOf: URL(fileURLWithPath: out + "/bank-meta.json")))
    let all = try loadAll(source, availableOnly: true)
    let (groups, _) = layerExpertGroups(all)
    let samples = min(Int(opt("--samples") ?? "200")!, meta.entries.count)
    let bfd = open(out + "/bank.bin", O_RDONLY); _ = fcntl(bfd, F_NOCACHE, 1)
    let a = UnsafeMutableRawPointer.allocate(byteCount: meta.blockLength, alignment: 16384)
    let b = UnsafeMutableRawPointer.allocate(byteCount: meta.blockLength, alignment: 16384)
    var bad = 0
    var picks = Array(meta.entries.shuffled().prefix(samples))
    picks += [meta.entries.first!, meta.entries.last!]
    for en in picks {
        pread(bfd, a, meta.blockLength, en.block * meta.blockLength)
        let raw = meta.parts.last!.offset + meta.parts.last!.length
        let sum = SHA256.hash(data: UnsafeRawBufferPointer(start: a, count: raw)).map { String(format: "%02x", $0) }.joined()
        for p in meta.parts {
            let t = groups[en.layer]![p.name]!
            pread(fd(t.file), b + p.offset, p.length, t.start + en.expert * p.length)
        }
        if sum != en.sha256 || memcmp(a, b, raw) != 0 { bad += 1; print("✗ block \(en.block) (layer \(en.layer) expert \(en.expert)) mismatch") }
    }
    // hot file must load as valid safetensors and match the source tensors
    let hot = try readHeader(out + "/hot.safetensors")
    let src = Dictionary(all.map { ($0.name, $0) }, uniquingKeysWith: { a, _ in a })
    var hotBad = 0
    for t in hot.shuffled().prefix(50) {
        guard let s = src[t.name], s.length == t.length else { hotBad += 1; continue }
        let n = min(t.length, 1 << 20)
        let x = UnsafeMutableRawPointer.allocate(byteCount: n, alignment: 16), y = UnsafeMutableRawPointer.allocate(byteCount: n, alignment: 16)
        pread(fd(out + "/hot.safetensors"), x, n, t.start); pread(fd(s.file), y, n, s.start)
        if memcmp(x, y, n) != 0 { hotBad += 1 }
        x.deallocate(); y.deallocate()
    }
    print("verify: \(picks.count) expert blocks checked byte-for-byte + sha256 → \(bad == 0 ? "all match ✓" : "\(bad) BAD ✗")")
    print("verify: \(min(50, hot.count)) hot tensors checked against the source → \(hotBad == 0 ? "all match ✓" : "\(hotBad) BAD ✗")")
    exit(bad + hotBad == 0 ? 0 : 1)
}

switch argv.dropFirst().first {
case "build": try build()
case "verify": try verify()
default: print("usage: lay build --source DIR --out DIR [--available-only] [--keep-vision] [--order order.json] | lay verify --source DIR --out DIR")
}
