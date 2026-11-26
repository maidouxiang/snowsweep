import SwiftUI
import AppKit
import Darwin
import SnowSweepCore

/// 首屏“全盘体检”的状态机：一句话 → 呼吸 → 全盘扫描 → 决策单。
/// 所有删除都走 ManualDeletionService：只移废纸篓、逐项复核、失败即停。
@MainActor
final class LandingAuditModel: ObservableObject {
    enum Phase: Equatable {
        case idle
        case breathing
        case results
        case failed
    }

    @Published private(set) var phase: Phase = .idle
    @Published private(set) var stage = ""
    @Published private(set) var progress: Double = 0
    @Published private(set) var scanPaths: [String] = []
    @Published private(set) var spacesLoading = false
    @Published private(set) var result: LandingAuditResult?
    @Published private(set) var spaces: [SpaceNode] = []
    @Published private(set) var spacesError: String?
    @Published private(set) var homeSpaces: [SpaceNode] = []
    @Published private(set) var homeSpacesError: String?
    @Published private(set) var query = ""
    @Published private(set) var startedAt = Date()
    @Published private(set) var isTrashing = false
    @Published private(set) var removedPaths: Set<String> = []
    @Published private(set) var removedBytes: Int64 = 0
    @Published private(set) var removedCount = 0
    @Published private(set) var lastMessage: String?
    @Published private(set) var lastError: String?

    private var auditTask: Task<Void, Never>?
    private var scanPathIndex = 0
    private let home = NSHomeDirectory()

    var isBusy: Bool { phase == .breathing }

    func begin(_ text: String, using model: ScanViewModel) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        auditTask?.cancel()
        if model.isScanning { model.cancelScan() }

        query = trimmed
        startedAt = Date()
        phase = .breathing
        stage = "正在打开全盘目录"
        progress = 0
        scanPaths = []
        scanPathIndex = 0
        spacesLoading = true
        result = nil
        spaces = []
        spacesError = nil
        homeSpaces = []
        homeSpacesError = nil
        removedPaths = []
        removedBytes = 0
        removedCount = 0
        lastMessage = nil
        lastError = nil

        let previousScope = model.scanScope
        let restoreScope = previousScope != .wholeDisk
        model.scanScope = .wholeDisk

