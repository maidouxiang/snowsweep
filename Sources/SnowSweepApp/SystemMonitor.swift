import Foundation
import AppKit
import SnowSweepCore

private struct DailyJournalSnapshot: Sendable {
    let summaries: [DailyBatterySummary]
    let latest: DailyMetricSample?
    let error: String?
}

/// 本机指标的界面状态容器。所有耗时读取都放到后台，主线程只接收结果。
@MainActor
final class SystemMonitor: ObservableObject {
    @Published var disk: DiskSnapshot?
    @Published var memory: MemorySnapshot?
    @Published var battery: BatterySnapshot?
    @Published var bluetooth: [BluetoothDeviceRow] = []
    @Published var processes: [ProcessRow] = []
    @Published var hardware: HardwareSnapshot?
    @Published var cpu: CPUSnapshot?
    @Published var network: NetworkSnapshot?
    @Published var thermal: ThermalSnapshot?

    // V0.5.0 日常记录：只在本机保存 JSONL，不参与清理判定。
    @Published var dailySummaries: [DailyBatterySummary] = []
    @Published var dailyFindings: [BatteryGuardFinding] = []
    @Published var dailyLatest: DailyMetricSample?
    @Published var dailyLoaded = false
    @Published var dailyError: String?
    @Published var dailyPruneNotice = ""
    @Published var isRecordingDaily = false
    @Published var dailyRangeDays = 7

    let dailyJournal: DailyJournal

    @Published var isRefreshing = false
    @Published var lastRefresh = Date()
    @Published var loadError: String?

    @Published var slices: [VolumeSlice] = []
    @Published var bigFiles: [LargeFileRecord] = []
    @Published var bigFilesTimedOut = false
    @Published var bigFilesUnreadable: [String] = []
    @Published var isAnalyzing = false
    @Published var analyzeNote = ""

    @Published var duplicateReview: DuplicateReview?
    @Published var duplicateNote = "尚未核对。重复文件功能只读，不会删除或勾选任何文件。"
    @Published var isFindingDuplicates = false

    @Published var apps: [AppEntry] = []
    @Published var isLoadingApps = false
    @Published var appSizes: [String: Int64] = [:]
    @Published var appLastUsed: [String: Date] = [:]
    @Published var isLoadingAppSizes = false
    @Published var isLoadingUsage = false
    @Published var selectedApp: AppEntry?
    @Published var selectedAppSize: Int64?
    @Published var selectedResiduals: [String] = []
    @Published var selectedResidualGroups: [ResidualGroup] = []
    @Published var isUninstalling = false
    @Published var actionMessage = ""

    @Published var auditEvents: [AuditEvent] = []
    @Published var auditVerification: AuditVerification?
    @Published var auditLoaded = false

    private var bluetoothLoadedAt: Date?
    private var bluetoothLastSeen: [String: Date] = {
        guard let stored = UserDefaults.standard.dictionary(forKey: "snow.bluetooth.lastSeen") as? [String: Double] else {
            return [:]
        }
        return stored.compactMapValues { Date(timeIntervalSince1970: $0) }
    }()

    init(dailyJournal: DailyJournal = DailyJournal()) {
        self.dailyJournal = dailyJournal
    }

    private func decorateBluetooth(_ rows: [BluetoothDeviceRow]) -> [BluetoothDeviceRow] {
        var seen = bluetoothLastSeen
        let now = Date()
        for row in rows where row.connected {
            seen[row.name] = now
        }
        bluetoothLastSeen = seen
        UserDefaults.standard.set(seen.mapValues { $0.timeIntervalSince1970 }, forKey: "snow.bluetooth.lastSeen")
        return rows.map { $0.withLastSeen(seen[$0.name]) }
    }

    private func offMain<T: Sendable>(_ work: @escaping @Sendable () -> T) async -> T {
        await Task.detached(priority: .userInitiated, operation: work).value
    }

    /// 菜单栏标题只需要磁盘与电池，不需要把结果写回所有页面状态。
    /// 这样后台定时刷新不会触发一整棵 SwiftUI 视图重算。
    struct MenuBarStatus: Sendable {
        let disk: DiskSnapshot?
        let battery: BatterySnapshot?
    }

