import Foundation
import AppKit
import SwiftUI
import ServiceManagement
import Darwin
import SnowSweepCore

extension Notification.Name {
    static let snowMenuBarPreferencesChanged = Notification.Name("SnowSweepMenuBarPreferencesChanged")
    static let snowRunModeChanged = Notification.Name("SnowSweepRunModeChanged")
    static let snowShowExpert = Notification.Name("SnowSweepShowExpert")
    static let snowShowLanding = Notification.Name("SnowSweepShowLanding")
    static let snowOpenNoviceReport = Notification.Name("SnowSweepOpenNoviceReport")
}

/// 供 @Sendable 进度回调使用的线程安全容器，避免跨并发域直接捕获 ViewModel。
public final class ScanProgressState: @unchecked Sendable {
    private let lock = NSLock()
    private var scanned = 0
    private var kept = 0
    private var currentPath = ""
    private var recentPaths: [String] = []
    private var cancelRequested = false

    public func update(_ progress: ScanProgress) -> Bool {
        lock.lock(); defer { lock.unlock() }
        scanned = progress.scanned
        kept = progress.kept
        currentPath = progress.currentPath
        if !currentPath.isEmpty, recentPaths.last != currentPath {
            recentPaths.append(currentPath)
            if recentPaths.count > 220 {
                recentPaths.removeFirst(recentPaths.count - 220)
            }
        }
        return !cancelRequested
    }

    public func requestCancel() {
        lock.lock(); defer { lock.unlock() }
        cancelRequested = true
    }

    public func reset() {
        lock.lock(); defer { lock.unlock() }
        scanned = 0; kept = 0; currentPath = ""; recentPaths = []; cancelRequested = false
    }

    public var snapshot: (scanned: Int, kept: Int, path: String, paths: [String]) {
        lock.lock(); defer { lock.unlock() }
        return (scanned, kept, currentPath, recentPaths)
    }
}

public enum AppError: LocalizedError, Identifiable {
    case scan(String)
    case settings(String)
    case permission(String)
    case export(String)

    public var id: String { String(describing: self) }
    public var errorDescription: String? {
        switch self {
        case let .scan(text): return "扫描失败：\(text)"
        case let .settings(text): return "设置未保存：\(text)"
        case let .permission(text): return "权限不足：\(text)"
        case let .export(text): return "报告导出失败：\(text)"
        }
    }
}

@MainActor
public final class ScanViewModel: ObservableObject {
    @Published public var report: ScanReport?
    @Published public var isScanning = false
    @Published public var progressFraction: Double = 0
    @Published public var currentPath = ""
    @Published public var recentPaths: [String] = []
    @Published public var errorMessage: AppError?
    /// 扫描结束后在主界面保留一次的完成反馈；开始下一轮或手动关闭后清空。
    @Published public var scanFinishedMessage: String?
    @Published public var aiMode: AIMode = .off {
        didSet { UserDefaults.standard.set(aiMode.rawValue, forKey: "snow.aiMode") }
    }
    /// Dock 图标默认开启：菜单栏常驻与普通 App 行为可以并存。
    /// accessory 模式下系统菜单栏只剩极简几项，容易让人以为"菜单栏坏了"。
    @Published public var showDockIcon: Bool {
        didSet {
            UserDefaults.standard.set(showDockIcon, forKey: "snow.showDockIcon")
            applyDockVisibility()
        }
    }
    /// 显示单位只影响格式化，不改变任何字节数值。
    @Published public var displayUnit: DisplayUnit = .auto {
        didSet { UserDefaults.standard.set(displayUnit.rawValue, forKey: "snow.displayUnit") }
    }
    /// V0.8.0：英文原名默认显示；关闭后界面只留中文，原始路径折叠到证据里的「查看原始路径」。
    @Published public var showEnglishOriginal: Bool = true {
        didSet { UserDefaults.standard.set(showEnglishOriginal, forKey: "snow.showEnglishOriginal") }
    }
    /// 菜单栏模块开关只影响面板显示与状态圆点，不影响扫描/判定/清理。
    @Published public var menuBarPreferences: MenuBarPreferences = .default {
        didSet {
            menuBarPreferences.save()
            NotificationCenter.default.post(name: .snowMenuBarPreferencesChanged, object: nil)
        }
    }
    /// 日常记录只在本机写入电池/磁盘/内存快照，不参与清理判定。
    @Published public var dailyJournalEnabled: Bool {
        didSet {
            UserDefaults.standard.set(dailyJournalEnabled, forKey: "snow.dailyJournalEnabled")
            notifyRunModeChanged()
        }
    }
    /// V0.6.0：三档运行模式。默认静默，偏好只影响刷新节奏，不影响判定。
    @Published public var preferredRunMode: RunMode = .silent {
        didSet {
            UserDefaults.standard.set(preferredRunMode.rawValue, forKey: "snow.runMode")
            notifyRunModeChanged()
        }
    }
    @Published public var isScanBoostActive = false
    /// V0.9.18：主窗口关闭后自动收进菜单栏；此状态只影响资源节奏和 Dock 可见性。
    @Published public var isMainWindowClosed = false
    /// V0.9.8：三态运行时只用于资源调度和菜单栏显示，不改变任何清理判定。
    @Published public var runtimeMode: RuntimeMode = .silent
    @Published public var runtimeReason = "启动，只保留菜单栏"
    @Published public var batteryPercentForMode: Int?
    @Published public var lowPowerModeForMode = false

    public var runModeStatus: RunModeStatus {
        RunModePolicy.status(
            preferred: preferredRunMode,
            batteryPercent: batteryPercentForMode,
            lowPowerMode: lowPowerModeForMode,
            isScanning: isScanBoostActive,
            mainWindowClosed: isMainWindowClosed
        )
    }