        let home = self.home
        auditTask = Task { [weak self] in
            guard let self else { return }

            // 空间大头和大文件与规则扫描并行跑：呼吸动画期间一起做完。
            let spacesTask = Task.detached(priority: .utility) {
                SystemMetrics.systemSpaceLayer(timeout: 20, concurrency: 6)
            }
            let bigTask = Task.detached(priority: .utility) {
                SystemMetrics.biggestFiles(home: home, minMegabytes: 20, limit: 5000, timeout: 20)
            }
            let homeTask = Task.detached(priority: .utility) {
                SystemMetrics.spaceLayer(of: home)
            }

            model.startScan()

            let clock = ContinuousClock()
            let deadline = clock.now.advanced(by: .seconds(240))
            while !Task.isCancelled && model.isScanning && clock.now < deadline {
                self.progress = model.progressFraction
                self.stage = Self.stageText(progress: model.progressFraction,
                                           path: model.currentPath)
                self.appendFreshPaths(from: model.recentPaths)
                try? await Task.sleep(for: .milliseconds(350))
            }
            if Task.isCancelled {
                if restoreScope { model.scanScope = previousScope }
                return
            }
            // 扫描可能在一次 HUD 发布前就结束；这里补收最终一批真实路径。
            self.appendFreshPaths(from: model.recentPaths)
            if model.isScanning { model.cancelScan() }

            self.stage = "正在排一二三四"
            self.progress = max(0.9, self.progress)
            let big = await bigTask.value
            if restoreScope { model.scanScope = previousScope }

            guard let report = model.report else {
                self.spacesLoading = false
                self.phase = .failed
                self.lastError = model.errorMessage?.errorDescription ?? "这次没读到扫描结果。请重试，或到「权限清单」检查完全磁盘访问权限。"
                return
            }
            if report.scanStatus == "cancelled" {
                self.spacesLoading = false
                self.phase = .failed
                self.lastError = "这次扫描被取消了，没有生成清单。"
                return
            }

            var warningParts: [String] = []
            if let blocked = report.cleaningBlockedReason {
                warningParts.append(blocked + "。清单只作参考，移入废纸篓已锁定。")
            } else if report.scanGaps.count > 0 {
                warningParts.append("有 \(report.scanGaps.count) 个位置没读全，已从可清清单里排除。")
            }
            if big.timedOut {
                warningParts.append("个人目录的大文件这次超时没读完，已跳过。")
            }
            if !warningParts.isEmpty {
                warningParts.append("报告只代表读到的部分。")
            }
            let warning = warningParts.isEmpty ? nil : warningParts.joined(separator: "")

            let audit = LandingAuditBuilder.build(
                verdicts: report.verdicts,
                bigFiles: big.rows,
                reportComplete: report.canClean,
                warning: warning
            )

            // 呼吸至少三秒，避免扫描太快时动画一闪而过。
            let elapsed = Date().timeIntervalSince(self.startedAt)
            if elapsed < 3.0 {
                try? await Task.sleep(for: .seconds(3.0 - elapsed))
            }
            guard !Task.isCancelled else {
                if restoreScope { model.scanScope = previousScope }
                return
            }

            // 决策单已经能出来了，先结束呼吸，让用户开始看；
            // 空间大头继续在后台算，算完再补进“空间去哪了”。
            self.result = audit
            self.progress = 1
            self.stage = "看完了"
            self.phase = .results
            RuntimeCenter.shared.noteScanFinished()

            let spaces = await spacesTask.value
            let homeLayer = await homeTask.value
            guard !Task.isCancelled, self.phase == .results else { return }
            self.spaces = spaces.nodes.filter { $0.bytes > 0 }
            self.spacesError = spaces.readError
            self.homeSpaces = homeLayer.nodes.filter { $0.bytes > 0 }
            self.homeSpacesError = homeLayer.readError
            self.spacesLoading = false
        }
    }

    func reset() {
        auditTask?.cancel()
        phase = .idle
        result = nil
        spaces = []
        spacesError = nil
        homeSpaces = []
        homeSpacesError = nil
        spacesLoading = false
        stage = ""
        progress = 0
        scanPaths = []
        scanPathIndex = 0
        query = ""
        lastMessage = nil
        lastError = nil
    }

    /// 关窗/静默时释放首屏结果。只清内存，不碰文件、废纸篓和审计。
    func releaseForSilent() {
        auditTask?.cancel()
        auditTask = nil
        phase = .idle
        result = nil
        spaces = []
        spacesError = nil
        homeSpaces = []
        homeSpacesError = nil
        spacesLoading = false
        query = ""
        progress = 0
        scanPaths = []
        scanPathIndex = 0
        stage = ""
        removedPaths = []
        removedBytes = 0
        removedCount = 0
        lastMessage = nil
        lastError = nil
        malloc_zone_pressure_relief(nil, 0)
    }

    // MARK: - 删除

    func trashOne(_ finding: AuditFinding, using model: ScanViewModel) async -> Bool {
        guard finding.isTrashable else { return false }
        isTrashing = true
        lastError = nil
        let service = deletionService(using: model)
        do {
            try await Task.detached(priority: .userInitiated) {
                let plan = try service.preview(path: finding.path, reason: finding.reason)
                _ = try service.moveToTrash(plan, source: "landing-audit")
            }.value
            removedPaths.insert(finding.id)
            removedBytes += finding.bytes
            removedCount += 1
            lastMessage = "已把「\(finding.title)」移入废纸篓，没有永久删除。"
            isTrashing = false
            return true
        } catch {
            lastError = (error as? LocalizedError)?.errorDescription ?? "\(error)"
            isTrashing = false
            return false
        }
    }

    func trashBatch(_ findings: [AuditFinding], using model: ScanViewModel) async {
        guard !findings.isEmpty else { return }
        isTrashing = true
        lastError = nil
        let service = deletionService(using: model)
        var moved = 0
        for finding in findings {
            if Task.isCancelled { break }
            do {
                try await Task.detached(priority: .userInitiated) {
                    let plan = try service.preview(path: finding.path, reason: finding.reason)
                    _ = try service.moveToTrash(plan, source: "landing-audit")
                }.value
                removedPaths.insert(finding.id)
                removedBytes += finding.bytes
                moved += 1
            } catch {
                lastError = (error as? LocalizedError)?.errorDescription ?? "\(error)"
                break
            }
        }
        removedCount += moved
        lastMessage = moved > 0
            ? "已移入废纸篓 \(moved) 项，没有永久删除。" + (lastError == nil ? "" : "后面遇到问题，已停手。")
            : nil
        isTrashing = false
    }

    private func deletionService(using model: ScanViewModel) -> ManualDeletionService {
        ManualDeletionService(
            protectionCheck: model.manualProtectionCheck,
            allowedRoots: ["/", home]
        )
    }

    // MARK: - 文案

    private func appendFreshPaths(from paths: [String]) {
        guard paths.count > scanPathIndex else { return }
        scanPaths.append(contentsOf: paths[scanPathIndex..<paths.count])
        scanPathIndex = paths.count
        if scanPaths.count > 500 {
            scanPaths.removeFirst(scanPaths.count - 500)
        }
    }

    private static func stageText(progress: Double, path: String) -> String {
        if progress < 0.12 { return "正在打开全盘目录" }
        if progress < 0.42 { return "正在辨认缓存、日志、安装包和构建产物" }
        if progress < 0.72 {
            return path.isEmpty ? "正在核对保护清单" : "正在看 \(path)"
        }
        if progress < 0.92 { return "正在算空间去向和最大的文件" }
        return "正在把结果排成一二三四"
    }
}
