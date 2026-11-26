import Foundation
import AppKit
import IOKit
import IOKit.ps
import CryptoKit
import SnowSweepCore

// 本机只读指标层：全部通过系统接口读取，不联网、不修改任何设置。
// 读不到就返回 nil，界面必须显式标注「读不到」，不能编造数字。

struct DiskSnapshot: Sendable {
    let totalBytes: Int64
    let freeBytes: Int64
    var usedBytes: Int64 { max(0, totalBytes - freeBytes) }
    var usedFraction: Double { totalBytes > 0 ? Double(usedBytes) / Double(totalBytes) : 0 }
}

/// 空间分析可读取的外置卷。只用来当扫描根，不参与清理判定。
struct ExternalVolumeSnapshot: Identifiable, Hashable, Sendable {
    let path: String
    let name: String
    let totalBytes: Int64
    let freeBytes: Int64
    let isReadOnly: Bool

    var id: String { path }
    var usedBytes: Int64 { max(0, totalBytes - freeBytes) }
    var usedFraction: Double { totalBytes > 0 ? Double(usedBytes) / Double(totalBytes) : 0 }
}

struct MemorySnapshot: Sendable {
    let totalBytes: Int64
    let usedBytes: Int64
    let activeBytes: Int64
    let wiredBytes: Int64
    let compressedBytes: Int64
    let swapUsedBytes: Int64
    var usedFraction: Double { totalBytes > 0 ? min(1, Double(usedBytes) / Double(totalBytes)) : 0 }
    var pressureLabel: String {
        switch usedFraction {
        case ..<0.6: return "正常"
        case ..<0.8: return "偏高"
        default: return "紧张"
        }
    }
}

struct CPUSnapshot: Sendable {
    let usagePercent: Double?
    let userPercent: Double?
    let systemPercent: Double?
    let coreCount: Int
    let load1: Double
    let load5: Double
    let load15: Double
}

enum ThermalPressure: String, Sendable {
    case nominal = "正常"
    case fair = "偏高"
    case serious = "严重"
    case critical = "临界"
    case unknown = "读不到"

    static func current() -> ThermalPressure {
        switch ProcessInfo.processInfo.thermalState {
        case .nominal: return .nominal
        case .fair: return .fair
        case .serious: return .serious
        case .critical: return .critical
        @unknown default: return .unknown
        }
    }
}

struct BatterySnapshot: Sendable {
    /// macOS 系统设置里显示的「最大容量」，经过系统平滑校准；优先作为界面口径。
    let healthPercent: Double?
    /// 原始满充容量 / 出厂设计容量，波动更大，只作为技术明细展示。
    let rawHealthPercent: Double?
    let cycleCount: Int?
    let designCapacity: Int?
    let maxCapacity: Int?
    let temperatureC: Double?
    let isCharging: Bool
    let externalPower: Bool
    let chargePercent: Int?
    /// 系统给出的剩余分钟数；充满或充电时通常是 65535（无意义哨兵值），此时为 nil。
    let timeRemainingMinutes: Int?
    /// 当前电源适配器的标称瓦数，来自 IORegistry AdapterDetails。
    let adapterWatts: Int?
    let lowPowerMode: Bool
    let thermalPressure: ThermalPressure
    var conditionLabel: String {
        guard let healthPercent else { return "读不到健康度" }
        if healthPercent >= 85 { return "状态良好" }
        if healthPercent >= 70 { return "容量有衰减" }
        return "建议检修"
    }
}

struct BluetoothDeviceRow: Identifiable, Sendable {
    let name: String
    let connected: Bool
    let battery: Int?
    let minBattery: Int?
    let batteryDetail: String?
    let minorType: String?
    let rssi: Int?
    let lastSeenConnected: Date?
    var id: String { name }

    func withLastSeen(_ date: Date?) -> BluetoothDeviceRow {
        BluetoothDeviceRow(name: name, connected: connected, battery: battery, minBattery: minBattery,
                           batteryDetail: batteryDetail, minorType: minorType, rssi: rssi,
                           lastSeenConnected: date)
    }
}

struct ProcessRow: Identifiable, Sendable {
    let pid: Int32
    let rawName: String
    let chineseName: String
    let cpuPercent: Double
    let memoryBytes: Int64
    var id: Int32 { pid }
}

struct HardwareSnapshot: Sendable {
    let model: String?
    let chip: String?
    let coreCount: Int?
    let memoryBytes: Int64?
    let storageKind: String?
    let smartStatus: String?
    let thermalPressure: ThermalPressure
    let lowPowerMode: Bool
}

struct AppEntry: Identifiable, Sendable {
    let name: String
    let bundleID: String
    let path: String
    let version: String?
    let isSystem: Bool
    let isAppStore: Bool
    let hasResiduals: Bool
    let isNestedInstall: Bool
    var id: String { path }
    var canUninstall: Bool {
        !isSystem && path.hasPrefix("/Applications/") && !bundleID.hasPrefix("com.apple.")
    }
    var installFolderName: String? {
        guard isNestedInstall else { return nil }
        return URL(fileURLWithPath: path).deletingLastPathComponent().lastPathComponent
    }
}

struct ResidualGroup: Identifiable, Sendable {
    let id: String
    let title: String
    let paths: [String]
}

struct VolumeSlice: Identifiable, Sendable {
    let name: String
    let path: String
    let bytes: Int64
    var isPartial: Bool = false
    var id: String { path }
}

/// 空间分析树图的一个节点：当前层的一个文件或目录。
struct SpaceNode: Identifiable, Sendable {
    let name: String
    let path: String
    let bytes: Int64
    let isDirectory: Bool
    let isPartial: Bool
    let isAggregate: Bool
    /// 中文判读：系统必需 / 缓存日志 / 应用残留 / 开发依赖……
    let category: String
    /// 只给建议，不替用户执行；系统位置永远只读。
    let advice: String
    /// 删除风险：高 / 中 / 低 / 只读。
    let risk: String

    init(name: String, path: String, bytes: Int64, isDirectory: Bool,
         isPartial: Bool = false, isAggregate: Bool = false,
         category: String = "未判读", advice: String = "", risk: String = "只读") {
        self.name = name
        self.path = path
        self.bytes = bytes
        self.isDirectory = isDirectory
        self.isPartial = isPartial
        self.isAggregate = isAggregate
        self.category = category
        self.advice = advice
        self.risk = risk
    }

    var id: String { path }
}

/// 当前目录一层的统计结果。`nodes` 已按体积降序，UI 决定画多少、余下归入「其他小项」。
struct SpaceLayer: Sendable {
    let nodes: [SpaceNode]
    let totalBytes: Int64
    let partialCount: Int
    /// 目录枚举阶段的明确错误（例如 macOS 未授权访问文稿/桌面/可移除卷）。
    var readError: String?
}

private struct FileMetadata {
    let inode: String
    let path: String
    let bytes: Int64
    let modifiedAt: Date
}

enum SystemMetrics {

    /// 并发统计系统盘分组时，结果容器必须自己带锁；不能直接捕获并修改
    /// `var nodes`，否则 Swift 6 会判定为跨并发域写入。
    private final class SpaceNodeCollector: @unchecked Sendable {
        private let lock = NSLock()
        private var nodes: [SpaceNode] = []

        func append(_ node: SpaceNode) {
            lock.lock()
            nodes.append(node)
            lock.unlock()
        }

        var snapshot: [SpaceNode] {
            lock.lock()
            defer { lock.unlock() }
            return nodes
        }
    }

    // MARK: - 基础工具

    static func bytesText(_ bytes: Int64) -> String {
        let raw = UserDefaults.standard.string(forKey: "snow.displayUnit") ?? ""
        let unit = DisplayUnit(rawValue: raw) ?? .auto
        return unit.format(bytes: bytes)
    }

