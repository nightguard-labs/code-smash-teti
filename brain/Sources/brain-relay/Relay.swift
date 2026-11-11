import Foundation
import BrainCore

/// One read lane: its own file handle on one drive, its own job queue, its own one-way data socket.
final class Lane {
    let id: Int
    let drive: Int
    let fd: Int32
    var dataFD: Int32 = -1
    var queue: [Job] = []
    var inflightBytes = 0
    var bytesPerSec: Double        // learned speed (moving average): how fast this lane really is right now
    var served = 0, stole = 0
    let buffer: UnsafeMutableRawPointer
    let bufferSize: Int

    init(id: Int, drive: Int, file: String, maxBlock: Int, initialSpeed: Double) throws {
        self.id = id; self.drive = drive
        fd = open(file, O_RDONLY)
        guard fd >= 0 else { throw WireError.system("open \(file): \(String(cString: strerror(errno)))") }
        _ = fcntl(fd, F_NOCACHE, 1)            // straight from the SSD; RAM caching is the brain's job, not the OS's
        bufferSize = RelayDelivery.size + maxBlock
        var p: UnsafeMutableRawPointer?
        posix_memalign(&p, 16384, bufferSize)
        buffer = p!
        bytesPerSec = initialSpeed
    }

    /// Expected seconds until this lane could finish one more job of `bytes`: the "resistance" of this path.
    func resistance(adding bytes: Int) -> Double {
        Double(queue.reduce(0) { $0 + $1.length } + inflightBytes + bytes) / max(bytesPerSec, 1)
    }
}

struct Job { let ask: RelayAsk; let length: Int; let locations: [BankIndex.Location]; let queued: UInt64 }

/// The traffic controller. Every request goes to the lane with the least resistance (shortest expected wait).
/// When a lane runs dry it steals waiting work from the most backed-up lane that can also reach that block,
/// so an opening lane automatically takes the load.
final class Scheduler {
    let lanes: [Lane]
    let index: BankIndex
    let cond = NSCondition()
    var stats = (asks: 0, steals: 0)

    init(index: BankIndex, lanes: [Lane]) { self.index = index; self.lanes = lanes }

    func submit(_ ask: RelayAsk) {
        guard Int(ask.block) < index.blocks.count else { return }
        let b = index.blocks[Int(ask.block)]
        let drives = Set(b.locations.map { $0.drive })
        cond.lock()
        let best = lanes.filter { drives.contains($0.drive) }.min { $0.resistance(adding: b.length) < $1.resistance(adding: b.length) }
        best?.queue.append(Job(ask: ask, length: b.length, locations: b.locations, queued: DispatchTime.now().uptimeNanoseconds))
        stats.asks += 1
        cond.broadcast()
        cond.unlock()
    }

    /// Blocks until there's work for `lane` (its own, or stolen). Returns (job, stolen).
    func next(for lane: Lane) -> (Job, Bool) {
        cond.lock(); defer { cond.unlock() }
        while true {
            if !lane.queue.isEmpty {
                let j = lane.queue.removeFirst(); lane.inflightBytes += j.length; return (j, false)
            }
            // Path of least resistance: steal from whichever reachable lane is most backed up.
            let victim = lanes.filter { $0 !== lane && $0.queue.count > 0 }
                .max { $0.resistance(adding: 0) < $1.resistance(adding: 0) }
            if let v = victim, let k = v.queue.lastIndex(where: { j in j.locations.contains { $0.drive == lane.drive } }) {
                let j = v.queue.remove(at: k); lane.inflightBytes += j.length; lane.stole += 1; stats.steals += 1
                return (j, true)
            }
            cond.wait()
        }
    }

    func finished(_ lane: Lane, _ job: Job, seconds: Double) {
        cond.lock()
        lane.inflightBytes -= job.length
        lane.served += 1
        let observed = Double(job.length) / max(seconds, 1e-6)
        lane.bytesPerSec = lane.bytesPerSec * 0.8 + observed * 0.2   // keep learning each lane's real speed
        cond.unlock()
    }
}