    func menuBarStatus() async -> MenuBarStatus {
        async let diskValue = offMain { SystemMetrics.disk() }
        async let batteryValue = offMain { SystemMetrics.battery() }
        return MenuBarStatus(disk: await diskValue, battery: await batteryValue)
    }

    /// 概览只读磁盘、内存、电池与蓝牙；不再顺带起 `ps`、`diskutil`。
    func refreshDashboard() async {
        isRefreshing = true
        defer { isRefreshing = false; lastRefresh = Date() }
        async let diskValue = offMain { SystemMetrics.disk() }
        async let memoryValue = offMain { SystemMetrics.memory() }
        async let batteryValue = offMain { SystemMetrics.battery() }
        async let cpuValue = offMain { SystemMetrics.cpu() }
        disk = await diskValue
        memory = await memoryValue
        battery = await batteryValue
        cpu = await cpuValue
        await refreshBluetoothIfNeeded()
    }

    /// 机身状态页读磁盘、内存、电池、CPU、蓝牙、硬件身份与温度；进程列表只留给内存页。
    /// 页面每 5 秒来一次，但指标最多旧 8 秒，避免把并发读取压成高频轮询。
    func refreshStatusOverview() async {
        if disk != nil, memory != nil, battery != nil, hardware != nil,
           Date().timeIntervalSince(lastRefresh) < 8 {
            await refreshBluetoothIfNeeded()
            return
        }
        isRefreshing = true
        defer { isRefreshing = false; lastRefresh = Date() }
        async let diskValue = offMain { SystemMetrics.disk() }
        async let memoryValue = offMain { SystemMetrics.memory() }
        async let batteryValue = offMain { SystemMetrics.battery() }
        async let cpuValue = offMain { SystemMetrics.cpu() }
        async let hardwareValue = offMain { SystemMetrics.hardware() }
        async let thermalValue = offMain { HIDTemperatureReader.shared.read() }
        async let networkValue = offMain { NetworkMetrics.read() }
        disk = await diskValue
        memory = await memoryValue
        battery = await batteryValue
        cpu = await cpuValue
        hardware = await hardwareValue
        thermal = await thermalValue
        network = await networkValue
        await refreshBluetoothIfNeeded()
    }

    /// 面板是用户主动点开的，只读面板真正显示的硬盘、内存、CPU、网络、设备、温度。
    /// 蓝牙 30 秒内复用，不再为空时一直显示「正在读取」。
    func refreshMenuPanel() async {
        isRefreshing = true
        defer { isRefreshing = false; lastRefresh = Date() }
        async let diskValue = offMain { SystemMetrics.disk() }
        async let memoryValue = offMain { SystemMetrics.memory() }
        async let cpuValue = offMain { SystemMetrics.cpu() }
        async let networkValue = offMain { NetworkMetrics.read() }
        async let thermalValue = offMain { HIDTemperatureReader.shared.read(force: true) }
        disk = await diskValue
        memory = await memoryValue
        cpu = await cpuValue
        network = await networkValue
        thermal = await thermalValue
        await refreshBluetoothIfNeeded()
    }

    private func refreshBluetoothIfNeeded() async {
        guard bluetooth.isEmpty || Date().timeIntervalSince(bluetoothLoadedAt ?? .distantPast) > 30 else { return }
        bluetooth = decorateBluetooth(await offMain { SystemMetrics.bluetoothDevices() })
        bluetoothLoadedAt = Date()
    }