    /// 运行一个只读命令。`timeout` 到点先 SIGTERM，再 SIGKILL，避免某个坏目录
    /// （例如卡住的 iCloud/外接盘路径）让整个统计无限等待。
    static func execute(_ launchPath: String, _ arguments: [String],
                        timeout: TimeInterval? = nil) -> (code: Int32, output: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: launchPath)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            return (-1, error.localizedDescription)
        }

        let lock = NSLock()
        var timedOut = false
        var timer: DispatchSourceTimer?
        if let timeout {
            let t = DispatchSource.makeTimerSource(queue: DispatchQueue.global(qos: .utility))
            t.schedule(deadline: .now() + timeout)
            t.setEventHandler {
                lock.lock()
                timedOut = true
                lock.unlock()
                if process.isRunning { process.terminate() }
                let pid = process.processIdentifier
                DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 0.8) {
                    if process.isRunning { kill(pid, SIGKILL) }
                }
            }
            t.resume()
            timer = t
        }

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        timer?.cancel()
        process.waitUntilExit()
        lock.lock()
        let didTimeOut = timedOut
        lock.unlock()
        let text = String(data: data, encoding: .utf8) ?? ""
        return (didTimeOut ? -2 : process.terminationStatus, text)
    }

    private static func run(_ launchPath: String, _ arguments: [String],
                            timeout: TimeInterval? = nil) -> String {
        execute(launchPath, arguments, timeout: timeout).output
    }

    private static func sysctlString(_ name: String) -> String? {
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var buffer = [CChar](repeating: 0, count: size)
        guard sysctlbyname(name, &buffer, &size, nil, 0) == 0 else { return nil }
        return String(decoding: buffer.prefix(while: { $0 != 0 }).map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }

    private static func sysctlInt(_ name: String) -> Int? {
        var value: Int32 = 0
        var size = MemoryLayout<Int32>.size
        guard sysctlbyname(name, &value, &size, nil, 0) == 0 else { return nil }
        return Int(value)
    }

    private static func intValue(_ dict: [String: Any], _ keys: String...) -> Int? {
        for key in keys {
            if let number = dict[key] as? NSNumber { return number.intValue }
            if let value = dict[key] as? Int { return value }
        }
        return nil
    }

    private static func boolValue(_ dict: [String: Any], _ key: String) -> Bool? {
        if let number = dict[key] as? NSNumber { return number.boolValue }
        if let value = dict[key] as? Bool { return value }
        return nil
    }

    // MARK: - 磁盘

    static func disk() -> DiskSnapshot {
        let url = URL(fileURLWithPath: "/")
        let values = try? url.resourceValues(forKeys: [
            .volumeTotalCapacityKey, .volumeAvailableCapacityForImportantUsageKey, .volumeAvailableCapacityKey
        ])
        let total = Int64(values?.volumeTotalCapacity ?? 0)
        let free = values?.volumeAvailableCapacityForImportantUsage ?? Int64(values?.volumeAvailableCapacity ?? 0)
        return DiskSnapshot(totalBytes: total, freeBytes: free)
    }

    /// 只列出本机、可浏览、非内置的挂载卷；网络盘与内置 APFS 卷不进空间分析。
    /// 这个方法只读元数据，不会触发磁盘枚举。
    static func externalVolumes() -> [ExternalVolumeSnapshot] {
        let keys: [URLResourceKey] = [
            .volumeNameKey, .volumeIsInternalKey, .volumeIsLocalKey,
            .volumeIsBrowsableKey, .volumeIsReadOnlyKey,
            .volumeTotalCapacityKey, .volumeAvailableCapacityKey
        ]
        let urls = FileManager.default.mountedVolumeURLs(
            includingResourceValuesForKeys: keys,
            options: [.skipHiddenVolumes]
        ) ?? []

        return urls.compactMap { url -> ExternalVolumeSnapshot? in
            guard url.path != "/",
                  let values = try? url.resourceValues(forKeys: Set(keys)),
                  values.volumeIsLocal == true,
                  values.volumeIsInternal == false,
                  values.volumeIsBrowsable == true else { return nil }
            let name = values.volumeName ?? url.lastPathComponent
            guard !name.isEmpty else { return nil }
            return ExternalVolumeSnapshot(
                path: url.path,
                name: name,
                totalBytes: Int64(values.volumeTotalCapacity ?? 0),
                freeBytes: Int64(values.volumeAvailableCapacity ?? 0),
                isReadOnly: values.volumeIsReadOnly == true
            )
        }
        .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    // MARK: - 内存

    static func memory() -> MemorySnapshot {
        let total = Int64(ProcessInfo.processInfo.physicalMemory)
        var stats = vm_statistics64_data_t()
        var count = UInt32(MemoryLayout<vm_statistics64_data_t>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &stats) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
            }
        }
        guard result == KERN_SUCCESS else {
            return MemorySnapshot(totalBytes: total, usedBytes: 0, activeBytes: 0, wiredBytes: 0,
                                  compressedBytes: 0, swapUsedBytes: 0)
        }
        var pageSize: vm_size_t = 0
        host_page_size(mach_host_self(), &pageSize)
        let page = Int64(pageSize)
        let active = Int64(stats.active_count) * page
        let wired = Int64(stats.wire_count) * page
        let compressed = Int64(stats.compressor_page_count) * page
        // 「已用」只算活跃、wired 与压缩页；inactive 是可回收的文件缓存，不计入，
        // 避免把 94% 的缓存占用误报成内存紧张。
        let used = min(total, active + wired + compressed)
        var swap = xsw_usage()
        var swapSize = MemoryLayout<xsw_usage>.size
        var swapUsed: Int64 = 0
        if sysctlbyname("vm.swapusage", &swap, &swapSize, nil, 0) == 0 {
            swapUsed = Int64(swap.xsu_used)
        }
        return MemorySnapshot(totalBytes: total, usedBytes: used, activeBytes: active, wiredBytes: wired,
                              compressedBytes: compressed, swapUsedBytes: swapUsed)
    }

    // MARK: - CPU

    private struct CPUTicks {
        let user: Int
        let system: Int
        let idle: Int
        let nice: Int
        var total: Int { user + system + idle + nice }
        var busy: Int { user + system + nice }
    }

    private final class CPUTicksCache: @unchecked Sendable {
        let lock = NSLock()
        var previous: (at: Date, ticks: CPUTicks, usage: Double?)?
    }

    private static let cpuTicksCache = CPUTicksCache()

    static func cpu() -> CPUSnapshot {
        var processorCount: Int32 = 0
        var infoCount: mach_msg_type_number_t = 0
        var info: processor_info_array_t?
        let result = host_processor_info(mach_host_self(), PROCESSOR_CPU_LOAD_INFO,
                                         &processorCount, &info, &infoCount)
        var usage: Double?
        var userPercent: Double?
        var systemPercent: Double?
        if result == KERN_SUCCESS, let info, processorCount > 0 {
            defer {
                vm_deallocate(mach_task_self_, UInt(bitPattern: info),
                              vm_size_t(infoCount) * vm_size_t(MemoryLayout<integer_t>.stride))
            }
            var user = 0, system = 0, idle = 0, nice = 0
            let stride = Int(CPU_STATE_MAX)
            for index in 0..<Int(processorCount) {
                let base = index * stride
                user += Int(info[base + Int(CPU_STATE_USER)])
                system += Int(info[base + Int(CPU_STATE_SYSTEM)])
                idle += Int(info[base + Int(CPU_STATE_IDLE)])
                nice += Int(info[base + Int(CPU_STATE_NICE)])
            }
            let ticks = CPUTicks(user: user, system: system, idle: idle, nice: nice)
            cpuTicksCache.lock.lock()
            if let previous = cpuTicksCache.previous, ticks.total > previous.ticks.total {
                let totalDelta = ticks.total - previous.ticks.total
                let busyDelta = ticks.busy - previous.ticks.busy
                usage = max(0, min(100, Double(busyDelta) / Double(totalDelta) * 100))
                userPercent = Double(ticks.user - previous.ticks.user) / Double(totalDelta) * 100
                systemPercent = Double(ticks.system - previous.ticks.system) / Double(totalDelta) * 100
            } else if ticks.total > 0 {
                // 首次调用只能给开机以来的平均，界面上标明「平均」。
                usage = Double(ticks.busy) / Double(ticks.total) * 100
                userPercent = Double(ticks.user) / Double(ticks.total) * 100
                systemPercent = Double(ticks.system) / Double(ticks.total) * 100
            }
            cpuTicksCache.previous = (Date(), ticks, usage)
            cpuTicksCache.lock.unlock()
        }

        var loads = [Double](repeating: 0, count: 3)
        loads.withUnsafeMutableBufferPointer { _ = getloadavg($0.baseAddress, 3) }
        return CPUSnapshot(
            usagePercent: usage,
            userPercent: userPercent,
            systemPercent: systemPercent,
            coreCount: Int(processorCount),
            load1: loads[0],
            load5: loads[1],
            load15: loads[2]
        )
    }

    // MARK: - 电池

    /// 公开电源接口 IOPowerSources 的兜底读取。
    /// 只取 Apple 文档里明确列出的键，不碰未文档化的 SMC 温度。
    private struct PublicBatteryInfo {
        let percent: Int?
        let charging: Bool?
        let externalPower: Bool?
        let timeRemaining: Int?
    }

    private static func publicBatteryInfo() -> PublicBatteryInfo? {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let list = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef],
              let source = list.first,
              let description = IOPSGetPowerSourceDescription(info, source)?.takeUnretainedValue() as? [String: Any]
        else { return nil }

        let current = (description[kIOPSCurrentCapacityKey as String] as? NSNumber)?.intValue
        let maximum = (description[kIOPSMaxCapacityKey as String] as? NSNumber)?.intValue
        let percent: Int? = {
            guard let current, let maximum, maximum > 0 else { return nil }
            // 公开接口在多数机器上直接给百分比；若给的是 mAh，则按容量换算。
            if maximum <= 100 { return min(100, max(0, current)) }
            return Int(round(Double(current) / Double(maximum) * 100))
        }()
        let charging = (description[kIOPSIsChargingKey as String] as? NSNumber)?.boolValue
        let state = description[kIOPSPowerSourceStateKey as String] as? String
        let external = state == (kIOPSACPowerValue as String)
        let time = (description[kIOPSTimeToEmptyKey as String] as? NSNumber)?.intValue
        return PublicBatteryInfo(
            percent: percent,
            charging: charging,
            externalPower: external,
            timeRemaining: (time.map { $0 > 0 && $0 < 65535 } ?? false) ? time : nil
        )
    }

    static func battery() -> BatterySnapshot? {
        let publicInfo = publicBatteryInfo()
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSmartBattery"))
        guard service != 0 else {
            guard let publicInfo else { return nil }
            return BatterySnapshot(
                healthPercent: nil,
                rawHealthPercent: nil,
                cycleCount: nil,
                designCapacity: nil,
                maxCapacity: nil,
                temperatureC: nil,
                isCharging: publicInfo.charging ?? false,
                externalPower: publicInfo.externalPower ?? false,
                chargePercent: publicInfo.percent,
                timeRemainingMinutes: publicInfo.timeRemaining,
                adapterWatts: nil,
                lowPowerMode: ProcessInfo.processInfo.isLowPowerModeEnabled,
                thermalPressure: ThermalPressure.current()
            )
        }
        defer { IOObjectRelease(service) }
        var properties: Unmanaged<CFMutableDictionary>?
        guard IORegistryEntryCreateCFProperties(service, &properties, kCFAllocatorDefault, 0) == KERN_SUCCESS,
              let dict = properties?.takeRetainedValue() as? [String: Any] else {
            guard let publicInfo else { return nil }
            return BatterySnapshot(
                healthPercent: nil, rawHealthPercent: nil, cycleCount: nil,
                designCapacity: nil, maxCapacity: nil, temperatureC: nil,
                isCharging: publicInfo.charging ?? false,
                externalPower: publicInfo.externalPower ?? false,
                chargePercent: publicInfo.percent,
                timeRemainingMinutes: publicInfo.timeRemaining,
                adapterWatts: nil,
                lowPowerMode: ProcessInfo.processInfo.isLowPowerModeEnabled,
                thermalPressure: ThermalPressure.current()
            )
        }

        // 容量字段在 BatteryData 子字典里，顶层同名键是百分比。
        let batteryData = dict["BatteryData"] as? [String: Any] ?? dict
        let design = intValue(batteryData, "DesignCapacity")
        let maxCapacity = intValue(batteryData, "AppleRawMaxCapacity", "FullChargeCapacity", "NominalChargeCapacity")
        let rawHealth: Double? = {
            guard let design, design > 0, let maxCapacity, maxCapacity > 0 else { return nil }
            return min(100, Double(maxCapacity) / Double(design) * 100)
        }()
        // macOS 的「最大容量」不是简单比值：系统会做校准和平滑，通常比原始比值高几个点。
        // 界面以系统报告为准，同时把原始比值留在技术明细里，避免两个数字打架时说不清来源。
        let health = reportedBatteryHealth() ?? rawHealth
        // 温度偶尔在顶层，也可能在 BatteryData 子字典；两处都看，单位是 1/100 °C。
        let temperature: Double? = {
            guard let raw = intValue(batteryData, "Temperature", "VirtualTemperature")
                    ?? intValue(dict, "Temperature", "VirtualTemperature") else { return nil }
            let celsius = Double(raw) / 100
            return (celsius > 0 && celsius < 100) ? celsius : nil
        }()
        let current = intValue(dict, "CurrentCapacity")
        let full = intValue(dict, "MaxCapacity")
        let percent: Int? = {
            guard let current, let full, full > 0 else { return publicInfo?.percent }
            if full <= 100 { return min(100, max(0, current)) }
            return Int(round(Double(current) / Double(full) * 100))
        }()
        let isCharging = boolValue(dict, "IsCharging") ?? publicInfo?.charging ?? false
        let externalPower = boolValue(dict, "ExternalConnected") ?? publicInfo?.externalPower ?? false
        // 65535 是系统在「正在充电 / 已充满」时常用的无意义哨兵值，不可当分钟数展示。
        let rawTime = intValue(dict, "TimeRemaining")
        let timeRemaining = (rawTime.map { $0 > 0 && $0 < 65535 } ?? false) ? rawTime : publicInfo?.timeRemaining
        let adapter = dict["AdapterDetails"] as? [String: Any]
        let adapterWatts = adapter.flatMap { intValue($0, "Watts") }
        return BatterySnapshot(
            healthPercent: health,
            rawHealthPercent: rawHealth,
            cycleCount: intValue(dict, "CycleCount"),
            designCapacity: design,
            maxCapacity: maxCapacity,
            temperatureC: temperature,
            isCharging: isCharging,
            externalPower: externalPower,
            chargePercent: percent,
            timeRemainingMinutes: timeRemaining,
            adapterWatts: adapterWatts,
            lowPowerMode: ProcessInfo.processInfo.isLowPowerModeEnabled,
            thermalPressure: ThermalPressure.current()
        )
    }

    /// 读取系统报告的「最大容量」。这是 Apple 自己平滑后的口径，和「系统设置 › 电池」一致。
    // 电池健康是标定值，不是实时指标；每次 battery() 都起 system_profiler 太重。
    // 只缓存「最大容量」，充电状态、百分比、剩余时间仍走 IOKit 现读。
    private struct BatteryHealthReading: Sendable {
        let percent: Double?
    }

    private final class BatteryHealthCache: @unchecked Sendable {
        let lock = NSLock()
        var cached: (at: Date, value: BatteryHealthReading)?
    }

    private static let batteryHealthCache = BatteryHealthCache()
    private static let batteryHealthTTL: TimeInterval = 600

    private static func reportedBatteryHealth() -> Double? {
        batteryHealthCache.lock.lock()
        if let cached = batteryHealthCache.cached,
           Date().timeIntervalSince(cached.at) < batteryHealthTTL {
            let value = cached.value.percent
            batteryHealthCache.lock.unlock()
            return value
        }
        batteryHealthCache.lock.unlock()

        let output = run("/usr/sbin/system_profiler", ["SPPowerDataType"])
        var value: Double?
        for line in output.split(separator: "\n") {
            let text = line.trimmingCharacters(in: .whitespaces)
            guard text.hasPrefix("Maximum Capacity:") else { continue }
            let raw = text
                .replacingOccurrences(of: "Maximum Capacity:", with: "")
                .trimmingCharacters(in: .whitespaces)
                .replacingOccurrences(of: "%", with: "")
            value = Double(raw)
            break
        }
        batteryHealthCache.lock.lock()
        batteryHealthCache.cached = (Date(), BatteryHealthReading(percent: value))
        batteryHealthCache.lock.unlock()
        return value
    }

    // MARK: - 蓝牙

    static func bluetoothDevices() -> [BluetoothDeviceRow] {
        var rows: [BluetoothDeviceRow] = []
        let output = run("/usr/sbin/system_profiler", ["-json", "SPBluetoothDataType"])
        if let data = output.data(using: .utf8),
           let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            walkBluetooth(root, connected: false, into: &rows)
        }

        // 第三方 BLE 鼠标（如 UGREEN）的电量既不在 system_profiler，也没有 ioreg BatteryPercent。
        // 系统设置能显示它，是因为 bluetoothd 把配件登记成 CBPowerSource；这里只解析本机日志兜底。
        let needsPowerSource = rows.contains { $0.connected && $0.battery == nil }
        let powerReadings = needsPowerSource ? bluetoothPowerSourceReadings() : [:]
        for index in rows.indices where rows[index].connected && rows[index].battery == nil {
            if let percent = BluetoothPowerSourceLog.fillMissing(
                deviceName: rows[index].name,
                currentBattery: rows[index].battery,
                readings: powerReadings
            ) {
                rows[index] = BluetoothDeviceRow(
                    name: rows[index].name,
                    connected: rows[index].connected,
                    battery: percent,
                    minBattery: percent,
                    batteryDetail: "系统电源",
                    minorType: rows[index].minorType,
                    rssi: rows[index].rssi,
                    lastSeenConnected: rows[index].lastSeenConnected
                )
            }
        }

        // Magic Mouse / Keyboard / Trackpad 的电量在 system_profiler 里经常是空的；
        // ioreg 的 IOHIDInterface 节点会带 BatteryPercent，属于未文档化键，只作兜底。
        for hid in hidBatteryDevices() {
            if let index = rows.firstIndex(where: { $0.name == hid.name }) {
                if rows[index].battery == nil {
                    rows[index] = BluetoothDeviceRow(
                        name: rows[index].name,
                        connected: rows[index].connected,
                        battery: hid.battery,
                        minBattery: hid.battery,
                        batteryDetail: "HID 电量 \(hid.battery ?? 0)%",
                        minorType: rows[index].minorType,
                        rssi: rows[index].rssi,
                        lastSeenConnected: rows[index].lastSeenConnected
                    )
                }
            } else {
                rows.append(hid)
            }
        }
        // 同名设备只留一条：已连接优先，其次有电量、有信号、有最后连接时间。
        var merged: [String: BluetoothDeviceRow] = [:]
        for row in rows {
            if let existing = merged[row.name] {
                merged[row.name] = preferredBluetoothRow(existing, row)
            } else {
                merged[row.name] = row
            }
        }
        return merged.values.sorted { lhs, rhs in
            if lhs.connected != rhs.connected { return lhs.connected && !rhs.connected }
            return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
        }
    }

    private static func preferredBluetoothRow(_ lhs: BluetoothDeviceRow,
                                              _ rhs: BluetoothDeviceRow) -> BluetoothDeviceRow {
        if lhs.connected != rhs.connected {
            return lhs.connected ? lhs : rhs
        }
        let base = lhs.battery != nil ? lhs : (rhs.battery != nil ? rhs : lhs)
        let extra = base.battery == nil ? rhs : lhs
        return BluetoothDeviceRow(
            name: base.name,
            connected: base.connected,
            battery: base.battery ?? extra.battery,
            minBattery: base.minBattery ?? extra.minBattery,
            batteryDetail: base.batteryDetail ?? extra.batteryDetail,
            minorType: base.minorType ?? extra.minorType,
            rssi: base.rssi ?? extra.rssi,
            lastSeenConnected: base.lastSeenConnected ?? extra.lastSeenConnected
        )
    }

    /// bluetoothd 每分钟会写一条 CBPowerSource；日志读取较慢，缓存 45 秒。
    /// 只在「已连接但前面接口都没读到电量」时才调用，不拖慢普通蓝牙列表。
    private final class BluetoothPowerSourceCache: @unchecked Sendable {
        let lock = NSLock()
        var loadedAt: Date?
        var readings: [String: BluetoothPowerSourceLog.Reading] = [:]
    }

    private static let bluetoothPowerSourceCache = BluetoothPowerSourceCache()

    private static func bluetoothPowerSourceReadings() -> [String: BluetoothPowerSourceLog.Reading] {
        let cache = bluetoothPowerSourceCache
        cache.lock.lock()
        if let loadedAt = cache.loadedAt, Date().timeIntervalSince(loadedAt) < 45 {
            let cached = cache.readings
            cache.lock.unlock()
            return cached
        }
        cache.lock.unlock()

        let output = run("/usr/bin/log", [
            "show", "--last", "3m", "--style", "compact",
            "--predicate", "process == \"bluetoothd\" AND eventMessage CONTAINS \"CBPowerSource\""
        ], timeout: 4)
        let readings = BluetoothPowerSourceLog.parse(output)

        cache.lock.lock()
        cache.loadedAt = Date()
        cache.readings = readings
        cache.lock.unlock()
        return readings
    }

    private static func hidBatteryDevices() -> [BluetoothDeviceRow] {
        let output = run("/usr/sbin/ioreg", ["-r", "-l", "-k", "BatteryPercent"], timeout: 3)
        var rows: [BluetoothDeviceRow] = []
        var product: String?
        for line in output.split(separator: "\n") {
            let text = String(line)
            if text.contains("+-o ") { product = nil }
            if let range = text.range(of: "\"Product\" = \"") {
                let rest = text[range.upperBound...]
                if let end = rest.firstIndex(of: "\"") {
                    product = String(rest[..<end])
                }
            }
            if text.contains("\"BatteryPercent\" = ") {
                let raw = text.components(separatedBy: "= ").last?
                    .replacingOccurrences(of: "\"", with: "")
                    .trimmingCharacters(in: .whitespaces) ?? ""
                guard let value = Int(raw), value >= 0, value <= 100 else { continue }
                let name = product ?? "HID 外设"
                rows.append(BluetoothDeviceRow(
                    name: name, connected: true, battery: value, minBattery: value,
                    batteryDetail: "HID 电量 \(value)%", minorType: "HID", rssi: nil,
                    lastSeenConnected: nil
                ))
            }
        }
        return rows
    }

    private static func walkBluetooth(_ object: Any, connected: Bool, into rows: inout [BluetoothDeviceRow]) {
        if let array = object as? [Any] {
            for item in array { walkBluetooth(item, connected: connected, into: &rows) }
            return
        }
        guard let dict = object as? [String: Any] else { return }
        // system_profiler 里同一只鼠标会同时出现在 connected / not_connected。
        // 必须固定先读 connected，否则字典随机遍历会让「已连接」被「未连接」覆盖。
        if dict["device_connected"] != nil || dict["device_not_connected"] != nil {
            if let connectedList = dict["device_connected"] {
                walkBluetooth(connectedList, connected: true, into: &rows)
            }
            if let notConnectedList = dict["device_not_connected"] {
                walkBluetooth(notConnectedList, connected: false, into: &rows)
            }
            return
        }
        for (key, value) in dict {
            if key == "device_connected" || key == "device_not_connected" {
                walkBluetooth(value, connected: key == "device_connected", into: &rows)
                continue
            }
            if key == "controller_properties" || key == "device_address" { continue }
            if let device = value as? [String: Any],
               device["device_address"] != nil || device.keys.contains(where: { $0.hasPrefix("device_batteryLevel") }) {
                let levels = batteryLevels(device)
                let rssi: Int? = {
                    if let number = device["device_rssi"] as? NSNumber { return number.intValue }
                    if let text = device["device_rssi"] as? String { return Int(text) }
                    return nil
                }()
                rows.append(BluetoothDeviceRow(
                    name: key,
                    connected: connected,
                    battery: levels.main,
                    minBattery: levels.min,
                    batteryDetail: levels.detail,
                    minorType: device["device_minorType"] as? String,
                    rssi: rssi,
                    lastSeenConnected: nil
                ))
                continue
            }
            walkBluetooth(value, connected: connected, into: &rows)
        }
    }

    private static func batteryLevels(_ device: [String: Any]) -> (main: Int?, min: Int?, detail: String?) {
        let candidates: [(String, String)] = [
            ("device_batteryLevelMain", "主"),
            ("device_batteryLevel", ""),
            ("device_batteryLevelLeft", "左"),
            ("device_batteryLevelRight", "右"),
            ("device_batteryLevelCase", "盒")
        ]
        var main: Int?
        var minimum: Int?
        var parts: [String] = []
        for (key, label) in candidates {
            guard let raw = device[key] else { continue }
            let text = "\(raw)"
            guard let number = Int(text.replacingOccurrences(of: "%", with: "").trimmingCharacters(in: .whitespaces)) else { continue }
            if main == nil { main = number }
            minimum = min(minimum ?? number, number)
            parts.append(label.isEmpty ? "\(number)%" : "\(label) \(number)%")
        }
        return (main, minimum, parts.isEmpty ? nil : parts.joined(separator: " · "))
    }

    // MARK: - 进程

    static func processes(limit: Int = 18) -> [ProcessRow] {
        let output = run("/bin/ps", ["-axo", "pid=,pcpu=,rss=,comm="])
        var rows: [ProcessRow] = []
        for line in output.split(separator: "\n") {
            let parts = line.split(separator: " ", maxSplits: 3, omittingEmptySubsequences: true)
            guard parts.count == 4,
                  let pid = Int32(parts[0]),
                  let cpu = Double(parts[1]),
                  let rssKB = Int64(parts[2]) else { continue }
            let raw = String(parts[3])
            let base = (raw as NSString).lastPathComponent
            rows.append(ProcessRow(pid: pid, rawName: base, chineseName: chineseProcessName(base),
                                   cpuPercent: cpu, memoryBytes: rssKB * 1024))
        }
        return Array(rows.sorted { $0.memoryBytes > $1.memoryBytes }.prefix(limit))
    }

    static func chineseProcessName(_ raw: String) -> String {
        let map: [String: String] = [
            "kernel_task": "系统内核",
            "WindowServer": "系统窗口服务",
            "launchd": "系统启动服务",
            "mds_stores": "聚焦索引",
            "mds": "聚焦索引",
            "coreaudiod": "音频服务",
            "bluetoothd": "蓝牙服务",
            "Finder": "访达",
            "Dock": "程序坞",
            "ControlCenter": "控制中心",
            "UserEventAgent": "用户事件代理",
            "loginwindow": "登录窗口",
            "runningboardd": "后台任务管理",
            "sharingd": "隔空投送",
            "cloudd": "云同步",
            "nsurlsessiond": "后台下载",
            "Safari": "Safari 浏览器",
            "Google Chrome": "谷歌浏览器",
            "Xcode": "Xcode 开发工具",
            "SnowSweepApp": "雪",
            "WorkBuddy": "豆包工作",
            "Doubao": "豆包",
            "Terminal": "终端",
            "Spotlight": "聚焦搜索",
            "NotificationCenter": "通知中心",
            "SystemUIServer": "菜单栏服务"
        ]
        if let hit = map[raw] { return hit }
        let lower = raw.lowercased()
        if lower.hasPrefix("doubaowork") {
            if lower.contains("renderer") { return "豆包工作 渲染进程" }
            if lower.contains("helper") { return "豆包工作 辅助进程" }
            if lower.contains("browser") { return "豆包工作浏览器" }
            return "豆包工作"
        }
        if lower.hasPrefix("workbuddy") {
            if lower.contains("renderer") { return "豆包工作 渲染进程" }
            if lower.contains("helper") { return "豆包工作 辅助进程" }
            return "豆包工作"
        }
        if lower.hasPrefix("doubao") {
            if lower.contains("renderer") { return "豆包 渲染进程" }
            if lower.contains("helper") { return "豆包 辅助进程" }
            return "豆包"
        }
        if raw.hasPrefix("com.apple.") { return "系统后台服务" }
        return raw
    }

    // MARK: - 硬件

    /// 硬件身份读一次就够：型号、芯片、核心数、存储介质、SMART 不会每 5 秒变。
    /// 热压力和低电量模式仍由每次 `hardware()` 现读，保证动态字段不过期。
    private struct HardwareIdentity: Sendable {
        let model: String?
        let chip: String?
        let coreCount: Int?
        let memoryBytes: Int64?
        let storageKind: String?
        let smartStatus: String?
    }

    private final class HardwareIdentityCache: @unchecked Sendable {
        let lock = NSLock()
        var cached: (at: Date, value: HardwareIdentity)?
    }

    private static let hardwareIdentityCache = HardwareIdentityCache()
    private static let hardwareIdentityTTL: TimeInterval = 600

    private static func hardwareIdentity() -> HardwareIdentity {
        hardwareIdentityCache.lock.lock()
        if let cached = hardwareIdentityCache.cached,
           Date().timeIntervalSince(cached.at) < hardwareIdentityTTL {
            hardwareIdentityCache.lock.unlock()
            return cached.value
        }
        hardwareIdentityCache.lock.unlock()

        var storage: String?
        var smart: String?
        let output = run("/usr/sbin/diskutil", ["info", "-plist", "/"])
        if let data = output.data(using: .utf8),
           let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] {
            if let solid = plist["SolidState"] as? Bool, solid { storage = "SSD" }
            if let smartStatus = plist["SMARTStatus"] as? String {
                smart = smartStatus == "Verified" ? "正常" : smartStatus
            }
        }
        let identity = HardwareIdentity(
            model: sysctlString("hw.model"),
            chip: sysctlString("machdep.cpu.brand_string"),
            coreCount: sysctlInt("hw.physicalcpu"),
            memoryBytes: Int64(ProcessInfo.processInfo.physicalMemory),
            storageKind: storage,
            smartStatus: smart
        )

        hardwareIdentityCache.lock.lock()
        hardwareIdentityCache.cached = (Date(), identity)
        hardwareIdentityCache.lock.unlock()
        return identity
    }

    static func hardware() -> HardwareSnapshot {
        let identity = hardwareIdentity()
        return HardwareSnapshot(
            model: identity.model,
            chip: identity.chip,
            coreCount: identity.coreCount,
            memoryBytes: identity.memoryBytes,
            storageKind: identity.storageKind,
            smartStatus: identity.smartStatus,
            thermalPressure: ThermalPressure.current(),
            lowPowerMode: ProcessInfo.processInfo.isLowPowerModeEnabled
        )
    }

    // MARK: - 空间分析

    static func directorySize(_ path: String, timeout: TimeInterval? = nil) -> VolumeSlice {
        let result = execute("/usr/bin/du", ["-sk", path], timeout: timeout)
        let kb = result.output.split(separator: "\t").first
            .flatMap { Int64(String($0).trimmingCharacters(in: .whitespaces)) } ?? 0
        return VolumeSlice(name: (path as NSString).lastPathComponent, path: path,
                           bytes: kb * 1024,
                           isPartial: result.code == -2 || (kb == 0 && result.code != 0))
    }

    static func directorySizes(_ paths: [String]) -> [VolumeSlice] {
        paths.map { directorySize($0) }.sorted { $0.bytes > $1.bytes }
    }

    /// 统计一个目录的「直接子项」体积。只做当前一层，进入下一层时再算，
    /// 避免为了树图一次性递归整盘。目录体积用一次 `du` 批量算，文件用资源值算。
    static func spaceLayer(of path: String) -> SpaceLayer {
        let directory = URL(fileURLWithPath: path)
        let children: [URL]
        do {
            children = try FileManager.default.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey,
                                             .totalFileAllocatedSizeKey, .fileSizeKey],
                options: []
            )
        } catch {
            return SpaceLayer(nodes: [], totalBytes: 0, partialCount: 0,
                              readError: spaceReadError(path: path, error: error))
        }

        var directories: [String] = []
        var files: [SpaceNode] = []
        for child in children {
            let values = try? child.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey,
                                                            .totalFileAllocatedSizeKey, .fileSizeKey])
            // 跳过符号链接，避免循环和重复计数。
            if values?.isSymbolicLink == true { continue }
            let isDirectory = values?.isDirectory ?? false
            if isDirectory {
                directories.append(child.path)
            } else {
                let bytes = Int64(values?.totalFileAllocatedSize ?? values?.fileSize ?? 0)
                files.append(SpaceNode(name: child.lastPathComponent, path: child.path,
                                       bytes: bytes, isDirectory: false))
            }
        }

        let directorySizes = directoryByteSizes(directories)
        var nodes = files
        var partialCount = 0
        for path in directories {
            let bytes = directorySizes[path] ?? 0
            if directorySizes[path] == nil { partialCount += 1 }
            nodes.append(SpaceNode(name: (path as NSString).lastPathComponent, path: path,
                                   bytes: bytes, isDirectory: true,
                                   isPartial: directorySizes[path] == nil))
        }
        nodes.sort { $0.bytes > $1.bytes }
        return SpaceLayer(nodes: nodes.map { annotated($0) },
                          totalBytes: nodes.reduce(0) { $0 + $1.bytes },
                          partialCount: partialCount)
    }

    // MARK: - 系统盘只读判读

    /// 系统盘不是把 `/` 整棵递归一遍：APFS 的 `/System/Volumes/Data`
    /// 会把数据卷重复算进来。这里按“用户真正会去动的系统位置”分组，
    /// 每组单独统计；只显示、只建议，不提供系统文件删除按钮。
    static func systemSpaceLayer(timeout: TimeInterval = 45, concurrency: Int = 3) -> SpaceLayer {
        struct Spec {
            let path: String
            let label: String
        }
        let specs: [Spec] = [
            .init(path: "/Applications", label: "应用程序 /Applications"),
            .init(path: "/Library", label: "共享资源库 /Library"),
            .init(path: "/System/Library", label: "系统本体 /System/Library"),
            .init(path: "/System/Applications", label: "系统应用 /System/Applications"),
            .init(path: "/usr", label: "Unix 工具 /usr"),
            .init(path: "/opt", label: "开发工具 /opt"),
            .init(path: "/private/var/db", label: "系统数据库 /private/var/db"),
            .init(path: "/private/var/log", label: "系统日志 /private/var/log"),
            .init(path: "/private/var/folders", label: "临时缓存 /private/var/folders"),
            .init(path: "/private/var/vm", label: "虚拟内存 /private/var/vm"),
            .init(path: NSHomeDirectory(), label: "用户目录（当前账号）")
        ]
        let gate = DispatchSemaphore(value: max(1, concurrency))
        let collector = SpaceNodeCollector()
        DispatchQueue.concurrentPerform(iterations: specs.count) { index in
            let spec = specs[index]
            guard FileManager.default.fileExists(atPath: spec.path) else { return }
            gate.wait()
            defer { gate.signal() }
            let slice = directorySize(spec.path, timeout: timeout)
            let node = annotated(SpaceNode(
                name: spec.label,
                path: spec.path,
                bytes: slice.bytes,
                isDirectory: true,
                isPartial: slice.isPartial
            ))
            collector.append(node)
        }
        let nodes = collector.snapshot.sorted { $0.bytes > $1.bytes }
        let partial = nodes.filter(\.isPartial).count
        var layer = SpaceLayer(
            nodes: nodes,
            totalBytes: nodes.reduce(0) { $0 + $1.bytes },
            partialCount: partial
        )
        if nodes.isEmpty {
            layer.readError = "系统盘位置都读不到。请确认雪已获得完全磁盘访问权限，并重启雪后再试。"
        }
        return layer
    }

    static func annotated(_ node: SpaceNode) -> SpaceNode {
        if node.isAggregate { return node }
        let info = annotation(path: node.path, isDirectory: node.isDirectory)
        return SpaceNode(
            name: node.name, path: node.path, bytes: node.bytes,
            isDirectory: node.isDirectory, isPartial: node.isPartial,
            isAggregate: false, category: info.category, advice: info.advice, risk: info.risk
        )
    }

    /// 只按路径语义判读，不根据文件名猜“没用”。读不到的体积仍然是读不到。
    static func annotation(path: String, isDirectory: Bool) -> (category: String, advice: String, risk: String) {
        let lower = path.lowercased()
        if lower.hasPrefix("/system/") || lower == "/system" {
            return ("系统必需", "macOS 本体，受 SIP 保护；不要手删，雪也不提供删除。", "只读")
        }
        if lower.hasPrefix("/bin/") || lower == "/bin" || lower.hasPrefix("/sbin/") || lower == "/sbin" {
            return ("系统必需", "系统命令目录，删除会导致系统无法启动或命令失效。", "只读")
        }
        if lower.hasPrefix("/private/var/vm") {
            return ("虚拟内存", "睡眠镜像与交换文件，由 macOS 管理；不要手删，异常占用优先重启。", "只读")
        }
        if lower.hasPrefix("/private/var/db") {
            return ("系统数据库", "系统与后台服务数据库；不要手删，删了可能导致服务异常。", "只读")
        }
        if lower.hasPrefix("/private/var/folders") {
            return ("缓存与临时文件", "可清，但优先用清理页或软件自带清理；不要删整个系统临时根。", "中")
        }
        if lower.hasPrefix("/private/var/log") {
            return ("日志", "旧日志可以按时间清；系统日志会自动轮转，不建议整目录删。", "中")
        }
        if lower.hasPrefix("/private/var") || lower.hasPrefix("/private/etc") {
            return ("系统运行数据", "日志、数据库与运行状态；系统会自动轮转，不要整目录删除。", "只读")
        }
        if lower.hasPrefix("/applications") {
            return ("应用程序", "整包删除请走「卸载」页核对归属；不要把正在用的 App 直接拖进废纸篓。", "中")
        }
        if lower == "/library" || lower == "/library/" {
            return ("共享资源库", "再进一层看 Caches、Logs、Application Support；只删确认无主的残留，不要整目录删。", "中")
        }
        if lower.contains("/library/caches") || lower.contains("/caches/") || lower.contains("/private/var/folders") {
            return ("缓存与日志", "可清，但优先用清理页或软件自带清理；系统缓存不要手删整个目录。", "中")
        }
        if lower.contains("/library/logs") || lower.contains("/private/var/log") || lower.contains("/log/") {
            return ("日志", "旧日志可以按时间清；系统日志会自动轮转，不建议整目录删。", "中")
        }
        if lower.contains("/library/application support") || lower.contains("/library/preferences")
            || lower.contains("/library/containers") || lower.contains("/group containers") {
            return ("应用共享数据", "先确认对应软件已经卸载；只删残留，不要删还在用软件的配置。", "中")
        }
        if lower.contains("/library/launchagents") || lower.contains("/library/launchdaemons")
            || lower.contains("/library/privilegedhelpertools") {
            return ("后台服务", "可能被系统或驱动使用；先到「启动项审查」看归属，不要手删。", "高")
        }
        if lower.hasPrefix("/usr/local") || lower.hasPrefix("/opt/homebrew") {
            return ("开发依赖", "Homebrew / 本地编译依赖；优先 `brew cleanup`，不要直接删整个目录。", "中")
        }
        if lower == "/usr" || lower.hasPrefix("/usr/") {
            return ("Unix 工具", "系统与开发工具混用；只读查看，不要按体积猜着删。", "只读")
        }
        if lower == "/opt" || lower.hasPrefix("/opt/") {
            return ("开发工具", "第三方工具与运行时；先确认对应工具不再使用，再走它自己的卸载。", "中")
        }
        if lower == "/users" || lower.hasPrefix("/users/") {
            return ("用户数据", "个人文件优先在「家目录」里按目录分析；这里不直接删。", "中")
        }
        if lower.hasPrefix("/volumes") {
            return ("外置盘", "外置盘只读统计，不参与本机清理。", "只读")
        }
        let name = (path as NSString).lastPathComponent.lowercased()
        if name.contains("cache") || name.contains("tmp") || name.contains("temp") {
            return ("缓存与临时文件", "可清，但先确认没有程序正在使用；不要删整个共享缓存根。", "中")
        }
        if name.contains("log") {
            return ("日志", "按时间清旧日志；正在写入的日志不要删。", "中")
        }
        if !isDirectory {
            return ("文件", "点中后看路径和归属；不确定就不要删。", "中")
        }
        return ("未判读", "没有足够证据判断无用；不要凭英文名字猜，先看软件归属或权限清单。", "只读")
    }

    /// 外置盘的一次性单层统计：`du -k -d 1 当前目录` 只走一遍目录树，
    /// 比逐个顶层目录分别 `du` 少重复遍历，大容量盘不会因为 5 秒批超时全部标「读不到」。
    /// 30 秒还没扫完时保留已输出的部分结果，未输出的目录由调用方标 partial。
    static func externalSpaceLayer(of path: String, timeout: TimeInterval = 30) -> SpaceLayer {
        let directory = URL(fileURLWithPath: path)
        let children: [URL]
        do {
            children = try FileManager.default.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey,
                                             .totalFileAllocatedSizeKey, .fileSizeKey],
                options: []
            )
        } catch {
            return SpaceLayer(nodes: [], totalBytes: 0, partialCount: 0,
                              readError: spaceReadError(path: path, error: error))
        }

        var directories: [String] = []
        var files: [SpaceNode] = []
        for child in children {
            let name = child.lastPathComponent
            guard !isVolumeMetadata(name) else { continue }
            let values = try? child.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey,
                                                            .totalFileAllocatedSizeKey, .fileSizeKey])
            if values?.isSymbolicLink == true { continue }
            let isDirectory = values?.isDirectory ?? false
            if isDirectory {
                directories.append(child.path)
            } else {
                let bytes = Int64(values?.totalFileAllocatedSize ?? values?.fileSize ?? 0)
                files.append(SpaceNode(name: name, path: child.path, bytes: bytes, isDirectory: false))
            }
        }

        let directorySizes = externalDirectoryByteSizes(of: path, timeout: timeout)
        var nodes = files
        var partialCount = 0
        for childPath in directories {
            let bytes = directorySizes[childPath] ?? 0
            if directorySizes[childPath] == nil { partialCount += 1 }
            nodes.append(SpaceNode(name: (childPath as NSString).lastPathComponent, path: childPath,
                                   bytes: bytes, isDirectory: true,
                                   isPartial: directorySizes[childPath] == nil))
        }
        nodes.sort { $0.bytes > $1.bytes }
        return SpaceLayer(nodes: nodes.map { annotated($0) },
                          totalBytes: nodes.reduce(0) { $0 + $1.bytes },
                          partialCount: partialCount)
    }

    /// 外置盘顶层常见的系统元数据目录与 AppleDouble 文件，不参与空间排行。
    private static func isVolumeMetadata(_ name: String) -> Bool {
        if name.hasPrefix("._") { return true }
        switch name {
        case ".Spotlight-V100", ".fseventsd", ".Trashes", ".TemporaryItems",
             ".DocumentRevisions-V100", ".MobileBackups", ".apdisk",
             ".VolumeIcon.icns", ".DS_Store", ".localized", ".hedge-enabled",
             "System Volume Information", "$RECYCLE.BIN":
            return true
        default:
            return false
        }
    }

    private static func spaceReadError(path: String, error: Error) -> String {
        let ns = error as NSError
        if ns.domain == NSCocoaErrorDomain, ns.code == NSFileReadNoPermissionError {
            return "没有权限读取「\(path)」。请到 系统设置 → 隐私与安全性 → 文件与文件夹 勾选雪；读取外置盘时还要允许「可移除卷」。"
        }
        return "读取「\(path)」失败：\(ns.localizedDescription)"
    }

    private static func externalDirectoryByteSizes(of path: String,
                                                   timeout: TimeInterval) -> [String: Int64] {
        let output = run("/usr/bin/du", ["-k", "-d", "1", path], timeout: timeout)
        return parseDU(output)
    }

    /// 每个目录单独启动 `du -sk`，最多 4 个并发，单项 45 秒。
    /// 以前把多个路径交给同一个 `du`，它会顺序处理；家目录 8 项共享 24 秒，
    /// 资源库一项就要约 18 秒，前面的大目录一慢，后面必然被误判成「读不到」。
    /// 拆成独立进程后，慢目录只影响自己，不会拖垮整层。
    private static func directoryByteSizes(_ paths: [String]) -> [String: Int64] {
        guard !paths.isEmpty else { return [:] }

        final class Box: @unchecked Sendable {
            let lock = NSLock()
            var values: [String: Int64] = [:]
            func merge(_ dict: [String: Int64]) {
                lock.lock(); values.merge(dict) { _, new in new }; lock.unlock()
            }
        }
        let box = Box()
        let gate = DispatchSemaphore(value: 4)
        DispatchQueue.concurrentPerform(iterations: paths.count) { i in
            gate.wait()
            defer { gate.signal() }
            let path = paths[i]
            let output = run("/usr/bin/du", ["-sk", path], timeout: 45)
            let dict = parseDU(output)
            if dict[path] != nil { box.merge(dict) }
        }
        return box.values
    }

    private static func parseDU(_ output: String) -> [String: Int64] {
        var result: [String: Int64] = [:]
        for line in output.split(separator: "\n") {
            let parts = line.split(separator: "\t", maxSplits: 1, omittingEmptySubsequences: false)
            guard parts.count == 2,
                  let kb = Int64(parts[0].trimmingCharacters(in: .whitespaces)) else { continue }
            let key = String(parts[1]).trimmingCharacters(in: .whitespaces)
            result[key] = kb * 1024
        }
        return result
    }

    struct BigFileScan: Sendable {
        var rows: [LargeFileRecord]
        var timedOut: Bool
        var unreadable: [String]
    }

    /// 只读取元数据：体积、修改时间、路径。类型与筛选全部在核心层按扩展名解释。
    /// 六个个人目录并发扫描，每个目录独立超时；一个慢目录不会让整页归零。
    static func biggestFiles(home: String, minMegabytes: Int = 100, limit: Int = 200,
                             timeout: TimeInterval = 12) -> BigFileScan {
        let roots = reviewRoots(home: home)
        let scan = concurrentMetadata(roots: roots,
                                      minBytes: Int64(max(1, minMegabytes)) * 1_000_000,
                                      timeout: min(20, timeout))
        let rows = uniqueInodes(scan.items).map {
            LargeFileRecord(path: $0.path, bytes: $0.bytes, modifiedAt: $0.modifiedAt)
        }
        let sortedRows = Array(rows.sorted { $0.bytes > $1.bytes }.prefix(limit))
        return BigFileScan(rows: sortedRows, timedOut: scan.timedOut, unreadable: scan.unreadable)
    }

    private static func reviewRoots(home: String) -> [String] {
        ["Desktop", "Documents", "Downloads", "Pictures", "Movies", "Music"]
            .map { home + "/" + $0 }
            .filter { FileManager.default.fileExists(atPath: $0) }
    }

    /// 应用进程内递归枚举，不再启动 /usr/bin/find 子进程。
    /// macOS 的目录隐私授权只对应用自身的文件访问可靠；子进程容易被 TCC 挂住，
    /// 即使用户在系统弹窗里点了允许，find 仍可能读不到桌面/下载/文稿。
    /// 每个根目录一个枚举器并发执行，跳过隐藏项、照片图库、应用包和音乐库。
    private final class MetadataBox: @unchecked Sendable {
        let lock = NSLock()
        var items: [FileMetadata] = []
        var timedOut = false
        var unreadable: [String] = []
    }

    private static let scanKeys: Set<URLResourceKey> = [
        .isDirectoryKey, .isRegularFileKey, .fileSizeKey,
        .contentModificationDateKey, .fileResourceIdentifierKey
    ]

    private static func concurrentMetadata(roots: [String], minBytes: Int64,
                                           maxBytes: Int64? = nil,
                                           timeout: TimeInterval) -> (items: [FileMetadata], timedOut: Bool, unreadable: [String]) {
        guard !roots.isEmpty else { return ([], false, []) }
        let box = MetadataBox()
        // 不用 concurrentPerform：它会一直等所有 worker 返回。
        // macOS 的目录授权弹窗未处理时，open 会卡在 TCC 里；
        // 用 DispatchGroup 的硬超时先放行界面，卡住的 worker 等授权恢复后自行结束。
        let group = DispatchGroup()
        for root in roots {
            group.enter()
            DispatchQueue.global(qos: .utility).async {
                let result = metadata(in: root, minBytes: minBytes, maxBytes: maxBytes, timeout: timeout)
                box.lock.lock()
                box.items.append(contentsOf: result.items)
                if result.timedOut { box.timedOut = true }
                if result.unreadable { box.unreadable.append(root) }
                box.lock.unlock()
                group.leave()
            }
        }
        if group.wait(timeout: .now() + timeout + 1) == .timedOut {
            box.lock.lock()
            box.timedOut = true
            box.lock.unlock()
        }
        box.lock.lock()
        let items = box.items
        let timedOut = box.timedOut
        let unreadable = box.unreadable
        box.lock.unlock()
        return (items, timedOut, unreadable)
    }

    private static func metadata(in root: String, minBytes: Int64, maxBytes: Int64?,
                                 timeout: TimeInterval) -> (items: [FileMetadata], timedOut: Bool, unreadable: Bool) {
        let fm = FileManager.default
        var hadError = false
        guard let enumerator = fm.enumerator(
            at: URL(fileURLWithPath: root),
            includingPropertiesForKeys: Array(scanKeys),
            options: [.skipsHiddenFiles],
            errorHandler: { _, _ in
                hadError = true
                return true // 单个子目录读不到时继续，不拖垮整个根目录
            }
        ) else {
            return ([], false, true)
        }

        let deadline = Date().addingTimeInterval(timeout)
        let blockedNames: Set<String> = [".photoslibrary", ".app", ".musiclibrary"]
        var items: [FileMetadata] = []
        var timedOut = false
        var visited = 0

        for case let url as URL in enumerator {
            visited += 1
            if visited % 256 == 0, Date() >= deadline {
                timedOut = true
                break
            }
            do {
                let values = try url.resourceValues(forKeys: scanKeys)
                if values.isDirectory == true {
                    let name = url.lastPathComponent.lowercased()
                    if blockedNames.contains(name) || name.hasSuffix(".app") {
                        enumerator.skipDescendants()
                    }
                    continue
                }
                guard values.isRegularFile == true,
                      let size = values.fileSize, Int64(size) >= minBytes else { continue }
                if let maxBytes, Int64(size) > maxBytes { continue }
                guard let identifier = values.fileResourceIdentifier else { continue }
                items.append(FileMetadata(
                    inode: String(describing: identifier),
                    path: url.path,
                    bytes: Int64(size),
                    modifiedAt: values.contentModificationDate ?? .distantPast
                ))
            } catch {
                hadError = true
            }
        }

        // 根目录本身被 TCC 拒绝时通常枚举器为空且没有条目；把它当作不可读提示。
        let unreadable = items.isEmpty && hadError
        return (items, timedOut, unreadable)
    }

    /// 同一个 inode 的多个硬链接不是多份占用；列表只留一条，避免重复计数。
    private static func uniqueInodes(_ items: [FileMetadata]) -> [FileMetadata] {
        var seen = Set<String>()
        return items.filter { seen.insert($0.inode).inserted }
    }

    struct DuplicateScan: Sendable {
        var review: DuplicateReview
        var note: String
        var unreadable: [String]
    }

    /// 重复核对只在个人常用目录做，避免把系统库和照片图库整体读一遍。
    /// 先用 Spotlight 给 1–600 MB 的候选，再按体积分组；只有同体积候选才读取内容算 SHA-256。
    /// 最多 80 个候选、合计 3 GB，保证一次核对不会长时间占住磁盘。
    static func duplicateFiles(home: String, timeout: TimeInterval = 15) -> DuplicateScan {
        let roots = reviewRoots(home: home)
        let scan = concurrentMetadata(roots: roots,
                                      minBytes: 1_000_000,
                                      maxBytes: 600_000_000,
                                      timeout: min(15, timeout))
        let candidates = uniqueInodes(scan.items).map {
            DuplicateFileRecord(path: $0.path, bytes: $0.bytes,
                                modifiedAt: $0.modifiedAt, digest: "")
        }

        // 体积唯一的文件不可能是重复文件，直接排除。
        let bySize = Dictionary(grouping: candidates, by: \.bytes)
        let sizeGroups = bySize.values.filter { $0.count > 1 }.map { group -> (files: [DuplicateFileRecord], waste: Int64) in
            let files = group.sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
            let waste = (files.first?.bytes ?? 0) * Int64(files.count - 1)
            return (files, waste)
        }
        .sorted {
            if $0.waste != $1.waste { return $0.waste > $1.waste }
            return $0.files.count > $1.files.count
        }

        let maxCandidates = 80
        let maxBytes: Int64 = 3_000_000_000
        var selected: [DuplicateFileRecord] = []
        var selectedBytes: Int64 = 0
        var skippedBecauseOfLimit = 0
        for sizeGroup in sizeGroups {
            let groupBytes = (sizeGroup.files.first?.bytes ?? 0) * Int64(sizeGroup.files.count)
            guard selected.count + sizeGroup.files.count <= maxCandidates,
                  selectedBytes + groupBytes <= maxBytes else {
                skippedBecauseOfLimit += sizeGroup.files.count
                continue
            }
            selected.append(contentsOf: sizeGroup.files)
            selectedBytes += groupBytes
        }
        let truncated = skippedBecauseOfLimit > 0

        var hashedRecords: [DuplicateFileRecord] = []
        var skippedFiles = 0
        for candidate in selected {
            if let digest = sha256(path: candidate.path) {
                hashedRecords.append(DuplicateFileRecord(path: candidate.path, bytes: candidate.bytes,
                                                         modifiedAt: candidate.modifiedAt, digest: digest))
            } else {
                skippedFiles += 1
            }
        }

        let groups = DuplicateGrouper.group(hashedRecords)
        let timedOut = scan.timedOut
        let review = DuplicateReview(groups: groups, candidates: selected.count,
                                     hashedFiles: hashedRecords.count, skippedFiles: skippedFiles,
                                     truncated: truncated, timedOut: timedOut)
        let limitNote = truncated ? "；候选较多，已优先核对体积浪费更大的 \(selected.count) 个" : ""
        let skippedNote = skippedFiles > 0 ? "；\(skippedFiles) 个读取失败已跳过" : ""
        let timeoutNote = timedOut ? "；有目录未在时限内读完，结果可能不完整" : ""
        let unreadableNote = scan.unreadable.isEmpty ? "" : "；系统未允许读取 " + scan.unreadable.map { ($0 as NSString).lastPathComponent }.joined(separator: "、")
        let note = groups.isEmpty
            ? "没有发现内容相同的重复文件（已核对 \(hashedRecords.count) 个候选\(limitNote)\(skippedNote)\(timeoutNote)\(unreadableNote)）。"
            : "发现 \(groups.count) 组重复文件（已核对 \(hashedRecords.count) 个候选\(limitNote)\(skippedNote)\(timeoutNote)\(unreadableNote)）。"
        return DuplicateScan(review: review, note: note, unreadable: scan.unreadable)
    }

    private static func sha256(path: String) -> String? {
        guard let handle = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? handle.close() }
        var hasher = SHA256()
        do {
            while let chunk = try handle.read(upToCount: 1_048_576), !chunk.isEmpty {
                hasher.update(data: chunk)
            }
        } catch {
            return nil
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    // MARK: - 应用清单

    static func applications() -> [AppEntry] {
        let home = NSHomeDirectory()
        let bases = ["/Applications", "/Applications/Utilities",
                     "/System/Applications", "/System/Applications/Utilities",
                     home + "/Applications"]
        var seen = Set<String>()
        var rows: [AppEntry] = []

        func append(_ url: URL, nested: Bool) {
            let entry = appEntry(at: url, isNestedInstall: nested)
            // 不允许卸载雪自己，也不允许把系统组件当普通应用。
            if entry.bundleID == Bundle.main.bundleIdentifier
                || URL(fileURLWithPath: entry.path).resolvingSymlinksInPath().path == Bundle.main.bundlePath {
                return
            }
            guard seen.insert(entry.path).inserted else { return }
            rows.append(entry)
        }

        for base in bases {
            let directory = URL(fileURLWithPath: base)
            guard let children = try? FileManager.default.contentsOfDirectory(
                at: directory, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]
            ) else { continue }
            for url in children where url.pathExtension == "app" {
                append(url, nested: false)
            }
        }

        // 后期软件常装在 /Applications/厂商目录/应用.app。只扫一层厂商目录，
        // 且要求父目录名与应用名互相吻合，避免把崩溃报告、卸载器等助手当成主应用。
        let top = URL(fileURLWithPath: "/Applications")
        if let children = try? FileManager.default.contentsOfDirectory(
            at: top, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]
        ) {
            for folder in children where folder.pathExtension != "app" {
                guard folder.path != "/Applications/Utilities",
                      (try? folder.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
                else { continue }
                guard let nested = try? FileManager.default.contentsOfDirectory(
                    at: folder, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]
                ) else { continue }
                for url in nested where url.pathExtension == "app" {
                    guard shouldIncludeNestedApp(url: url, in: folder) else { continue }
                    append(url, nested: true)
                }
            }
        }
        return rows.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    /// 只收「厂商目录名 ≈ 应用名」的嵌套主应用：
    /// Adobe Photoshop 2027 / Adobe Photoshop 2027.app 会收；
    /// Adobe Photoshop 2027 / AdobeCrashReport.app 不会收。
    static func shouldIncludeNestedApp(url: URL, in folder: URL) -> Bool {
        ApplicationInstallPolicy.isNestedMainApp(
            appName: url.deletingPathExtension().lastPathComponent,
            folderName: folder.lastPathComponent
        )
    }

    static func appEntry(at url: URL, isNestedInstall: Bool = false) -> AppEntry {
        let bundle = Bundle(url: url)
        let info = bundle?.infoDictionary
        let display = (info?["CFBundleDisplayName"] as? String) ?? (info?["CFBundleName"] as? String)
        let name = display?.trimmingCharacters(in: .whitespaces).isEmpty == false
            ? display! : url.deletingPathExtension().lastPathComponent
        let bundleID = (info?["CFBundleIdentifier"] as? String) ?? bundle?.bundleIdentifier ?? ""
        let version = (info?["CFBundleShortVersionString"] as? String) ?? (info?["CFBundleVersion"] as? String)
        let system = url.path.hasPrefix("/System/") || bundleID.hasPrefix("com.apple.")
        let store = FileManager.default.fileExists(
            atPath: url.appendingPathComponent("Contents/_MASReceipt/receipt").path
        )
        return AppEntry(name: name, bundleID: bundleID, path: url.path, version: version,
                        isSystem: system, isAppStore: store,
                        hasResiduals: !residuals(for: bundleID).isEmpty,
                        isNestedInstall: isNestedInstall)
    }

    static func appSize(path: String, timeout: TimeInterval? = nil) -> Int64 {
        let result = execute("/usr/bin/du", ["-sk", path], timeout: timeout)
        let kb = result.output.split(separator: "\t").first
            .flatMap { Int64(String($0).trimmingCharacters(in: .whitespaces)) } ?? 0
        return kb * 1024
    }

    /// 只有用户主动按体积排序/查看时才批量算，最多 4 个并发、单项 5 秒超时。
    static func appSizes(_ paths: [String]) -> [String: Int64] {
        guard !paths.isEmpty else { return [:] }
        final class Box: @unchecked Sendable {
            let lock = NSLock()
            var values: [String: Int64] = [:]
            func set(_ path: String, _ bytes: Int64) {
                lock.lock(); values[path] = bytes; lock.unlock()
            }
        }
        let box = Box()
        let gate = DispatchSemaphore(value: 4)
        DispatchQueue.concurrentPerform(iterations: paths.count) { i in
            gate.wait()
            defer { gate.signal() }
            let path = paths[i]
            let bytes = appSize(path: path, timeout: 5)
            if bytes > 0 { box.set(path, bytes) }
        }
        return box.values
    }

    /// 最近使用不是从文件 atime 猜的：用 Spotlight 的 `kMDItemLastUsedDate`。
    /// 读不到就返回 nil，不把「没有记录」当成「未使用」。
    static func lastUsedDate(path: String) -> Date? {
        let result = execute("/usr/bin/mdls", ["-name", "kMDItemLastUsedDate", "-raw", path],
                             timeout: 2)
        let text = result.output.trimmingCharacters(in: .whitespacesAndNewlines)
        guard text != "(null)", !text.isEmpty else { return nil }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss Z"
        return formatter.date(from: text)
    }

    static func appLastUsedDates(_ paths: [String]) -> [String: Date] {
        guard !paths.isEmpty else { return [:] }
        final class Box: @unchecked Sendable {
            let lock = NSLock()
            var values: [String: Date] = [:]
            func set(_ path: String, _ date: Date) {
                lock.lock(); values[path] = date; lock.unlock()
            }
        }
        let box = Box()
        let gate = DispatchSemaphore(value: 4)
        DispatchQueue.concurrentPerform(iterations: paths.count) { i in
            gate.wait()
            defer { gate.signal() }
            let path = paths[i]
            if let date = lastUsedDate(path: path) { box.set(path, date) }
        }
        return box.values
    }

    static func residuals(for bundleID: String) -> [String] {
        residualGroups(for: bundleID).flatMap(\.paths)
    }

    static func residualGroups(for bundleID: String) -> [ResidualGroup] {
        guard !bundleID.isEmpty else { return [] }
        let home = NSHomeDirectory()
        let candidates: [(String, String)] = [
            ("应用支持", "\(home)/Library/Application Support/\(bundleID)"),
            ("缓存", "\(home)/Library/Caches/\(bundleID)"),
            ("沙盒容器", "\(home)/Library/Containers/\(bundleID)"),
            ("偏好设置", "\(home)/Library/Preferences/\(bundleID).plist"),
            ("窗口恢复", "\(home)/Library/Saved Application State/\(bundleID).savedState"),
            ("日志", "\(home)/Library/Logs/\(bundleID)"),
            ("网络缓存", "\(home)/Library/HTTPStorages/\(bundleID)"),
            ("WebKit 数据", "\(home)/Library/WebKit/\(bundleID)"),
            ("Cookie", "\(home)/Library/Cookies/\(bundleID).binarycookies")
        ]
        var groups: [String: [String]] = [:]
        for (title, path) in candidates where FileManager.default.fileExists(atPath: path) {
            groups[title, default: []].append(path)
        }
        return candidates.compactMap { title, _ in
            guard let paths = groups[title], !paths.isEmpty else { return nil }
            return ResidualGroup(id: title, title: title, paths: paths)
        }
    }

    // MARK: - 审计历史

    static func audit() -> (events: [AuditEvent], verification: AuditVerification?) {
        let log = AuditLog()
        let events = (try? log.events()) ?? []
        let verification = try? log.verify()
        return (events, verification)
    }

    static func actionText(_ action: AuditAction) -> String {
        switch action {
        case .dryRun: return "预览"
        case .moveToTrash: return "移到废纸篓"
        case .moveToTrashFailed: return "移废纸篓失败"
        case .skippedAfterTrashFailure: return "失败后跳过"
        case .movedToBackup: return "移入备份"
        case .backupFailed: return "备份失败"
        case .permanentDelete: return "永久删除"
        case .permanentDeleteFailed: return "永久删除失败"
        case .policyRejected: return "策略拒绝"
        case .protectionChanged: return "保护清单变更"
        case .targetRejected: return "身份复核拒绝"
        }
    }
}
