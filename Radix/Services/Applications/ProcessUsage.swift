import Darwin
import Foundation

nonisolated struct AppProcessSample: Sendable {
    let cpuNanoseconds: UInt64
    let memoryBytes: UInt64
    let uptimeNanoseconds: UInt64
}

nonisolated enum ProcessUsage {
    static func sample(pid: pid_t) -> AppProcessSample? {
        var info = rusage_info_v4()
        let status = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) {
                proc_pid_rusage(pid, RUSAGE_INFO_V4, $0)
            }
        }
        guard status == 0 else { return nil }
        // rusage CPU times are in Mach absolute time units, which are not nanoseconds on Apple silicon.
        var timebase = mach_timebase_info_data_t()
        mach_timebase_info(&timebase)
        let ticks = info.ri_user_time + info.ri_system_time
        return AppProcessSample(
            cpuNanoseconds: ticks * UInt64(timebase.numer) / UInt64(max(timebase.denom, 1)),
            memoryBytes: info.ri_phys_footprint,
            uptimeNanoseconds: DispatchTime.now().uptimeNanoseconds
        )
    }

    /// Share of one core used between two samples, as in Activity Monitor (can exceed 100).
    static func cpuPercent(from old: AppProcessSample, to new: AppProcessSample) -> Double {
        guard new.uptimeNanoseconds > old.uptimeNanoseconds, new.cpuNanoseconds >= old.cpuNanoseconds else { return 0 }
        return Double(new.cpuNanoseconds - old.cpuNanoseconds) / Double(new.uptimeNanoseconds - old.uptimeNanoseconds) * 100
    }
}
