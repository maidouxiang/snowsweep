import SwiftUI
import AppKit
import SnowSweepCore

// SPDX-License-Identifier: GPL-3.0-or-later
// 本项目沿用 Mole CLI 的 GPL-3.0 许可开源；分发二进制时须同时提供对应源码。

/// 菜单栏与主窗口共享同一份扫描状态和系统指标。
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let model: ScanViewModel
    let monitor: SystemMonitor

    override init() {
        // 必须在任何存储初始化之前完成：旧数据先复制到「雪」，
        // 旧 SnowSweep 目录保持只读，不移动、不删除。
        let migration = SnowDataMigrator.migrateIfNeeded()
        let defaultsCopied = SnowDefaultsMigrator.migrateIfNeeded()
        print("[MIGRATION] \(migration.summary) preferences=\(defaultsCopied)")
        model = ScanViewModel()
        monitor = SystemMonitor()
        super.init()
    }

    private var statusItem: NSStatusItem?
    private var diskButton: NSStatusBarButton?
    private var statusTimer: Timer?
    private var dailyTimer: Timer?
    private var timelineTimer: Timer?
    private var panelPopover: NSPopover?
    private var panelLocalMonitor: Any?
    private var panelDismissObservers: [NSObjectProtocol] = []
    private var panelCloseObserver: NSObjectProtocol?
    private var panelRefreshTimer: Timer?
    private var panelRefreshInFlight = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        if ProcessInfo.processInfo.arguments.contains("--xpc-smoke") {
            Task { await runXPCSmoke() }
            return
        }
        RuntimeCenter.shared.configure(model: model, monitor: monitor)
        // 菜单栏面板要能独立显示实时上下行；采样器在启动时就开始，
        // 不依赖用户先打开主界面的网络页。
        NetworkTrafficSampler.shared.start()
        installStatusItem()
        installWindowCloseObserver()
        startDailyJournal()
        startSpaceTimelineScheduler()
        applyRunModeTimers()
    }

    /// 验收用：直接以 App 包启动，验证两个 XPC 服务能被系统拉起。
    /// 只读扫描 3 秒后自动取消；不执行清理，不写用户数据。
    private func runXPCSmoke() async {
        var lines: [String] = []
        do {
            let status = try await ModelHostClient.shared.status()
            lines.append("MODELHOST status system=\(status.systemModelAvailable) localServer=\(status.localServerRunning) detail=\(status.detail)")
        } catch {
            lines.append("MODELHOST failed \(error.localizedDescription)")
        }

        let ruleURL = Bundle.main.url(forResource: "rules", withExtension: "json")
            ?? Bundle.main.url(forResource: "rules", withExtension: "json", subdirectory: "Rules")
        do {
            guard let ruleURL else { throw RemoteScannerError.invalidResponse("App 包里没有 rules.json") }
            let engine = try UserRuleRegistry().loadEngine(builtinURL: ruleURL, extraProtectedPaths: [])
            let remote = RemoteScannerClient()
            let request = ScannerXPCRequest(
                ruleBook: engine.ruleBook,
                scope: .userOnly,
                maxConcurrentRoots: 2,
                cancelAfterSeconds: 3
            )
            let response = try remote.scan(request: request, onProgress: { _ in })
            lines.append("SCANNER source=child scanned=\(response.summary.scanned) kept=\(response.summary.kept) cancelled=\(response.cancelled) items=\(response.items.count) gaps=\(response.gaps.count) failure=\(response.failure ?? "none")")
        } catch {
            lines.append("SCANNER failed \(error.localizedDescription)")
        }
        let report = lines.joined(separator: "\n")
        try? report.write(toFile: "/tmp/xpc-smoke-result.txt", atomically: true, encoding: .utf8)
        print(report)
        fflush(stdout)
        exit(lines.contains(where: { $0.contains("SCANNER source=xpc") }) ? 0 : 2)
    }

    func applicationWillTerminate(_ notification: Notification) {
        timelineTimer?.invalidate()
        timelineTimer = nil
        stopPanelRefresh()
        NetworkTrafficSampler.shared.stop()
        if let panelCloseObserver {
            NotificationCenter.default.removeObserver(panelCloseObserver)
            self.panelCloseObserver = nil
        }
        RuntimeCenter.shared.shutdown()
    }

    /// 崩溃后 AppKit 会弹“是否恢复窗口”的模态框，冒烟与正常启动都可能被它挡住。
    /// 雪不需要窗口恢复：关窗就进静默，重开由用户自己点。
    func applicationShouldSaveApplicationState(_ app: NSApplication) -> Bool { false }

    func applicationShouldRestoreApplicationState(_ app: NSApplication) -> Bool { false }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        // 关主窗口只进入静默，菜单栏继续可用；完全退出才停后台。
        false
    }

    private func installWindowCloseObserver() {
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(mainWindowWillClose(_:)),
            name: NSWindow.willCloseNotification,
            object: nil
        )
    }

    @objc private func mainWindowWillClose(_ note: Notification) {
        guard let window = note.object as? NSWindow,
              window.identifier?.rawValue.contains("main") == true
        else { return }
        // 先收起 Dock 与菜单，再释放报告和快照；进程留在菜单栏，不退出。
        model.setMainWindowClosed(true)
        RuntimeCenter.shared.enterSilent(reason: "主窗口关闭，自动收进菜单栏")
    }

    private func installStatusItem() {
        // 菜单栏面板延迟到第一次点击再创建，静默启动不实例化 SwiftUI 面板。
        // 顶栏只留一枚雪花；可用空间、电池和告警状态放进悬停提示与点击面板。
        let item = NSStatusBar.system.statusItem(withLength: 30)
        guard let button = item.button else { return }
        button.target = self
        button.action = #selector(togglePanel(_:))
        button.toolTip = "雪 · 点击打开快速面板"

        button.font = NSFont.systemFont(ofSize: 14, weight: .medium)
        if let snow = NSImage(systemSymbolName: "snowflake", accessibilityDescription: "雪") {
            snow.isTemplate = true
            button.image = snow
            button.imagePosition = .imageOnly
            button.title = ""
        } else {
            button.title = "❄"
        }
        // 只保留雪花；不加文字、不加状态圆点，避免顶栏被撑宽。
        button.wantsLayer = true
        button.layer?.cornerRadius = 7
        button.layer?.backgroundColor = NSColor.systemBlue.withAlphaComponent(0.10).cgColor
        item.isVisible = true
        statusItem = item
        diskButton = button

        NotificationCenter.default.addObserver(
            self, selector: #selector(menuBarPreferencesChanged),
            name: .snowMenuBarPreferencesChanged, object: nil
        )
        NotificationCenter.default.addObserver(
            self, selector: #selector(runModeChanged),
            name: .snowRunModeChanged, object: nil
        )
        Task { await refreshStatusTitle() }
    }

    private func makePanelPopover() -> NSPopover {
        let popover = NSPopover()
        popover.behavior = .transient
        let panel = MenuBarPanel()
            .environmentObject(model)
            .environmentObject(monitor)
        let hosting = NSHostingController(rootView: panel)
        // 弹窗尺寸跟着 SwiftUI 内容走：内容固定 330 宽，高度按实际行数伸缩。
        // 以前写死 540×520，会把 330 宽的内容居中放进 540 宽的弹窗，右侧留出空白。
        hosting.sizingOptions = [.preferredContentSize]
        popover.contentViewController = hosting
        panelCloseObserver = NotificationCenter.default.addObserver(
            forName: NSPopover.didCloseNotification,
            object: popover,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.stopPanelRefresh()
                self?.removePanelDismissObservers()
            }
        }
        return popover
    }

    @objc private func menuBarPreferencesChanged() {
        Task { await refreshStatusTitle() }
    }

    @objc private func runModeChanged() {
        applyRunModeTimers()
    }

    /// 静默/均衡/性能只改刷新节奏，不改判定。扫描临时性能由 ScanViewModel 控制。
    private func applyRunModeTimers() {
        scheduleStatusTimer()
        scheduleDailyTimer()
    }

    private func scheduleStatusTimer() {
        statusTimer?.invalidate()
        let interval = model.effectiveRunMode.menuBarInterval
        let timer = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.refreshStatusTitle() }
        }
        // 允许系统把刷新窗口合并到相邻唤醒；菜单栏不需要秒级准点。
        timer.tolerance = max(1, interval * 0.10)
        RunLoop.main.add(timer, forMode: .common)
        statusTimer = timer
    }

    private func scheduleDailyTimer() {
        dailyTimer?.invalidate()
        guard model.dailyJournalEnabled else {
            dailyTimer = nil
            return
        }
        let interval = model.effectiveRunMode.dailyJournalInterval
        let timer = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.model.dailyJournalEnabled else { return }
                await self.monitor.recordDailySnapshot()
            }
        }
        // 日常记录同样是宽松任务，10% 容差足够，能减少一次独立唤醒。
        timer.tolerance = max(10, interval * 0.10)
        RunLoop.main.add(timer, forMode: .common)
        dailyTimer = timer
    }

    /// 每 10 分钟记录一次本机电池/磁盘/内存快照。主窗口关掉也继续，
    /// 但 App 完全退出后不补采；这是自用轻量记录，不安装后台守护进程。
    private func startDailyJournal() {
        Task { @MainActor in
            await monitor.pruneDailyJournal()
            await monitor.refreshDailyJournal(days: monitor.dailyRangeDays)
            if model.dailyJournalEnabled {
                await monitor.recordDailySnapshot()
            }
        }
    }

    /// 空间时间线兜底：启动 15 秒后检查一次，之后每 6 小时检查一次。
    /// 只有距上一张快照满 7 天才真正跑目录统计；扫描成功会另外立即写一张。
    private func startSpaceTimelineScheduler() {
        timelineTimer?.invalidate()
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(15))
            await SpaceSnapshotAutoCapture.captureIfDue()
        }
        let timer = Timer(timeInterval: 6 * 3_600, repeats: true) { _ in
            Task { await SpaceSnapshotAutoCapture.captureIfDue() }
        }
        timer.tolerance = 600
        RunLoop.main.add(timer, forMode: .common)
        timelineTimer = timer
    }

    private func refreshStatusTitle() async {
        statusItem?.length = 30
        let status = await monitor.menuBarStatus()
        model.updatePowerState(
            percent: status.battery?.chargePercent,
            lowPowerMode: status.battery?.lowPowerMode ?? false
        )
        if diskButton?.image == nil { diskButton?.title = "❄" }
        guard let disk = status.disk else {
            diskButton?.toolTip = "雪 · 磁盘暂时读不到 · 点击打开快速面板"
            return
        }
        let text = model.displayUnit.format(bytes: disk.freeBytes)
            .replacingOccurrences(of: " bytes", with: " B")
        let batteryText = status.battery?.chargePercent.map { "\($0)%" } ?? "读不到"
        diskButton?.toolTip = "雪 · 可用 \(text) · 电池 \(batteryText) · 点击打开快速面板"
    }

    @objc private func togglePanel(_ sender: Any?) {
        guard let button = statusItem?.button else { return }
        if panelPopover == nil {
            panelPopover = makePanelPopover()
        }
        guard let popover = panelPopover else { return }
        if popover.isShown {
            closePanel(sender)
        } else {
            NSApp.activate(ignoringOtherApps: true)
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            installPanelDismissObservers()
            startPanelRefresh()
        }
    }

    /// 主窗口关闭时 RuntimeCenter 会释放所有页面快照；快捷面板却被 NSPopover 缓存着，
    /// SwiftUI 的 `.task` 不会在每次重开时再跑。这里在每次展开时主动取一次，
    /// 并在展开期间定时补磁盘/内存/CPU；网络上下行由 1 秒采样器单独驱动。
    private func startPanelRefresh() {
        panelRefreshTimer?.invalidate()
        refreshPanelNow()
        let timer = Timer(timeInterval: 5, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refreshPanelNow() }
        }
        timer.tolerance = 0.5
        RunLoop.main.add(timer, forMode: .common)
        panelRefreshTimer = timer
    }

    private func refreshPanelNow() {
        guard !panelRefreshInFlight else { return }
        panelRefreshInFlight = true
        Task { @MainActor in
            await monitor.refreshMenuPanel()
            panelRefreshInFlight = false
        }
    }

    private func stopPanelRefresh() {
        panelRefreshTimer?.invalidate()
        panelRefreshTimer = nil
    }

    /// NSPopover 的 .transient 在菜单栏 App 里并不可靠：点到别的窗口、
    /// 桌面或其他 App 时，弹窗可能继续驻留。这里显式收口两条路径：
    /// 1) 本 App 内点到弹窗以外的窗口；
    /// 2) App 失去激活（点到 Finder、桌面或其他应用）。
    ///
    /// 不监听 NSWindow.didBecomeKeyNotification：从别的 App 点菜单栏时，
    /// NSApp.activate 会让主窗口成为 key，晚到的通知会把刚打开的弹窗误关。
    /// 同 App 内的点击已经由本地鼠标监听覆盖。
    private func installPanelDismissObservers() {
        removePanelDismissObservers()

        panelLocalMonitor = NSEvent.addLocalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]
        ) { [weak self] event in
            guard let self, let popover = self.panelPopover, popover.isShown else { return event }
            // 点菜单栏雪花本身交给 togglePanel 关闭，避免“先关又开”。
            if event.window === self.statusItem?.button?.window { return event }
            if event.window !== popover.contentViewController?.view.window {
                self.closePanel(nil)
            }
            return event
        }

        let center = NotificationCenter.default
        panelDismissObservers.append(center.addObserver(
            forName: NSApplication.didResignActiveNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.closePanel(nil)
            }
        })
    }

    private func removePanelDismissObservers() {
        if let panelLocalMonitor {
            NSEvent.removeMonitor(panelLocalMonitor)
            self.panelLocalMonitor = nil
        }
        let center = NotificationCenter.default
        panelDismissObservers.forEach(center.removeObserver)
        panelDismissObservers.removeAll()
    }

    private func closePanel(_ sender: Any?) {
        removePanelDismissObservers()
        stopPanelRefresh()
        panelPopover?.performClose(sender)
    }
}

