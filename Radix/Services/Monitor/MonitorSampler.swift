import Darwin
import Foundation
import IOKit
import IOKit.ps

nonisolated struct ProcessSample: Identifiable, Hashable, Sendable {
    var pid: Int32
    var name: String
    var path: String?
    var cpuPercent: Double
    var memory: UInt64

    var id: Int32 { pid }
}

nonisolated struct VolumeSpace: Equatable, Sendable {
    var name: String
    var available: Int64
    var total: Int64
}

nonisolated struct DiskRates: Equatable, Sendable {
    var read: Double
    var write: Double
}

nonisolated struct MonitorSnapshot: Sendable {
    var cores: [CPUUsage]?
    var memory: MemoryUsage
    var swapUsed: UInt64
    var swapTotal: UInt64
    var pressure: MemoryPressure
    var loadAverage: [Double]
    var topByCPU: [ProcessSample]?
    var topByMemory: [ProcessSample] = []
    var disk: DiskRates?
    var slow: SlowSample?
}

/// Sampled every few seconds only: ports, battery and startup volume change slowly.
nonisolated struct SlowSample: Sendable {
    var ports: [ListeningPort]
    var battery: BatteryInfo?
    var volume: VolumeSpace?
}

/// Owns the previous counters needed for deltas; one instance per visible session.
actor MonitorSampler {
    private let host = mach_host_self()
    private let timebase: mach_timebase_info_data_t = {
        var info = mach_timebase_info_data_t()
        mach_timebase_info(&info)
        return info
    }()
    private var previousCores: [CPUTicks]?
    private var previousProcessTimes: [Int32: UInt64] = [:]
    private var previousProcessClock: UInt64?
    private var previousDisk: (read: UInt64, write: UInt64, clock: UInt64)?

    func sample(includeSlow: Bool) -> MonitorSnapshot {
        let swap = Self.swapUsage()
        var snapshot = MonitorSnapshot(
            cores: coreUsage(),
            memory: memoryUsage(),
            swapUsed: swap.used,
            swapTotal: swap.total,
            pressure: Self.memoryPressure(),
            loadAverage: Self.loadAverage()
        )
        let processes = processSamples()
        if let processes {
            snapshot.topByCPU = Array(processes.sorted { $0.cpuPercent > $1.cpuPercent }.prefix(10)).map(Self.named)
        }
        snapshot.topByMemory = Array((processes ?? []).sorted { $0.memory > $1.memory }.prefix(10)).map(Self.named)
        snapshot.disk = diskRates()
        if includeSlow {
            snapshot.slow = SlowSample(ports: PortSampler.listeningPorts(), battery: Self.battery(), volume: Self.startupVolume())
        }
        return snapshot
    }

    nonisolated static func coreKinds() -> [CoreKind]? {
        guard sysctlInt("hw.nperflevels") ?? 1 > 1 else { return nil }
        let cpus = IORegistryEntryFromPath(kIOMainPortDefault, "IODeviceTree:/cpus")
        guard cpus != 0 else { return nil }
        defer { IOObjectRelease(cpus) }
        var iterator: io_iterator_t = 0
        guard IORegistryEntryGetChildIterator(cpus, kIODeviceTreePlane, &iterator) == KERN_SUCCESS else { return nil }
        defer { IOObjectRelease(iterator) }
        var kinds: [Int: CoreKind] = [:]
        while case let entry = IOIteratorNext(iterator), entry != 0 {
            defer { IOObjectRelease(entry) }
            guard let id = registryProperty(entry, "logical-cpu-id") as? NSNumber,
                  let type = (registryProperty(entry, "cluster-type") as? Data)?.first else { continue }
            kinds[id.intValue] = type == UInt8(ascii: "E") ? .efficiency : .performance
        }
        let ordered = (0..<kinds.count).compactMap { kinds[$0] }
        return ordered.count == kinds.count && !ordered.isEmpty ? ordered : nil
    }

    private func coreUsage() -> [CPUUsage]? {
        var cpuCount: natural_t = 0
        var info: processor_info_array_t?
        var infoCount: mach_msg_type_number_t = 0
        guard host_processor_info(host, PROCESSOR_CPU_LOAD_INFO, &cpuCount, &info, &infoCount) == KERN_SUCCESS,
              let info else { return nil }
        defer {
            vm_deallocate(mach_task_self_, vm_address_t(bitPattern: info), vm_size_t(Int(infoCount) * MemoryLayout<integer_t>.stride))
        }
        let ticks = (0..<Int(cpuCount)).map { core in
            let base = core * Int(CPU_STATE_MAX)
            return CPUTicks(
                user: UInt32(bitPattern: info[base + Int(CPU_STATE_USER)]),
                system: UInt32(bitPattern: info[base + Int(CPU_STATE_SYSTEM)]),
                idle: UInt32(bitPattern: info[base + Int(CPU_STATE_IDLE)]),
                nice: UInt32(bitPattern: info[base + Int(CPU_STATE_NICE)])
            )
        }
        defer { previousCores = ticks }
        guard let previousCores, previousCores.count == ticks.count else { return nil }
        return zip(previousCores, ticks).map { CPUUsage(from: $0, to: $1) }
    }

    private func memoryUsage() -> MemoryUsage {
        var stats = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64_data_t>.stride / MemoryLayout<integer_t>.stride)
        _ = withUnsafeMutablePointer(to: &stats) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(host, HOST_VM_INFO64, $0, &count)
            }
        }
        return MemoryUsage(
            pageSize: UInt64(getpagesize()),
            total: ProcessInfo.processInfo.physicalMemory,
            internalPages: UInt64(stats.internal_page_count),
            purgeablePages: UInt64(stats.purgeable_count),
            externalPages: UInt64(stats.external_page_count),
            wiredPages: UInt64(stats.wire_count),
            compressorPages: UInt64(stats.compressor_page_count)
        )
    }

    /// Returns nil on the first call, which only records the starting counters.
    private func processSamples() -> [ProcessSample]? {
        let now = clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
        var times: [Int32: UInt64] = [:]
        var samples: [ProcessSample] = []
        let elapsed = previousProcessClock.map { now - $0 }
        for pid in Self.allPIDs() {
            var usage = rusage_info_v4()
            let result = withUnsafeMutablePointer(to: &usage) {
                $0.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(pid, RUSAGE_INFO_V4, $0) }
            }
            guard result == 0 else { continue }
            let cpu = MonitorTime.nanoseconds(machTicks: usage.ri_user_time + usage.ri_system_time,
                                              numer: timebase.numer, denom: timebase.denom)
            times[pid] = cpu
            var percent = 0.0
            if let elapsed, let old = previousProcessTimes[pid], cpu >= old {
                percent = MonitorTime.cpuPercent(cpuNanoseconds: cpu - old, elapsedNanoseconds: elapsed)
            }
            samples.append(ProcessSample(pid: pid, name: "", cpuPercent: percent, memory: usage.ri_phys_footprint))
        }
        previousProcessTimes = times
        previousProcessClock = now
        return elapsed == nil ? nil : samples
    }

    private func diskRates() -> DiskRates? {
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOBlockStorageDriver"), &iterator) == KERN_SUCCESS else {
            return nil
        }
        defer { IOObjectRelease(iterator) }
        var read: UInt64 = 0
        var write: UInt64 = 0
        while case let entry = IOIteratorNext(iterator), entry != 0 {
            defer { IOObjectRelease(entry) }
            guard let stats = IORegistryEntryCreateCFProperty(entry, "Statistics" as CFString, kCFAllocatorDefault, 0)?
                .takeRetainedValue() as? [String: Any] else { continue }
            read += (stats["Bytes (Read)"] as? NSNumber)?.uint64Value ?? 0
            write += (stats["Bytes (Write)"] as? NSNumber)?.uint64Value ?? 0
        }
        let now = clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
        defer { previousDisk = (read, write, now) }
        guard let previousDisk else { return nil }
        let seconds = Double(now - previousDisk.clock) / 1e9
        return DiskRates(read: MonitorTime.rate(from: previousDisk.read, to: read, seconds: seconds),
                         write: MonitorTime.rate(from: previousDisk.write, to: write, seconds: seconds))
    }

    nonisolated static func allPIDs() -> [Int32] {
        let estimate = proc_listallpids(nil, 0)
        guard estimate > 0 else { return [] }
        var pids = [Int32](repeating: 0, count: Int(estimate) + 64)
        let count = proc_listallpids(&pids, Int32(pids.count * MemoryLayout<Int32>.size))
        return pids.prefix(Int(max(0, count))).filter { $0 > 0 }
    }

    nonisolated static func path(of pid: Int32) -> String? {
        var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN) * 4)
        guard proc_pidpath(pid, &buffer, UInt32(buffer.count)) > 0 else { return nil }
        return String(cString: buffer)
    }

    /// The kernel name is truncated to 32 characters, the executable file name is not but can
    /// be meaningless (a versioned binary such as "2.1.319"), so the file name wins only when it extends it.
    nonisolated static func name(of pid: Int32, path: String?) -> String {
        var buffer = [CChar](repeating: 0, count: 256)
        proc_name(pid, &buffer, UInt32(buffer.count))
        let short = String(cString: buffer)
        let file = path.map { ($0 as NSString).lastPathComponent }
        if let file, short.isEmpty || file.hasPrefix(short) { return file }
        return short.isEmpty ? String(pid) : short
    }

    private static func named(_ sample: ProcessSample) -> ProcessSample {
        var sample = sample
        sample.path = path(of: sample.pid)
        sample.name = name(of: sample.pid, path: sample.path)
        return sample
    }

    private static func swapUsage() -> (used: UInt64, total: UInt64) {
        var swap = xsw_usage()
        var size = MemoryLayout<xsw_usage>.size
        guard sysctlbyname("vm.swapusage", &swap, &size, nil, 0) == 0 else { return (0, 0) }
        return (swap.xsu_used, swap.xsu_total)
    }

    private static func memoryPressure() -> MemoryPressure {
        sysctlInt("kern.memorystatus_vm_pressure_level").flatMap(MemoryPressure.init(rawValue:)) ?? .normal
    }

    private static func loadAverage() -> [Double] {
        var loads = [Double](repeating: 0, count: 3)
        return getloadavg(&loads, 3) == 3 ? loads : []
    }

    private static func battery() -> BatteryInfo? {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSmartBattery"))
        guard service != 0 else { return nil }
        defer { IOObjectRelease(service) }
        var properties: Unmanaged<CFMutableDictionary>?
        guard IORegistryEntryCreateCFProperties(service, &properties, kCFAllocatorDefault, 0) == KERN_SUCCESS,
              let registry = properties?.takeRetainedValue() as? [String: Any] else { return nil }
        let adapter = IOPSCopyExternalPowerAdapterDetails()?.takeRetainedValue() as? [String: Any]
        return BatteryInfo(registry: registry, adapterWatts: (adapter?[kIOPSPowerAdapterWattsKey] as? NSNumber)?.intValue)
    }

    private static func startupVolume() -> VolumeSpace? {
        let keys: Set<URLResourceKey> = [.volumeLocalizedNameKey, .volumeAvailableCapacityForImportantUsageKey, .volumeTotalCapacityKey]
        guard let values = try? URL(fileURLWithPath: "/").resourceValues(forKeys: keys),
              let total = values.volumeTotalCapacity,
              let available = values.volumeAvailableCapacityForImportantUsage else { return nil }
        return VolumeSpace(name: values.volumeLocalizedName ?? "/", available: available, total: Int64(total))
    }

    private nonisolated static func sysctlInt(_ name: String) -> Int? {
        var value: Int32 = 0
        var size = MemoryLayout<Int32>.size
        return sysctlbyname(name, &value, &size, nil, 0) == 0 ? Int(value) : nil
    }

    private nonisolated static func registryProperty(_ entry: io_registry_entry_t, _ key: String) -> Any? {
        IORegistryEntryCreateCFProperty(entry, key as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue()
    }
}