/// The relay server: request lane in, N data lanes out.
final class Relay {
    let index: BankIndex
    let lanes: [Lane]
    let scheduler: Scheduler
    let maxBlock: Int

    init(index: BankIndex, lanesOverride: Int? = nil) throws {
        self.index = index
        maxBlock = index.blocks.map { $0.length }.max() ?? 0
        var ls: [Lane] = []
        for (d, drive) in index.drives.enumerated() {
            let n = lanesOverride ?? drive.lanes
            // starting guess per lane from the 11/05 drive measurements; then each lane learns its real speed
            let speed = drive.name.lowercased().contains("internal") ? 1.3e9 : 0.8e9
            for _ in 0..<n { ls.append(try Lane(id: ls.count, drive: d, file: drive.file, maxBlock: maxBlock, initialSpeed: speed)) }
        }
        lanes = ls
        scheduler = Scheduler(index: index, lanes: ls)
    }

    func serve() throws {
        try FileManager.default.createDirectory(at: BrainPaths.run, withIntermediateDirectories: true)
        let reqListen = try RawIO.listenUnix(BrainPaths.relayRequests.path)
        let dataListen = try RawIO.listenUnix(BrainPaths.relayData.path)
        print("relay: \(lanes.count) lanes over \(index.drives.count) drive(s), \(index.blocks.count) blocks")
        print("relay: request lane \(BrainPaths.relayRequests.path)")
        print("relay: data lanes  \(BrainPaths.relayData.path) (connect \(lanes.count))")
        while true {
            // A client = 1 request connection, then one data connection per lane (accepted in order).
            let req = accept(reqListen, nil, nil)
            guard req >= 0 else { continue }
            for lane in lanes {
                let d = accept(dataListen, nil, nil)
                var big: Int32 = 8 << 20
                setsockopt(d, SOL_SOCKET, SO_SNDBUF, &big, socklen_t(MemoryLayout<Int32>.size))
                lane.dataFD = d
            }
            startLanes()
            readRequests(req)
        }
    }

    private var lanesStarted = false
    func startLanes() {
        guard !lanesStarted else { return }
        lanesStarted = true
        for lane in lanes {
            let t = Thread { [self] in laneLoop(lane) }
            t.qualityOfService = .userInteractive
            t.start()
        }
    }

    func laneLoop(_ lane: Lane) {
        while true {
            let (job, stolen) = scheduler.next(for: lane)
            let loc = job.locations.first { $0.drive == lane.drive } ?? job.locations[0]
            let t0 = DispatchTime.now().uptimeNanoseconds
            let payload = lane.buffer + RelayDelivery.size
            var got = 0
            while got < job.length {
                let r = pread(lane.fd, payload + got, job.length - got, off_t(loc.offset + got))
                if r <= 0 { break }
                got += r
            }
            let t1 = DispatchTime.now().uptimeNanoseconds
            scheduler.finished(lane, job, seconds: Double(t1 - t0) / 1e9)
            RelayDelivery(id: job.ask.id, block: job.ask.block, length: UInt32(got), lane: UInt16(lane.id),
                          stolen: stolen ? 1 : 0, micros: UInt32((t1 - job.queued) / 1000)).write(to: lane.buffer)
            _ = RawIO.writeAll(lane.dataFD, lane.buffer, RelayDelivery.size + got)
        }
    }

    func readRequests(_ fd: Int32) {
        var buf = [UInt8](repeating: 0, count: RelayAsk.size * 256)
        var have = 0
        while true {
            let r = buf.withUnsafeMutableBytes { Darwin.read(fd, $0.baseAddress! + have, $0.count - have) }
            if r <= 0 { close(fd); return }
            have += r
            let whole = have / RelayAsk.size
            buf.withUnsafeBytes { p in
                for i in 0..<whole { scheduler.submit(RelayAsk.decode(p.baseAddress! + i * RelayAsk.size)) }
            }
            let rest = have - whole * RelayAsk.size
            if rest > 0 { for i in 0..<rest { buf[i] = buf[whole * RelayAsk.size + i] } }
            have = rest
        }
    }
}
