import SwiftUI
import AppKit
import UniformTypeIdentifiers
import SnowSweepCore

/// 主窗口的前台化与定位。
/// accessory（无 Dock 图标）模式下只调 activate() 不会把已有窗口提到最前，
/// 表现为"点了打开主界面却没反应"或"窗口被别的窗口盖住"。
@MainActor
enum AppWindow {
    /// 找到主窗口（WindowGroup id = "main"），激活 App 并置顶。
    ///
    /// 主窗口被关闭后 SwiftUI 会从 `NSApp.windows` 移除它；只调 activate() 只会
    /// 在 Dock 里亮起图标，面板并不会回来。所以这里分两条路：
    /// 1. 窗口还在：取消最小化、makeKey、orderFrontRegardless；
    /// 2. 窗口已没了：请 LaunchServices 对同一个 App 做一次 reopen（不会再开第二个实例），
    ///    等 SwiftUI 重建窗口后再置顶。
    static func showMain() {
        // 关窗后是 accessory，先按 Dock 偏好恢复前台策略，窗口才会真正浮到最前。
        let showsDock = (UserDefaults.standard.object(forKey: "snow.showDockIcon") as? Bool) ?? true
        NSApp.setActivationPolicy(showsDock ? .regular : .accessory)
        NSApp.activate(ignoringOtherApps: true)

        Task { @MainActor in
            await Task.yield()
            if let main = visibleMainWindow {
                bringForward(main)
            } else {
                reopenMainWindow()
                // openApplication 的完成回调不保证回来；窗口重建通常要 0.5–1 秒，
                // 这里再兜一次，确保新窗口真的成为 key window。
                try? await Task.sleep(for: .milliseconds(1_200))
                if let main = visibleMainWindow {
                    bringForward(main)
                }
            }
        }
    }

    /// 回到首屏并让首屏开始一次只读新手体检。
    /// 先切回首屏，等 SwiftUI 装好订阅后再发“打开报告”，避免通知丢在视图创建前。
    static func showNoviceReport() {
        UserDefaults.standard.set(false, forKey: pendingExpertKey)
        UserDefaults.standard.set(false, forKey: pendingLandingKey)
        NotificationCenter.default.post(name: .snowShowLanding, object: nil)
        showMain()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) {
            NotificationCenter.default.post(name: .snowOpenNoviceReport, object: nil)
        }
    }

    /// 先切到指定侧栏入口，再置顶主窗口。
    /// 窗口刚被 reopen 重建时监听器可能还没装好，所以 0.7 秒后再补发一次；
    /// 这次只影响首屏/专家模式的显示，不会重复创建窗口。
    static func showMain(section: String) {
        UserDefaults.standard.set(section, forKey: "snow.main.selection")
        UserDefaults.standard.set(false, forKey: pendingLandingKey)
        // 窗口被关掉时没有监听者，通知会丢；用一个一次性标记让重建出来的
        // MainWindow 在 onAppear 时自己切到专家模式。
        UserDefaults.standard.set(true, forKey: pendingExpertKey)
        NotificationCenter.default.post(name: .snowShowExpert, object: nil)
        showMain()
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(700))
            NotificationCenter.default.post(name: .snowShowExpert, object: nil)
        }
    }

    /// 快捷面板的“打开主面板”只回到 AI 首屏，不替用户切到专家模式。
    /// 与专家入口一样用一次性标记，保证窗口重建后的第一屏也落在首屏。
    static func showAIPanel() {
        UserDefaults.standard.set(false, forKey: pendingExpertKey)
        UserDefaults.standard.set(true, forKey: pendingLandingKey)
        NotificationCenter.default.post(name: .snowShowLanding, object: nil)
        showMain()
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(700))
            guard UserDefaults.standard.bool(forKey: pendingLandingKey) else { return }
            NotificationCenter.default.post(name: .snowShowLanding, object: nil)
        }
    }

    static let pendingExpertKey = "snow.pending.expertPresentation"
    static let pendingLandingKey = "snow.pending.aiPresentation"

    /// 只认 SwiftUI 给主窗口的 `main-AppWindow-1` 标识。
    /// 关窗后 AppKit 还可能留下不可见的 500×500 辅助窗口；若把它当主窗口，
    /// makeKey/orderFront 都不会显示任何东西，表现就是“点了没反应”。
    private static var mainWindow: NSWindow? {
        NSApp.windows.first { window in
            window.canBecomeKey
                && (window.identifier?.rawValue.contains("main") ?? false)
        }
    }

    /// 关窗后 AppKit 可能还留着一个不可见的同名窗口对象；`isVisible == false`
    /// 时必须让 LaunchServices 重建，否则 makeKey/orderFront 都作用在僵尸窗口上。
    private static var visibleMainWindow: NSWindow? {
        guard let window = mainWindow, window.isVisible else { return nil }
        return window
    }

    /// 新建/重建的主窗口出现后再兜一次前台，避免 SwiftUI 把窗口画在别的 App 后面。
    static func focusMainWindow() {
        guard let main = mainWindow else { return }
        bringForward(main)
    }

    private static func bringForward(_ window: NSWindow) {
        if window.isMiniaturized {
            window.deminiaturize(nil)
        }
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        window.orderFrontRegardless()
    }

    private static func reopenMainWindow() {
        let url = Bundle.main.bundleURL
        guard url.pathExtension.lowercased() == "app" else {
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        configuration.createsNewApplicationInstance = false
        NSWorkspace.shared.openApplication(at: url, configuration: configuration) { _, _ in
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(350))
                if let main = mainWindow {
                    bringForward(main)
                } else {
                    NSApp.activate(ignoringOtherApps: true)
                }
            }
        }
    }
}

/// 统一全局异常提示：任何模块都通过 model.errorMessage 走同一个组件。
struct ErrorBanner: View {
    @EnvironmentObject var model: ScanViewModel

    var body: some View {
        if let error = model.errorMessage {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                VStack(alignment: .leading, spacing: 3) {
                    Text(error.localizedDescription)
                        .font(.callout)
                    if case .permission = error {
                        Button("打开系统设置") { model.openFullDiskAccessSettings() }
                            .buttonStyle(.link)
                            .font(.caption)
                    }
                }
                Spacer()
                Button { model.errorMessage = nil } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
            .padding(12)
            .background(Color.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 10))
        }
    }
}

struct MenuBarPanel: View {
    @EnvironmentObject var model: ScanViewModel
    @EnvironmentObject var monitor: SystemMonitor
    @ObservedObject private var traffic = NetworkTrafficSampler.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header

            VStack(spacing: 0) {
                if model.menuBarPreferences.showDiskSpace {
                    PanelVitalRow(
                        icon: "internaldrive", tint: .blue, title: "硬盘",
                        value: diskValue, detail: diskDetail, fraction: monitor.disk?.usedFraction,
                        action: nil
                    )
                    Divider().padding(.leading, 38)
                }
                if model.menuBarPreferences.showMemory {
                    PanelVitalRow(
                        icon: "memorychip", tint: .purple, title: "内存",
                        value: memoryValue, detail: memoryDetail, fraction: monitor.memory?.usedFraction,
                        action: nil
                    )
                    Divider().padding(.leading, 38)
                }
                PanelVitalRow(
                    icon: "cpu", tint: cpuTint, title: "CPU",
                    value: cpuValue, detail: cpuDetail,
                    fraction: monitor.cpu?.usagePercent.map { $0 / 100 },
                    action: { AppWindow.showMain(section: "状态") }
                )
                Divider().padding(.leading, 38)
                PanelVitalRow(
                    icon: "network", tint: networkTint, title: "网络",
                    value: networkValue, detail: networkDetail, fraction: nil,
                    action: { AppWindow.showMain(section: "网络") }
                )
                Divider().padding(.leading, 38)
                PanelVitalRow(
                    icon: "dot.radiowaves.left.and.right", tint: .orange, title: "设备",
                    value: deviceValue, detail: deviceDetail, fraction: nil,
                    action: { AppWindow.showMain(section: "蓝牙") }
                )
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 4)
            .background(panelCardBackground)