    public var effectiveRunMode: RunMode { runModeStatus.mode }

    /// 电量与低电量模式由常驻刷新带进来。只有实际模式变化时才通知重排定时器。
    public func updatePowerState(percent: Int?, lowPowerMode: Bool) {
        let before = effectiveRunMode
        if batteryPercentForMode != percent { batteryPercentForMode = percent }
        if lowPowerModeForMode != lowPowerMode { lowPowerModeForMode = lowPowerMode }
        if before != effectiveRunMode { notifyRunModeChanged() }
    }

    private func notifyRunModeChanged() {
        NotificationCenter.default.post(name: .snowRunModeChanged, object: nil)
    }
    @Published public var customProtections: [String] = []
    @Published public var hudTick = 0
    @Published public var lastAction = "尚未执行任何清理"
    /// 权限与启动项是只读观察，结果单独存放，绝不参与清理决策。
    @Published public var permissionSnapshot: PermissionSnapshot?
    @Published public var startupSnapshot: StartupSnapshot?
    @Published public var directoryAccess: DirectoryAccessSnapshot?
    @Published public var builtInProtectionPaths: [String] = []
    @Published public var isInspecting = false
    /// 启动时探测个人目录；读不到就把授权入口放在所有页面顶部。
    @Published public var unreadableHomeFolders: [String] = []
    @Published public var accessBannerDismissed = false
    private var isCheckingHomeAccess = false

    // MARK: - 扫描范围与 FDA 授权范围可视化（V0.3.0）
    /// 默认只扫描用户目录；扩大范围由用户在设置里主动选择，且不改变任何删除判定。
    @Published public var scanScope: ScanScope = .userOnly {
        didSet { UserDefaults.standard.set(scanScope.rawValue, forKey: "snow.scan.scope") }
    }
    /// 由只读权限快照推导，UI 只负责显示，不据此自动扩大扫描范围。
    public var fdaScopeStatus: FDAScopeStatus {
        let status = FDAScopeInspector.status(from: permissionSnapshot)
        // TCC.db 被 SIP / root 独占时，有授权的 App 也会读不到数据库；
        // 此时改用受保护目录的行为探测，避免把“数据库读不到”误报成“没有授权”。
        if status == .blocked && FullDiskAccessProbe.isLikelyGranted() {
            return .inferredGrant
        }
        return status
    }

    // MARK: - 清理闭环（V0.2.0）
    /// dry-run 预览条目：点「预览」后生成，点「确认」才真正移废纸篓。
    @Published public var cleanupPreview: [CleanupSelection.Entry] = []
    @Published public var cleanupSummaryText = ""
    @Published public var isCleaning = false
    /// 单批次规模闸门：超限时必须显式勾选确认，否则确认清理会被代码拒绝。
    @Published public var batchGate: BatchGateDecision = .allowed
    @Published public var batchAcknowledged = false

    // MARK: - 恢复清单（V0.3.0）：只定位，不自动移回
    @Published public var rollbackCandidates: [RollbackCandidate] = []
    @Published public var rollbackError: String?

    /// 离开恢复页后释放候选清单：只清 UI 快照，不动审计、废纸篓或任何文件。
    public func releaseRollbackCandidates() {
        rollbackTask?.cancel()
        rollbackTask = nil
        rollbackCandidates = []
        rollbackError = nil
    }

    public let progressState = ScanProgressState()
    private var scanTask: Task<Void, Never>?
    private var remoteScanner: RemoteScannerClient?
    private var scanBoostEndTask: Task<Void, Never>?
    private var hudTask: Task<Void, Never>?
    /// HUD 只在扫描或用户打开主界面时运行；静默态不保留 5 秒循环。
    private var isHUDEnabled = false
    private var inspectionTask: Task<Void, Never>?
    private var rollbackTask: Task<Void, Never>?
    private var cleanupTask: Task<Void, Never>?
    /// 扫描时加载的规则引擎，清理时用于 protectionCheck（保护清单判定）。
    private var activeEngine: RuleEngine?
    /// 手动清理不一定先跑全盘扫描；这里按当前内置规则 + 已启用用户规则临时加载。
    /// 每次读取注册表，用户启用/停用后无需重启 App。
    private var manualGuardEngine: RuleEngine? {
        let custom = (try? protectionStore.load()) ?? []
        return try? userRuleRegistry.loadEngine(
            builtinURL: ruleURL,
            extraProtectedPaths: custom
        )
    }

    /// 给大文件、重复、族谱和空间分析的手动废纸篓入口注入保护路径判定。
    /// 用户刚启用保护规则时，旧扫描引擎不能继续兜底；这里每次取最新注册表。
    public var manualProtectionCheck: (@Sendable (String) -> Bool)? {
        guard let engine = manualGuardEngine else { return nil }
        return { path in engine.isProtected(path) }
    }

    /// 一次预览到确认共用一个批次号，历史页据此把同一批清理聚合为一条。
    private var cleanupBatchID: String?

    private let ruleURL: URL
    private let protectionStore: ProtectionListStore
    private let glossary: Glossary?

    /// 规则页与试扫共用同一个注册表。
    public let userRuleRegistry: UserRuleRegistry
    /// 内置规则路径，供导入校验与规则页读取。
    public var builtinRulesURL: URL { ruleURL }