    /// 切换模块后释放非当前页的重快照。只清内存缓存，不删本地记录，也不影响正在跑的扫描。
    func applyPageRetention(page: String, runMode: RunMode) {
        guard !isAnalyzing, !isLoadingApps, !isFindingDuplicates else { return }
        let release = SnapshotRetentionPolicy.groupsToRelease(for: page, runMode: runMode)
        guard !release.isEmpty else { return }
        if release.contains(.space) {
            slices = []
        }
        if release.contains(.storageReview) {
            bigFiles = []
            bigFilesUnreadable = []
            bigFilesTimedOut = false
            duplicateReview = nil
            analyzeNote = ""
            duplicateNote = "尚未核对。重复文件功能只读，不会删除或勾选任何文件。"
        }
        if release.contains(.apps) {
            apps = []
            appSizes = [:]
            appLastUsed = [:]
            selectedApp = nil
            selectedAppSize = nil
            selectedResiduals = []
            selectedResidualGroups = []
            // 列表都释放了，加载标记也要归零；否则回到卸载页会拿到空体积/空最近使用。
            sizesLoaded = false
            usageLoaded = false
        }
        if release.contains(.audit) {
            auditEvents = []
            auditVerification = nil
            auditLoaded = false
        }
        if release.contains(.device) {
            processes = []
            hardware = nil
            cpu = nil
            network = nil
            thermal = nil
            bluetooth = []
            bluetoothLoadedAt = nil
        }
        lastRefresh = .distantPast
    }

    /// 静默态释放所有页面快照。只清内存缓存，不删日常记录、审计或任何文件；
    /// 下次打开菜单栏/主界面会按需重新读取。
    func releaseTransientSnapshots() {
        disk = nil
        memory = nil
        battery = nil
        bluetooth = []
        processes = []
        hardware = nil
        cpu = nil
        network = nil
        thermal = nil

        dailySummaries = []
        dailyFindings = []
        dailyLatest = nil
        dailyLoaded = false
        dailyError = nil
        dailyPruneNotice = ""

        slices = []
        bigFiles = []
        bigFilesTimedOut = false
        bigFilesUnreadable = []
        duplicateReview = nil
        duplicateNote = "尚未核对。重复文件功能只读，不会删除或勾选任何文件。"
        apps = []
        appSizes = [:]
        appLastUsed = [:]
        selectedApp = nil
        selectedAppSize = nil
        selectedResiduals = []
        selectedResidualGroups = []
        sizesLoaded = false
        usageLoaded = false
        auditEvents = []
        auditVerification = nil
        auditLoaded = false

        lastRefresh = .distantPast
    }

    /// 电池页单独刷新：电池字典 + 本机 HID 电池温度一起读。
    /// HID 温度有 30 秒缓存，首次进入读缓存，手动刷新才强制现读。
    func refreshBatteryOnly(forceThermal: Bool = false) async {
        isRefreshing = true
        defer { isRefreshing = false }
        async let batteryValue = offMain { SystemMetrics.battery() }
        async let thermalValue = offMain { HIDTemperatureReader.shared.read(force: forceThermal) }
        battery = await batteryValue
        thermal = await thermalValue
    }

    /// force 用于「重新搜索」：用户主动点击时跳过 30 秒复用，避免按钮看起来没反应。
    func refreshBluetooth(force: Bool = false) async {
        if !force, !bluetooth.isEmpty, Date().timeIntervalSince(bluetoothLoadedAt ?? .distantPast) < 30 {
            return
        }
        isRefreshing = true
        defer { isRefreshing = false }
        bluetooth = decorateBluetooth(await offMain { SystemMetrics.bluetoothDevices() })
        bluetoothLoadedAt = Date()
    }

    func refreshMemoryOnly(limit: Int = 18) async {
        memory = await offMain { SystemMetrics.memory() }
        processes = await offMain { SystemMetrics.processes(limit: limit) }
    }

    // MARK: - 日常记录（V0.5.0）

    var dailyJournalURL: URL { dailyJournal.fileURL }

    /// 启动时按 120 天保留策略裁剪一次；只重写日常记录 JSONL，不碰任何用户文件。
    func pruneDailyJournal(keepingDays: Int = 120) async {
        let journal = dailyJournal
        let now = Date()
        let removed = await Task.detached(priority: .utility) { () -> Int in
            (try? journal.prune(keepingDays: keepingDays, now: now)) ?? 0
        }.value
        if removed > 0 {
            dailyPruneNotice = "已按 120 天保留策略清理 \(removed) 条旧日常记录；没有删除任何用户文件。"
        } else {
            dailyPruneNotice = ""
        }
    }

