import Foundation
import Testing
@testable import RadixCore

struct MonitorMathTests {
    @Test
    func testCPUUsageFromTickDeltasIncludingWrap() {
        let old = CPUTicks(user: 100, system: 50, idle: 800, nice: 50)
        let new = CPUTicks(user: 160, system: 70, idle: 900, nice: 60)
        let usage = CPUUsage(from: old, to: new)
        #expect(abs(usage.user - 70.0 / 190.0) < 1e-9)
        #expect(abs(usage.system - 20.0 / 190.0) < 1e-9)

        let wrapped = CPUUsage(from: CPUTicks(user: .max - 9, system: 0, idle: 0, nice: 0),
                               to: CPUTicks(user: 10, system: 0, idle: 20, nice: 0))
        #expect(abs(wrapped.user - 0.5) < 1e-9)
        #expect(CPUUsage(from: old, to: old) == .zero)
        #expect(abs(CPUUsage.average([CPUUsage(user: 1, system: 0), CPUUsage(user: 0, system: 0.5)]).total - 0.75) < 1e-9)
    }

    @Test
    func testMachTimeConversionAndProcessPercent() {
        #expect(MonitorTime.nanoseconds(machTicks: 24_000_000, numer: 125, denom: 3) == 1_000_000_000)
        #expect(MonitorTime.nanoseconds(machTicks: 42, numer: 1, denom: 1) == 42)
        #expect(MonitorTime.nanoseconds(machTicks: 1 << 58, numer: 125, denom: 3) == 12_009_599_006_321_322_666)
        #expect(MonitorTime.cpuPercent(cpuNanoseconds: 2_000_000_000, elapsedNanoseconds: 1_000_000_000) == 200)
        #expect(MonitorTime.cpuPercent(cpuNanoseconds: 1, elapsedNanoseconds: 0) == 0)
        #expect(MonitorTime.rate(from: 1_000, to: 3_000, seconds: 2) == 1_000)
        #expect(MonitorTime.rate(from: 3_000, to: 1_000, seconds: 2) == 0)
    }

    @Test
    func testMemoryUsedMatchesActivityMonitor() {
        let memory = MemoryUsage(pageSize: 16_384, total: 16 << 30, internalPages: 500_000, purgeablePages: 20_000,
                                 externalPages: 100_000, wiredPages: 150_000, compressorPages: 50_000)
        #expect(memory.app == 480_000 * 16_384)
        #expect(memory.cached == 120_000 * 16_384)
        #expect(memory.used == (480_000 + 150_000 + 50_000) * 16_384)
    }

    @Test
    func testRingBufferKeepsLastSixtySamples() {
        var buffer = RingBuffer<Int>(capacity: 60)
        for value in 0..<75 { buffer.append(value) }
        #expect(buffer.elements.count == 60)
        #expect(buffer.elements.first == 15)
        #expect(buffer.elements.last == 74)
    }

    @Test
    func testBatteryHealthFromRegistryDictionaries() throws {
        let appleSilicon: [String: Any] = [
            "CurrentCapacity": 52, "MaxCapacity": 100, "CycleCount": 683, "IsCharging": false,
            "ExternalConnected": false, "TimeRemaining": 46, "AvgTimeToFull": 65535,
            "BatteryData": ["DesignCapacity": 6249, "NominalChargeCapacity": 5251, "AppleRawMaxCapacity": 5099],
        ]
        let battery = try #require(BatteryInfo(registry: appleSilicon, adapterWatts: nil))
        #expect(battery.percent == 52)
        #expect(battery.minutesRemaining == 46)
        #expect(battery.cycleCount == 683)
        #expect(abs((battery.health ?? 0) - 5251.0 / 6249.0) < 1e-9)
        #expect(battery.temperature == nil)

        let intel: [String: Any] = [
            "CurrentCapacity": 3000, "MaxCapacity": 6000, "DesignCapacity": 5000, "IsCharging": true,
            "AvgTimeToFull": 65535, "Temperature": 3050,
        ]
        let charging = try #require(BatteryInfo(registry: intel, adapterWatts: 96))
        #expect(charging.percent == 50)
        #expect(charging.health == 1)
        #expect(charging.minutesRemaining == nil)
        #expect(charging.temperature == 30.5)

        #expect(BatteryInfo(registry: ["BatteryInstalled": false, "CurrentCapacity": 0], adapterWatts: nil) == nil)
        #expect(BatteryInfo.health(design: 0, full: 10) == nil)
    }

    @Test
    func testPortsMergeIPv4AndIPv6AndKeepWidestExposure() {
        let sockets = [
            SocketEntry(pid: 10, processName: "node", proto: .tcp, port: 3000, address: "127.0.0.1"),
            SocketEntry(pid: 10, processName: "node", proto: .tcp, port: 3000, address: "::"),
            SocketEntry(pid: 10, processName: "node", proto: .tcp, port: 3000, address: "::"),
            SocketEntry(pid: 20, processName: "postgres", proto: .tcp, port: 5432, address: "::1"),
            SocketEntry(pid: 20, processName: "postgres", proto: .tcp, port: 5432, address: "127.0.0.1"),
            SocketEntry(pid: 30, processName: "mdns", proto: .udp, port: 5353, address: "192.168.1.4"),
            SocketEntry(pid: 30, processName: "mdns", proto: .tcp, port: 5353, address: "0.0.0.0"),
        ]
        let ports = ListeningPort.group(sockets)
        #expect(ports.map(\.port) == [3000, 5353, 5353, 5432])
        #expect(ports[0].scope == .allInterfaces)
        #expect(ports[0].addresses == ["127.0.0.1", "::"])
        #expect(ports[1].proto == .tcp && ports[1].scope == .allInterfaces)
        #expect(ports[2].proto == .udp && ports[2].scope == .specific)
        #expect(ports[3].scope == .localhost)
        #expect(PortScope(address: "::ffff:127.0.0.1") == .localhost)
    }

    @Test
    func testLiveSamplerProducesPlausibleValues() async throws {
        let sampler = MonitorSampler()
        let first = await sampler.sample(includeSlow: true)
        #expect(first.cores == nil)
        #expect(first.memory.used > 0 && first.memory.used <= first.memory.total)
        try await Task.sleep(for: .milliseconds(300))
        let second = await sampler.sample(includeSlow: false)
        let cores = try #require(second.cores)
        #expect(cores.count == ProcessInfo.processInfo.processorCount)
        #expect(cores.allSatisfy { $0.total >= 0 && $0.total <= 1 })
        #expect(second.topByCPU?.isEmpty == false)
        #expect(second.topByMemory.first.map { $0.memory > 0 && !$0.name.isEmpty } == true)
    }
}