    public init() {
        let candidates = [
            // 已安装的 App：规则随 bundle 打包，放第一位，避免依赖源码目录。
            Bundle.main.url(forResource: "rules", withExtension: "json", subdirectory: "Rules"),
            // 开发调试：源码工程目录。
            URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
                .appendingPathComponent("Rules/rules.json"),
            URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
                .appendingPathComponent("Rules/rules.json")
        ].compactMap { $0 }
        self.ruleURL = candidates.first { FileManager.default.fileExists(atPath: $0.path) } ?? candidates[0]
        self.protectionStore = ProtectionListStore()
        self.userRuleRegistry = UserRuleRegistry()
        self.glossary = try? Glossary.loadBundled()
        self.customProtections = (try? protectionStore.load()) ?? []
        self.showDockIcon = (UserDefaults.standard.object(forKey: "snow.showDockIcon") as? Bool) ?? true
        self.displayUnit = DisplayUnit(rawValue: UserDefaults.standard.string(forKey: "snow.displayUnit") ?? "") ?? .auto
        self.showEnglishOriginal = (UserDefaults.standard.object(forKey: "snow.showEnglishOriginal") as? Bool) ?? true
        self.aiMode = AIMode(rawValue: UserDefaults.standard.string(forKey: "snow.aiMode") ?? "") ?? .off
        self.menuBarPreferences = MenuBarPreferences.load()
        self.dailyJournalEnabled = (UserDefaults.standard.object(forKey: "snow.dailyJournalEnabled") as? Bool) ?? true
        self.preferredRunMode = RunMode(rawValue: UserDefaults.standard.string(forKey: "snow.runMode") ?? "") ?? .silent
        if let saved = UserDefaults.standard.string(forKey: "snow.scan.scope"),
           let scope = ScanScope(rawValue: saved) {
            self.scanScope = scope
        }
        self.builtInProtectionPaths = Self.loadBuiltInProtectionPaths(ruleURL: self.ruleURL)
        // 静默态不启动 HUD；扫描或打开主界面时再按需启动。
    }

    // MARK: - V0.9.8 三态运行时

    public func setRuntimeMode(_ mode: RuntimeMode, reason: String) {
        runtimeMode = mode
        runtimeReason = reason
    }

    /// 扫描态：只启动轻量 HUD，不加载模型。
    public func prepareForScan() {
        isHUDEnabled = true
        startHUDIfNeeded()
    }

    /// 智能清理态：不跑扫描进度循环；模型会话由 AssistantModelBridge 单次创建并释放。
    public func prepareForAssist() {
        isHUDEnabled = false
        hudTask?.cancel()
        hudTask = nil
    }

    /// 静默态：取消后台循环，释放报告、预览、快照和可回收内存。
    /// 只清内存，不删除文件、不碰审计、不改变任何保护路径。
    public func enterSilentMode() {
        if isScanning { cancelScan() }
        if isCleaning {
            cleanupTask?.cancel()
            isCleaning = false
        }
        isHUDEnabled = false
        hudTask?.cancel()
        hudTask = nil
        releaseTransientMemory(includeReport: true)
    }

    /// 释放非必要驻留。includeReport=true 时连扫描报告一起放掉；
    /// 关闭主窗口后再次打开需要重新扫描，这是静默态低内存的代价。
    public func releaseTransientMemory(includeReport: Bool) {
        guard !isScanning, !isCleaning else { return }
        cleanupPreview = []
        cleanupSummaryText = ""
        batchGate = .allowed
        batchAcknowledged = false
        cleanupBatchID = nil
        rollbackTask?.cancel()
        rollbackCandidates = []
        rollbackError = nil
        permissionSnapshot = nil
        startupSnapshot = nil
        directoryAccess = nil
        scanFinishedMessage = nil
        activeEngine = nil
        if includeReport {
            report = nil
            progressFraction = 0
            currentPath = ""
            recentPaths = []
            errorMessage = nil
        }
        lastRefreshMemoryRelief()
    }

    /// 向系统归还一批可回收页；不保证 RSS 立刻下降，但能减少后续峰值。
    private func lastRefreshMemoryRelief() {
        malloc_zone_pressure_relief(nil, 0)
    }

    // MARK: - 扫描：后台异步 + 用户取消 + 进度回调