            Button("打开主面板") { AppWindow.showAIPanel() }
                .buttonStyle(PanelPrimaryButton())

            HStack(spacing: 6) {
                Text("只读本机数据，不联网").font(.caption2).foregroundStyle(.secondary)
                Spacer(minLength: 0)
                Text(monitor.lastRefresh, style: .time)
                    .font(.caption2.monospacedDigit()).foregroundStyle(.tertiary)
            }
        }
        .padding(14)
        .frame(width: 330)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private var header: some View {
        HStack(alignment: .center) {
            VStack(alignment: .leading, spacing: 1) {
                Text("雪").font(.system(size: 17, weight: .semibold))
                Text("快速面板").font(.caption2).foregroundStyle(.secondary)
            }
            Spacer()
            Text(model.isScanning ? "扫描中 · \(model.effectiveRunMode.chineseName)" : "\(model.runtimeMode.chineseName) · 本地")
                .font(.caption2.weight(.medium))
                .foregroundStyle(runtimeTint)
                .padding(.horizontal, 8).padding(.vertical, 3)
                .background(runtimeTint.opacity(0.12), in: Capsule())
                .help(model.runtimeReason)
        }
        .padding(.bottom, 1)
    }

    private var runtimeTint: Color {
        if model.isScanning { return .orange }
        switch model.runtimeMode {
        case .silent: return .green
        case .scan: return .orange
        case .assist: return Color(red: 0.82, green: 0.66, blue: 0.34)
        }
    }

    private var panelCardBackground: some View {
        RoundedRectangle(cornerRadius: 11)
            .fill(Color(nsColor: .controlBackgroundColor))
            .overlay(RoundedRectangle(cornerRadius: 11).stroke(Color.primary.opacity(0.06), lineWidth: 1))
    }

    private var diskValue: String {
        guard let disk = monitor.disk else { return "读取中…" }
        return SystemMetrics.bytesText(disk.freeBytes) + " 可用"
    }

    private var diskDetail: String {
        guard let disk = monitor.disk else { return "正在读取磁盘" }
        return "已用 \(Int(disk.usedFraction * 100))% · 共 \(SystemMetrics.bytesText(disk.totalBytes))"
    }

    private var memoryValue: String {
        guard let memory = monitor.memory else { return "读取中…" }
        return "\(SystemMetrics.bytesText(memory.usedBytes)) / \(SystemMetrics.bytesText(memory.totalBytes))"
    }

    private var memoryDetail: String {
        guard let memory = monitor.memory else { return "正在读取内存" }
        return "压力 \(memory.pressureLabel) · 交换 \(SystemMetrics.bytesText(memory.swapUsedBytes))"
    }

    private var cpuValue: String {
        guard let usage = monitor.cpu?.usagePercent else { return "读不到" }
        return String(format: "%.0f%%", usage)
    }

    private var cpuDetail: String {
        guard let cpu = monitor.cpu else { return "正在读取 CPU" }
        let temp = monitor.thermal?.socCelsius.map { String(format: "CPU/SoC %.0f°", $0) } ?? "温度读不到"
        return "\(cpu.coreCount) 核 · \(temp) · 负载 \(String(format: "%.1f", cpu.load1))"
    }

    private var cpuTint: Color {
        guard let usage = monitor.cpu?.usagePercent else { return .secondary }
        if usage > 80 { return .red }
        if usage > 45 { return .orange }
        return .green
    }

    private var networkValue: String {
        guard let network = networkSnapshot, network.connected else { return "未连接" }
        guard traffic.lastSampleAt != nil else { return "测速中…" }
        return "↓ \(rateText(downRate))  ↑ \(rateText(upRate))"
    }

    private var networkDetail: String {
        guard let network = networkSnapshot, network.connected else { return "没有活动的网络接口" }
        let interface = network.interfaceName ?? "—"
        guard traffic.lastSampleAt != nil else {
            return "\(network.kind) · \(interface) · 正在采样"
        }
        let total = "本次 ↓ \(SystemMetrics.bytesText(traffic.sessionRxBytes)) ↑ \(SystemMetrics.bytesText(traffic.sessionTxBytes))"
        return "\(network.kind) · \(network.ipv4 ?? interface) · \(total)"
    }

    private var networkSnapshot: NetworkSnapshot? {
        traffic.network ?? monitor.network
    }

    /// 优先显示主接口的单口速率；采样器没认出主接口时退回所有物理口合计。
    private var downRate: Double {
        guard let name = networkSnapshot?.interfaceName,
              let row = traffic.interfaces.first(where: { $0.name == name })
        else { return traffic.rxRate }
        return row.rxRate
    }

    private var upRate: Double {
        guard let name = networkSnapshot?.interfaceName,
              let row = traffic.interfaces.first(where: { $0.name == name })
        else { return traffic.txRate }
        return row.txRate
    }

    private func rateText(_ bytesPerSecond: Double) -> String {
        NetworkRateFormatter.string(bytesPerSecond: bytesPerSecond)
    }

    private var networkTint: Color { networkSnapshot?.connected == true ? .green : .secondary }

    private var deviceValue: String {
        let connected = monitor.bluetooth.filter(\.connected)
        guard let first = connected.first else {
            return monitor.bluetooth.isEmpty ? "读取中…" : "没有连接"
        }
        if let battery = first.battery { return "\(shortDeviceName(first.name)) \(battery)%" }
        return "\(shortDeviceName(first.name)) · 未上报电量"
    }

    private var deviceDetail: String {
        let connected = monitor.bluetooth.filter(\.connected)
        if connected.isEmpty {
            return monitor.bluetooth.isEmpty ? "正在读取蓝牙外设" : "已配对 \(monitor.bluetooth.count) 个，当前都没连接"
        }
        if connected.count > 1 { return "\(connected.count) 个已连接 · 点击查看外设" }
        return "1 个已连接 · 点击查看外设"
    }

    private func shortDeviceName(_ name: String) -> String {
        name.replacingOccurrences(of: " BLE Mouse", with: "").replacingOccurrences(of: " Magic Mouse", with: "")
    }
}

private struct PanelVitalRow: View {
    let icon: String
    let tint: Color
    let title: String
    let value: String
    let detail: String
    let fraction: Double?
    let action: (() -> Void)?

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(tint)
                .frame(width: 28, height: 28)
                .background(tint.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(title).font(.caption).foregroundStyle(.secondary)
                    Spacer(minLength: 4)
                    Text(value)
                        .font(.system(size: 13, weight: .semibold))
                        .lineLimit(1).minimumScaleFactor(0.85)
                        .multilineTextAlignment(.trailing)
                }
                HStack(spacing: 6) {
                    Text(detail).font(.caption2).foregroundStyle(.secondary).lineLimit(1).minimumScaleFactor(0.9)
                    Spacer(minLength: 4)
                    if let fraction {
                        PanelBar(fraction: fraction, tint: tint)
                    }
                }
            }

            if action != nil {
                Image(systemName: "chevron.right").font(.caption2).foregroundStyle(.tertiary)
            }
        }
        .padding(.vertical, 8)
        .contentShape(Rectangle())
        .onTapGesture { action?() }
    }
}

private struct PanelBar: View {
    let fraction: Double
    let tint: Color

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.primary.opacity(0.10))
                Capsule().fill(tint.opacity(0.85))
                    .frame(width: max(3, proxy.size.width * min(1, max(0, fraction))))
            }
        }
        .frame(width: 58, height: 4)
    }
}

private struct PanelPrimaryButton: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.callout.weight(.semibold))
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 9)
            .background(
                RoundedRectangle(cornerRadius: 9)
                    .fill(Color.accentColor)
                    .opacity(configuration.isPressed ? 0.8 : 1)
            )
    }
}

