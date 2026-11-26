import Foundation
import CoreFoundation
import Darwin

/// Apple Silicon 上没有公开的「读 CPU 温度」API；系统只给 `ProcessInfo.thermalState`。
/// 这里走 IOHIDEventSystemClient 的传感器服务，读取 PMU tdie 节点的温度事件。
/// 只读、无 root、无网络；接口不可用时返回 nil，界面必须显示「读不到」。
struct ThermalSnapshot: Sendable {
    let socCelsius: Double?
    let sensorCount: Int
    let batteryCelsius: Double?
    let source: String
    let socMinCelsius: Double?
    let socMaxCelsius: Double?

    init(socCelsius: Double?, sensorCount: Int, batteryCelsius: Double?, source: String,
         socMinCelsius: Double? = nil, socMaxCelsius: Double? = nil) {
        self.socCelsius = socCelsius
        self.sensorCount = sensorCount
        self.batteryCelsius = batteryCelsius
        self.source = source
        self.socMinCelsius = socMinCelsius
        self.socMaxCelsius = socMaxCelsius
    }
}

final class HIDTemperatureReader: @unchecked Sendable {
    static let shared = HIDTemperatureReader()

    private struct API {
        let create: @convention(c) (CFAllocator?) -> UnsafeMutableRawPointer?
        let setMatching: @convention(c) (UnsafeMutableRawPointer, CFDictionary) -> Void
        let copyServices: @convention(c) (UnsafeMutableRawPointer) -> CFArray?
        let copyProperty: @convention(c) (UnsafeMutableRawPointer, CFString) -> UnsafeMutableRawPointer?
        let copyEvent: @convention(c) (UnsafeMutableRawPointer, Int32, Int32, Int64) -> UnsafeMutableRawPointer?
        let getFloat: @convention(c) (UnsafeMutableRawPointer, Int32) -> Double
    }

    private let lock = NSLock()
    private var cached: (at: Date, value: ThermalSnapshot)?
    private var client: UnsafeMutableRawPointer?
    private let api: API?

    private init() {
        guard let handle = dlopen("/System/Library/Frameworks/IOKit.framework/Versions/A/IOKit", RTLD_LAZY) else {
            api = nil
            return
        }
        func symbol<T>(_ name: String, as type: T.Type) -> T? {
            guard let pointer = dlsym(handle, name) else { return nil }
            return unsafeBitCast(pointer, to: T.self)
        }
        guard let create = symbol("IOHIDEventSystemClientCreate", as: (@convention(c) (CFAllocator?) -> UnsafeMutableRawPointer?).self),
              let setMatching = symbol("IOHIDEventSystemClientSetMatching", as: (@convention(c) (UnsafeMutableRawPointer, CFDictionary) -> Void).self),
              let copyServices = symbol("IOHIDEventSystemClientCopyServices", as: (@convention(c) (UnsafeMutableRawPointer) -> CFArray?).self),
              let copyProperty = symbol("IOHIDServiceClientCopyProperty", as: (@convention(c) (UnsafeMutableRawPointer, CFString) -> UnsafeMutableRawPointer?).self),
              let copyEvent = symbol("IOHIDServiceClientCopyEvent", as: (@convention(c) (UnsafeMutableRawPointer, Int32, Int32, Int64) -> UnsafeMutableRawPointer?).self),
              let getFloat = symbol("IOHIDEventGetFloatValue", as: (@convention(c) (UnsafeMutableRawPointer, Int32) -> Double).self)
        else {
            api = nil
            return
        }
        api = API(create: create, setMatching: setMatching, copyServices: copyServices,
                  copyProperty: copyProperty, copyEvent: copyEvent, getFloat: getFloat)
    }

    func read(force: Bool = false) -> ThermalSnapshot {
        lock.lock()
        defer { lock.unlock() }
        // 温度变化慢；状态页每 8 秒刷新时复用 30 秒缓存，避免反复枚举 46 个 HID 服务。
        // 快速面板是用户主动打开，force=true 现读一次。
        if !force, let cached, Date().timeIntervalSince(cached.at) < 30 {
            return cached.value
        }
        let value = readUncached()
        cached = (Date(), value)
        return value
    }

    private func readUncached() -> ThermalSnapshot {
        guard let api else {
            return ThermalSnapshot(socCelsius: nil, sensorCount: 0, batteryCelsius: nil, source: "IOHID 传感器接口不可用")
        }
        let readyClient: UnsafeMutableRawPointer
        if let client {
            readyClient = client
        } else {
            guard let created = api.create(kCFAllocatorDefault) else {
                return ThermalSnapshot(socCelsius: nil, sensorCount: 0, batteryCelsius: nil, source: "IOHID 客户端不可用")
            }
            client = created
            readyClient = created
        }
        // PrimaryUsagePage 65280 / PrimaryUsage 5 是 Apple 的 PMU 温度传感器集合。
        let matching = ["PrimaryUsagePage": 65280, "PrimaryUsage": 5] as CFDictionary
        api.setMatching(readyClient, matching)
        guard let services = api.copyServices(readyClient) else {
            return ThermalSnapshot(socCelsius: nil, sensorCount: 0, batteryCelsius: nil, source: "没有温度传感器")
        }
        var dieTemps: [Double] = []
        var batteryTemps: [Double] = []
        let count = CFArrayGetCount(services)
        for index in 0..<count {
            guard let rawService = CFArrayGetValueAtIndex(services, index) else { continue }
            let service = UnsafeMutableRawPointer(mutating: rawService)
            guard let rawName = api.copyProperty(service, "Product" as CFString) else { continue }
            let name = Unmanaged<CFString>.fromOpaque(rawName).takeRetainedValue() as String
            guard let event = api.copyEvent(service, 15, 0, 0) else { continue }
            defer { Unmanaged<AnyObject>.fromOpaque(event).release() }
            let celsius = api.getFloat(event, (15 << 16) | 0)
            guard celsius.isFinite, celsius > 0, celsius < 150 else { continue }
            let lowered = name.lowercased()
            if lowered.contains("tdie") {
                dieTemps.append(celsius)
            } else if lowered.contains("gas gauge") {
                batteryTemps.append(celsius)
            }
        }
        let soc = dieTemps.isEmpty ? nil : dieTemps.reduce(0, +) / Double(dieTemps.count)
        let socMin = dieTemps.min()
        let socMax = dieTemps.max()
        let battery = batteryTemps.isEmpty ? nil : batteryTemps.reduce(0, +) / Double(batteryTemps.count)
        return ThermalSnapshot(
            socCelsius: soc,
            sensorCount: dieTemps.count,
            batteryCelsius: battery,
            source: dieTemps.isEmpty
                ? "HID 温度节点未返回数值"
                : "CPU / SoC · PMU tdie 平均（IOHID 未公开接口）",
            socMinCelsius: socMin,
            socMaxCelsius: socMax
        )
    }
}
