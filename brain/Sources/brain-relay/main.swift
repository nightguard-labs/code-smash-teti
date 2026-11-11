import Foundation
import BrainCore

// brain-relay: Code Smash TeTi's SSD relay server (knowledge bank → engine).
//
//   brain-relay serve --index <bank.json> [--lanes N]
//   brain-relay make-test-bank --dir <folder> [--dir <folder2>] [--blocks 400] [--mb 5.25]
//   brain-relay bench --index <bank.json> --lanes 1,2,4,8 [--asks 600] [--depth 32]
//
// The bench runs the real relay and a real client over the real sockets, reading straight from the SSD.

setvbuf(stdout, nil, _IOLBF, 0)
signal(SIGPIPE, SIG_IGN)
let argv = CommandLine.arguments
func opt(_ n: String) -> String? { argv.firstIndex(of: n).flatMap { $0 + 1 < argv.count ? argv[$0 + 1] : nil } }
func opts(_ n: String) -> [String] { argv.indices.filter { argv[$0] == n && $0 + 1 < argv.count }.map { argv[$0 + 1] } }

func loadIndex() -> BankIndex {
    guard let p = opt("--index"), let d = FileManager.default.contents(atPath: p),
          let idx = try? JSONDecoder().decode(BankIndex.self, from: d) else { print("need --index <bank.json>"); exit(2) }
    return idx
}

