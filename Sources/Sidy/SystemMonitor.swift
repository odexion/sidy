import Darwin
import Foundation
import IOKit
import IOKit.ps
import Observation

struct BatteryInfo {
    var level: Double
    var charging: Bool
    var pluggedIn: Bool
    var minutesRemaining: Int?
}

/// Samples CPU, GPU, memory, disk, network, battery and thermals every two seconds.
@Observable
final class SystemMonitor {
    static let historyLength = 20

    var cpu = 0.0
    var cpuHistory = Array(repeating: 0.0, count: historyLength)
    var gpu = 0.0
    var gpuHistory = Array(repeating: 0.0, count: historyLength)
    var memoryUsed: UInt64 = 0
    let memoryTotal = ProcessInfo.processInfo.physicalMemory
    var diskFree: Int64 = 0
    var diskTotal: Int64 = 0
    var download = 0.0
    var upload = 0.0
    var downloadHistory = Array(repeating: 0.0, count: historyLength)
    var uploadHistory = Array(repeating: 0.0, count: historyLength)
    var battery: BatteryInfo?
    var thermal = ProcessInfo.processInfo.thermalState
    var loadAverage = [0.0, 0.0, 0.0]
    let cores = ProcessInfo.processInfo.activeProcessorCount
    let bootDate = SystemMonitor.readBootDate()

    private let interval = 2.0
    private var timer: Timer?
    private var tick = 0
    private var previousCPU: (busy: Double, total: Double)?
    private var previousNet: [String: (rx: UInt32, tx: UInt32)] = [:]