@main
struct SnowSweepApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        // 固定 id，让菜单栏/坞图标能可靠地重新打开同一主窗口；
        // 不设 id 时窗口被关掉后 activate() 无法重建，表现为"打不开主界面"。
        WindowGroup("雪", id: "main") {
            MainWindow()
                .environmentObject(appDelegate.model)
                .environmentObject(appDelegate.monitor)
        }
        .defaultSize(width: 980, height: 700)
        // 启动即呈现窗口，避免只有菜单栏场景被激活、主窗口不出现。
        .defaultLaunchBehavior(.presented)
        .windowResizability(.contentMinSize)
        .commands {
            CommandGroup(replacing: .appInfo) {
                Button("关于雪") { NSApp.orderFrontStandardAboutPanel(nil) }
            }
            CommandGroup(replacing: .appSettings) {
                Button("设置…") { AppWindow.showMain(section: "设置") }
                    .keyboardShortcut(",", modifiers: .command)
            }
            CommandGroup(after: .newItem) {
                Divider()
                Button("打开主界面") { AppWindow.showMain() }
                    .keyboardShortcut("0", modifiers: .command)
                Button("释放内存，进入静默") {
                    RuntimeCenter.shared.enterSilent(reason: "手动进入静默", releaseMemory: true)
                }
                Button(appDelegate.model.isScanning ? "取消扫描" : "开始扫描") {
                    appDelegate.model.isScanning ? appDelegate.model.cancelScan() : appDelegate.model.startScan()
                }
                .keyboardShortcut("r", modifiers: .command)
                Divider()
                Button("权限清单") { AppWindow.showMain(section: "权限") }
                Button("启动项审查") { AppWindow.showMain(section: "启动项") }
                Button("扫描缺口") { AppWindow.showMain(section: "缺口") }
            }
            CommandGroup(replacing: .help) {
                Button("雪帮助") { AppWindow.showMain(section: "帮助") }
                    .keyboardShortcut("/", modifiers: [.command, .shift])
            }
        }
    }
}