switch argv.dropFirst().first {

case "make-test-bank":
    // Blocks the size of one real expert (~5.25 MB at 4-bit for Qwen3.5-122B), each stamped with its id
    // so the bench can prove every delivery is the right block.
    let dirs = opts("--dir"); guard !dirs.isEmpty else { print("need --dir"); exit(2) }
    let count = Int(opt("--blocks") ?? "400")!
    let len = (Int((Double(opt("--mb") ?? "5.25")! * 1_048_576)) / 16384) * 16384
    var drives: [BankIndex.Drive] = [], blocks: [BankIndex.Block] = []
    for (d, dir) in dirs.enumerated() {
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let file = dir + "/testbank.bin"
        let fd = open(file, O_WRONLY | O_CREAT | O_TRUNC, 0o600); _ = fcntl(fd, F_NOCACHE, 1)
        var p: UnsafeMutableRawPointer?; posix_memalign(&p, 16384, len)
        for i in 0..<count {
            memset(p!, Int32(i & 0xff), len)
            p!.storeBytes(of: UInt64(i).bigEndian, as: UInt64.self)
            _ = RawIO.writeAll(fd, p!, len)
            if d == 0 { blocks.append(.init(id: i, length: len, locations: [])) }
            blocks[i].locations.append(.init(drive: d, offset: i * len))
        }
        fsync(fd); close(fd); free(p)
        let onInternal = dir.hasPrefix(NSHomeDirectory())
        drives.append(.init(name: onInternal ? "internal SSD" : "external SSD", file: file, lanes: onInternal ? 4 : 1))
        print("wrote \(count) blocks × \(String(format: "%.2f", Double(len) / 1_048_576)) MB → \(file)")
    }
    let out = dirs[0] + "/testbank.json"
    let enc = JSONEncoder(); enc.outputFormatting = .prettyPrinted
    try enc.encode(BankIndex(drives: drives, blocks: blocks)).write(to: URL(fileURLWithPath: out))
    print("index → \(out)")

case "serve":
    let relay = try Relay(index: loadIndex(), lanesOverride: opt("--lanes").flatMap(Int.init))
    try relay.serve()

case "bench":
    let index = loadIndex()
    let asks = Int(opt("--asks") ?? "600")!, depth = Int(opt("--depth") ?? "32")!
    let configs = (opt("--lanes") ?? "1,4").split(separator: ",").compactMap { Int($0) }
    print("bench: \(asks) random expert reads, \(depth) in flight, straight from SSD (no RAM cache)\n")
    print("lanes   GB/s   avg wait   p95 wait   steals   per-lane share")
    for lanes in configs {
        // fresh relay process per config so nothing is shared between runs
        let me = URL(fileURLWithPath: argv[0]).resolvingSymlinksInPath().path
        let p = Process()
        p.executableURL = URL(fileURLWithPath: me)
        p.arguments = ["serve", "--index", opt("--index")!, "--lanes", String(lanes)]
        p.standardOutput = FileHandle.nullDevice
        try p.run()
        defer { p.terminate(); p.waitUntilExit() }
        var reqFD: Int32 = -1
        for _ in 0..<100 { if let fd = try? RawIO.connectUnix(BrainPaths.relayRequests.path) { reqFD = fd; break }; usleep(50_000) }
        guard reqFD >= 0 else { print("relay didn't start"); exit(1) }
        let totalLanes = lanes * index.drives.count
        let dataFDs = try (0..<totalLanes).map { _ in try RawIO.connectUnix(BrainPaths.relayData.path) }

        var rng = SystemRandomNumberGenerator()
        let order = (0..<asks).map { _ in UInt32.random(in: 0..<UInt32(index.blocks.count), using: &rng) }
        let lock = NSCondition()
        var received = 0, outstanding = 0, bad = 0, steals = 0, bytes = 0
        var waits: [Double] = []
        var perLane = [Int](repeating: 0, count: totalLanes)
        let maxLen = index.blocks.map { $0.length }.max()!
        let t0 = Date()
        // one reader thread per data lane (one-way, never waits on another lane)
        for fd in dataFDs {
            Thread.detachNewThread {
                let hdr = UnsafeMutableRawPointer.allocate(byteCount: RelayDelivery.size, alignment: 8)
                let body = UnsafeMutableRawPointer.allocate(byteCount: maxLen, alignment: 16384)
                while RawIO.readAll(fd, hdr, RelayDelivery.size) {
                    let d = RelayDelivery.read(hdr)
                    guard RawIO.readAll(fd, body, Int(d.length)) else { break }
                    let stamped = UInt64(bigEndian: body.loadUnaligned(as: UInt64.self))
                    lock.lock()
                    if stamped != UInt64(d.block) || Int(d.length) != index.blocks[Int(d.block)].length { bad += 1 }
                    received += 1; outstanding -= 1; bytes += Int(d.length); steals += Int(d.stolen)
                    waits.append(Double(d.micros) / 1000); perLane[Int(d.lane)] += 1
                    lock.broadcast(); lock.unlock()
                }
            }
        }
        // request lane: keep `depth` asks in flight
        for (i, b) in order.enumerated() {
            lock.lock(); while outstanding >= depth { lock.wait() }; outstanding += 1; lock.unlock()
            let a = RelayAsk(id: UInt64(i), block: b).encode()
            _ = a.withUnsafeBytes { RawIO.writeAll(reqFD, $0.baseAddress!, RelayAsk.size) }
        }
        lock.lock(); while received < asks { lock.wait() }; lock.unlock()
        let secs = Date().timeIntervalSince(t0)
        waits.sort()
        let share = perLane.map { String(Int((Double($0) / Double(asks) * 100).rounded())) + "%" }.joined(separator: " ")
        print(String(format: "%5d  %5.2f   %6.1f ms  %6.1f ms   %5d    %@%@", totalLanes, Double(bytes) / secs / 1e9,
                     waits.reduce(0, +) / Double(waits.count), waits[Int(Double(waits.count) * 0.95)], steals, share,
                     bad > 0 ? "   ✗ \(bad) BAD BLOCKS" : ""))
        close(reqFD); dataFDs.forEach { close($0) }
    }
    print("\nevery delivered block was checked against its id stamp")

default:
    print("usage: brain-relay serve --index bank.json [--lanes N] | make-test-bank --dir D [--dir D2] | bench --index bank.json --lanes 1,4,8")
}
