import Foundation

/// 系统蓝牙设置能显示第三方 BLE 鼠标电量，但 `system_profiler` / `ioreg` 不带这个字段。
/// macOS 会把配件电量登记成 bluetoothd 的 CBPowerSource，并以文本写入本机统一日志：
/// `Power source updated CBPowerSource Nm 'UGREEN BLE Mouse', ... Battery -90%`
/// 这里只解析本机日志文本，不联网、不改设置。日志里的负号是系统内部方向标记，
/// 系统设置显示的 90% 对应这里的绝对值。
public enum BluetoothPowerSourceLog {
    public struct Reading: Equatable, Sendable {
        public let name: String
        public let percent: Int
        public let isPresent: Bool

        public init(name: String, percent: Int, isPresent: Bool) {
            self.name = name
            self.percent = percent
            self.isPresent = isPresent
        }
    }

    /// 解析 `log show` 输出，同名设备按出现顺序后者覆盖前者（取最新一条）。
    public static func parse(_ text: String) -> [String: Reading] {
        var result: [String: Reading] = [:]
        for line in text.split(separator: "\n") {
            let line = String(line)
            guard line.contains("CBPowerSource"),
                  let name = quotedValue(after: "Nm '", in: line) ?? quotedValue(after: "Nm \"", in: line),
                  let percent = batteryPercent(in: line) else { continue }
            let present = line.contains("Present yes") || line.contains("Present 1")
            let reading = Reading(name: name, percent: percent, isPresent: present)
            result[name] = reading
        }
        return result
    }

    /// 只取「已连接、确实有电量、但 system_profiler 没读到」的设备。
    public static func fillMissing(
        deviceName: String,
        currentBattery: Int?,
        readings: [String: Reading]
    ) -> Int? {
        guard currentBattery == nil,
              let reading = readings[deviceName],
              reading.isPresent,
              reading.percent >= 0,
              reading.percent <= 100 else { return nil }
        return reading.percent
    }

    private static func quotedValue(after marker: String, in line: String) -> String? {
        guard let range = line.range(of: marker) else { return nil }
        let rest = line[range.upperBound...]
        guard let end = rest.firstIndex(of: marker.hasSuffix("'") ? "'" : "\"") else { return nil }
        let value = String(rest[..<end]).trimmingCharacters(in: .whitespaces)
        return value.isEmpty ? nil : value
    }

    private static func batteryPercent(in line: String) -> Int? {
        guard let range = line.range(of: "Battery ") else { return nil }
        let rest = line[range.upperBound...]
        guard let end = rest.firstIndex(of: "%") else { return nil }
        let raw = rest[..<end].trimmingCharacters(in: .whitespaces)
        guard let value = Int(raw) else { return nil }
        let percent = abs(value)
        guard percent >= 0, percent <= 100 else { return nil }
        return percent
    }
}
