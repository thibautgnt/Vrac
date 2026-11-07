import AppKit
import Combine
import SwiftUI

@MainActor
final class MonitorRoomModel: ObservableObject {
    static let shared = MonitorRoomModel()
    static let historyLength = 60

    @Published private(set) var cores: [CPUUsage] = []
    @Published private(set) var cpuHistory = RingBuffer<CPUUsage>(capacity: historyLength)
    @Published private(set) var memory: MemoryUsage?
    @Published private(set) var memoryHistory = RingBuffer<Double>(capacity: historyLength)
    @Published private(set) var swapUsed: UInt64 = 0
    @Published private(set) var pressure = MemoryPressure.normal
    @Published private(set) var loadAverage: [Double] = []
    @Published private(set) var topByCPU: [ProcessSample] = []
    @Published private(set) var topByMemory: [ProcessSample] = []
    @Published private(set) var diskHistory = RingBuffer<DiskRates>(capacity: historyLength)
    @Published private(set) var ports: [ListeningPort]?
    @Published private(set) var battery: BatteryInfo?
    @Published private(set) var volume: VolumeSpace?

    let coreKinds = MonitorSampler.coreKinds()
    private var task: Task<Void, Never>?
    private var runningApps: [Int32: NSRunningApplication] = [:]
    private var icons: [String: NSImage] = [:]

    var cpu: CPUUsage? { cores.isEmpty ? nil : CPUUsage.average(cores) }

    /// Sampling runs only while the room is on screen; each start begins fresh deltas and history.
    func start() {
        guard task == nil else { return }
        cpuHistory = RingBuffer(capacity: Self.historyLength)
        memoryHistory = RingBuffer(capacity: Self.historyLength)
        diskHistory = RingBuffer(capacity: Self.historyLength)
        let sampler = MonitorSampler()
        task = Task { [weak self] in
            var tick = 0
            while !Task.isCancelled {
                let snapshot = await sampler.sample(includeSlow: tick % 5 == 0)
                guard !Task.isCancelled, let self else { return }
                self.apply(snapshot)
                tick += 1
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }

    func stop() {
        task?.cancel()
        task = nil
    }

    func application(for pid: Int32) -> NSRunningApplication? {
        runningApps[pid]
    }

    func displayName(of process: ProcessSample) -> String {
        runningApps[process.pid]?.localizedName ?? process.name
    }

    /// Small copies, so redraws pick the 16 pt representation instead of scaling a 1024 px one.
    func icon(of process: ProcessSample) -> NSImage {
        let app = runningApps[process.pid]
        let key = app?.bundleURL?.path ?? process.path ?? "/bin/sh"
        if let icon = icons[key] { return icon }
        let source = app?.icon ?? NSWorkspace.shared.icon(forFile: key)
        let icon = source.copy() as? NSImage ?? source
        icon.size = NSSize(width: 18, height: 18)
        icons[key] = icon
        return icon
    }

    func revealURL(of process: ProcessSample) -> URL? {
        runningApps[process.pid]?.bundleURL ?? process.path.map(URL.init(fileURLWithPath:))
    }

    private func apply(_ snapshot: MonitorSnapshot) {
        runningApps = Dictionary(NSWorkspace.shared.runningApplications.map { ($0.processIdentifier, $0) }) { first, _ in first }
        if let cores = snapshot.cores {
            self.cores = cores
            cpuHistory.append(CPUUsage.average(cores))
        }
        memory = snapshot.memory
        memoryHistory.append(snapshot.memory.total > 0 ? Double(snapshot.memory.used) / Double(snapshot.memory.total) : 0)
        swapUsed = snapshot.swapUsed
        pressure = snapshot.pressure
        loadAverage = snapshot.loadAverage
        if let top = snapshot.topByCPU { topByCPU = top }
        topByMemory = snapshot.topByMemory
        if let disk = snapshot.disk { diskHistory.append(disk) }
        if let slow = snapshot.slow {
            ports = slow.ports
            battery = slow.battery
            volume = slow.volume
        }
    }
}
