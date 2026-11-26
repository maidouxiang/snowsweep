import SwiftUI
import AppKit

// MARK: - 内存

private enum ProcessSort: String, CaseIterable, Identifiable {
    case memory = "内存占用"
    case cpu = "CPU"
    case name = "名称"
    var id: String { rawValue }
}

struct MemoryView: View {
    @EnvironmentObject var monitor: SystemMonitor
    @State private var samples: [Double] = []
    @State private var search = ""
    @State private var sort: ProcessSort = .memory

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .top) {
                    PageHeader(title: "内存", subtitle: "看看是谁占了内存。进程名尽量翻成中文，原始名折叠在下面。")
                    Spacer()
                    Button("刷新") { Task { await monitor.refreshMemoryOnly(limit: 40) } }
                }

                if let memory = monitor.memory {
                    HStack(alignment: .top, spacing: 14) {
                        ModuleCard {
                            HStack(spacing: 18) {
                                GaugeRing(fraction: memory.usedFraction,
                                          big: SystemMetrics.bytesText(memory.usedBytes),
                                          small: "已用 / \(SystemMetrics.bytesText(memory.totalBytes))",
                                          color: pressureTint(memory.usedFraction))
                                VStack(alignment: .leading, spacing: 5) {
                                    Text("内存压力\(memory.pressureLabel)").font(.title3.weight(.semibold))
                                    Text("物理内存 \(SystemMetrics.bytesText(memory.totalBytes))")
                                        .font(.callout).foregroundStyle(.secondary)
                                    Text(memory.swapUsedBytes > 0
                                         ? "交换空间已用 \(SystemMetrics.bytesText(memory.swapUsedBytes))"
                                         : "没有使用交换空间")
                                        .font(.callout).foregroundStyle(.secondary)
                                }
                            }
                        }
                        HStack(spacing: 10) {
                            MetricTile(title: "正在使用", value: SystemMetrics.bytesText(memory.usedBytes),
                                       foot: "含活跃与压缩内存", color: .blue)
                            MetricTile(title: "压缩内存", value: SystemMetrics.bytesText(memory.compressedBytes),
                                       foot: "系统自动压缩", color: .purple)
                            MetricTile(title: "交换空间", value: SystemMetrics.bytesText(memory.swapUsedBytes),
                                       foot: "写入磁盘的临时内存", color: .orange)
                        }
                        .frame(maxWidth: .infinity)
                    }

                    ModuleCard {
                        VStack(alignment: .leading, spacing: 6) {
                            HStack {
                                Text("内存压力（本次打开后最多 5 分钟）").font(.headline)
                                Spacer()
                                if !samples.isEmpty {
                                    Text("峰值 \(Int((samples.max() ?? 0) * 100))% · 平均 \(Int(averageSample * 100))%")
                                        .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                                }
                            }
                            Text("绿色 0–60% 健康，黄色 60–80% 需注意，红色 80% 以上偏高；每 2 秒采样，本次最多保留 150 个点")
                                .font(.caption).foregroundStyle(.secondary)
                            MemorySparkline(samples: samples)
                                .frame(height: 120)
                        }
                    }
                } else {
                    InfoBanner(text: "正在读取内存信息…")
                }

                ModuleCard {
                    VStack(spacing: 0) {
                        HStack(spacing: 10) {
                            Text("进程").font(.headline)
                            TextField("搜索进程名或 PID（回车生效）", text: $search)
                                .textFieldStyle(.roundedBorder)
                                .frame(maxWidth: 260)
                            Picker("排序", selection: $sort) {
                                ForEach(ProcessSort.allCases) { item in
                                    Text(item.rawValue).tag(item)
                                }
                            }
                            .pickerStyle(.menu)
                            .labelsHidden()
                            .frame(width: 116)
                            Spacer()
                            Text("\(filteredProcesses.count) / \(monitor.processes.count) 个")
                                .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                        }
                        .padding(.bottom, 7)
                        HStack {
                            Text("程序（中文名）").frame(maxWidth: .infinity, alignment: .leading)
                            Text("占用").frame(width: 90, alignment: .trailing)
                            Text("CPU").frame(width: 70, alignment: .trailing)
                        }
                        .font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                        .padding(.vertical, 7)
                        Divider()
                        if filteredProcesses.isEmpty {
                            Text("没有匹配的进程。搜索只覆盖当前已加载的前 \(monitor.processes.count) 个进程。")
                                .font(.caption).foregroundStyle(.secondary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.vertical, 10)
                        }
                        ForEach(filteredProcesses) { row in
                            HStack {
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(row.chineseName).font(.callout)
                                    Text("\(row.rawName) · PID \(row.pid)").font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                                Text(SystemMetrics.bytesText(row.memoryBytes))
                                    .font(.callout.monospacedDigit()).frame(width: 90, alignment: .trailing)
                                Text(String(format: "%.1f%%", row.cpuPercent))
                                    .font(.callout.monospacedDigit()).frame(width: 70, alignment: .trailing)
                            }
                            .padding(.vertical, 5)
                            Divider()
                        }
                    }
                }
            }
            .padding(18)
        }
        .task {
            await monitor.refreshMemoryOnly(limit: 40)
            await tickLoop()
        }
    }

    private var averageSample: Double {
        guard !samples.isEmpty else { return 0 }
        return samples.reduce(0, +) / Double(samples.count)
    }

    private var filteredProcesses: [ProcessRow] {
        let base = monitor.processes.filter { row in
            guard !search.isEmpty else { return true }
            return row.chineseName.localizedCaseInsensitiveContains(search)
                || row.rawName.localizedCaseInsensitiveContains(search)
                || "\(row.pid)".contains(search)
        }
        switch sort {
        case .memory:
            return base.sorted { $0.memoryBytes > $1.memoryBytes }
        case .cpu:
            return base.sorted { $0.cpuPercent > $1.cpuPercent }
        case .name:
            return base.sorted { $0.chineseName.localizedStandardCompare($1.chineseName) == .orderedAscending }
        }
    }

    private func tickLoop() async {
        while !Task.isCancelled {
            if let memory = monitor.memory {
                samples.append(memory.usedFraction)
                if samples.count > 150 { samples.removeFirst(samples.count - 150) }
            }
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            if Task.isCancelled { break }
            await monitor.refreshMemoryOnly(limit: 40)
        }
    }
}

