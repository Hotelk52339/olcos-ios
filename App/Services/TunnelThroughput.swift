import Foundation
#if canImport(Darwin)
import Darwin
#endif

// MARK: - Tunnel throughput (hero picture intensity + spoken rate)
//
// The hero picture's traffic particles flow with real traffic; the measured
// rate is spoken to VoiceOver (VPN: ↓/↑; SOCKS5: one "about" figure), never
// printed. Two data sources, both documented in docs/architecture.md:
//
//   • VPN mode — EXACT. `Tunnel/PacketTunnelProvider.swift` answers the
//     "stats" provider message with cumulative tunstack counters (`rxBytes`
//     toward the device, `txBytes` from the device, `v` = 1). The app polls
//     them ~1/s through `VPNController.stats()` while connected and on screen.
//   • SOCKS5 in-app mode — APPROXIMATE. Upstream's `mobile.Runtime` exposes no
//     byte counters (internal/client/tunnel.go discards CopyBidirectional's
//     counts), and adding some would mean patching the submodule. Instead the
//     app reads the loopback interface (`lo0`) byte counters via getifaddrs
//     and takes deltas while the local SOCKS5 listener is active. Every byte
//     a local client exchanges with the listener crosses lo0 once, so the
//     delta is a fair proxy for total tunnelled traffic — but it cannot be
//     split into ↓/↑ and includes any other loopback traffic on the device.
//     The readout therefore shows ONE figure marked "≈".
//
// Nothing here invents numbers: no sample → no reading → nothing spoken, and
// the picture falls back to its calm idle drift.

/// Cumulative byte counters observed at one instant of a monotonic clock.
struct ThroughputCounters: Equatable {
    /// Bytes toward the device (↓). For the loopback estimate: lo0 input bytes.
    var inBytes: UInt64
    /// Bytes from the device (↑). For the loopback estimate: equals `inBytes`.
    var outBytes: UInt64
    /// Monotonic seconds (provider or process uptime), never wall-clock.
    var at: TimeInterval
}

/// A smoothed rate for the readout and the waveform.
enum ThroughputReading: Equatable {
    /// Exact packet-path counters (VPN mode).
    case exact(inBytesPerSecond: Double, outBytesPerSecond: Double)
    /// Loopback estimate (SOCKS5 in-app mode): one undirected figure.
    case estimate(totalBytesPerSecond: Double)

    var totalBytesPerSecond: Double {
        switch self {
        case .exact(let i, let o): return i + o
        case .estimate(let t):     return t
        }
    }

    var isExact: Bool {
        if case .exact = self { return true }
        return false
    }

    /// 0…1 part of the traffic flowing toward the device. Exact counters
    /// split it; the undirected estimate (and a silent tunnel) report 0.5.
    var inboundShare: Double {
        switch self {
        case .exact(let i, let o):
            let total = i + o
            guard total.isFinite, total > 0, i.isFinite, i >= 0 else { return 0.5 }
            return min(1, max(0, i / total))
        case .estimate:
            return 0.5
        }
    }
}

/// Exponential moving average over cumulative counters. Pure; testable.
struct ThroughputEstimator: Equatable {
    /// EMA time constant in seconds: 1 Hz samples settle in ~3 samples.
    static let timeConstant: TimeInterval = 2.0

    private(set) var inBytesPerSecond = 0.0
    private(set) var outBytesPerSecond = 0.0
    private var last: ThroughputCounters?

    /// Feeds one sample. Returns nil until two ordered samples exist. A
    /// counter that went backwards (tunnel restarted) resets the average.
    mutating func ingest(_ sample: ThroughputCounters) -> (inBytesPerSecond: Double, outBytesPerSecond: Double)? {
        guard let previous = last else {
            last = sample
            return nil
        }
        last = sample
        let dt = sample.at - previous.at
        guard dt.isFinite, dt > 0 else { return nil }
        guard sample.inBytes >= previous.inBytes, sample.outBytes >= previous.outBytes else {
            inBytesPerSecond = 0
            outBytesPerSecond = 0
            return nil
        }
        let instantIn = Double(sample.inBytes - previous.inBytes) / dt
        let instantOut = Double(sample.outBytes - previous.outBytes) / dt
        let weight = 1 - exp(-dt / Self.timeConstant)
        inBytesPerSecond += (instantIn - inBytesPerSecond) * weight
        outBytesPerSecond += (instantOut - outBytesPerSecond) * weight
        return (inBytesPerSecond, outBytesPerSecond)
    }

    mutating func reset() {
        self = ThroughputEstimator()
    }
}

/// Extends a 32-bit interface counter (`if_data.ifi_ibytes` wraps at 4 GiB)
/// into a monotonic 64-bit value. Pure; testable.
struct WrappingCounter32: Equatable {
    private var previous: UInt32?
    private(set) var total: UInt64 = 0

    mutating func extend(_ value: UInt32) -> UInt64 {
        if let previous {
            total &+= UInt64(value &- previous)
        }
        previous = value
        return total
    }
}

/// Human figure for the readout: "0 KB/s" … "999 KB/s", "1.2 MB/s", "120 MB/s".
/// The unit strings are localized; digits use the current locale's separator.
enum ThroughputFormat {
    static let kilo = 1024.0
    static let mega = 1024.0 * 1024.0

    static func rate(_ bytesPerSecond: Double, locale: Locale = .current) -> String {
        let value = bytesPerSecond.isFinite ? max(0, bytesPerSecond) : 0
        if value < mega {
            let kb = (value / kilo).rounded()
            return L10n.throughputKBps_fmt.formatted(number(kb, fractionDigits: 0, locale: locale))
        }
        let mb = value / mega
        return L10n.throughputMBps_fmt.formatted(number(mb, fractionDigits: mb < 100 ? 1 : 0, locale: locale))
    }