/// 个人目录读不到时，把“去设置授权”放在所有页面顶部。
/// macOS 不允许 App 替用户勾选 TCC，所以这里只能一键打开设置、复制路径，再请用户重启。
struct AccessReminderBanner: View {
    @EnvironmentObject private var model: ScanViewModel

    var body: some View {
        if !model.accessBannerDismissed, model.unreadableHomeFolders.count >= 3 {
            HStack(spacing: 10) {
                Image(systemName: "lock.trianglebadge.exclamationmark")
                    .foregroundStyle(.orange)
                VStack(alignment: .leading, spacing: 1) {
                    Text("\(model.unreadableHomeFolders.count) 个个人目录读不到，扫描会不完整")
                        .font(.callout.weight(.semibold))
                    Text("已缺：\(model.unreadableHomeFolders.joined(separator: "、"))。一次完全磁盘访问覆盖这些目录；macOS 不允许雪替你勾选。")
                        .font(.caption).foregroundStyle(.secondary).lineLimit(2)
                }
                Spacer()
                Button("打开系统设置") { model.openFullDiskAccessSettings() }
                    .controlSize(.small)
                Button("复制雪路径") { model.copyAppBundlePath() }
                    .controlSize(.small)
                Button("重新检测") { model.checkHomeFolderAccess() }
                    .controlSize(.small)
                Button("稍后") { model.accessBannerDismissed = true }
                    .buttonStyle(.link).font(.caption)
            }
            .padding(.horizontal, 14).padding(.vertical, 7)
            .background(Color.orange.opacity(0.09))
            .overlay(alignment: .bottom) { Divider() }
        }
    }
}

/// 跨页面可见的扫描状态条。以前扫描只在「清理」页显示，用户在大文件页点开始扫描后
/// 主界面没有任何反馈，只剩菜单栏一句含糊的“性能扫描中”。
struct ScanActivityBanner: View {
    @EnvironmentObject private var model: ScanViewModel

    var body: some View {
        if model.isScanning {
            HStack(spacing: 10) {
                ProgressView(value: model.progressFraction)
                    .progressViewStyle(.linear)
                    .frame(width: 120)
                VStack(alignment: .leading, spacing: 1) {
                    Text("正在扫描").font(.callout.weight(.semibold))
                    Text(model.currentPath.isEmpty
                         ? "正在读取目录与元数据；不会删除任何文件"
                         : "当前：\(model.currentPath)")
                        .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer()
                Text("\(Int(model.progressFraction * 100))%")
                    .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                Button("取消扫描") { model.cancelScan() }
                    .controlSize(.small)
            }
            .padding(.horizontal, 14).padding(.vertical, 7)
            .background(Color.accentColor.opacity(0.08))
            .overlay(alignment: .bottom) { Divider() }
        } else if let message = model.scanFinishedMessage {
            let incomplete = message.contains("不完整")
            HStack(spacing: 8) {
                Image(systemName: incomplete ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                    .foregroundStyle(incomplete ? .orange : .green)
                Text(message).font(.callout).lineLimit(2)
                Spacer()
                if incomplete {
                    Button("去授权") { model.openFullDiskAccessSettings() }
                        .controlSize(.small)
                    Button("重启雪") { model.relaunchApplication() }
                        .controlSize(.small)
                }
                Button("关闭") { model.scanFinishedMessage = nil }
                    .buttonStyle(.link).font(.caption)
            }
            .padding(.horizontal, 14).padding(.vertical, 7)
            .background((incomplete ? Color.orange : Color.green).opacity(0.08))
            .overlay(alignment: .bottom) { Divider() }
        }
    }
}

struct MainWindow: View {
    @EnvironmentObject var model: ScanViewModel
    @EnvironmentObject var monitor: SystemMonitor
    @AppStorage("snow.main.selection") private var selection = "概览"
    @AppStorage("snow.appearance") private var appearance: SnowTheme = .snowDay
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var showLanding = true
    @State private var showAskSnow = false
    @State private var expertExpanded = false
    @State private var deviceExpanded = false
    @State private var manageExpanded = false
    @State private var sidebarKeyboardArmed = false
    @State private var sidebarKeyMonitor: Any?
    @State private var sidebarMouseMonitor: Any?
    @State private var sidebarWidth: CGFloat = 205

    private var isExpertSection: Bool {
        [
            "概览", "清理", "空间分析", "族谱", "大文件", "内存", "自检",
            "电池", "蓝牙", "网络", "状态",
            "卸载", "优化", "历史", "保护", "规则", "缺失", "权限", "启动项", "恢复", "缺口"
        ].contains(selection)
    }

    private static let sidebarOrder = [
        "概览", "清理", "空间分析", "族谱", "大文件", "内存",
        "电池", "蓝牙", "网络", "状态",
        "卸载", "优化", "历史", "保护", "规则", "缺失", "权限", "启动项", "恢复", "缺口",
        "设置", "帮助"
    ]

    private func moveSidebarSelection(_ delta: Int) {
        guard let index = Self.sidebarOrder.firstIndex(of: selection) else { return }
        let next = min(max(index + delta, 0), Self.sidebarOrder.count - 1)
        guard next != index else { return }
        selection = Self.sidebarOrder[next]
    }

    private func installSidebarKeyMonitor() {
        guard sidebarKeyMonitor == nil else { return }
        sidebarMouseMonitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) { event in
            guard event.window === NSApp.keyWindow else { return event }
            sidebarKeyboardArmed = event.locationInWindow.x <= sidebarWidth
            return event
        }
        sidebarKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            guard sidebarKeyboardArmed, !showLanding, !showAskSnow else { return event }
            guard event.modifierFlags.intersection([.command, .option, .control]).isEmpty else { return event }
            guard let responder = event.window?.firstResponder, !(responder is NSTextView) else { return event }
            switch event.keyCode {
            case 126:
                moveSidebarSelection(-1)
                return nil
            case 125:
                moveSidebarSelection(1)
                return nil
            default:
                return event
            }
        }
    }

    private func removeSidebarKeyMonitor() {
        if let sidebarKeyMonitor {
            NSEvent.removeMonitor(sidebarKeyMonitor)
            self.sidebarKeyMonitor = nil
        }
        if let sidebarMouseMonitor {
            NSEvent.removeMonitor(sidebarMouseMonitor)
            self.sidebarMouseMonitor = nil
        }
    }

    private func syncSidebarExpansion() {
        if isExpertSection { expertExpanded = true }
        if ["电池", "蓝牙", "网络", "状态"].contains(selection) { deviceExpanded = true }
        if ["卸载", "优化", "历史", "保护", "规则", "缺失", "权限", "启动项", "恢复", "缺口"].contains(selection) {
            manageExpanded = true
        }
    }