    public func startScan() {
        guard RuntimeCenter.shared.enterScan(reason: "开始扫描：只读规则根与元数据") else { return }
        // 并发按开始前的用户模式/低电量状态取一次；扫描中的临时性能不把静默扫描抬成全核。
        let scanConcurrency = effectiveRunMode.scanConcurrency()
        scanTask?.cancel()
        beginScanBoost()
        progressState.reset()
        isScanning = true
        progressFraction = 0
        recentPaths = []
        errorMessage = nil
        scanFinishedMessage = nil

        let ruleURL = self.ruleURL
        let customProtections = (try? protectionStore.load()) ?? []
        let userRuleRegistry = self.userRuleRegistry
        let scope = self.scanScope
        let progressState = self.progressState

        let remote = RemoteScannerClient()
        remoteScanner = remote

        // 扫描必须离开主 actor：真实家目录的目录聚合是同步循环，放在主线程会冻结窗口。
        scanTask = Task.detached(priority: .userInitiated) { [weak self] in
            do {
                let engine = try userRuleRegistry.loadEngine(
                    builtinURL: ruleURL,
                    extraProtectedPaths: customProtections
                )
                let request = ScannerXPCRequest(
                    ruleBook: engine.ruleBook,
                    scope: scope,
                    home: NSHomeDirectory(),
                    maxConcurrentRoots: scanConcurrency,
                    extraProtectedPaths: customProtections,
                    overallTimeoutSeconds: 60
                )

                // 首选进程外扫描：扫描峰值、目录体积统计和文件遍历都在 ScannerService 里。
                var payload = ScanPayload(source: "xpc", items: [], gaps: [])
                var summary = ScanStreamSummary(scanned: 0, kept: 0)
                var usedXPC = false
                var usedMainProcessRetry = false
                do {
                    let response = try remote.scan(request: request, onProgress: { progress in
                        _ = progressState.update(
                            ScanProgress(
                                scanned: progress.scanned,
                                kept: progress.kept,
                                currentPath: progress.currentPath
                            )
                        )
                    })
                    if let failure = response.failure {
                        // 服务没有真正完成扫描时，不能用半截结果；交给下面的主进程回退。
                        throw RemoteScannerError.serviceUnavailable(failure)
                    }
                    // 自签名 helper 在本机拿不到 TCC 身份：系统设置里即使勾选，也会被
                    // AMFI 判成未知签名。先确认主 App 自己能读同一个位置，再回主进程复扫，
                    // 这样不会把 SIP 真正禁止的目录误当成授权问题。
                    if let denied = response.gaps.first(where: {
                        $0.kind == .permissionDenied || $0.kind == .tccDenied
                    }) {
                        throw MainProcessPermissionRetry(path: denied.path)
                    }
                    summary = response.summary
                    payload = ScanPayload(
                        source: "xpc",
                        items: response.items,
                        gaps: response.gaps,
                        truncated: response.summary.truncated
                    )
                    usedXPC = true
                } catch {
                    // 服务不可用、签名不匹配或连接中断时才回退；正常路径不会走这里。
                    usedMainProcessRetry = error is MainProcessPermissionRetry
                    let fallback = RuleRootScanner(engine: engine, maxConcurrentRoots: scanConcurrency, overallTimeout: 60)
                    let fallbackCollector = ScanPayloadCollector(maxItems: 10_000)
                    summary = try fallback.streamAnalyze(
                        scope: scope,
                        onProgress: { progress in progressState.update(progress) },
                        sink: fallbackCollector
                    )
                    payload = fallbackCollector.payload
                    if !usedMainProcessRetry {
                        payload = ScanPayload(
                            source: payload.source,
                            items: payload.items,
                            gaps: payload.gaps + [
                                ScanGap(
                                    kind: .transientIO,
                                    path: "扫描服务",
                                    detail: "进程外扫描不可用，已回退主进程：\(error.localizedDescription)",
                                    severity: .warning, scope: .directory
                                )
                            ],
                            truncated: payload.truncated
                        )
                    }
                }
                guard !Task.isCancelled else { return }

                let verdicts = payload.items.map { engine.verdict(for: $0) }
                // 全盘扫描没有 FDA 时，系统目录会被静默跳过；这属于全盘级缺口，
                // 必须让报告锁定清理，而不是把 104 个局部警告当成“还能整机清理”。
                var gaps = payload.gaps
                if scope == .wholeDisk && !Self.hasFullDiskAccessHint() {
                    gaps.insert(
                        ScanGap(
                            kind: .tccDenied,
                            path: "整个磁盘",
                            detail: "没有完全磁盘访问权限，系统目录会被跳过；到「权限清单」查看授权说明。"
                        ),
                        at: 0
                    )
                }

                await MainActor.run {
                    guard let self else { return }
                    self.remoteScanner = nil
                    self.activeEngine = engine
                    self.builtInProtectionPaths = engine.ruleBook.protectedPaths
                    let status = Self.diskTotals()
                    let hasCritical = gaps.contains { $0.severity == .critical }
                    let report = ScanReport(
                        scanStatus: summary.cancelled ? "cancelled" :
                            (hasCritical ? "partial" : "complete"),
                        totalBytes: status.total,
                        verdicts: verdicts,
                        scanGaps: gaps
                    )
                    self.report = report
                    self.isScanning = false
                    // 收尾把真实路径留住一拍，首屏的路径流不会因为扫描太快而闪空。
                    self.recentPaths = self.progressState.snapshot.paths
                    self.stopHUDForIdle()
                    self.endScanBoost(after: 60)
                    RuntimeCenter.shared.noteScanFinished()
                    self.progressFraction = 1
                    self.currentPath = ""
                    // 新报告作废上一轮清理预览，避免拿过期快照执行删除。
                    self.cleanupPreview = []
                    self.cleanupSummaryText = ""
                    self.batchGate = .allowed
                    self.batchAcknowledged = false
                    // 每次扫描成功都留一张只读空间快照；用户不必记得手动点“记录快照”。
                    if !summary.cancelled {
                        Task { await SpaceSnapshotAutoCapture.captureAfterScan() }
                    }
                    if report.canClean {
                        let note = gaps.isEmpty ? "" : "（\(gaps.count) 个位置已跳过）"
                        let channel = usedMainProcessRetry ? "主进程权限复扫"
                            : (usedXPC ? "进程外扫描" : "主进程回退扫描")
                        self.lastAction = "扫描完成，可预览清理\(note)"
                        self.scanFinishedMessage = "扫描完成（\(channel)）：共核对 \(verdicts.count) 项，可到「清理」预览。\(note)"
                    } else {
                        self.lastAction = "扫描不完整，清理已锁定"
                        self.scanFinishedMessage = "扫描结束，但报告不完整，清理已锁定。请到「扫描缺口」查看原因。"
                    }
                }
            } catch {
                await MainActor.run {
                    self?.remoteScanner = nil
                    self?.isScanning = false
                    self?.stopHUDForIdle()
                    self?.endScanBoost(after: 60)
                    self?.errorMessage = .scan("\(error)")
                    RuntimeCenter.shared.noteScanFinished()
                }
            }
        }
    }

