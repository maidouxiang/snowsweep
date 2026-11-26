import SwiftUI
import Darwin

/// 一条物理接口的实时计数。只读接口字节数，不抓包、不读内容。
struct InterfaceTraffic: Identifiable, Sendable {
    let name: String
    let rxBytes: Int64
    let txBytes: Int64
    let rxRate: Double
    let txRate: Double
    var id: String { name }
}

/// 本机网络流量采样器。macOS 的 `if_data` 字节计数是 32 位，
/// 可能回绕；这里按 1 秒采样的差值累加“本次雪运行”的真实流量，
/// 不把回绕后的接口总数冒充成累计值。
@MainActor
final class NetworkTrafficSampler: ObservableObject {
    static let shared = NetworkTrafficSampler()

    @Published private(set) var interfaces: [InterfaceTraffic] = []
    @Published private(set) var rxRate: Double = 0
    @Published private(set) var txRate: Double = 0
    @Published private(set) var sessionRxBytes: Int64 = 0
    @Published private(set) var sessionTxBytes: Int64 = 0
    @Published private(set) var startedAt = Date()
    @Published private(set) var lastSampleAt: Date?
    @Published private(set) var isRunning = false
    @Published private(set) var network: NetworkSnapshot?

    private var previous: [String: (rx: UInt64, tx: UInt64)] = [:]
    private var loop: Task<Void, Never>?
    private var tick = 0

    private init() {}

    func start() {
        guard loop == nil else { return }
        startedAt = Date()
        sessionRxBytes = 0
        sessionTxBytes = 0
        previous = [:]
        isRunning = true
        loop = Task { [weak self] in
            while !Task.isCancelled {
                self?.sample()
                try? await Task.sleep(nanoseconds: 1_000_000_000)
            }
        }
    }

    func stop() {
        loop?.cancel()
        loop = nil
        isRunning = false
    }

    private func sample() {
        let now = Date()
        let interval = lastSampleAt.map { max(0.2, now.timeIntervalSince($0)) } ?? 1
        let counters = Self.readCounters()
        var rows: [InterfaceTraffic] = []
        var totalRxRate = 0.0
        var totalTxRate = 0.0

        for (name, current) in counters.sorted(by: { $0.key < $1.key }) {
            let old = previous[name]
            let rxDelta = Self.delta(current.rx, old?.rx)
            let txDelta = Self.delta(current.tx, old?.tx)
            if old != nil {
                sessionRxBytes += Int64(rxDelta)
                sessionTxBytes += Int64(txDelta)
            }
            let rxRate = Double(rxDelta) / interval
            let txRate = Double(txDelta) / interval
            totalRxRate += rxRate
            totalTxRate += txRate
            rows.append(InterfaceTraffic(
                name: name,
                rxBytes: Int64(current.rx),
                txBytes: Int64(current.tx),
                rxRate: rxRate,
                txRate: txRate
            ))
        }

        previous = counters
        interfaces = rows.filter {
            $0.rxBytes > 0 || $0.txBytes > 0 || $0.rxRate > 0 || $0.txRate > 0
        }
        rxRate = totalRxRate
        txRate = totalTxRate
        lastSampleAt = now
        tick += 1
        // 接口类型与 IP 每 5 秒更新一次，避免每秒都走 SystemConfiguration。
        if tick == 1 || tick % 5 == 0 {
            network = NetworkMetrics.read()
        }
    }

    private static func delta(_ current: UInt64, _ previous: UInt64?) -> UInt64 {
        guard let previous else { return 0 }
        if current >= previous { return current - previous }
        // 32 位计数回绕：当前值 + 2^32 - 上一次。
        let wrapped = current + (UInt64(UInt32.max) + 1) - previous
        // 接口被重置时会出现接近 4 GB 的假增量；单秒超过 2 GB 视为重置，不计入。
        return wrapped < 2_000_000_000 ? wrapped : 0
    }

    private static func readCounters() -> [String: (rx: UInt64, tx: UInt64)] {
        var list: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&list) == 0, let first = list else { return [:] }
        defer { freeifaddrs(list) }

        var result: [String: (rx: UInt64, tx: UInt64)] = [:]
        var cursor: UnsafeMutablePointer<ifaddrs>? = first
        while let current = cursor {
            defer { cursor = current.pointee.ifa_next }
            guard let address = current.pointee.ifa_addr,
                  address.pointee.sa_family == UInt8(AF_LINK),
                  let data = current.pointee.ifa_data else { continue }
            let name = String(cString: current.pointee.ifa_name)
            // 只统计真实物理接口，排除 lo0、awdl、llw、utun、bridge 等虚拟/重复计数。
            guard name.hasPrefix("en") || name.hasPrefix("pdp_ip") else { continue }
            let flags = Int32(current.pointee.ifa_flags)
            guard (flags & IFF_UP) != 0 else { continue }
            let stats = data.assumingMemoryBound(to: if_data.self).pointee
            result[name] = (UInt64(stats.ifi_ibytes), UInt64(stats.ifi_obytes))
        }
        return result
    }
}