    var body: some View {
        Group {
            if showLanding {
                LandingView(showLanding: $showLanding, selection: $selection)
                    .frame(minWidth: 980, minHeight: 660)
            } else {
                expertShell
            }
        }
        .preferredColorScheme(appearance.colorScheme)
        .tint(SnowSkin.accent)
        .onAppear {
            // 从快捷面板进来时窗口可能刚被重建，通知来早了会丢。
            // 这里消费一次性标记：设备入口进专家页，“打开主面板”回 AI 首屏。
            if UserDefaults.standard.bool(forKey: AppWindow.pendingLandingKey) {
                UserDefaults.standard.set(false, forKey: AppWindow.pendingLandingKey)
                showLanding = true
            } else if UserDefaults.standard.bool(forKey: AppWindow.pendingExpertKey) {
                UserDefaults.standard.set(false, forKey: AppWindow.pendingExpertKey)
                syncSidebarExpansion()
                showLanding = false
            }
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(360))
                AppWindow.focusMainWindow()
            }
        }
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.26), value: appearance)
        .onReceive(NotificationCenter.default.publisher(for: .snowShowExpert)) { _ in
            UserDefaults.standard.set(false, forKey: AppWindow.pendingLandingKey)
            UserDefaults.standard.set(false, forKey: AppWindow.pendingExpertKey)
            syncSidebarExpansion()
            showLanding = false
        }
        .onReceive(NotificationCenter.default.publisher(for: .snowShowLanding)) { _ in
            UserDefaults.standard.set(false, forKey: AppWindow.pendingExpertKey)
            UserDefaults.standard.set(false, forKey: AppWindow.pendingLandingKey)
            showLanding = true
        }
    }

    private func sidebarRow(_ title: String, _ icon: String, _ value: String? = nil) -> some View {
        let key = value ?? title
        return Button {
            selection = key
            sidebarKeyboardArmed = true
        } label: {
            HStack(spacing: 8) {
                Image(systemName: icon)
                    .font(.system(size: 12.5, weight: .medium))
                    .frame(width: 19, alignment: .center)
                Text(title)
                    .font(.system(size: 12.5, weight: selection == key ? .semibold : .regular))
                Spacer(minLength: 0)
            }
            .foregroundStyle(selection == key ? SnowSkin.accent : SnowSkin.text)
            .padding(.horizontal, 8)
            .frame(height: 26)
            .background(
                selection == key ? SnowSkin.accent.opacity(0.14) : Color.clear,
                in: RoundedRectangle(cornerRadius: 7)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .listRowInsets(EdgeInsets(top: 1, leading: 6, bottom: 1, trailing: 6))
    }

    private var expertShell: some View {
        NavigationSplitView {
            List {
                DisclosureGroup(isExpanded: $expertExpanded) {
                    sidebarRow("概览", "square.grid.2x2")
                    sidebarRow("清理", "trash")
                    sidebarRow("空间分析", "chart.bar.xaxis")
                    sidebarRow("软件族谱", "point.3.connected.trianglepath.dotted", "族谱")
                    sidebarRow("大文件与重复", "doc.on.doc", "大文件")
                    sidebarRow("内存", "memorychip")

                    DisclosureGroup(isExpanded: $deviceExpanded) {
                        sidebarRow("电池", "battery.100.bolt")
                        sidebarRow("蓝牙外设", "dot.radiowaves.left.and.right", "蓝牙")
                        sidebarRow("网络流量", "network", "网络")
                        sidebarRow("机身状态", "cpu", "状态")
                    } label: {
                        Label("设备状态", systemImage: "bolt.horizontal.circle")
                    }

                    DisclosureGroup(isExpanded: $manageExpanded) {
                        sidebarRow("卸载", "minus.circle")
                        sidebarRow("优化", "slider.horizontal.3")
                        sidebarRow("操作历史", "clock.arrow.circlepath", "历史")
                        sidebarRow("保护路径", "shield", "保护")
                        sidebarRow("规则注册表", "list.bullet.rectangle", "规则")
                        sidebarRow("规则缺失报告", "questionmark.folder", "缺失")
                        sidebarRow("权限清单", "hand.raised", "权限")
                        sidebarRow("启动项审查", "power", "启动项")
                        sidebarRow("恢复清单", "arrow.uturn.backward", "恢复")
                        sidebarRow("扫描缺口", "exclamationmark.triangle", "缺口")
                    } label: {
                        Label("管理与维护", systemImage: "wrench.and.screwdriver")
                    }
                } label: {
                    Label("专家模式", systemImage: "square.grid.2x2")
                }

                Section {
                    sidebarRow("设置", "gearshape")
                    sidebarRow("帮助", "questionmark.circle")
                }
            }
            .listStyle(.sidebar)
            .tint(SnowSkin.accent)
            .transaction { $0.animation = nil }
            .onAppear(perform: syncSidebarExpansion)
            .onChange(of: selection) { _, _ in syncSidebarExpansion() }
            .onGeometryChange(for: CGFloat.self) { proxy in
                proxy.size.width
            } action: { width in
                sidebarWidth = width
            }
            .frame(minWidth: 205)
            .onAppear {
                model.setMainWindowClosed(false)
                NetworkTrafficSampler.shared.start()
            }
            .onChange(of: selection) { _, page in
                monitor.applyPageRetention(page: page, runMode: model.effectiveRunMode)
                if page != "恢复" { model.releaseRollbackCandidates() }
            }
        } detail: {
            VStack(spacing: 0) {
                ErrorBanner()
                AccessReminderBanner()
                ScanActivityBanner()
                switch selection {
                case "清理": CleanView()
                case "概览": DashboardView()
                case "空间分析": AnalyzeView()
                case "族谱": SoftwareFamilyView()
                case "大文件": StorageReviewView()
                case "内存": MemoryView()
                case "自检": SelfCheckView()
                case "电池": BatteryHubView()
                case "蓝牙": BluetoothView()
                case "网络": NetworkTrafficView()
                case "状态": StatusView()
                case "卸载": UninstallView()
                case "优化": OptimizeView()
                case "历史": HistoryView()
                case "保护": ProtectManagerView()
                case "规则": RuleRegistryView()
                case "缺失": UnknownCasesView()
                case "恢复": RollbackListView()
                case "权限": PermissionListView()
                case "启动项": StartupListView()
                case "缺口": GapView()
                case "设置": SettingsView()
                case "帮助": HelpView()
                default: DashboardView()
                }
            }
            .environmentObject(monitor)
        }
        .frame(minWidth: 980, minHeight: 660)
        .sheet(isPresented: $showAskSnow) {
            AskSnowPanel(page: selection)
        }
        .onAppear {
            if selection == "电池守护" || selection == "电池健康" {
                selection = "电池"
            }
            syncSidebarExpansion()
            installSidebarKeyMonitor()
        }
        .onDisappear(perform: removeSidebarKeyMonitor)
        .toolbar {
            ToolbarItem(placement: .navigation) {
                Button {
                    showLanding = true
                } label: {
                    Label("雪", systemImage: "snowflake")
                }
                .help("回到极简首屏")
            }
            ToolbarItem(placement: .primaryAction) {
                Button {
                    showAskSnow = true
                } label: {
                    Label("问雪", systemImage: "snowflake")
                }
                .help("只解释当前界面，不生成清理计划，也不执行删除")
            }
            ToolbarItem(placement: .primaryAction) {
                Button(model.isScanning ? "取消扫描" : "开始扫描") {
                    model.isScanning ? model.cancelScan() : model.startScan()
                }
                .id(model.isScanning)
            }
        }
    }
}


/// 恢复清单：告诉用户"软件把什么移到了哪里"，并帮他在 Finder 里定位。
/// 这里没有任何"一键恢复"按钮——那是故意的，见 ScanViewModel.revealRollback 的说明。
struct RollbackListView: View {
    @EnvironmentObject var model: ScanViewModel
    @State private var search = ""
    @State private var destinationFilter = "all"
    @State private var grouping = "time"

    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter
    }()

    private var visibleCandidates: [RollbackCandidate] {
        let text = search.trimmingCharacters(in: .whitespacesAndNewlines)
        return model.rollbackCandidates.filter { candidate in
            let destinationOK: Bool
            switch destinationFilter {
            case "trash": destinationOK = candidate.destination == .trash
            case "backup": destinationOK = candidate.destination != .trash
            default: destinationOK = true
            }
            let textOK = text.isEmpty ||
                candidate.originalPath.localizedCaseInsensitiveContains(text) ||
                candidate.displayName.localizedCaseInsensitiveContains(text) ||
                (candidate.ruleID ?? "").localizedCaseInsensitiveContains(text)
            return destinationOK && textOK
        }
    }

    private var groups: [(title: String, rows: [RollbackCandidate])] {
        let rows = visibleCandidates
        if grouping == "type" {
            return [
                ("废纸篓", rows.filter { $0.destination == .trash }),
                ("备份目录", rows.filter { $0.destination != .trash })
            ].filter { !$0.1.isEmpty }
        }
        let calendar = Calendar.current
        let now = Date()
        var today: [RollbackCandidate] = []
        var week: [RollbackCandidate] = []
        var earlier: [RollbackCandidate] = []
        for row in rows {
            if calendar.isDateInToday(row.movedAt) {
                today.append(row)
            } else if let seven = calendar.date(byAdding: .day, value: -7, to: now), row.movedAt >= seven {
                week.append(row)
            } else {
                earlier.append(row)
            }
        }
        return [("今天", today), ("最近七天", week), ("更早", earlier)].filter { !$0.1.isEmpty }
    }

    var body: some View {
        GeometryReader { geo in
        ScrollView {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("恢复清单").font(.largeTitle.bold())
                    Text("这里列出本软件移到废纸篓或备份目录的条目。只帮你找到它，不会自动移回去——原位置可能已经有了同名的新文件。")
                        .font(.callout).foregroundStyle(.secondary)
                }
                Spacer()
                Button("重新读取审计日志") { model.refreshRollback() }
            }

            InfoBanner(text: "新记录会保存废纸篓里的精确位置，Finder 可直接选中该条目；旧记录没有位置时按“原名前缀”匹配，匹配不到才打开废纸篓根目录。",
                       color: .blue)

            if let error = model.rollbackError {
                Text(error)
                    .font(.callout)
                    .foregroundStyle(.red)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(10)
                    .background(Color.red.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
            }

            if model.rollbackCandidates.isEmpty {
                ContentUnavailableView {
                    Label("还没有可恢复的清理记录", systemImage: "arrow.uturn.backward")
                } description: {
                    Text("只有成功移到废纸篓或备份目录的条目才会出现在这里；永久删除不会被列出。")
                }
            } else {
                HStack(spacing: 8) {
                    Picker("位置", selection: $destinationFilter) {
                        Text("全部位置").tag("all")
                        Text("废纸篓").tag("trash")
                        Text("备份目录").tag("backup")
                    }
                    .pickerStyle(.menu).frame(minWidth: 130)

                    Picker("分组", selection: $grouping) {
                        Text("按时间").tag("time")
                        Text("按类型").tag("type")
                    }
                    .pickerStyle(.segmented).frame(width: 170)

                    HStack(spacing: 6) {
                        Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                        TextField("搜索文件名、路径或规则", text: $search)
                            .textFieldStyle(.plain)
                        if !search.isEmpty {
                            Button("清空") { search = "" }.buttonStyle(.borderless).font(.caption)
                        }
                    }
                    .padding(.horizontal, 9).padding(.vertical, 6)
                    .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 8))

                    Spacer()
                    Text("显示 \(visibleCandidates.count) / \(model.rollbackCandidates.count)")
                        .font(.caption).foregroundStyle(.secondary)
                }

                if visibleCandidates.isEmpty {
                    ContentUnavailableView("没有匹配的恢复记录", systemImage: "line.3.horizontal.decrease.circle",
                                           description: Text("换个位置筛选或清空搜索词试试。"))
                        .frame(maxWidth: .infinity, minHeight: 180)
                } else {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(groups, id: \.title) { group in
                            Text("\(group.title) · \(group.rows.count)")
                                .font(.headline)
                                .padding(.horizontal, 12)
                                .padding(.top, 12)
                                .padding(.bottom, 6)
                            ForEach(group.rows) { candidate in
                                candidateRow(candidate)
                                    .padding(.horizontal, 12)
                                    .padding(.vertical, 8)
                                Divider().padding(.leading, 12)
                            }
                        }
                    }
                    .background(.quaternary.opacity(0.12), in: RoundedRectangle(cornerRadius: 10))
                    .overlay(RoundedRectangle(cornerRadius: 10).stroke(.quaternary.opacity(0.5)))
                }
            }
        }
        .padding(18)
        .frame(width: geo.size.width, alignment: .leading)
        }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .task { if model.rollbackCandidates.isEmpty && model.rollbackError == nil { model.refreshRollback() } }
    }

    private func candidateRow(_ candidate: RollbackCandidate) -> some View {
        DisclosureGroup {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("原始路径").font(.caption).foregroundStyle(.secondary)
                    Text(candidate.originalPath).font(.caption.monospaced()).textSelection(.enabled)
                }
                if let location = candidate.resultingItemURL, !location.isEmpty {
                    HStack {
                        Text("精确位置").font(.caption).foregroundStyle(.secondary)
                        Text(location).font(.caption.monospaced()).textSelection(.enabled)
                            .lineLimit(2).truncationMode(.middle)
                    }
                } else {
                    Text("位置：旧记录没有保存精确位置，将按原文件名在废纸篓里匹配。")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Text("命中规则：\(candidate.ruleID ?? "未记录") · 审计第 \(candidate.auditLine) 行")
                    .font(.caption).foregroundStyle(.secondary)
                HStack(spacing: 12) {
                    Button("在 Finder 中定位") { model.revealRollback(candidate) }
                    Button("复制原始路径") { model.copyRollbackPath(candidate) }
                }
                .buttonStyle(.link)
                Text("恢复动作请自己在 Finder 里完成：确认目标文件夹里没有同名的新文件，再拖回去。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            .padding(.top, 6)
        } label: {
            HStack(spacing: 10) {
                Image(systemName: destinationIcon(candidate.destination))
                    .foregroundStyle(candidate.destination == .trash ? .blue : .orange)
                VStack(alignment: .leading, spacing: 2) {
                    Text(model.rollbackChineseName(for: candidate)).font(.body)
                    Text(destinationText(candidate.destination))
                        .font(.caption).foregroundStyle(.secondary)
                    Text(candidate.resultingItemURL == nil ? "旧记录 · 文件名匹配" : "已记录精确位置")
                        .font(.caption2).foregroundStyle(.secondary)
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 2) {
                    Text(ByteCountFormatter.string(
                        fromByteCount: candidate.sizeBytes, countStyle: .file
                    )).font(.caption)
                    Text(Self.timeFormatter.string(from: candidate.movedAt))
                        .font(.caption2).foregroundStyle(.secondary)
                }
            }
        }
    }

    private func destinationText(_ destination: RollbackDestination) -> String {
        switch destination {
        case .trash: return "已移到废纸篓 · 可恢复"
        case let .backup(path): return "按你的选择备份到：\(path)"
        }
    }

    private func destinationIcon(_ destination: RollbackDestination) -> String {
        switch destination {
        case .trash: return "trash"
        case .backup: return "externaldrive.fill"
        }
    }
}

