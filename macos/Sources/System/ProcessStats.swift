import Darwin
import Foundation
import IOKit
import os.log

private let logger = Logger(subsystem: "com.localport.app", category: "ProcessStats")

/// Resource usage of one process. `nil` means not measured yet (CPU, GPU
/// and network need two samples) or not readable.
struct ProcessStats: Equatable {
    var cpuPercent: Double?
    var gpuPercent: Double?
    var memoryBytes: UInt64?
    var netInPerSecond: Double?
    var netOutPerSecond: Double?
}

/// Samples CPU, GPU, memory and network for the pids behind LocalPort's
/// ports. Runs only between `start()` and `stop()` — the app starts it while
/// the popover shows the Ports tab — so it costs nothing otherwise.
///
/// - CPU and memory: `proc_pid_rusage` (CPU time; physical footprint, as in
///   Activity Monitor).
/// - GPU: each process's accumulated GPU time from the IOAccelerator user
///   clients in the IORegistry.
/// - Network: a one-second `/usr/bin/nettop` sample per tick, limited to
///   the pids (macOS ships it; there is no public per-process byte counter
///   API). Each run exits, so its output arrives whole rather than
///   block-buffered.
final class ProcessStatsSampler {
    /// Delivered on the main queue.
    var onUpdate: (([Int32: ProcessStats]) -> Void)?
    /// The pids to sample; read on the main queue before each sample.
    var pids: () -> Set<Int32> = { [] }

    private static let interval: TimeInterval = 2

    private let queue = DispatchQueue(label: "com.localport.process-stats")
    private var timer: DispatchSourceTimer?

    // Queue-only state.
    private var previous: [Int32: (cpuNanos: UInt64, gpuNanos: UInt64?)] = [:]
    private var previousAt: UInt64 = 0
    /// From the latest finished nettop run; `nil` until the first one.
    private var netRates: [Int32: (inPerSecond: Double, outPerSecond: Double)]?
    private var nettop: Process?

    private static let ticksToNanos: Double = {
        var timebase = mach_timebase_info_data_t()
        mach_timebase_info(&timebase)
        return Double(timebase.numer) / Double(timebase.denom)
    }()

    var isRunning: Bool { timer != nil }