    public func cancelScan() {
        progressState.requestCancel()
        remoteScanner?.cancel()
        scanTask?.cancel()
        isScanning = false
        stopHUDForIdle()
        endScanBoost(after: 60)
        lastAction = "已取消扫描"
        scanFinishedMessage = "扫描已取消，没有执行任何清理。"
        RuntimeCenter.shared.noteScanFinished()
    }

    /// 扫描期间临时切性能；结束后保留 60 秒，再按偏好与电量回退。
    private func beginScanBoost() {
        scanBoostEndTask?.cancel()
        scanBoostEndTask = nil
        guard !isScanBoostActive else { return }
        isScanBoostActive = true
        notifyRunModeChanged()
    }

    private func endScanBoost(after seconds: TimeInterval) {
        scanBoostEndTask?.cancel()
        let delay = UInt64(max(0, seconds) * 1_000_000_000)
        scanBoostEndTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: delay)
            guard !Task.isCancelled else { return }
            guard let self else { return }
            self.isScanBoostActive = false
            self.scanBoostEndTask = nil
            self.notifyRunModeChanged()
        }
    }

    // MARK: - 清理闭环（V0.2.0）：dry-run 预览 → 用户确认 → 移到废纸篓

    /// 第一步：dry-run 预览。只算判定、不碰文件系统。
    /// 即使 UI 误传了 protected/review 路径，CleanupSelection 也会过滤掉。
    public func prepareCleanup(paths: Set<String>, allowReview: Bool = false) {
        guard let report, report.canClean else {
            lastAction = "报告不完整，无法生成清理预览"
            return
        }
        // V0.8.1：扫描能拿到路径，不代表当前进程能安全操作。
        // 系统保护目录（如 HomeKit 缓存）先在这里跳过，不再等 trashItem 失败才停整批。
        let accessible = Set(paths.filter { CleanupSelection.Readiness.isAccessible($0) })
        let blockedCount = paths.count - accessible.count
        let entries = CleanupSelection.entries(
            from: report,
            selectedPaths: accessible,
            allowReview: allowReview
        )
        let summary = CleanupSelection.summary(entries)
        cleanupPreview = entries
        batchGate = BatchSizeGate.check(entries)
        batchAcknowledged = false
        let batchID = makeBatchID("clean")
        cleanupBatchID = batchID
        if !entries.isEmpty {
            _ = try? AuditLog().append(
                action: .dryRun,
                path: "批次共 \(entries.count) 项",
                sizeBytes: summary.bytes,
                success: true,
                detail: "预览生成，无文件操作",
                batchID: batchID
            )
        }
        let bytes = ByteCountFormatter.string(fromByteCount: summary.bytes, countStyle: .file)
        cleanupSummaryText = entries.isEmpty
            ? "没有可安全清理的条目"
            : "预览 \(summary.count) 项，预计释放 \(bytes)；尚未删除任何文件"
        if blockedCount > 0 {
            cleanupSummaryText += "；\(blockedCount) 项受系统保护或当前无权限，已跳过"
        }
        lastAction = cleanupSummaryText
    }

    /// 取消预览时必须一并作废规模闸门的确认状态，否则下一次预览可能继承上一次的勾选。
    public func cancelCleanupPreview() {
        cleanupPreview = []
        cleanupSummaryText = ""
        batchGate = .allowed
        batchAcknowledged = false
        cleanupBatchID = nil
        lastAction = "已取消预览，未删除任何文件"
    }

    /// 全部安全项的预览（UI「全选安全项」用）。
    public func prepareAllSafeCleanup() {
        guard let report, report.canClean else {
            lastAction = "报告不完整，无法生成清理预览"
            return
        }
        let safePaths = Set(report.verdicts.filter(\.defaultSelected).map(\.item.path))
        let accessible = Set(safePaths.filter { CleanupSelection.Readiness.isAccessible($0) })
        let blockedCount = safePaths.count - accessible.count
        let entries = CleanupSelection.entries(
            from: report,
            selectedPaths: accessible,
            allowReview: false
        )
        let summary = CleanupSelection.summary(entries)
        cleanupPreview = entries
        batchGate = BatchSizeGate.check(entries)
        batchAcknowledged = false
        let batchID = makeBatchID("clean")
        cleanupBatchID = batchID
        if !entries.isEmpty {
            _ = try? AuditLog().append(
                action: .dryRun,
                path: "批次共 \(entries.count) 项",
                sizeBytes: summary.bytes,
                success: true,
                detail: "预览生成，无文件操作",
                batchID: batchID
            )
        }
        let bytes = ByteCountFormatter.string(fromByteCount: summary.bytes, countStyle: .file)
        cleanupSummaryText = entries.isEmpty
            ? "没有可安全清理的条目"
            : "预览 \(summary.count) 项，预计释放 \(bytes)；尚未删除任何文件"
        if blockedCount > 0 {
            cleanupSummaryText += "；\(blockedCount) 项受系统保护或当前无权限，已跳过"
        }
        lastAction = cleanupSummaryText
    }

    /// 第二步：对预览条目执行真实清理——只移废纸篓，绝不永久删除。
    /// 删除前逐条复核身份与保护清单（coordinator 内 revalidate），任一失败即停。
    public func confirmCleanup() {
        guard !isCleaning, !cleanupPreview.isEmpty else { return }
        guard let report, report.canClean else {
            lastAction = "报告已失效，取消清理，请重新扫描"
            cleanupPreview = []
            return
        }
        // 规模闸门硬校验：超限且未显式确认时，直接拒绝，绝不进入删除层。
        guard batchGate.allows(acknowledged: batchAcknowledged) else {
            lastAction = "这批清理超过规模上限，请先勾选确认；未删除任何文件"
            return
        }
        isCleaning = true
        lastAction = "正在清理…"
        let entries = cleanupPreview
        // 删除前再读一次注册表：用户刚启用的保护规则必须立即生效，不能沿用旧扫描引擎。
        guard let engine = manualGuardEngine else {
            isCleaning = false
            lastAction = "规则库加载失败，取消清理；未删除任何文件"
            cleanupPreview = []
            return
        }
        let batchID = cleanupBatchID ?? makeBatchID("clean")
        cleanupBatchID = batchID

        cleanupTask?.cancel()
        cleanupTask = Task { [weak self] in
            guard let self else { return }
            // 生产环境：严格身份复核 + 保护清单由刚加载的规则引擎判定。
            let protectionCheck: (@Sendable (String) -> Bool)? = { path in
                engine.isProtected(path)
            }
            let coordinator = DeletionCoordinator(
                policy: DeletionPolicy(),  // 永久删除保持关闭
                protectionCheck: protectionCheck,
                requireIdentity: true
            )
            var moved = 0
            var failure: String?
            for entry in entries {
                if Task.isCancelled { break }
                let item = entry.verdict.item
                do {
                    _ = try coordinator.moveToTrash(
                        item, ruleID: entry.ruleID, report: report,
                        resolution: .stop, batchID: batchID
                    )
                    moved += 1
                } catch {
                    failure = (item.path as NSString).lastPathComponent + "：\(error)"
                    break  // 失败即停，绝不继续，更不回退永久删除
                }
            }
            let resultMoved = moved
            let resultFailure = failure
            await MainActor.run {
                self.isCleaning = false
                self.cleanupPreview = []
                self.cleanupSummaryText = ""
                self.batchGate = .allowed
                self.batchAcknowledged = false
                self.cleanupBatchID = nil
                if let resultFailure {
                    self.lastAction = "已将 \(resultMoved) 项移到废纸篓；随后失败并停止：\(resultFailure)"
                } else if Task.isCancelled {
                    self.lastAction = "已取消，本次将 \(resultMoved) 项移到废纸篓"
                } else {
                    self.lastAction = "完成：已将 \(resultMoved) 项移到废纸篓（可随时恢复）"
                }
            }
        }
    }

    // MARK: - 恢复清单（V0.3.0）

    /// 从审计日志生成可找回清单。链校验失败时只显示错误，不显示任何候选。
    public func refreshRollback() {
        rollbackTask?.cancel()
        // 审计日志可能很大，读取和链校验都放到后台，避免切页时卡主线程。
        rollbackTask = Task.detached(priority: .userInitiated) { [weak self] in
            do {
                let candidates = try AuditRollback().candidates()
                guard !Task.isCancelled else { return }
                await MainActor.run {
                    self?.rollbackCandidates = candidates
                    self?.rollbackError = nil
                }
            } catch {
                guard !Task.isCancelled else { return }
                await MainActor.run {
                    self?.rollbackCandidates = []
                    self?.rollbackError = error.localizedDescription
                }
            }
        }
    }

    /// 恢复项的中文标识：优先用词典映射原始路径，没有词条才退回文件名。
    public func rollbackChineseName(for candidate: RollbackCandidate) -> String {
        let label = glossary?.chineseLabel(for: candidate.originalPath) ?? "其他项目"
        return label == "其他项目" ? candidate.displayName : label
    }

    /// 在 Finder 中定位：废纸篓里优先选中重命名后的条目，备份项选中备份目录。
    /// 绝不自动移回原路径——那里可能已经有同名的新文件。
    public func revealRollback(_ candidate: RollbackCandidate) {
        let helper = AuditRollback()
        let targets: [URL]
        switch candidate.destination {
        case .trash:
            if let exact = helper.exactLocation(for: candidate) {
                targets = [exact]
            } else {
                let matches = helper.trashMatches(for: candidate)
                targets = matches.isEmpty ? [TrashLocations.directory()] : matches
            }
        case .backup:
            if let exact = helper.exactLocation(for: candidate) {
                targets = [exact]
            } else {
                targets = helper.backupDestination(for: candidate).map { [$0] } ?? []
            }
        }
        if targets.isEmpty {
            rollbackError = "这份备份的位置已经不存在了，请按原始路径自行查找。"
            return
        }
        NSWorkspace.shared.activateFileViewerSelecting(targets)
    }

    /// 复制原始路径，方便用户自己去 Finder 里"前往文件夹"核对。
    public func copyRollbackPath(_ candidate: RollbackCandidate) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(candidate.originalPath, forType: .string)
    }

    /// 扫描中 300 毫秒一次降采样，够路径流滚动，又不把静默态拖成常驻循环。
    private func startHUDIfNeeded() {
        guard isHUDEnabled, hudTask == nil else { return }
        hudTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                try? await Task.sleep(for: .milliseconds(300))
                guard !Task.isCancelled else { return }
                await MainActor.run {
                    guard self.isHUDEnabled else { return }
                    self.hudTick += 1
                    let snapshot = self.progressState.snapshot
                    self.progressFraction = snapshot.scanned == 0
                        ? 0
                        : Double(snapshot.kept) / Double(max(1, snapshot.scanned))
                    let fullPath = snapshot.path
                    self.currentPath = fullPath.isEmpty ? "" : (fullPath as NSString).lastPathComponent
                    self.recentPaths = snapshot.paths
                }
            }
        }
    }

    private func stopHUDForIdle() {
        isHUDEnabled = false
        hudTask?.cancel()
        hudTask = nil
    }

    // MARK: - 设置

    /// 设置页「英文字典对照」用：只读暴露内置词条。
    public var glossaryEntries: [GlossaryEntry] { glossary?.entries ?? [] }

    /// 界面主行统一显示中文名；没有词条时才退回英文文件名，并明确标注。
    public func chineseLabel(for path: String) -> String {
        guard let glossary else { return (path as NSString).lastPathComponent }
        let label = glossary.chineseLabel(for: path)
        if label == "其他项目" { return (path as NSString).lastPathComponent }
        return label
    }

    public func applyDockVisibility() {
        // 主窗口关闭时即使偏好允许 Dock 图标，也先收成 accessory；重开再恢复。
        let showsDock = DockVisibilityPolicy.shouldShowDockIcon(
            preference: showDockIcon,
            mainWindowClosed: isMainWindowClosed
        )
        NSApp.setActivationPolicy(showsDock ? .regular : .accessory)
    }

    /// 主窗口出现/关闭时更新 Dock 与运行节奏。
    /// 只改当前会话的资源状态，不覆盖用户存在本机的运行模式偏好。
    public func setMainWindowClosed(_ closed: Bool) {
        guard isMainWindowClosed != closed else {
            applyDockVisibility()
            return
        }
        isMainWindowClosed = closed
        applyDockVisibility()
        notifyRunModeChanged()
    }

    // MARK: - 配置导入导出（V0.4.2）

    /// 只导出偏好与保护路径，不含用户文件内容、扫描结果或审计日志。
    public func configurationData() throws -> Data {
        try ConfigurationTransfer.encode(currentConfiguration)
    }

    public var currentConfiguration: AppConfiguration {
        AppConfiguration(
            customProtections: customProtections,
            aiMode: aiMode.rawValue,
            showDockIcon: showDockIcon,
            displayUnit: displayUnit,
            scanScope: scanScope.rawValue,
            menuBar: menuBarPreferences,
            dailyJournalEnabled: dailyJournalEnabled,
            runMode: preferredRunMode.rawValue,
            showEnglishOriginal: showEnglishOriginal
        )
    }

    /// 应用顺序：先校验并落盘保护路径，成功后再生效其它偏好；任何一步失败都不静默半应用。
    @discardableResult
    public func applyConfiguration(_ configuration: AppConfiguration) throws -> Int {
        let normalized = try ConfigurationTransfer.decode(try ConfigurationTransfer.encode(configuration))
        let old = (try? protectionStore.load()) ?? []
        try protectionStore.save(normalized.customProtections)
        customProtections = normalized.customProtections

        aiMode = AIMode(rawValue: normalized.aiMode) ?? .off
        showDockIcon = normalized.showDockIcon
        displayUnit = normalized.displayUnit
        scanScope = ScanScope(rawValue: normalized.scanScope) ?? .userOnly
        menuBarPreferences = normalized.menuBar
        dailyJournalEnabled = normalized.dailyJournalEnabled
        preferredRunMode = RunMode(rawValue: normalized.runMode) ?? .silent
        showEnglishOriginal = normalized.showEnglishOriginal
        UserDefaults.standard.set(aiMode.rawValue, forKey: "snow.aiMode")
        errorMessage = nil
        return max(0, normalized.customProtections.count - old.count)
    }

    public func addProtection(_ path: String) {
        do {
            customProtections = try protectionStore.add(path)
            errorMessage = nil
        } catch {
            errorMessage = .settings("\(error)")
        }
    }

    /// 批量导入保护路径。一次校验、一次落盘；任何一条非法都不写入，
    /// 避免出现“导入了一半”的清单。返回实际新增条目数。
    @discardableResult
    public func importProtections(_ paths: [String]) -> Int {
        let existing = (try? protectionStore.load()) ?? []
        var merged = existing
        var seen = Set(existing)
        for raw in paths {
            let path = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !path.isEmpty, seen.insert(path).inserted else { continue }
            merged.append(path)
        }
        do {
            try protectionStore.save(merged)
            customProtections = merged
            errorMessage = nil
            return merged.count - existing.count
        } catch {
            errorMessage = .settings("\(error)")
            return 0
        }
    }

    public func removeProtection(_ path: String) {
        do {
            customProtections = try protectionStore.remove(path)
            errorMessage = nil
        } catch {
            errorMessage = .settings("\(error)")
        }
    }

    /// 清理页证据抽屉用：按规则 ID 还原规则中文名。
    public func ruleName(for ruleID: String?) -> String? {
        guard let ruleID else { return nil }
        return activeEngine?.ruleBook.rules.first { $0.id == ruleID }?.name
    }

    private func makeBatchID(_ prefix: String) -> String {
        let stamp = Int(Date().timeIntervalSince1970)
        let suffix = UUID().uuidString.prefix(8)
        return "\(prefix)-\(stamp)-\(suffix)"
    }

    /// macOS 不允许应用替用户勾选 TCC；能做的只有把正确页面打开、把 App 路径复制好，
    /// 让用户用一次拖动完成授权。重装后 ad-hoc 签名变化，系统会再次要求授权。
    public func relaunchApplication() {
        let bundleURL = Bundle.main.bundleURL
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        process.arguments = ["-n", bundleURL.path]
        do {
            try process.run()
        } catch {
            errorMessage = .settings("无法重新启动：\(error.localizedDescription)")
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
            NSApp.terminate(nil)
        }
    }

    /// 权限探测只在自己的串行队列里跑。个人目录可能卡在 iCloud / 网络盘或系统授权上，
    /// 不能占用全局 utility 队列，否则会连模型宿主的管道读取一起饿死。
    private let homeAccessQueue = DispatchQueue(
        label: "com.selfuse.xue.home-access",
        qos: .utility
    )

    /// 只做一次轻量目录探测：读不到就提示授权，不在后台反复扫盘，也不在启动时自动弹系统授权。
    public func checkHomeFolderAccess() {
        guard !isCheckingHomeAccess else { return }
        isCheckingHomeAccess = true
        let home = NSHomeDirectory()
        let names = [("Desktop", "桌面"), ("Documents", "文稿"), ("Downloads", "下载"),
                     ("Pictures", "图片"), ("Music", "音乐"), ("Movies", "影片"), ("Library", "资源库")]
        homeAccessQueue.async { [weak self] in
            let fm = FileManager.default
            var missing: [String] = []
            for (name, display) in names {
                let path = (home as NSString).appendingPathComponent(name)
                do {
                    // TCC 拒绝时有的目录会抛出错误，有的会返回空列表；
                    // 这些个人目录正常不会是空的，空列表也按“没读到”处理。
                    let entries = try fm.contentsOfDirectory(atPath: path)
                    if entries.isEmpty { missing.append(display) }
                } catch {
                    missing.append(display)
                }
            }
            DispatchQueue.main.async {
                guard let self else { return }
                self.unreadableHomeFolders = missing
                self.isCheckingHomeAccess = false
            }
        }
    }

    public func copyAppBundlePath() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(Bundle.main.bundlePath, forType: .string)
    }

    public func openFullDiskAccessSettings() {
        guard let url = SystemSettingsLinks.fullDiskAccessURL() else {
            errorMessage = .permission("无法构造系统设置地址")
            return
        }
        NSWorkspace.shared.open(url)
    }

    // MARK: - 只读检查：权限清单 / 启动项审查

    /// 只读取证，不参与清理；读不到就由 Core 写缺口，界面显示"无法列出"。
    public func refreshInspections() {
        guard !isInspecting else { return }
        // Swift 6.2 的默认 MainActor 隔离会把 Task.detached 的同步体也拉回主线程；
        // 权限数据库与目录探测又可能等 TCC 授权，必须走 GCD 全局队列。
        isInspecting = true
        inspectionTask = Task { [weak self] in
            let result = await Self.collectInspections()
            guard !Task.isCancelled, let self else { return }
            self.permissionSnapshot = result.permissions
            self.startupSnapshot = result.startup
            self.directoryAccess = result.directories
            self.isInspecting = false
        }
    }

    /// 在 nonisolated 函数里再派发到全局队列，避免默认 MainActor 隔离
    /// 把同步体留在主线程；权限数据库与目录探测都可能等 TCC 授权。
    nonisolated private static func collectInspections() async -> (
        permissions: PermissionSnapshot,
        startup: StartupSnapshot,
        directories: DirectoryAccessSnapshot
    ) {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let permissions = PermissionInspector().snapshot()
                let startup = StartupInspector().snapshot()
                let directories = RestrictedDirectoryCatalog.snapshot()
                continuation.resume(returning: (permissions, startup, directories))
            }
        }
    }

    public func openPermissionSettings(for grant: PermissionGrant) {
        let kind = PermissionCatalog.definition(forService: grant.rawService)?.kind
        openPermissionSettings(for: kind)
    }

    public func openPermissionSettings(for kind: PermissionKind?) {
        guard let url = SystemSettingsLinks.permissionURL(for: kind) else {
            errorMessage = .permission("无法构造系统设置地址")
            return
        }
        NSWorkspace.shared.open(url)
    }

    public func openLoginItemsSettings() {
        // 官方 API 优先（macOS 13+），它直接打开「通用 › 登录项与扩展」；
        // 万一系统版本不支持，退回 Core 里经过验证的 URL。
        if #available(macOS 13.0, *) {
            SMAppService.openSystemSettingsLoginItems()
            return
        }
        guard let url = SystemSettingsLinks.loginItemsURL() else {
            errorMessage = .permission("无法构造登录项设置地址")
            return
        }
        NSWorkspace.shared.open(url)
    }

    /// 重试读取单个缺口目录。只做一次只读列目录，不改报告、不解除清理锁。
    public func probeDirectoryReadable(_ path: String) async -> Bool {
        await Task.detached(priority: .userInitiated) {
            SystemDirectoryAccessChecker().canList(NSString(string: path).expandingTildeInPath)
        }.value
    }

    private static func loadBuiltInProtectionPaths(ruleURL: URL) -> [String] {
        guard let data = try? Data(contentsOf: ruleURL) else { return [] }
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return (try? decoder.decode(RuleBook.self, from: data))?.protectedPaths ?? []
    }

    private nonisolated static func hasFullDiskAccessHint() -> Bool {
        // TCC.db 读不到不代表没有授权（数据库被 SIP / root 独占）；
        // 以 Safari、邮件等受保护目录能否打开为准。
        FullDiskAccessProbe.isLikelyGranted()
    }

    private static func diskTotals() -> (free: Int64, total: Int64) {
        let attributes = try? FileManager.default.attributesOfFileSystem(forPath: NSHomeDirectory())
        let free = (attributes?[.systemFreeSize] as? NSNumber)?.int64Value ?? 0
        let total = (attributes?[.systemSize] as? NSNumber)?.int64Value ?? 0
        return (free, total)
    }
}


/// 进程外扫描被 TCC 拒绝，但主 App 自己能读同一位置；用主进程复扫避免假缺口。
private struct MainProcessPermissionRetry: LocalizedError {
    let path: String
    var errorDescription: String? { "进程外扫描无权限，主进程可读：\(path)" }
}