struct GapView: View {
    @EnvironmentObject var model: ScanViewModel
    @State private var probeResults: [String: String] = [:]
    @State private var message = ""

    private var gaps: [ScanGap] { model.report?.scanGaps ?? [] }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .top) {
                    PageHeader(title: "扫描缺口", subtitle: "只要存在关键缺口，清理按钮就会被锁定。按级别分组；可以复制路径、单目录重试读取，或导出报告。")
                    Spacer()
                    Button("复制全部路径") { copyAll() }
                        .disabled(gaps.isEmpty)
                    Button("导出报告") { exportReport() }
                        .disabled(gaps.isEmpty)
                    Button("重新扫描") {
                        probeResults.removeAll()
                        message = ""
                        model.startScan()
                    }
                }

                if !message.isEmpty {
                    InfoBanner(text: message, color: .green)
                }

                if gaps.isEmpty {
                    InfoBanner(text: model.report == nil
                               ? "还没有扫描结果。先点右上角「开始扫描」，才能判断有没有目录读不到、条目是否达到上限。"
                               : "上次扫描没有留下缺口。若之后系统权限或目录状态发生变化，重新扫描会再次核对。",
                               color: .blue)
                } else {
                    HStack(spacing: 8) {
                        Text("关键 \(gaps.filter { $0.severity == .critical }.count)").font(.caption)
                            .padding(.horizontal, 8).padding(.vertical, 3)
                            .background(Color.red.opacity(0.12), in: Capsule()).foregroundStyle(.red)
                        Text("局部 \(gaps.filter { $0.severity == .warning }.count)").font(.caption)
                            .padding(.horizontal, 8).padding(.vertical, 3)
                            .background(Color.orange.opacity(0.12), in: Capsule()).foregroundStyle(.orange)
                        Text("提示 \(gaps.filter { $0.severity == .info }.count)").font(.caption)
                            .padding(.horizontal, 8).padding(.vertical, 3)
                            .background(Color.gray.opacity(0.12), in: Capsule()).foregroundStyle(.secondary)
                        Spacer()
                        Text("报告共 \(gaps.count) 个缺口").font(.caption).foregroundStyle(.secondary)
                    }

                    ForEach(ScanGapReport.grouped(gaps), id: \.severity.rawValue) { group in
                        VStack(alignment: .leading, spacing: 8) {
                            HStack(spacing: 7) {
                                Image(systemName: group.severity == .critical ? "xmark.octagon.fill" : (group.severity == .warning ? "exclamationmark.triangle.fill" : "info.circle"))
                                    .foregroundStyle(severityColor(group.severity))
                                Text(ScanGapReport.severityTitle(group.severity)).font(.headline)
                                Text("\(group.gaps.count) 项").font(.caption).foregroundStyle(.secondary)
                                Spacer()
                            }
                            ModuleCard(padding: 0) {
                                VStack(spacing: 0) {
                                    ForEach(group.gaps, id: \.self) { gap in
                                        gapRow(gap)
                                        if gap != group.gaps.last { Divider() }
                                    }
                                }
                            }
                        }
                    }
                }

                PermissionGuideView()
            }
            .padding(18)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
    }

    private func gapRow(_ gap: ScanGap) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: gap.severity == .critical ? "xmark.octagon.fill" : (gap.severity == .warning ? "exclamationmark.triangle.fill" : "info.circle"))
                .foregroundStyle(severityColor(gap.severity))
            VStack(alignment: .leading, spacing: 4) {
                Text(gap.displayText).font(.callout)
                Text(gap.path).font(.caption2.monospaced()).foregroundStyle(.secondary)
                    .textSelection(.enabled)
                if let detail = gap.detail {
                    Text(detail).font(.caption).foregroundStyle(.secondary)
                }
                if let result = probeResults[gap.path] {
                    Text(result).font(.caption2).foregroundStyle(result.contains("现在可") ? .green : .orange)
                }
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 5) {
                Text(gap.severity == .critical ? "全盘级" : (gap.scope == .wholeScan ? "整次扫描" : "单个目录"))
                    .font(.caption2)
                    .foregroundStyle(severityColor(gap.severity))
                HStack(spacing: 10) {
                    Button("复制路径") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(gap.path, forType: .string)
                        message = "已复制路径"
                    }
                    .buttonStyle(.link)
                    if gap.scope == .directory && gap.kind != .truncated {
                        Button("重试该目录") {
                            probeResults[gap.path] = "正在重试读取…"
                            Task {
                                let readable = await model.probeDirectoryReadable(gap.path)
                                probeResults[gap.path] = readable
                                    ? "现在可读取；重新扫描后才会更新报告。"
                                    : "仍然读不到；请检查授权或目录是否已移动。"
                            }
                        }
                        .buttonStyle(.link)
                    }
                }
                .font(.caption)
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
    }

    private func severityColor(_ severity: ScanGap.Severity) -> Color {
        switch severity {
        case .critical: return .red
        case .warning: return .orange
        case .info: return .secondary
        }
    }

    private func copyAll() {
        let text = gaps.map { "\($0.displayText)\n\($0.path)" }.joined(separator: "\n\n")
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        message = "已复制 \(gaps.count) 条缺口路径"
    }

    private func exportReport() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "md") ?? .plainText]
        panel.canCreateDirectories = true
        panel.nameFieldStringValue = "雪-扫描缺口.md"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let markdown = ScanGapReport.markdown(
            gaps: gaps,
            scanScope: model.scanScope.chineseName
        )
        do {
            try Data(markdown.utf8).write(to: url, options: .atomic)
            message = "已导出缺口报告：\(url.lastPathComponent)"
        } catch {
            message = "导出失败：\(error.localizedDescription)"
        }
    }
}