    /// Locale decimal separator, no thousands grouping: "1023", "1.2" / "1,2".
    /// (`String(format:locale:)` groups — "1,023 KB/s" — which reads as a
    /// decimal in half the locales this app ships in.)
    static func number(_ value: Double, fractionDigits: Int, locale: Locale) -> String {
        let plain = String(format: "%.\(fractionDigits)f", value)   // C locale: "." and no grouping
        guard fractionDigits > 0, let separator = locale.decimalSeparator, separator != "." else { return plain }
        return plain.replacingOccurrences(of: ".", with: separator)
    }
}

// MARK: - Sources

/// Loopback (`lo0`) byte counters from getifaddrs, extended to 64 bits.
/// Device-wide, not per process; direction is meaningless on loopback.
struct LoopbackCounterReader {
    static let interfaceName = "lo0"
    private var inCounter = WrappingCounter32()
    private var outCounter = WrappingCounter32()

    #if canImport(Darwin)
    /// Raw 32-bit interface counters, or nil when the interface is not listed.
    static func rawCounters(interface: String = interfaceName) -> (inBytes: UInt32, outBytes: UInt32)? {
        var list: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&list) == 0, let first = list else { return nil }
        defer { freeifaddrs(list) }
        var cursor: UnsafeMutablePointer<ifaddrs>? = first
        var result: (inBytes: UInt32, outBytes: UInt32)?
        while let node = cursor {
            let entry = node.pointee
            if let address = entry.ifa_addr,
               address.pointee.sa_family == UInt8(AF_LINK),
               let data = entry.ifa_data,
               String(cString: entry.ifa_name) == interface {
                let stats = data.assumingMemoryBound(to: if_data.self).pointee
                result = (stats.ifi_ibytes, stats.ifi_obytes)
                break
            }
            cursor = entry.ifa_next
        }
        return result
    }
    #else
    static func rawCounters(interface: String = interfaceName) -> (inBytes: UInt32, outBytes: UInt32)? { nil }
    #endif

    mutating func sample(now: TimeInterval = ProcessInfo.processInfo.systemUptime) -> ThroughputCounters? {
        guard let raw = Self.rawCounters() else { return nil }
        return ThroughputCounters(inBytes: inCounter.extend(raw.inBytes),
                                  outBytes: outCounter.extend(raw.outBytes),
                                  at: now)
    }

    mutating func reset() {
        self = LoopbackCounterReader()
    }
}

// MARK: - Monitor

/// Polls the active backend ~1/s and publishes a smoothed reading. Runs only
/// while the caller says the tunnel is connected AND the hero is on screen in
/// the foreground; `update` with anything else cancels the loop and clears the
/// reading so no stale figure survives a disconnect or a mode change.
@MainActor
final class TunnelThroughputMonitor: ObservableObject {
    @Published private(set) var reading: ThroughputReading?

    static let pollInterval: Duration = .seconds(1)

    private var task: Task<Void, Never>?
    private var runningMode: TunnelMode?
    private var estimator = ThroughputEstimator()
    private var loopback = LoopbackCounterReader()

    /// Smoothed total for the waveform (0 when there is no reading).
    var intensity: Double {
        SignalMotionPolicy.intensity(bytesPerSecond: reading?.totalBytesPerSecond ?? 0)
    }

    func update(isConnected: Bool, isOnScreen: Bool, sceneIsActive: Bool,
                mode: TunnelMode, vpn: VPNController) {
        let shouldRun = isConnected && isOnScreen && sceneIsActive
        guard shouldRun else { stop(); return }
        if task != nil, runningMode == mode { return }
        stop()
        runningMode = mode
        task = Task { [weak self] in
            while !Task.isCancelled {
                let sample: ThroughputCounters?
                switch mode {
                case .vpn:   sample = await Self.packetTunnelCounters(vpn)
                case .proxy: sample = self?.loopback.sample() ?? nil
                }
                guard let self, !Task.isCancelled else { return }
                self.apply(sample, mode: mode)
                try? await Task.sleep(for: Self.pollInterval)
            }
        }
    }

    func stop() {
        task?.cancel()
        task = nil
        runningMode = nil
        estimator.reset()
        loopback.reset()
        if reading != nil { reading = nil }
    }

    private func apply(_ sample: ThroughputCounters?, mode: TunnelMode) {
        guard let sample, let rates = estimator.ingest(sample) else {
            if sample == nil, reading != nil { reading = nil }
            return
        }
        let next: ThroughputReading
        switch mode {
        case .vpn:
            next = .exact(inBytesPerSecond: rates.inBytesPerSecond,
                          outBytesPerSecond: rates.outBytesPerSecond)
        case .proxy:
            // lo0 input == lo0 output byte-for-byte; report one figure.
            next = .estimate(totalBytesPerSecond: rates.inBytesPerSecond)
        }
        if next != reading { reading = next }
    }

    private static func packetTunnelCounters(_ vpn: VPNController) async -> ThroughputCounters? {
        guard let data = await vpn.stats(),
              let stats = VPNController.ProviderStats.decode(data),
              let rx = stats.rxBytes, let tx = stats.txBytes else { return nil }
        let at = stats.monotonicMs.map { Double($0) / 1000 } ?? ProcessInfo.processInfo.systemUptime
        return ThroughputCounters(inBytes: UInt64(max(0, rx)), outBytes: UInt64(max(0, tx)), at: at)
    }
}