    func refreshDailyJournal(days: Int = 7) async {
        let limit = max(1, min(30, days))
        dailyRangeDays = limit
        let journal = dailyJournal
        let now = Date()
        let snapshot = await Task.detached(priority: .utility) { () -> DailyJournalSnapshot in
            do {
                let summaries = try journal.summaries(days: limit, now: now)
                let latest = try journal.latestSample()
                return DailyJournalSnapshot(summaries: summaries, latest: latest, error: nil)
            } catch {
                return DailyJournalSnapshot(summaries: [], latest: nil, error: error.localizedDescription)
            }
        }.value
        dailySummaries = snapshot.summaries
        dailyLatest = snapshot.latest
        dailyFindings = BatteryGuardAdvisor.findings(summaries: snapshot.summaries, latest: snapshot.latest, now: now)
        dailyError = snapshot.error
        dailyLoaded = true
    }

    /// 采样由菜单栏常驻进程驱动，每 10 分钟一次；启动时补一条，不补历史空档。
    func recordDailySnapshot(force: Bool = false) async {
        guard !isRecordingDaily else { return }
        let now = Date()
        if !force, let latest = dailyLatest, now.timeIntervalSince(latest.at) < 300 {
            return
        }
        isRecordingDaily = true
        defer { isRecordingDaily = false }

        async let batteryValue = offMain { SystemMetrics.battery() }
        async let diskValue = offMain { SystemMetrics.disk() }
        async let memoryValue = offMain { SystemMetrics.memory() }
        let battery = await batteryValue
        let disk = await diskValue
        let memory = await memoryValue

        guard let battery else {
            dailyError = "读不到电池信息，本次没有记录。台式 Mac 或没有电池的机型不会产生电池历史。"
            return
        }

        let sample = DailyMetricSample(
            at: now,
            chargePercent: battery.chargePercent,
            isCharging: battery.isCharging,
            externalPower: battery.externalPower,
            adapterWatts: battery.adapterWatts,
            cycleCount: battery.cycleCount,
            healthPercent: battery.healthPercent,
            temperatureC: battery.temperatureC,
            thermalPressure: battery.thermalPressure.rawValue,
            lowPowerMode: battery.lowPowerMode,
            diskFreeBytes: disk.freeBytes,
            memoryUsedBytes: memory.usedBytes,
            memoryTotalBytes: memory.totalBytes
        )
        let journal = dailyJournal
        do {
            try await Task.detached(priority: .utility) {
                try journal.append(sample)
            }.value
            dailyError = nil
        } catch {
            dailyError = "写入日常记录失败：\(error.localizedDescription)"
            return
        }
        await refreshDailyJournal(days: dailyRangeDays)
    }

    func dailyReport(days: Int) async -> String? {
        let journal = dailyJournal
        let now = Date()
        do {
            let report = try await Task.detached(priority: .utility) {
                try journal.report(days: days, now: now)
            }.value
            dailyError = nil
            return report
        } catch {
            dailyError = "生成周报失败：\(error.localizedDescription)"
            return nil
        }
    }

    func revealDailyJournal() {
        let url = dailyJournal.fileURL
        if FileManager.default.fileExists(atPath: url.path) {
            NSWorkspace.shared.activateFileViewerSelecting([url])
        } else {
            NSWorkspace.shared.open(url.deletingLastPathComponent())
        }
    }