struct PermissionGuideView: View {
    @EnvironmentObject var model: ScanViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if model.directoryAccess?.hasFullDiskAccess == true {
                Label("完全磁盘访问权限已获得", systemImage: "checkmark.seal.fill")
                    .font(.headline)
                    .foregroundStyle(.green)
                Text("系统目录可读；如果仍出现缺口，再按具体目录处理。")
                    .font(.callout).foregroundStyle(.secondary)
            } else {
                Text("完全磁盘访问权限").font(.headline)
                Text("没有它，全盘扫描会跳过系统目录，报告按全盘级缺口锁定清理；日常清理请先选「仅我的用户目录」。")
                    .font(.callout).foregroundStyle(.secondary)
                Button("前往系统设置开启") { model.openFullDiskAccessSettings() }
            }
        }
        .padding(12)
        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 10))
    }
}

struct SettingsView: View {
    @EnvironmentObject var model: ScanViewModel
    @EnvironmentObject var monitor: SystemMonitor
    @AppStorage("snow.main.selection") private var selection = "概览"
    @AppStorage("snow.appearance") private var appearance: SnowTheme = .snowDay
    @State private var dictSearch = ""
    @StateObject private var provider = AssistantProviderSettings.shared
    @State private var configMessage: String?
    @State private var configMessageIsError = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                PageHeader(title: "设置",
                           subtitle: "所有偏好只存在本机。导入导出只含设置与保护路径，不含任何用户文件内容。")