    func start() {
        sample()
        timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in self?.sample() }
    }

    private func sample() {
        if let value = sampleCPU() { cpu = value; push(value, to: &cpuHistory) }
        if let value = sampleGPU() { gpu = value; push(value, to: &gpuHistory) }
        memoryUsed = sampleMemory()
        sampleNetwork()
        if tick % 15 == 0 {
            sampleDisk()
            battery = sampleBattery()
        }
        thermal = ProcessInfo.processInfo.thermalState
        getloadavg(&loadAverage, 3)
        tick += 1
    }

    private func push(_ value: Double, to history: inout [Double]) {
        history.removeFirst()
        history.append(value)
    }

    // MARK: CPU

    private func sampleCPU() -> Double? {
        var count: natural_t = 0
        var info: processor_info_array_t?
        var infoCount: mach_msg_type_number_t = 0
        guard host_processor_info(mach_host_self(), PROCESSOR_CPU_LOAD_INFO, &count, &info, &infoCount) == KERN_SUCCESS,
              let info else { return nil }
        defer {
            vm_deallocate(mach_task_self_, vm_address_t(bitPattern: info),
                          vm_size_t(Int(infoCount) * MemoryLayout<integer_t>.stride))
        }

        var busy = 0.0, total = 0.0
        for core in 0..<Int(count) {
            let ticks = { (state: Int32) in Double(UInt32(bitPattern: info[core * Int(CPU_STATE_MAX) + Int(state)])) }
            let used = ticks(CPU_STATE_USER) + ticks(CPU_STATE_SYSTEM) + ticks(CPU_STATE_NICE)
            busy += used
            total += used + ticks(CPU_STATE_IDLE)
        }
        defer { previousCPU = (busy, total) }
        guard let previous = previousCPU, total > previous.total else { return nil }
        return min(max((busy - previous.busy) / (total - previous.total), 0), 1)
    }

    // MARK: GPU

    private func sampleGPU() -> Double? {
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOAccelerator"), &iterator) == KERN_SUCCESS
        else { return nil }
        defer { IOObjectRelease(iterator) }

        var result: Double?
        var entry = IOIteratorNext(iterator)
        while entry != 0 {
            if let stats = IORegistryEntryCreateCFProperty(entry, "PerformanceStatistics" as CFString, kCFAllocatorDefault, 0)?
                .takeRetainedValue() as? [String: Any],
               let utilization = stats["Device Utilization %"] as? Int {
                result = max(result ?? 0, Double(utilization) / 100)
            }
            IOObjectRelease(entry)
            entry = IOIteratorNext(iterator)
        }
        return result
    }

    // MARK: Memory

    /// Matches Activity Monitor's "Memory Used": app memory + wired + compressed.
    private func sampleMemory() -> UInt64 {
        var stats = vm_statistics64()
        var size = mach_msg_type_number_t(MemoryLayout<vm_statistics64_data_t>.stride / MemoryLayout<integer_t>.stride)
        let status = withUnsafeMutablePointer(to: &stats) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(size)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &size)
            }
        }
        guard status == KERN_SUCCESS else { return memoryUsed }
        let pages = UInt64(stats.internal_page_count) - UInt64(stats.purgeable_count)
            + UInt64(stats.wire_count) + UInt64(stats.compressor_page_count)
        return pages * UInt64(vm_kernel_page_size)
    }

    // MARK: Disk

    private func sampleDisk() {
        let keys: Set<URLResourceKey> = [.volumeTotalCapacityKey, .volumeAvailableCapacityForImportantUsageKey]
        guard let values = try? URL(fileURLWithPath: "/").resourceValues(forKeys: keys) else { return }
        diskTotal = Int64(values.volumeTotalCapacity ?? 0)
        diskFree = values.volumeAvailableCapacityForImportantUsage ?? 0
    }

    // MARK: Network

    /// Sums physical (en*) interfaces. Counters are 32-bit, so deltas use wrapping subtraction.
    private func sampleNetwork() {
        var addresses: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&addresses) == 0, let first = addresses else { return }
        defer { freeifaddrs(addresses) }

        var rx: UInt64 = 0, tx: UInt64 = 0
        var current: [String: (rx: UInt32, tx: UInt32)] = [:]
        for pointer in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let entry = pointer.pointee
            guard entry.ifa_addr?.pointee.sa_family == UInt8(AF_LINK),
                  entry.ifa_flags & UInt32(IFF_UP) != 0,
                  let data = entry.ifa_data?.assumingMemoryBound(to: if_data.self).pointee else { continue }
            let name = String(cString: entry.ifa_name)
            guard name.hasPrefix("en") else { continue }
            current[name] = (data.ifi_ibytes, data.ifi_obytes)
            if let previous = previousNet[name] {
                rx += UInt64(data.ifi_ibytes &- previous.rx)
                tx += UInt64(data.ifi_obytes &- previous.tx)
            }
        }
        let hadPrevious = !previousNet.isEmpty
        previousNet = current
        guard hadPrevious else { return }

        download = Double(rx) / interval
        upload = Double(tx) / interval
        push(download, to: &downloadHistory)
        push(upload, to: &uploadHistory)
    }

    // MARK: Battery

    private func sampleBattery() -> BatteryInfo? {
        let blob = IOPSCopyPowerSourcesInfo().takeRetainedValue()
        let sources = IOPSCopyPowerSourcesList(blob).takeRetainedValue() as [CFTypeRef]
        for source in sources {
            guard let info = IOPSGetPowerSourceDescription(blob, source)?.takeUnretainedValue() as? [String: Any],
                  info["Type"] as? String == "InternalBattery",
                  let current = info["Current Capacity"] as? Int,
                  let capacity = info["Max Capacity"] as? Int, capacity > 0 else { continue }
            let charging = info["Is Charging"] as? Bool ?? false
            let minutes = info[charging ? "Time to Full Charge" : "Time to Empty"] as? Int
            return BatteryInfo(level: Double(current) / Double(capacity),
                               charging: charging,
                               pluggedIn: info["Power Source State"] as? String == "AC Power",
                               minutesRemaining: (minutes ?? -1) > 0 ? minutes : nil)
        }
        return nil
    }

    // MARK: Uptime

    private static func readBootDate() -> Date {
        var mib = [CTL_KERN, KERN_BOOTTIME]
        var time = timeval()
        var size = MemoryLayout<timeval>.size
        guard sysctl(&mib, 2, &time, &size, nil, 0) == 0 else {
            return Date(timeIntervalSinceNow: -ProcessInfo.processInfo.systemUptime)
        }
        return Date(timeIntervalSince1970: Double(time.tv_sec))
    }
}