    func start() {
        guard timer == nil else { return }
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now(), repeating: Self.interval)
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            let pids = DispatchQueue.main.sync { self.pids() }
            let stats = self.sample(pids)
            DispatchQueue.main.async { self.onUpdate?(stats) }
        }
        self.timer = timer
        timer.resume()
    }

    func stop() {
        timer?.cancel()
        timer = nil
        queue.async {
            self.nettop?.terminate()
            self.nettop = nil
            self.previous = [:]
            self.previousAt = 0
            self.netRates = nil
        }
    }

    // MARK: - Sampling (queue)

    private func sample(_ pids: Set<Int32>) -> [Int32: ProcessStats] {
        let now = DispatchTime.now().uptimeNanoseconds
        let elapsed = previousAt == 0 ? nil : Double(now - previousAt)
        let gpu = pids.isEmpty ? [:] : Self.gpuNanosByPid()
        sampleNetwork(pids)

        var result: [Int32: ProcessStats] = [:]
        var current: [Int32: (cpuNanos: UInt64, gpuNanos: UInt64?)] = [:]
        for pid in pids {
            guard let usage = Self.rusage(pid) else { continue }
            let cpuNanos = UInt64(Double(usage.ri_user_time + usage.ri_system_time) * Self.ticksToNanos)
            current[pid] = (cpuNanos, gpu[pid])

            var stats = ProcessStats(memoryBytes: usage.ri_phys_footprint)
            if let elapsed, let before = previous[pid] {
                stats.cpuPercent = Self.percent(before.cpuNanos, cpuNanos, over: elapsed)
                // No GPU user client means the process has never used the GPU.
                stats.gpuPercent = Self.percent(before.gpuNanos ?? 0, gpu[pid] ?? 0, over: elapsed)
            }
            if let netRates {
                // Absent: no open sockets in the sample, so no traffic.
                stats.netInPerSecond = netRates[pid]?.inPerSecond ?? 0
                stats.netOutPerSecond = netRates[pid]?.outPerSecond ?? 0
            }
            result[pid] = stats
        }
        previous = current
        previousAt = now
        return result
    }

    /// Share of one core used between two cumulative readings; can exceed
    /// 100 for multithreaded work. `nil` if the counter went backwards
    /// (e.g. a recycled pid).
    static func percent(_ before: UInt64, _ after: UInt64, over elapsedNanos: Double) -> Double? {
        guard after >= before, elapsedNanos > 0 else { return nil }
        return Double(after - before) / elapsedNanos * 100
    }

    private static func rusage(_ pid: Int32) -> rusage_info_v2? {
        var info = rusage_info_v2()
        let rc = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) {
                proc_pid_rusage(pid, RUSAGE_INFO_V2, $0)
            }
        }
        return rc == 0 ? info : nil
    }

    /// Accumulated GPU time per pid, summed over its IOAccelerator clients.
    private static func gpuNanosByPid() -> [Int32: UInt64] {
        var result: [Int32: UInt64] = [:]
        var accelerators: io_iterator_t = 0
        guard IOServiceGetMatchingServices(
            kIOMainPortDefault, IOServiceMatching("IOAccelerator"), &accelerators
        ) == KERN_SUCCESS else { return result }
        defer { IOObjectRelease(accelerators) }

        var accelerator = IOIteratorNext(accelerators)
        while accelerator != 0 {
            var clients: io_iterator_t = 0
            if IORegistryEntryCreateIterator(
                accelerator, kIOServicePlane, IOOptionBits(kIORegistryIterateRecursively), &clients
            ) == KERN_SUCCESS {
                var client = IOIteratorNext(clients)
                while client != 0 {
                    if let (pid, nanos) = gpuUsage(of: client) {
                        result[pid, default: 0] += nanos
                    }
                    IOObjectRelease(client)
                    client = IOIteratorNext(clients)
                }
                IOObjectRelease(clients)
            }
            IOObjectRelease(accelerator)
            accelerator = IOIteratorNext(accelerators)
        }
        return result
    }

    /// `IOUserClientCreator` is "pid 1234, name"; `AppUsage` lists GPU time
    /// per API in nanoseconds.
    private static func gpuUsage(of entry: io_registry_entry_t) -> (Int32, UInt64)? {
        var properties: Unmanaged<CFMutableDictionary>?
        guard IORegistryEntryCreateCFProperties(entry, &properties, kCFAllocatorDefault, 0) == KERN_SUCCESS,
              let dict = properties?.takeRetainedValue() as? [String: Any],
              let creator = dict["IOUserClientCreator"] as? String, creator.hasPrefix("pid "),
              let pid = Int32(creator.dropFirst(4).prefix { $0.isNumber }),
              let usage = dict["AppUsage"] as? [[String: Any]] else { return nil }
        let nanos = usage.compactMap { ($0["accumulatedGPUTime"] as? NSNumber)?.uint64Value }.reduce(0, +)
        return (pid, nanos)
    }

    // MARK: - Network via nettop (queue)

    /// Start a one-second nettop sample; its result is used from the next
    /// tick on. Skipped while the previous run is still going.
    private func sampleNetwork(_ pids: Set<Int32>) {
        guard nettop == nil, !pids.isEmpty else { return }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/nettop")
        // Per-process CSV, two samples one second apart, the second as a delta.
        process.arguments = ["-P", "-L", "2", "-s", "1", "-d", "-n", "-x", "-J", "bytes_in,bytes_out"]
            + pids.flatMap { ["-p", String($0)] }
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        process.terminationHandler = { [weak self] _ in
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            let text = String(data: data, encoding: .utf8) ?? ""
            self?.queue.async {
                guard let self, self.nettop === process else { return }
                self.nettop = nil
                if process.terminationStatus == 0 {
                    self.netRates = Self.parseNettopDelta(text)
                }
            }
        }
        do {
            try process.run()
            nettop = process
        } catch {
            logger.error("Couldn't run nettop: \(error.localizedDescription)")
        }
    }

    /// Bytes per second from the second (delta) block of a 1-second sample.
    /// Blocks start with a header line; data lines are "name.pid,in,out,".
    static func parseNettopDelta(_ output: String) -> [Int32: (inPerSecond: Double, outPerSecond: Double)] {
        var rates: [Int32: (inPerSecond: Double, outPerSecond: Double)] = [:]
        var blocks = 0
        for line in output.split(separator: "\n") {
            if line.hasPrefix(",") {
                blocks += 1
            } else if blocks == 2, let (pid, bytesIn, bytesOut) = parseNettop(String(line)) {
                rates[pid] = (Double(bytesIn), Double(bytesOut))
            }
        }
        return rates
    }

    static func parseNettop(_ line: String) -> (Int32, UInt64, UInt64)? {
        let fields = line.split(separator: ",", omittingEmptySubsequences: false)
        guard fields.count >= 3,
              let dot = fields[0].lastIndex(of: "."),
              let pid = Int32(fields[0][fields[0].index(after: dot)...]),
              let bytesIn = UInt64(fields[1]), let bytesOut = UInt64(fields[2]) else { return nil }
        return (pid, bytesIn, bytesOut)
    }
}