                settingsCard("外观", "同一套信息，两种光；雪日默认，雪夜不是旧黑金") {
                    Picker("外观主题", selection: $appearance) {
                        ForEach(SnowTheme.allCases) { theme in
                            Text(theme.chineseName).tag(theme)
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .frame(maxWidth: 360, alignment: .leading)
                    Text(appearance.detail)
                        .font(.caption).foregroundStyle(.secondary)
                }

                settingsCard("显示与存储", "影响界面上的数字格式与常驻方式") {
                    HStack(alignment: .center, spacing: 16) {
                        VStack(alignment: .leading, spacing: 3) {
                            Text("存储显示单位").font(.callout.weight(.medium))
                            Text("自动按大小选 MB / GB；固定单位便于横向比较。只改显示，不改数值。")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer(minLength: 12)
                        Picker("存储显示单位", selection: $model.displayUnit) {
                            ForEach(DisplayUnit.allCases) { unit in
                                Text(unit.chineseName).tag(unit)
                            }
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()
                        .frame(width: 220)
                    }
                    Divider()
                    Toggle("主窗口打开时在 Dock 显示图标", isOn: $model.showDockIcon)
                    Text("关闭主窗口会自动收进菜单栏，Dock 图标随之隐藏并转入静默；再次打开时再按这个开关恢复。主窗口仍可用 ⌘0 打开。")
                        .font(.caption).foregroundStyle(.secondary)
                    Divider()
                    Toggle("显示英文原文", isOn: $model.showEnglishOriginal)
                    Text("默认开；关闭后清理列表与证据只留中文，原始路径折叠到「查看原始路径」。")
                        .font(.caption).foregroundStyle(.secondary)
                }

                settingsCard("运行模式", "默认静默；只改刷新节奏，不改任何清理判定") {
                    Picker("运行模式", selection: $model.preferredRunMode) {
                        ForEach(RunMode.allCases) { mode in
                            Text(mode.chineseName).tag(mode)
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .frame(maxWidth: 360, alignment: .leading)

                    Text(model.preferredRunMode.detail)
                        .font(.caption).foregroundStyle(.secondary)

                    Divider()

                    let status = model.runModeStatus
                    HStack(alignment: .top, spacing: 8) {
                        Image(systemName: status.mode == .performance ? "bolt.fill" : "snowflake")
                            .foregroundStyle(status.mode == .performance ? Color.orange : Color.blue)
                        VStack(alignment: .leading, spacing: 3) {
                            Text("当前实际：\(status.mode.chineseName)\(status.isTemporary ? "（临时）" : "")")
                                .font(.callout.weight(.medium))
                            Text(status.reason)
                                .font(.caption).foregroundStyle(.secondary)
                            if let percent = model.batteryPercentForMode {
                                Text("电量 \(percent)% · 系统低电量模式 \(model.lowPowerModeForMode ? "已开启" : "未开启") · 低于 \(RunMode.lowBatteryThreshold)% 会强制静默。")
                                    .font(.caption2).foregroundStyle(.secondary)
                            }
                        }
                        Spacer(minLength: 8)
                    }
                    .padding(10)
                    .background(Color.blue.opacity(0.06), in: RoundedRectangle(cornerRadius: 8))
                }

                settingsCard("日常记录与电池守护", "只写本机，不联网；记录不参与清理判定") {
                    HStack(alignment: .center, spacing: 16) {
                        VStack(alignment: .leading, spacing: 3) {
                            Text("记录电池与资源日常数据").font(.callout.weight(.medium))
                            Text("按运行模式记录：静默 30 分钟、均衡 10 分钟、性能 5 分钟；记录电量、电源、热压力、磁盘与内存，雪退出后不补采。")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer(minLength: 12)
                        Toggle("", isOn: Binding(
                            get: { model.dailyJournalEnabled },
                            set: { enabled in
                                model.dailyJournalEnabled = enabled
                                if enabled { Task { await monitor.recordDailySnapshot(force: true) } }
                            }
                        ))
                        .labelsHidden()
                        .toggleStyle(.switch)
                    }
                    HStack(spacing: 10) {
                        Text("保存在 ~/Library/Application Support/雪/daily-metrics.jsonl")
                            .font(.caption).foregroundStyle(.secondary)
                        Spacer()
                        Button("去电池") { selection = "电池" }
                            .buttonStyle(.link)
                    }
                }

                settingsCard("模型接入（雪语）", "默认系统本地模型；API 只是可插拔选项，本地规则始终兜底") {
                    Picker("模型接入", selection: $provider.route) {
                        ForEach(AssistantProviderRoute.allCases) { route in
                            Text(route.chineseName).tag(route)
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .frame(maxWidth: 640, alignment: .leading)

                    Text(provider.route.detail)
                        .font(.caption).foregroundStyle(.secondary)

                    if provider.route == .local3B {
                        Divider()
                        HStack(spacing: 10) {
                            Button("填入 Qwen3-4B 观测预设") { provider.applyLocalObservationPreset() }
                            Text("4B / Q4_K_M / 约 2.4 GB；只做只读观察，不参与删除。")
                                .font(.caption).foregroundStyle(.secondary)
                            Spacer(minLength: 0)
                        }
                        providerField("llama-server") {
                            TextField("/path/to/llama-server", text: $provider.localRuntimePath)
                                .textFieldStyle(.roundedBorder)
                                .font(.system(size: 12, design: .monospaced))
                                .frame(maxWidth: 420, alignment: .leading)
                            Button("选择") { chooseLocalRuntime() }
                        }
                        providerField("GGUF 权重") {
                            TextField("/path/to/model.gguf", text: $provider.localModelPath)
                                .textFieldStyle(.roundedBorder)
                                .font(.system(size: 12, design: .monospaced))
                                .frame(maxWidth: 420, alignment: .leading)
                            Button("选择") { chooseLocalModel() }
                        }
                        providerField("本地端口") {
                            Stepper("127.0.0.1:\(provider.localPort)", value: $provider.localPort, in: 19_000...19_999)
                                .fixedSize()
                            Text("只监听本机；空闲 120 秒后宿主会退出 llama-server。")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        HStack(spacing: 10) {
                            Button("测试本地小模型") { provider.testConnection() }
                                .disabled(provider.isTesting)
                            if provider.isTesting { ProgressView().controlSize(.small) }
                            Text("权重不随 App 分发；首次测试会加载模型，可能等十几秒。")
                                .font(.caption).foregroundStyle(.secondary)
                            Spacer(minLength: 0)
                        }
                    }

                    if provider.route == .openAICompatible {
                        Divider()
                        providerField("接口地址") {
                            TextField("https://api.openai.com/v1", text: $provider.baseURL)
                                .textFieldStyle(.roundedBorder)
                                .font(.system(size: 12, design: .monospaced))
                        }
                        providerField("模型名") {
                            TextField("例如 gpt-4.1-mini", text: $provider.model)
                                .textFieldStyle(.roundedBorder)
                                .font(.system(size: 12, design: .monospaced))
                                .frame(maxWidth: 280, alignment: .leading)
                            Stepper("超时 \(provider.timeoutSeconds) 秒",
                                    value: $provider.timeoutSeconds, in: 3...30)
                                .fixedSize()
                        }
                        providerField("API Key") {
                            SecureField(provider.hasStoredKey ? "已保存，可留空" : "粘贴 Key", text: $provider.apiKeyDraft)
                                .textFieldStyle(.roundedBorder)
                                .frame(maxWidth: 320, alignment: .leading)
                            Button(provider.hasStoredKey ? "更新钥匙串" : "保存到钥匙串") {
                                provider.saveAPIKey()
                            }
                            Button("清除") { provider.clearAPIKey() }
                                .disabled(!provider.hasStoredKey && provider.apiKeyDraft.isEmpty)
                        }
                        HStack(spacing: 10) {
                            Button("测试连接") { provider.testConnection() }
                                .disabled(provider.isTesting)
                            if provider.isTesting {
                                ProgressView().controlSize(.small)
                            }
                            Text("只发一句测试话；不发路径、文件名、体积或扫描结果。")
                                .font(.caption).foregroundStyle(.secondary)
                            Spacer(minLength: 0)
                        }
                    }

                    HStack(alignment: .top, spacing: 8) {
                        Image(systemName: provider.statusIsError ? "exclamationmark.triangle.fill" : "key.fill")
                            .foregroundStyle(provider.statusIsError ? Color.orange : Color.secondary)
                            .font(.caption)
                        Text(provider.statusText)
                            .font(.caption)
                            .foregroundStyle(provider.statusIsError ? Color.orange : Color.secondary)
                        Spacer(minLength: 0)
                    }
                    .padding(9)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 8))

                    if provider.connectionState == .failed,
                       let failure = provider.lastFailureText,
                       failure != provider.statusText {
                        Text("最近一次请求：\(failure)")
                            .font(.caption2)
                            .foregroundStyle(Color.orange.opacity(0.85))
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    Text("API Key 只存在本机钥匙串；配置导入导出不含 Key，也不含接口地址。失败时依次退回系统模型、本地规则，不会跳过规则直接清理。")
                        .font(.caption2).foregroundStyle(.tertiary)
                }


                settingsCard("开发模型自检", "只影响开发自检页；雪语真正的接入方式在上方，不影响扫描和删除判定") {
                    HStack {
                        Picker("自检档位", selection: $model.aiMode) {
                            Text("关闭").tag(AIMode.off)
                            Text("混合模板").tag(AIMode.hybrid)
                            Text("完整解释").tag(AIMode.full)
                        }
                        .labelsHidden()
                        .pickerStyle(.segmented)
                        .frame(maxWidth: 360, alignment: .leading)
                        Spacer()
                        Button("打开模型自检") { selection = "自检" }
                            .buttonStyle(.link)
                    }
                    Text("这里是旧的开发自检，不是本地小模型；本地小模型在上方单独配置。自检关闭时零调用，中文名称来自本地词典。")
                        .font(.caption).foregroundStyle(.secondary)
                }

                settingsCard("菜单栏快速面板", "快速面板只留重要信息：硬盘、内存、CPU、设备、网络；其余内容进主面板") {
                    menuToggle("面板显示硬盘", "只影响点击后的快速面板；顶栏始终只留一枚雪花。", \.showDiskSpace)
                    Divider()
                    menuToggle("面板显示内存", "在快速面板显示已用 / 总内存。", \.showMemory)
                    Divider()
                    Text("CPU、设备、网络固定显示；电池、扫描与工具入口收进主面板。")
                        .font(.caption).foregroundStyle(.secondary)
                }

                settingsCard("扫描范围", "下次扫描生效；范围只决定看多远，不改变删除判定") {
                    Picker("扫描范围", selection: $model.scanScope) {
                        ForEach(ScanScope.allCases) { scope in
                            Text(scope.chineseName).tag(scope)
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    Text(model.scanScope.explain)
                        .font(.caption).foregroundStyle(.secondary)
                    if model.scanScope == .wholeDisk {
                        Label("未获全盘授权时，全盘扫描会跳过系统目录并锁定清理；日常清理建议先用「仅我的用户目录」。",
                              systemImage: "exclamationmark.triangle.fill")
                            .font(.caption)
                            .foregroundStyle(.orange)
                            .padding(10)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(Color.orange.opacity(0.10), in: RoundedRectangle(cornerRadius: 8))
                    }
                }

                settingsCard("配置导入 / 导出", "把偏好搬到另一台 Mac，或换机前留一份") {
                    HStack(spacing: 10) {
                        Button("导出配置") { exportConfiguration() }
                        Button("导入配置") { importConfiguration() }
                        Spacer()
                    }
                    Text("包含：保护路径、菜单栏开关、模型档位、显示单位、扫描范围、日常记录开关。不含扫描结果、审计日志、任何文件内容、模型接口地址或钥匙串里的 API Key。")
                        .font(.caption).foregroundStyle(.secondary)
                    if let configMessage {
                        Text(configMessage)
                            .font(.callout)
                            .foregroundStyle(configMessageIsError ? .red : .green)
                            .padding(10)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background((configMessageIsError ? Color.red : Color.green).opacity(0.08),
                                        in: RoundedRectangle(cornerRadius: 8))
                    }
                }

                settingsCard("我额外保护的路径", "保护路径只增不减；完整管理在专用页面") {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("已保护 \(model.customProtections.count) 条自定义路径").font(.callout.weight(.medium))
                            Text(model.customProtections.isEmpty
                                 ? "还没有自定义保护路径。"
                                 : model.customProtections.prefix(3).joined(separator: " · "))
                                .font(.caption).foregroundStyle(.secondary)
                                .lineLimit(1).truncationMode(.middle)
                        }
                        Spacer()
                        Button("去保护路径") { selection = "保护" }
                    }
                }

                dictionaryCard

                settingsCard("安全边界", "这些是硬规则，不提供关闭开关") {
                    boundaryRow("默认移到废纸篓", "可恢复；永久删除需要二次确认。")
                    Divider()
                    boundaryRow("执行前先看预览", "任何删除先列出清单，不静默执行。")
                    Divider()
                    boundaryRow("JSONL 审计日志", "预览、成功、失败都记录，带哈希链，改动会留下痕迹。")
                    Divider()
                    boundaryRow("废纸篓失败即停止", "绝不静默改成永久删除。")
                }

                settingsCard("版本与许可", "个人自用，不发布 V1.0.0 正式版") {
                    Text(AppVersion.current.fullDisplay).font(.callout.weight(.medium))
                    Text("阶段：\(AppVersion.current.stage)").font(.caption).foregroundStyle(.secondary)
                    Text("GPL-3.0 · 不联网、无遥测、无账号。若对外分发二进制，须按 GPL-3.0 开放对应源码并重新评估合规义务。")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func menuToggle(_ title: String, _ detail: String,
                            _ keyPath: WritableKeyPath<MenuBarPreferences, Bool>) -> some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.callout.weight(.medium))
                Text(detail).font(.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: 12)
            Toggle("", isOn: Binding(
                get: { model.menuBarPreferences[keyPath: keyPath] },
                set: { newValue in
                    var prefs = model.menuBarPreferences
                    prefs[keyPath: keyPath] = newValue
                    model.menuBarPreferences = prefs
                }
            ))
            .labelsHidden()
            .toggleStyle(.switch)
        }
    }

    private var dictionaryCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("英文字典对照").font(.headline)
                Text("\(model.glossaryEntries.count) 条").font(.caption).foregroundStyle(.secondary)
                Spacer()
                TextField("搜索中文或英文…", text: $dictSearch)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 220)
            }
            Text("看不懂的英文来这里查。清理页显示的中文名与一句话解释，都来自这张表。")
                .font(.caption).foregroundStyle(.secondary)
            let filtered = model.glossaryEntries.filter {
                dictSearch.isEmpty
                    || $0.en.localizedCaseInsensitiveContains(dictSearch)
                    || $0.zh.localizedCaseInsensitiveContains(dictSearch)
            }
            if filtered.isEmpty {
                Text("没有匹配词条。").font(.caption).foregroundStyle(.secondary)
            } else {
                VStack(spacing: 0) {
                    ForEach(filtered.prefix(40), id: \.en) { entry in
                        HStack(alignment: .firstTextBaseline, spacing: 10) {
                            Text(entry.en).font(.caption.monospaced()).frame(width: 200, alignment: .leading)
                                .lineLimit(1).truncationMode(.middle)
                            Text(entry.zh).font(.callout.weight(.medium)).frame(width: 120, alignment: .leading)
                            Text(entry.say).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                            Spacer(minLength: 0)
                        }
                        .padding(.vertical, 4)
                        Divider()
                    }
                }
                if filtered.count > 40 {
                    Text("共 \(filtered.count) 条，列表只显示前 40 条；用上面的搜索框缩小范围。")
                        .font(.caption2).foregroundStyle(.secondary)
                }
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.18), in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(.quaternary.opacity(0.5)))
    }

    private func chooseLocalRuntime() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.message = "选择可执行的 llama-server"
        if panel.runModal() == .OK, let url = panel.url {
            provider.localRuntimePath = url.path
        }
    }

    private func chooseLocalModel() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.message = "选择 GGUF 权重文件"
        if let gguf = UTType(filenameExtension: "gguf") {
            panel.allowedContentTypes = [gguf]
        }
        if panel.runModal() == .OK, let url = panel.url {
            provider.localModelPath = url.path
        }
    }

    private func providerField<Content: View>(_ title: String,
                                              @ViewBuilder content: () -> Content) -> some View {
        HStack(alignment: .center, spacing: 10) {
            Text(title)
                .font(.caption.weight(.medium))
                .frame(width: 72, alignment: .leading)
            content()
            Spacer(minLength: 0)
        }
    }

    private func settingsCard<Content: View>(_ title: String, _ detail: String,
                                             @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title).font(.headline)
            Text(detail).font(.caption).foregroundStyle(.secondary)
            content()
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.18), in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(.quaternary.opacity(0.5)))
    }

    private func boundaryRow(_ title: String, _ detail: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Text(title).font(.callout.weight(.medium)).frame(width: 150, alignment: .leading)
            Text(detail).font(.caption).foregroundStyle(.secondary)
            Spacer(minLength: 0)
        }
    }

    private func exportConfiguration() {
        do {
            let data = try model.configurationData()
            let panel = NSSavePanel()
            panel.nameFieldStringValue = "雪配置.json"
            panel.allowedContentTypes = [.json]
            guard panel.runModal() == .OK, let url = panel.url else { return }
            try data.write(to: url, options: .atomic)
            configMessageIsError = false
            configMessage = "已导出配置：\(url.lastPathComponent)（不含文件内容）"
        } catch {
            configMessageIsError = true
            configMessage = "导出失败：\(error.localizedDescription)"
        }
    }

    private func importConfiguration() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let data = try Data(contentsOf: url)
            let configuration = try ConfigurationTransfer.decode(data)
            let newCount = try model.applyConfiguration(configuration)
            configMessageIsError = false
            configMessage = "已导入配置：保护路径 \(configuration.customProtections.count) 条（新增 \(newCount) 条）；菜单栏、单位、模型档位、日常记录已生效。"
        } catch {
            configMessageIsError = true
            configMessage = "导入失败：\(error.localizedDescription)"
        }
    }
}
