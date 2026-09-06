import Foundation
import Darwin

/// Permission-free machine counters. Same rule as `SystemSensors`: everything
/// here is a public kernel statistic, so nothing triggers a TCC prompt and
/// nothing needs an entitlement.
///
/// These are all *counters*, not rates — CPU ticks and interface byte totals
/// only mean something as a delta between two reads. `StatsHub` owns the
/// differencing; this file just reads.
enum SystemMetrics {

    // MARK: CPU

    /// See `CPUTicks` — the arithmetic lives in the public layer so it can be
    /// unit-tested without a running kernel.
    static func cpuTicks() -> CPUTicks? {
        var info = host_cpu_load_info()
        var count = mach_msg_type_number_t(MemoryLayout<host_cpu_load_info_data_t>.size
                                           / MemoryLayout<integer_t>.size)
        let status = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics(mach_host_self(), HOST_CPU_LOAD_INFO, $0, &count)
            }
        }
        guard status == KERN_SUCCESS else { return nil }
        return CPUTicks(user: UInt64(info.cpu_ticks.0),
                        system: UInt64(info.cpu_ticks.1),
                        idle: UInt64(info.cpu_ticks.2),
                        nice: UInt64(info.cpu_ticks.3))
    }

    // MARK: Memory

    /// Bytes in use and installed. "Used" follows Activity Monitor's Memory
    /// Used — resident app pages plus wired plus compressed — rather than
    /// "anything not free", which on macOS is always ~100% because the cache
    /// keeps every spare page.
    static func memory() -> (used: UInt64, total: UInt64)? {
        var stats = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64_data_t>.size
                                           / MemoryLayout<integer_t>.size)
        let status = withUnsafeMutablePointer(to: &stats) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
            }
        }
        guard status == KERN_SUCCESS else { return nil }

        let page = UInt64(vm_kernel_page_size)
        let used = (UInt64(stats.active_count)
                    + UInt64(stats.wire_count)
                    + UInt64(stats.compressor_page_count)) * page
        let total = ProcessInfo.processInfo.physicalMemory
        guard total > 0 else { return nil }
        return (min(used, total), total)
    }

    // MARK: Network

    /// Cumulative bytes in/out across every up, non-loopback interface.
    ///
    /// Read from the link-layer (`AF_LINK`) entries `getifaddrs` returns, which
    /// carry the per-interface `if_data` counters. Loopback is excluded because
    /// local traffic is not what "am I using the network" means.
    static func networkBytes() -> (received: UInt64, sent: UInt64) {
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0, let first = head else { return (0, 0) }
        defer { freeifaddrs(head) }

        var received: UInt64 = 0
        var sent: UInt64 = 0
        for entry in sequence(first: first, next: { $0.pointee.ifa_next }) {
            guard entry.pointee.ifa_addr?.pointee.sa_family == UInt8(AF_LINK) else { continue }
            let flags = Int32(entry.pointee.ifa_flags)
            guard flags & IFF_UP != 0, flags & IFF_LOOPBACK == 0 else { continue }
            guard let data = entry.pointee.ifa_data?.assumingMemoryBound(to: if_data.self)
            else { continue }
            received &+= UInt64(data.pointee.ifi_ibytes)
            sent &+= UInt64(data.pointee.ifi_obytes)
        }
        return (received, sent)
    }

    // MARK: Misc

    /// One-minute load average, or 0 when the kernel won't say.
    static func loadAverage() -> Double {
        var loads = [Double](repeating: 0, count: 3)
        guard getloadavg(&loads, 3) == 3 else { return 0 }
        return loads[0]
    }

    /// Total capacity of the boot volume, for the disk meter's denominator.
    static func diskTotalBytes() -> Int64 {
        let url = URL(fileURLWithPath: "/")
        let values = try? url.resourceValues(forKeys: [.volumeTotalCapacityKey])
        return Int64(values?.volumeTotalCapacity ?? 0)
    }

    /// Physical cores, for the load-average scale.
    static var coreCount: Int { ProcessInfo.processInfo.activeProcessorCount }
}