private struct GaugeRing: View {
    let fraction: Double
    let big: String
    let small: String
    let color: Color
    var body: some View {
        ZStack {
            Circle().stroke(Color.secondary.opacity(0.16), lineWidth: 10)
            Circle().trim(from: 0, to: CGFloat(min(1, max(0, fraction))))
                .stroke(color, style: StrokeStyle(lineWidth: 10, lineCap: .round))
                .rotationEffect(.degrees(-90))
            VStack(spacing: 1) {
                Text(big).font(.system(size: 19, weight: .bold, design: .rounded))
                Text(small).font(.caption2).foregroundStyle(.secondary)
            }
        }
        .frame(width: 118, height: 118)
    }
}

private struct MemorySparkline: View {
    let samples: [Double]
    var body: some View {
        GeometryReader { geo in
            let width = geo.size.width
            let height = geo.size.height
            ZStack {
                ForEach([0.6, 0.8], id: \.self) { level in
                    Path { path in
                        path.move(to: CGPoint(x: 0, y: height * (1 - level)))
                        path.addLine(to: CGPoint(x: width, y: height * (1 - level)))
                    }
                    .stroke(Color.secondary.opacity(0.18), lineWidth: 1)
                }
                Path { path in
                    guard !samples.isEmpty else { return }
                    let step = width / CGFloat(max(1, samples.count - 1))
                    for (index, value) in samples.enumerated() {
                        let point = CGPoint(x: CGFloat(index) * step, y: height * (1 - CGFloat(value)))
                        if index == 0 { path.move(to: point) } else { path.addLine(to: point) }
                    }
                }
                .stroke(Color.blue, lineWidth: 2)
            }
        }
    }
}

// MARK: - 电池健康