    /// 空间分析：每个顶层目录一次 du，外加家目录里最大的文件。
    /// 每个 du 有超时，且算完一个就先发布一个，坏目录不会让整页一直空白。
    func analyzeSpace() async {
        guard !isAnalyzing else { return }
        isAnalyzing = true
        analyzeNote = "正在统计各目录体积…"
        bigFilesTimedOut = false
        bigFilesUnreadable = []
        let home = NSHomeDirectory()
        let roots = ["Desktop", "Documents", "Downloads", "Library", "Movies", "Music", "Pictures",
                     ".npm", ".gradle"].map { home + "/" + $0 }
        let existing = roots.filter { FileManager.default.fileExists(atPath: $0) }
        async let bigTask = offMain {
            SystemMetrics.biggestFiles(home: home, minMegabytes: 100, limit: 200, timeout: 10)
        }
        let sizes = await withTaskGroup(of: VolumeSlice.self) { group -> [VolumeSlice] in
            for path in existing {
                // 单项 45 秒：资源库本机约 15–20 秒，20 秒会把大目录误判成读不到。
                group.addTask { SystemMetrics.directorySize(path, timeout: 45) }
            }
            var result: [VolumeSlice] = []
            for await slice in group {
                result.append(slice)
                let visible = result.filter { $0.bytes > 0 || $0.isPartial }
                    .sorted { $0.bytes > $1.bytes }
                if !visible.isEmpty { slices = visible }
            }
            return result.sorted { $0.bytes > $1.bytes }
        }
        slices = sizes.filter { $0.bytes > 0 || $0.isPartial }
        analyzeNote = "正在查找大文件…"
        let bigScan = await bigTask
        bigFiles = bigScan.rows
        bigFilesTimedOut = bigScan.timedOut
        bigFilesUnreadable = bigScan.unreadable
        analyzeNote = "统计完成 · \(slices.count) 个目录 · \(bigFiles.count) 个大文件"
        isAnalyzing = false
    }

    /// 大文件页单独刷新时只做六个个人目录的元数据扫描，不同时跑目录 du。
    /// 每个目录独立超时，慢目录不会把整页结果挤成空列表。
    func refreshBigFiles() async {
        guard !isAnalyzing else { return }
        isAnalyzing = true
        bigFilesTimedOut = false
        bigFilesUnreadable = []
        analyzeNote = "正在并发读取个人目录的文件元数据…"
        let home = NSHomeDirectory()
        let scan = await offMain {
            SystemMetrics.biggestFiles(home: home, minMegabytes: 100, limit: 200, timeout: 12)
        }
        bigFiles = scan.rows
        bigFilesTimedOut = scan.timedOut
        bigFilesUnreadable = scan.unreadable
        analyzeNote = scan.timedOut
            ? "部分目录未在时限内读完，列表是已读到的部分"
            : "找到 \(bigFiles.count) 个 100 MB 以上的文件"
        isAnalyzing = false
    }

    /// 只读核对重复文件：扫描、哈希、分组都在后台；不会生成选择集合。
    func findDuplicates() async {
        guard !isFindingDuplicates else { return }
        isFindingDuplicates = true
        duplicateNote = "正在按体积筛选候选，并核对 SHA-256…"
        let home = NSHomeDirectory()
        let scan = await offMain { SystemMetrics.duplicateFiles(home: home, timeout: 15) }
        duplicateReview = scan.review
        duplicateNote = scan.note
        isFindingDuplicates = false
    }

    private var sizesLoaded = false
    private var usageLoaded = false

    func loadApps() async {
        guard apps.isEmpty, !isLoadingApps else { return }
        isLoadingApps = true
        defer { isLoadingApps = false }
        apps = await offMain { SystemMetrics.applications() }
    }

    func loadAppSizesIfNeeded() async {
        guard !apps.isEmpty, !sizesLoaded, !isLoadingAppSizes else { return }
        isLoadingAppSizes = true
        let paths = apps.map(\.path)
        let sizes = await offMain { SystemMetrics.appSizes(paths) }
        appSizes.merge(sizes) { _, new in new }
        sizesLoaded = true
        isLoadingAppSizes = false
    }

    func loadUsageIfNeeded() async {
        guard !apps.isEmpty, !usageLoaded, !isLoadingUsage else { return }
        isLoadingUsage = true
        let paths = apps.map(\.path)
        appLastUsed = await offMain { SystemMetrics.appLastUsedDates(paths) }
        usageLoaded = true
        isLoadingUsage = false
    }

    func clearSelection() {
        selectedApp = nil
        selectedAppSize = nil
        selectedResiduals = []
        selectedResidualGroups = []
    }

    func select(app: AppEntry) async {
        selectedApp = app
        selectedResiduals = []
        selectedResidualGroups = []
        selectedAppSize = appSizes[app.path]
        let bundleID = app.bundleID
        let path = app.path
        let groups = await offMain { SystemMetrics.residualGroups(for: bundleID) }
        selectedResidualGroups = groups
        selectedResiduals = groups.flatMap(\.paths)
        guard selectedApp?.path == path else { return }
        if selectedAppSize == nil {
            let size = await offMain { SystemMetrics.appSize(path: path, timeout: 5) }
            guard selectedApp?.path == path else { return }
            selectedAppSize = size
            if size > 0 { appSizes[path] = size }
        }
        if appLastUsed[path] == nil {
            if let date = await offMain({ SystemMetrics.lastUsedDate(path: path) }) {
                appLastUsed[path] = date
            }
        }
    }