struct NetworkTrafficView: View {
    @StateObject private var sampler = NetworkTrafficSampler.shared

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .top) {
                    PageHeader(
                        title: "网络流量",
                        subtitle: "读本机接口字节计数：实时上下行速度与本次雪运行累计。不抓包、不读内容、不联网。"
                    )
                    Spacer()
                    Button("打开网络设置") {
                        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.network") {
                            NSWorkspace.shared.open(url)
                        }
                    }
                    .controlSize(.small)
                }

                HStack(spacing: 14) {
                    speedTile(
                        title: "实时下行",
                        value: speedText(sampler.rxRate),
                        icon: "arrow.down",
                        color: .blue
                    )
                    speedTile(
                        title: "实时上行",
                        value: speedText(sampler.txRate),
                        icon: "arrow.up",
                        color: .orange
                    )
                }

                ModuleCard {
                    VStack(alignment: .leading, spacing: 10) {
                        HStack(spacing: 8) {
                            Image(systemName: "network")
                                .foregroundStyle(.blue)
                            Text("当前连接").font(.headline)
                            Spacer()
                            Text(sampler.isRunning ? "每秒采样" : "未采样")
                                .font(.caption2)
                                .foregroundStyle(sampler.isRunning ? .green : .secondary)
                        }
                        if let network = sampler.network {
                            HStack(spacing: 24) {
                                statusPair("接口", network.interfaceName ?? "未读到")
                                statusPair("类型", network.connected ? network.kind : "未连接")
                                statusPair("IPv4", network.ipv4 ?? "未读到")
                                statusPair("IPv6", network.ipv6 ?? "未读到")
                            }
                        } else {
                            Text("正在读取接口信息…").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }

                ModuleCard {
                    VStack(alignment: .leading, spacing: 10) {
                        HStack {
                            Text("本次雪运行累计").font(.headline)
                            Spacer()
                            Text(durationText)
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(.secondary)
                        }
                        HStack(spacing: 14) {
                            totalTile("累计下行", value: SystemMetrics.bytesText(sampler.sessionRxBytes), icon: "arrow.down.circle.fill", color: .blue)
                            totalTile("累计上行", value: SystemMetrics.bytesText(sampler.sessionTxBytes), icon: "arrow.up.circle.fill", color: .orange)
                            totalTile("合计", value: SystemMetrics.bytesText(sampler.sessionRxBytes + sampler.sessionTxBytes), icon: "arrow.left.arrow.right.circle.fill", color: .green)
                        }
                        Text("累计从雪启动时开始，用每秒差值相加；系统接口的 32 位计数回绕已处理，不会把回绕值当成流量。")
                            .font(.caption2).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }

                ModuleCard {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text("物理接口").font(.headline)
                            Spacer()
                            Text("\(sampler.interfaces.count) 个")
                                .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                        }
                        if sampler.interfaces.isEmpty {
                            Text("没有读到活动的物理接口。Wi‑Fi 或网线断开时属正常。")
                                .font(.caption).foregroundStyle(.secondary)
                        } else {
                            ForEach(sampler.interfaces) { row in
                                HStack(spacing: 10) {
                                    Image(systemName: "cable.connector")
                                        .font(.caption).foregroundStyle(.secondary)
                                    Text(row.name).font(.callout.monospaced()).frame(width: 64, alignment: .leading)
                                    Text("↓ \(speedText(row.rxRate))")
                                        .font(.caption.monospacedDigit()).foregroundStyle(.blue)
                                        .frame(width: 118, alignment: .leading)
                                    Text("↑ \(speedText(row.txRate))")
                                        .font(.caption.monospacedDigit()).foregroundStyle(.orange)
                                        .frame(width: 118, alignment: .leading)
                                    Spacer()
                                    Text("接口低位计数 \(SystemMetrics.bytesText(row.rxBytes)) / \(SystemMetrics.bytesText(row.txBytes))")
                                        .font(.caption2).foregroundStyle(.tertiary)
                                }
                                .padding(.vertical, 3)
                                Divider().opacity(0.4)
                            }
                        }
                    }
                }

                InfoBanner(
                    text: "这里只读接口字节数，不解析包内容、不记录访问了哪些网站。若速度长期为 0，先确认 Wi‑Fi/网线是否活动；VPN 的 utun 流量会体现在物理接口上，不重复计算。",
                    color: .gray
                )
            }
            .padding(18)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .task {
            sampler.start()
        }
    }

    private var durationText: String {
        let seconds = max(0, Int(Date().timeIntervalSince(sampler.startedAt)))
        let h = seconds / 3600
        let m = (seconds % 3600) / 60
        let s = seconds % 60
        if h > 0 { return "\(h) 小时 \(m) 分" }
        if m > 0 { return "\(m) 分 \(s) 秒" }
        return "\(s) 秒"
    }

    private func speedText(_ bytesPerSecond: Double) -> String {
        guard bytesPerSecond.isFinite, bytesPerSecond > 0 else { return "0 B/s" }
        if bytesPerSecond < 1024 { return String(format: "%.0f B/s", bytesPerSecond) }
        if bytesPerSecond < 1024 * 1024 { return String(format: "%.1f KB/s", bytesPerSecond / 1024) }
        if bytesPerSecond < 1024 * 1024 * 1024 { return String(format: "%.1f MB/s", bytesPerSecond / 1024 / 1024) }
        return String(format: "%.2f GB/s", bytesPerSecond / 1024 / 1024 / 1024)
    }

    private func speedTile(title: String, value: String, icon: String, color: Color) -> some View {
        ModuleCard {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 7) {
                    Image(systemName: icon)
                        .font(.title3).foregroundStyle(color)
                    Text(title).font(.callout.weight(.medium))
                    Spacer()
                }
                Text(value)
                    .font(.system(size: 34, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(color)
                    .lineLimit(1).minimumScaleFactor(0.6)
            }
        }
    }

    private func totalTile(_ title: String, value: String, icon: String, color: Color) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Label(title, systemImage: icon)
                .font(.caption).foregroundStyle(color)
            Text(value)
                .font(.title3.weight(.semibold)).monospacedDigit()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(color.opacity(0.07), in: RoundedRectangle(cornerRadius: 9))
    }

    private func statusPair(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.caption2).foregroundStyle(.secondary)
            Text(value).font(.callout.monospaced()).lineLimit(1).textSelection(.enabled)
        }
    }
}