struct BatteryView: View {
    @EnvironmentObject var monitor: SystemMonitor

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .top) {
                    PageHeader(title: "电池健康", subtitle: "这里直接看容量、循环次数和充电状态；温度先读系统字段，读不到再用本机传感器补，不估算。")
                    Spacer(minLength: 12)
                    HStack(spacing: 8) {
                        Text("数据来自本机 · 不上传")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                        Button("刷新") { Task { await monitor.refreshBatteryOnly(forceThermal: true) } }
                            .disabled(monitor.isRefreshing)
                    }
                    .fixedSize()
                }

                if let battery = monitor.battery {
                    ViewThatFits(in: .horizontal) {
                        HStack(alignment: .top, spacing: 14) {
                            batteryHealthCard(battery)
                                .frame(width: 360)
                            batteryStatsCard(battery)
                                .frame(width: 780)
                        }
                        VStack(alignment: .leading, spacing: 14) {
                            batteryHealthCard(battery)
                            batteryStatsCard(battery)
                        }
                    }

                    ModuleCard {
                        HStack(alignment: .top, spacing: 9) {
                            Image(systemName: "lightbulb").foregroundStyle(.blue)
                            VStack(alignment: .leading, spacing: 3) {
                                Text("建议：长期插电时开启「优化充电」").font(.body.weight(.medium))
                                Text("系统会把电量限制在 80% 左右以减缓老化。这个开关在「系统设置 › 电池」，本软件只提醒，不代为修改。")
                                    .font(.callout).foregroundStyle(.secondary)
                            }
                        }
                    }

                    if battery.thermalPressure == .serious || battery.thermalPressure == .critical {
                        InfoBanner(text: "系统热压力已到「\(battery.thermalPressure.rawValue)」。先保存工作、降低负载；这是系统状态，不是温度数值。",
                                   color: .orange)
                    }
                    InfoBanner(text: "电池温度优先读系统电池字典；没有时读本机 IOHID 的「gas gauge battery」传感器。两者都没有就写「未读到」，不估算，也不拿 SoC 温度冒充电池温度。",
                               color: .gray)
                    InfoBanner(text: "剩余时间与充满时间只采用系统 IORegistry 给出的值；充电或充满时系统常返回 65535 哨兵值，雪不会把它换算成小时数，也不会自行估算。",
                               color: .gray)
                    InfoBanner(text: "macOS 不向第三方提供「按 App 耗电」的实时数据，所以这里不编造瓦数。想看谁在耗电，可以在「内存」页按 CPU 占用排序，或去系统自带的「电池」面板。",
                               color: .blue)
                } else {
                    InfoBanner(text: "读不到电池信息。台式 Mac 或没有电池的机型本来就没有这一项。", color: .gray)
                }
            }
            .padding(18)
        }
        .task {
            if monitor.battery == nil || monitor.thermal == nil {
                await monitor.refreshBatteryOnly()
            }
        }
    }

    private func batteryHealthCard(_ battery: BatterySnapshot) -> some View {
        ModuleCard {
            HStack(spacing: 18) {
                GaugeRing(fraction: (battery.healthPercent ?? 0) / 100,
                          big: battery.healthPercent.map { "\(Int($0))%" } ?? "—",
                          small: "电池健康度",
                          color: (battery.healthPercent ?? 0) >= 85 ? .green : .orange)
                VStack(alignment: .leading, spacing: 5) {
                    Text(battery.conditionLabel).font(.title3.weight(.semibold))
                    if let max = battery.maxCapacity, let design = battery.designCapacity {
                        Text("当前满电容量 \(max) mAh")
                            .font(.callout).monospacedDigit()
                        Text("出厂设计容量 \(design) mAh")
                            .font(.callout).foregroundStyle(.secondary).monospacedDigit()
                        if let raw = battery.rawHealthPercent,
                           let shown = battery.healthPercent,
                           abs(raw - shown) >= 0.5 {
                            Text("系统平滑后显示 \(Int(shown))%；原始容量比值 \(Int(raw))%")
                                .font(.caption2).foregroundStyle(.secondary)
                                .lineSpacing(1)
                        }
                    } else {
                        Text("未读到设计容量，只能显示系统给出的健康度。")
                            .font(.callout).foregroundStyle(.secondary)
                    }
                }
                .fixedSize(horizontal: false, vertical: true)
                .layoutPriority(1)
            }
            .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func batteryStatsCard(_ battery: BatterySnapshot) -> some View {
        ModuleCard {
            VStack(alignment: .leading, spacing: 12) {
                LazyVGrid(columns: [GridItem(.flexible(minimum: 100)),
                                    GridItem(.flexible(minimum: 100)),
                                    GridItem(.flexible(minimum: 100)),
                                    GridItem(.flexible(minimum: 100))],
                          alignment: .leading, spacing: 14) {
                    batteryStat("循环次数", battery.cycleCount.map { "\($0) 次" } ?? "未读到")
                    batteryStat("当前电量", battery.chargePercent.map { "\($0)%" } ?? "未读到")
                    batteryStat("电池温度", batteryTemperatureText(battery),
                                detail: batteryTemperatureSource(battery))
                    batteryStat("充电状态", battery.isCharging ? "正在充电" : (battery.externalPower ? "已接电源" : "未充电"))
                    batteryStat("剩余时间", timeRemainingValue(battery),
                                detail: timeRemainingDetail(battery))
                    batteryStat("电源适配器", battery.adapterWatts.map { "\($0) W" } ?? "未读到")
                    batteryStat("低电量模式", battery.lowPowerMode ? "已开启" : "关闭")
                    batteryStat("系统热压力", battery.thermalPressure.rawValue)
                }
                MetricBar(fraction: (battery.healthPercent ?? 0) / 100,
                          color: (battery.healthPercent ?? 0) >= 85 ? .green : .orange)
                Text("容量条按健康度绘制，不做任何美化")
                    .font(.caption2).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func batteryTemperatureText(_ battery: BatterySnapshot) -> String {
        guard let celsius = battery.temperatureC ?? monitor.thermal?.batteryCelsius else {
            return "未读到"
        }
        return String(format: "%.1f °C", celsius)
    }

    private func batteryTemperatureSource(_ battery: BatterySnapshot) -> String? {
        if battery.temperatureC != nil { return "系统电池字段" }
        if monitor.thermal?.batteryCelsius != nil { return "本机 HID 传感器" }
        return "系统与 HID 都没有"
    }

    private func timeRemainingValue(_ battery: BatterySnapshot) -> String {
        if battery.isCharging { return "充电中" }
        if battery.externalPower { return "已接电源" }
        guard let minutes = battery.timeRemainingMinutes else { return "未读到" }
        if minutes <= 0 { return "小于 1 分钟" }
        let hours = minutes / 60
        let rest = minutes % 60
        return hours > 0 ? "约 \(hours) 小时 \(rest) 分" : "约 \(rest) 分"
    }

    private func timeRemainingDetail(_ battery: BatterySnapshot) -> String? {
        if battery.isCharging { return "系统不给充满时间" }
        if battery.externalPower { return "系统不给剩余时间" }
        guard battery.timeRemainingMinutes != nil else { return "系统未给出估算" }
        return "系统估算，不自行计算"
    }

    private func batteryStat(_ title: String, _ value: String, detail: String? = nil) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(value)
                .font(.callout.weight(.medium))
                .lineLimit(1)
                .minimumScaleFactor(0.85)
            if let detail {
                Text(detail)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .lineSpacing(1)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - 蓝牙外设

struct BluetoothView: View {
    @EnvironmentObject var monitor: SystemMonitor

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .top) {
                    PageHeader(title: "蓝牙外设", subtitle: "鼠标、键盘、耳机、手机……电量集中在这里看，低电量会提醒你。")
                    Spacer()
                    Button("重新搜索") { Task { await monitor.refreshBluetooth(force: true) } }
                        .disabled(monitor.isRefreshing)
                }

                if monitor.bluetooth.isEmpty {
                    InfoBanner(text: "没有读到蓝牙设备。可能是没有已配对的外设，或系统正在刷新。点「重新搜索」再试一次；读不到时不会编造设备。", color: .gray)
                } else {
                    HStack(spacing: 12) {
                        Text("共 \(monitor.bluetooth.count) 个 · 已连接 \(monitor.bluetooth.filter(\.connected).count) 个")
                            .font(.caption).foregroundStyle(.secondary)
                        if lowBatteryCount > 0 {
                            Text("低电 \(lowBatteryCount) 个")
                                .font(.caption.weight(.semibold)).foregroundStyle(.orange)
                        }
                        Spacer()
                    }
                    ModuleCard(padding: 0) {
                        VStack(spacing: 0) {
                            ForEach(sortedDevices) { device in
                                HStack(spacing: 12) {
                                    Image(systemName: deviceIcon(device.name, minorType: device.minorType))
                                        .font(.title3).foregroundStyle(.purple)
                                        .frame(width: 32)
                                    VStack(alignment: .leading, spacing: 2) {
                                        HStack(spacing: 6) {
                                            Text(device.name).font(.callout.weight(.medium))
                                            if let level = device.minBattery {
                                                Text(batteryGrade(level).0)
                                                    .font(.caption2.weight(.semibold))
                                                    .foregroundStyle(batteryGrade(level).1)
                                            }
                                        }
                                        if let detail = device.batteryDetail {
                                            Text(detail).font(.caption).foregroundStyle(.secondary)
                                        } else if device.connected && device.minBattery == nil {
                                            Text("设备未提供 Battery Level")
                                                .font(.caption2).foregroundStyle(.secondary)
                                        }
                                        HStack(spacing: 8) {
                                            if let rssi = device.rssi {
                                                Text("信号 \(rssi) dBm").font(.caption2).foregroundStyle(.secondary)
                                            }
                                            Text(lastSeenText(device)).font(.caption2).foregroundStyle(.secondary)
                                        }
                                    }
                                    Spacer()
                                    if let battery = device.minBattery {
                                        VStack(alignment: .trailing, spacing: 3) {
                                            Text("\(battery)%").font(.callout.monospacedDigit())
                                                .foregroundStyle(batteryGrade(battery).1)
                                            MetricBar(fraction: Double(battery) / 100,
                                                      color: batteryGrade(battery).1)
                                                .frame(width: 90)
                                        }
                                    } else {
                                        Text(device.connected ? "未上报电量" : "—")
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                            .lineLimit(1)
                                            .help(device.connected
                                                  ? "系统没有给出 Battery Level，雪不估算"
                                                  : "设备未连接，不读取电量")
                                    }
                                    Text(device.connected ? "已连接" : "未连接")
                                        .font(.caption2)
                                        .padding(.horizontal, 7).padding(.vertical, 3)
                                        .background((device.connected ? Color.green : Color.gray).opacity(0.12), in: Capsule())
                                        .foregroundStyle(device.connected ? Color.green : Color.secondary)
                                }
                                .padding(13)
                                Divider()
                            }
                        }
                    }
                }

                InfoBanner(text: "只显示系统真实电量。系统没给出 Battery Level 时写「未上报电量」，不估算；未连接设备不读电量。低于 40% 标「偏低」、低于 20% 标「低电」、低于 10% 标「紧急」；多部件设备按最低电量分级。",
                           color: .orange)
            }
            .padding(18)
        }
        .task { if monitor.bluetooth.isEmpty { await monitor.refreshBluetooth() } }
    }

    private var sortedDevices: [BluetoothDeviceRow] {
        monitor.bluetooth.sorted { a, b in
            if a.connected != b.connected { return a.connected }
            let ab = a.minBattery ?? 101
            let bb = b.minBattery ?? 101
            if ab != bb { return ab < bb }
            return a.name.localizedStandardCompare(b.name) == .orderedAscending
        }
    }

    private var lowBatteryCount: Int {
        monitor.bluetooth.filter { ($0.minBattery ?? 100) < 20 }.count
    }

    private func batteryGrade(_ percent: Int) -> (String, Color) {
        switch percent {
        case ..<10: return ("紧急", .red)
        case ..<20: return ("低电", .red)
        case ..<40: return ("偏低", .orange)
        default: return ("正常", .green)
        }
    }

    private func lastSeenText(_ device: BluetoothDeviceRow) -> String {
        if device.connected { return "当前连接中" }
        guard let date = device.lastSeenConnected else { return "雪还没有连接记录" }
        return "最后连接 " + date.formatted(date: .numeric, time: .shortened)
    }

    private func deviceIcon(_ name: String, minorType: String?) -> String {
        let lower = name.lowercased()
        let type = minorType?.lowercased() ?? ""
        if lower.contains("airpods") || lower.contains("耳机") || lower.contains("headphone") || type.contains("headset") { return "airpods" }
        if lower.contains("mouse") || lower.contains("鼠标") || type.contains("mouse") { return "magicmouse" }
        if lower.contains("keyboard") || lower.contains("键盘") || type.contains("keyboard") { return "keyboard" }
        if lower.contains("trackpad") || lower.contains("触控") { return "trackpad" }
        if lower.contains("watch") || lower.contains("手表") { return "applewatch" }
        if lower.contains("phone") || lower.contains("iphone") { return "iphone" }
        return "dot.radiowaves.left.and.right"
    }
}

// MARK: - 机身状态

struct StatusView: View {
    @EnvironmentObject var monitor: SystemMonitor

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .top) {
                    PageHeader(title: "机身状态", subtitle: "实时指标与硬件只读信息。点顶部菜单栏的雪花，不打开窗口也能看。")
                    Spacer(minLength: 12)
                    Text("只读 · 不上传")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize()
                }

                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible()), GridItem(.flexible())], spacing: 12) {
                    MetricTile(title: "磁盘可用",
                               value: monitor.disk.map { SystemMetrics.bytesText($0.freeBytes) } ?? "读不到",
                               foot: monitor.disk.map { "已用 \(Int($0.usedFraction * 100))%" } ?? "读取中",
                               color: .blue)
                    MetricTile(title: "内存压力",
                               value: monitor.memory?.pressureLabel ?? "读不到",
                               foot: monitor.memory.map {
                                   SystemMetrics.bytesText($0.usedBytes) + " / " + SystemMetrics.bytesText($0.totalBytes)
                               } ?? "读取中",
                               color: pressureTint(monitor.memory?.usedFraction))
                    MetricTile(title: "电池",
                               value: batteryPending ? "读取中…" : (monitor.battery?.chargePercent.map { "\($0)%" } ?? "无电池"),
                               foot: batteryPending ? "正在读取电池信息" : batteryFootText,
                               color: batteryPending ? .blue : ((monitor.battery?.chargePercent ?? 100) < 20 ? .orange : .green))
                    MetricTile(title: "CPU",
                               value: monitor.cpu?.usagePercent.map { String(format: "%.0f%%", $0) } ?? "读不到",
                               foot: monitor.cpu.map { "\($0.coreCount) 核 · 负载 \(String(format: "%.1f", $0.load1))" } ?? "正在读取 CPU",
                               color: (monitor.cpu?.usagePercent ?? 0) > 80 ? .red : .green)
                    MetricTile(title: "网络",
                               value: monitor.network?.connected == true ? monitor.network?.kind ?? "已连接" : "未连接",
                               foot: monitor.network?.ipv4 ?? "没有活动的网络接口",
                               color: monitor.network?.connected == true ? .green : .secondary)
                    MetricTile(title: "蓝牙外设",
                               value: "\(monitor.bluetooth.filter(\.connected).count) 个已连接",
                               foot: "电量见「蓝牙外设」页",
                               color: .purple)
                }

                Text("每 5 秒检查 · 指标最多旧 8 秒 · 温度 30 秒")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Text("硬件只读信息").font(.headline)
                Text("只看不改 · 不修改任何系统设置").font(.caption).foregroundStyle(.secondary)

                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible()),
                                    GridItem(.flexible()), GridItem(.flexible())], spacing: 12) {
                    hardwareCard("磁盘健康（SMART）", hardwarePending ? "读取中…" : (monitor.hardware?.smartStatus ?? "未读到"), "Apple Silicon 内置盘只暴露系统验证状态")
                    hardwareCard("系统热压力", hardwarePending ? "读取中…" : (monitor.hardware?.thermalPressure.rawValue ?? monitor.battery?.thermalPressure.rawValue ?? "未读到"), "ProcessInfo 状态，不是温度数值")
                    hardwareCard("CPU / SoC 温度", monitor.thermal?.socCelsius.map { String(format: "%.0f°C", $0) } ?? "未读到", cpuTemperatureDetail)
                    hardwareCard("电池温度", batteryTemperatureText, batteryTemperatureDetail)
                    hardwareCard("低电量模式", hardwarePending ? "读取中…" : ((monitor.hardware?.lowPowerMode ?? monitor.battery?.lowPowerMode ?? false) ? "已开启" : "关闭"), "只读，修改请去系统设置")
                    hardwareCard("处理器", hardwarePending ? "读取中…" : (monitor.hardware?.chip ?? "未读到"),
                                 hardwarePending ? "正在读取硬件信息" : (monitor.hardware?.coreCount.map { "\($0) 核 CPU" } ?? "核心数未读到"))
                    hardwareCard("物理内存", hardwarePending ? "读取中…" : (monitor.hardware?.memoryBytes.map { SystemMetrics.bytesText($0) } ?? "未读到"),
                                 "统一内存，不可自行加装")
                    hardwareCard("存储介质", hardwarePending ? "读取中…" : (monitor.hardware?.storageKind ?? "未读到"), "内置硬盘 · 不显示猜测值")
                }

                ModuleCard {
                    HStack(alignment: .top, spacing: 9) {
                        Image(systemName: "checkmark.seal").foregroundStyle(.green)
                        VStack(alignment: .leading, spacing: 3) {
                            Text("这里没有需要立刻处理的问题").font(.body.weight(.medium))
                            Text("缓存较大属于正常现象。可以在「清理」页按中文说明自行判断；本页不会自动修改系统设置。")
                                .font(.callout).foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .padding(18)
        }
        .task {
            await monitor.refreshStatusOverview()
            await refreshLoop()
        }
    }

    private var hardwarePending: Bool { monitor.hardware == nil && monitor.isRefreshing }
    private var batteryPending: Bool { monitor.battery == nil && monitor.isRefreshing }

    private var batteryFootText: String {
        guard let battery = monitor.battery else { return "无电池或读不到" }
        if battery.isCharging { return "正在充电 · 系统不提供充满时间" }
        if battery.externalPower { return "已接电源 · 系统不提供剩余时间" }
        if let minutes = battery.timeRemainingMinutes {
            let hours = minutes / 60
            let rest = minutes % 60
            return hours > 0 ? "约 \(hours) 小时 \(rest) 分（系统估算）" : "约 \(rest) 分（系统估算）"
        }
        return "未充电 · 剩余时间未读到"
    }

    private var batteryTemperatureText: String {
        guard let celsius = monitor.battery?.temperatureC ?? monitor.thermal?.batteryCelsius else {
            return "未读到"
        }
        return String(format: "%.1f°C", celsius)
    }

    private var batteryTemperatureDetail: String {
        if monitor.battery?.temperatureC != nil { return "系统电池字段" }
        if monitor.thermal?.batteryCelsius != nil { return "本机 HID gas gauge" }
        return "系统与 HID 都没有"
    }

    private var cpuTemperatureDetail: String {
        guard let thermal = monitor.thermal else { return "需要 HID 温度传感器" }
        if let min = thermal.socMinCelsius, let max = thermal.socMaxCelsius, thermal.sensorCount > 0 {
            return "PMU tdie 平均 · \(thermal.sensorCount) 个传感器 · \(String(format: "%.1f", min))–\(String(format: "%.1f", max))°C"
        }
        return thermal.source
    }

    private func hardwareCard(_ title: String, _ value: String, _ detail: String) -> some View {
        ModuleCard {
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Text(value)
                    .font(.title3.weight(.semibold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                Text(detail)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .lineSpacing(1)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, minHeight: 82, alignment: .topLeading)
        }
    }

    private func refreshLoop() async {
        while !Task.isCancelled {
            try? await Task.sleep(nanoseconds: 5_000_000_000)
            if Task.isCancelled { break }
            await monitor.refreshStatusOverview()
        }
    }
}
