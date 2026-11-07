import Foundation

nonisolated struct RingBuffer<Element: Sendable>: Sendable {
    let capacity: Int
    private(set) var elements: [Element] = []

    init(capacity: Int) {
        self.capacity = capacity
    }

    mutating func append(_ element: Element) {
        elements.append(element)
        if elements.count > capacity {
            elements.removeFirst(elements.count - capacity)
        }
    }
}

/// Cumulative scheduler ticks of one core, as returned by host_processor_info.
nonisolated struct CPUTicks: Equatable, Sendable {
    var user: UInt32
    var system: UInt32
    var idle: UInt32
    var nice: UInt32
}

nonisolated struct CPUUsage: Equatable, Sendable {
    var user: Double
    var system: Double
    var total: Double { user + system }

    static let zero = CPUUsage(user: 0, system: 0)

    /// Counters are 32-bit and wrap, hence the wrapping subtraction.
    init(from old: CPUTicks, to new: CPUTicks) {
        let user = Double((new.user &- old.user) &+ (new.nice &- old.nice))
        let system = Double(new.system &- old.system)
        let idle = Double(new.idle &- old.idle)
        let total = user + system + idle
        self.init(user: total > 0 ? user / total : 0, system: total > 0 ? system / total : 0)
    }

    init(user: Double, system: Double) {
        self.user = user
        self.system = system
    }

    static func average(_ cores: [CPUUsage]) -> CPUUsage {
        guard !cores.isEmpty else { return .zero }
        let count = Double(cores.count)
        return CPUUsage(user: cores.map(\.user).reduce(0, +) / count, system: cores.map(\.system).reduce(0, +) / count)
    }
}

nonisolated enum CoreKind: Sendable {
    case performance
    case efficiency
}

nonisolated enum MonitorTime {
    /// On Apple silicon, mach ticks are not nanoseconds (timebase 125/3).
    static func nanoseconds(machTicks: UInt64, numer: UInt32, denom: UInt32) -> UInt64 {
        guard denom > 0 else { return machTicks }
        let product = machTicks.multipliedFullWidth(by: UInt64(numer))
        return UInt64(denom).dividingFullWidth(product).quotient
    }

    /// Percent of one core, as Activity Monitor shows it (a busy 4-thread process reads 400 %).
    static func cpuPercent(cpuNanoseconds: UInt64, elapsedNanoseconds: UInt64) -> Double {
        guard elapsedNanoseconds > 0 else { return 0 }
        return Double(cpuNanoseconds) / Double(elapsedNanoseconds) * 100
    }

    static func rate(from old: UInt64, to new: UInt64, seconds: Double) -> Double {
        guard seconds > 0, new >= old else { return 0 }
        return Double(new - old) / seconds
    }
}

nonisolated struct MemoryUsage: Equatable, Sendable {
    var total: UInt64
    var app: UInt64
    var wired: UInt64
    var compressed: UInt64
    var cached: UInt64

    /// Same split as Activity Monitor: used = app + wired + compressed.
    var used: UInt64 { app + wired + compressed }

    init(total: UInt64, app: UInt64, wired: UInt64, compressed: UInt64, cached: UInt64) {
        self.total = total
        self.app = app
        self.wired = wired
        self.compressed = compressed
        self.cached = cached
    }

    init(pageSize: UInt64, total: UInt64, internalPages: UInt64, purgeablePages: UInt64,
         externalPages: UInt64, wiredPages: UInt64, compressorPages: UInt64) {
        self.init(
            total: total,
            app: (internalPages > purgeablePages ? internalPages - purgeablePages : 0) * pageSize,
            wired: wiredPages * pageSize,
            compressed: compressorPages * pageSize,
            cached: (externalPages + purgeablePages) * pageSize
        )
    }
}

nonisolated enum MemoryPressure: Int, Sendable {
    case normal = 1
    case warning = 2
    case critical = 4
}