    /// 卸载应用本身 + 勾选残留，全部进废纸篓，并写审计日志。
    func uninstallSelectedApp(includeResiduals: Bool) async -> String {
        guard let app = selectedApp else { return "没有选中应用" }
        return await uninstall(apps: [app], includeResiduals: includeResiduals)
    }

    /// 多选批量卸载。系统组件、非 /Applications 路径、雪自己一律跳过。
    func uninstall(apps chosen: [AppEntry], includeResiduals: Bool) async -> String {
        guard !chosen.isEmpty else { return "没有选中应用" }
        isUninstalling = true
        defer { isUninstalling = false }

        var moved = 0
        var failed: [String] = []
        var skipped: [String] = []
        var removedPaths: Set<String> = []
        var movedApps: [String] = []
        let log = AuditLog()
        let batchID = "uninstall-\(Int(Date().timeIntervalSince1970))-\(UUID().uuidString.prefix(8))"

        for app in chosen {
            guard app.canUninstall else {
                skipped.append(app.name)
                continue
            }
            var targets = [app.path]
            if includeResiduals {
                let residuals = await offMain { SystemMetrics.residuals(for: app.bundleID) }
                targets.append(contentsOf: residuals)
            }
            var appMoved = false
            for path in targets {
                do {
                    var resulting: NSURL?
                    try FileManager.default.trashItem(at: URL(fileURLWithPath: path), resultingItemURL: &resulting)
                    moved += 1
                    if path == app.path { appMoved = true }
                    _ = try? log.append(action: .moveToTrash, path: path, sizeBytes: 0, success: true,
                                         detail: "卸载 \(app.name)", batchID: batchID)
                } catch {
                    failed.append((path as NSString).lastPathComponent)
                    _ = try? log.append(action: .moveToTrashFailed, path: path, sizeBytes: 0, success: false,
                                         detail: error.localizedDescription, batchID: batchID)
                }
            }
            if appMoved {
                removedPaths.insert(app.path)
                movedApps.append(app.name)
            }
        }

        if !removedPaths.isEmpty {
            apps.removeAll { removedPaths.contains($0.path) }
            for path in removedPaths {
                appSizes[path] = nil
                appLastUsed[path] = nil
            }
        }
        selectedApp = nil
        selectedAppSize = nil
        selectedResiduals = []
        selectedResidualGroups = []

        if failed.isEmpty {
            if skipped.isEmpty {
                actionMessage = movedApps.isEmpty
                    ? "没有可卸载的应用"
                    : "已把 \(moved) 项移入废纸篓（\(movedApps.count) 个应用），可随时恢复"
            } else {
                actionMessage = "已卸载 \(movedApps.count) 个；跳过系统/受保护应用：\(skipped.prefix(3).joined(separator: "、"))"
            }
        } else {
            actionMessage = "已移动 \(moved) 项，失败 \(failed.count) 项（\(failed.first ?? "")）"
        }
        await refreshAudit()
        return actionMessage
    }

    func refreshAudit() async {
        let result = await offMain { SystemMetrics.audit() }
        auditEvents = Array(result.events.reversed())
        auditVerification = result.verification
        auditLoaded = true
    }

    func openTrash() {
        NSWorkspace.shared.open(URL(fileURLWithPath: NSHomeDirectory() + "/.Trash"))
    }

    func exportAuditCopy() -> URL? {
        let source = AuditLog().fileURL
        guard FileManager.default.fileExists(atPath: source.path) else { return nil }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "雪-操作历史-\(Self.stamp()).jsonl"
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let destination = panel.url else { return nil }
        try? FileManager.default.copyItem(at: source, to: destination)
        return destination
    }

    private static func stamp() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmm"
        return formatter.string(from: Date())
    }
}