nonisolated struct BatteryInfo: Equatable, Sendable {
    var percent: Int
    var isCharging: Bool
    var isPluggedIn: Bool
    var isFullyCharged: Bool
    var minutesRemaining: Int?
    var cycleCount: Int?
    var health: Double?
    var temperature: Double?
    var adapterWatts: Int?

    /// `registry` is the AppleSmartBattery property dictionary; recent macOS moves the
    /// capacity keys into its "BatteryData" sub-dictionary.
    init?(registry: [String: Any], adapterWatts: Int?) {
        let nested = registry["BatteryData"] as? [String: Any] ?? [:]
        func int(_ key: String) -> Int? {
            (registry[key] as? NSNumber ?? nested[key] as? NSNumber)?.intValue
        }
        guard registry["BatteryInstalled"] as? Bool != false, let current = int("CurrentCapacity") else { return nil }
        let maxCapacity = int("MaxCapacity") ?? 100
        percent = maxCapacity > 0 ? Int((Double(current) / Double(maxCapacity) * 100).rounded()) : current
        isCharging = registry["IsCharging"] as? Bool ?? false
        isPluggedIn = registry["ExternalConnected"] as? Bool ?? false
        isFullyCharged = registry["FullyCharged"] as? Bool ?? false
        let minutes = isCharging ? int("AvgTimeToFull") : int("TimeRemaining") ?? int("AvgTimeToEmpty")
        minutesRemaining = minutes.flatMap { $0 > 0 && $0 < 65535 ? $0 : nil }
        cycleCount = int("CycleCount")
        health = Self.health(design: int("DesignCapacity"),
                             full: int("NominalChargeCapacity") ?? int("AppleRawMaxCapacity") ?? (maxCapacity > 100 ? maxCapacity : nil))
        temperature = int("Temperature").flatMap { $0 > 0 ? Double($0) / 100 : nil }
        self.adapterWatts = adapterWatts
    }

    static func health(design: Int?, full: Int?) -> Double? {
        guard let design, let full, design > 0, full > 0 else { return nil }
        return min(1, Double(full) / Double(design))
    }
}

nonisolated enum PortProtocol: String, Sendable {
    case tcp = "TCP"
    case udp = "UDP"
}

nonisolated enum PortScope: Int, Comparable, Sendable {
    case localhost
    case specific
    case allInterfaces

    init(address: String) {
        switch address {
        case "0.0.0.0", "::", "*": self = .allInterfaces
        case "::1": self = .localhost
        default: self = address.hasPrefix("127.") || address.hasPrefix("::ffff:127.") ? .localhost : .specific
        }
    }

    static func < (lhs: PortScope, rhs: PortScope) -> Bool { lhs.rawValue < rhs.rawValue }
}

nonisolated struct SocketEntry: Hashable, Sendable {
    var pid: Int32
    var processName: String
    var proto: PortProtocol
    var port: UInt16
    var address: String
}

nonisolated struct ListeningPort: Identifiable, Hashable, Sendable {
    var pid: Int32
    var processName: String
    var proto: PortProtocol
    var port: UInt16
    var scope: PortScope
    var addresses: [String]

    var id: String { "\(proto.rawValue)-\(port)-\(pid)" }

    /// One row per process, protocol and port: the IPv4 and IPv6 sockets of a
    /// server merge, and the row keeps its widest exposure.
    static func group(_ sockets: [SocketEntry]) -> [ListeningPort] {
        var rows: [String: ListeningPort] = [:]
        for socket in sockets {
            let scope = PortScope(address: socket.address)
            let key = "\(socket.proto.rawValue)-\(socket.port)-\(socket.pid)"
            if var row = rows[key] {
                row.scope = max(row.scope, scope)
                if !row.addresses.contains(socket.address) { row.addresses.append(socket.address) }
                rows[key] = row
            } else {
                rows[key] = ListeningPort(pid: socket.pid, processName: socket.processName, proto: socket.proto,
                                          port: socket.port, scope: scope, addresses: [socket.address])
            }
        }
        return rows.values.sorted {
            ($0.port, $0.proto.rawValue, $0.pid) < ($1.port, $1.proto.rawValue, $1.pid)
        }
    }
}
