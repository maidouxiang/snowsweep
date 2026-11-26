import SwiftUI
import AppKit
import SnowSweepCore

// MARK: - 页内筛选

private enum FamilyFilter: String, CaseIterable, Identifiable {
    case candidate
    case shared
    case keep
    case all

    var id: String { rawValue }
    var title: String {
        switch self {
        case .candidate: return "候选"
        case .shared: return "多宿主"
        case .keep: return "保留"
        case .all: return "全部"
        }
    }
}

// MARK: - 扫描模型

@MainActor
final class SoftwareFamilyModel: ObservableObject {
    @Published var report: SoftwareGraphReport?
    @Published var isScanning = false
    @Published var errorText: String?
    @Published var duration: TimeInterval?

    private var scanTask: Task<Void, Never>?

    func scan(force: Bool = false) {
        guard !isScanning else { return }
        if !force, let cached = SoftwareGraphSession.shared.cachedReport {
            report = cached
            duration = SoftwareGraphSession.shared.cachedDuration
            errorText = nil
            return
        }
        scanTask?.cancel()
        isScanning = true
        errorText = nil
        let started = Date()

        scanTask = Task { [weak self] in
            do {
                let report = try await Task.detached(priority: .utility) { () throws -> SoftwareGraphReport in
                    let store = try SoftwareFamilyStore.loadBundled()
                    return SoftwareGraphScanner.scan(store: store, options: .live())
                }.value
                guard let self, !Task.isCancelled else { return }
                self.report = report
                let elapsed = Date().timeIntervalSince(started)
                self.duration = elapsed
                SoftwareGraphSession.shared.store(report, duration: elapsed)
                self.isScanning = false
            } catch {
                guard let self else { return }
                self.errorText = "族谱扫描失败：\(error.localizedDescription)"
                self.isScanning = false
            }
        }
    }

    func cancel() {
        scanTask?.cancel()
        isScanning = false
    }
}

// MARK: - 软件族谱页

struct SoftwareFamilyView: View {
    @EnvironmentObject private var appModel: ScanViewModel
    @StateObject private var model = SoftwareFamilyModel()
    @State private var query = ""
    @State private var filter: FamilyFilter = .candidate
    @State private var familyFilter: String?
    @State private var selectedID: String?
    @State private var copiedPath = false
    @State private var prompt: ManualDeletionPrompt?
    @State private var notice: String?
    @State private var noticeIsError = false
    @State private var onlineOptIn = false
    @State private var onlineLoading = false
    @State private var onlineError: String?
    @State private var onlineResult: OnlineAppVerification?
    @State private var onlineBundleID: String?

    private var findings: [SoftwareFinding] {
        model.report?.findings ?? []
    }

    private var visibleFindings: [SoftwareFinding] {
        let text = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return findings.filter { finding in
            let verdictOK: Bool
            switch filter {
            case .candidate:
                verdictOK = finding.verdict == .suggestedCleanup
                    || finding.verdict == .possibleRedundancy
            case .shared:
                verdictOK = finding.isShared
            case .keep:
                verdictOK = finding.verdict == .keep
            case .all:
                verdictOK = true
            }
            let familyOK = familyFilter == nil || finding.familyID == familyFilter
            let textOK = text.isEmpty
                || finding.node.name.localizedCaseInsensitiveContains(text)
                || finding.node.path.localizedCaseInsensitiveContains(text)
                || (finding.familyName ?? "").localizedCaseInsensitiveContains(text)
            return verdictOK && familyOK && textOK
        }
    }

    private var selectedFinding: SoftwareFinding? {
        if let selectedID,
           let hit = findings.first(where: { $0.id == selectedID }),
           visibleFindings.contains(where: { $0.id == selectedID }) {
            return hit
        }
        return visibleFindings.first
    }

    private var familyOptions: [(id: String, name: String, count: Int, bytes: Int64)] {
        var map: [String: (name: String, count: Int, bytes: Int64)] = [:]
        for finding in findings {
            guard let id = finding.familyID else { continue }
            let current = map[id] ?? (finding.familyName ?? id, 0, 0)
            map[id] = (current.name, current.count + 1, current.bytes + (finding.sizeBytes ?? 0))
        }
        return map.map { ($0.key, $0.value.name, $0.value.count, $0.value.bytes) }
            .sorted { $0.3 > $1.3 }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .top) {
                    PageHeader(
                        title: "软件族谱",
                        subtitle: "先看它属于哪个软件，再看那个软件还在不在。候选要逐项确认后才能移入废纸篓；共享宿主和受保护项不提供删除。"
                    )
                    Spacer()
                    if model.isScanning {
                        Button("取消") { model.cancel() }
                    } else {
                        Button("重新扫描") { model.scan(force: true) }
                    }
                }

                if let notice {
                    InfoBanner(text: notice, color: noticeIsError ? .red : .green)
                }

                if let stats = model.report?.stats {
                    HStack(spacing: 12) {
                        MetricTile(
                            title: "候选",
                            value: "\(stats.suggestedCleanupCount + stats.possibleRedundancyCount)",
                            foot: stats.suggestedCleanupCount == 0
                                ? "全是「可能冗余」"
                                : "其中 \(stats.suggestedCleanupCount) 条硬建议",
                            color: .orange
                        )
                        MetricTile(
                            title: "候选体积",
                            value: SystemMetrics.bytesText(stats.totalCandidateBytes),
                            foot: "不含保留与受保护",
                            color: .red
                        )
                        MetricTile(
                            title: "保留",
                            value: "\(stats.keepCount)",
                            foot: "宿主还在，或同家族多宿主",
                            color: .green
                        )
                        MetricTile(
                            title: "待判断 / 受保护",
                            value: "\(stats.unknownCount) / \(stats.protectedCount)",
                            foot: "证据不足，默认不动",
                            color: .gray
                        )
                    }
                }

                if model.isScanning {
                    HStack(spacing: 9) {
                        ProgressView().controlSize(.small)
                        Text("正在读应用、安装收据、插件根和体积；第一次扫描通常 10–30 秒。")
                            .font(.callout).foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 4)
                } else if let errorText = model.errorText {
                    InfoBanner(text: errorText, color: .orange)
                } else if let report = model.report {
                    HStack(spacing: 8) {
                        Text("已扫描 \(report.stats.appCount) 个应用、\(report.stats.familyCount) 个家族、\(report.stats.pluginNodeCount) 个插件节点。")
                        if let duration = model.duration {
                            Text(String(format: "耗时 %.1f 秒。", duration))
                        }
                        Text("没有删除任何文件。")
                            .foregroundStyle(.secondary)
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }

                if model.report != nil {
                    InfoBanner(text: "当前覆盖：应用包、安装收据、已收录软件家族的插件根、LaunchAgents。没有收录进本地族谱的新软件不会凭空出现；普通偏好、容器和缓存由空间分析与大文件页另行核对。", color: .blue)
                    HStack(spacing: 8) {
                        Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                        TextField("搜插件名、家族或路径", text: $query)
                            .textFieldStyle(.roundedBorder)
                            .frame(maxWidth: 280)
                        Picker("", selection: $filter) {
                            ForEach(FamilyFilter.allCases) { item in
                                Text(item.title).tag(item)
                            }
                        }
                        .pickerStyle(.segmented)
                        .frame(width: 230)
                        Menu {
                            Button("全部家族") { familyFilter = nil }
                            ForEach(familyOptions, id: \.id) { option in
                                Button("\(option.name) · \(option.count) 项") {
                                    familyFilter = option.id
                                }
                            }
                        } label: {
                            Text(familyFilter.flatMap { id in familyOptions.first(where: { $0.id == id })?.name } ?? "全部家族")
                        }
                        .menuStyle(.borderlessButton)
                        .frame(width: 130)
                        Spacer()
                        Text("\(visibleFindings.count) 项")
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                }

                if model.report == nil && !model.isScanning {
                    InfoBanner(text: "还没有族谱结果。点「重新扫描」开始；这轮只读，不会改任何文件。", color: .blue)
                } else if model.report != nil && visibleFindings.isEmpty {
                    InfoBanner(text: "这个筛选下没有结果。试试「全部」，或清空搜索。", color: .gray)
                } else if model.report != nil {
                    HStack(alignment: .top, spacing: 14) {
                        findingList
                            .frame(width: 410)

                        if let finding = selectedFinding {
                            findingDetail(finding)
                        } else {
                            ModuleCard {
                                Text("左侧选一项，右边会显示它和哪个软件有关、那个软件还在不在、能不能删。")
                                    .font(.callout).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
            .padding(18)
        }
        .task {
            if model.report == nil && !model.isScanning { model.scan() }
        }
        .manualDeletionSheet(prompt: $prompt) { result in
            switch result {
            case let .success(count):
                noticeIsError = false
                notice = "已将 \(count) 项移到废纸篓，并重新扫描族谱。可在废纸篓或恢复清单核对。"
                model.scan(force: true)
            case let .failure(error):
                noticeIsError = true
                notice = error.localizedDescription
            }
        }
    }

    private var findingList: some View {
        ModuleCard(padding: 0) {
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(visibleFindings) { finding in
                        Button {
                            selectedID = finding.id
                            copiedPath = false
                        } label: {
                            HStack(alignment: .top, spacing: 9) {
                                Circle()
                                    .fill(verdictColor(finding.verdict))
                                    .frame(width: 8, height: 8)
                                    .padding(.top, 5)
                                VStack(alignment: .leading, spacing: 3) {
                                    HStack(spacing: 6) {
                                        Text(finding.node.name)
                                            .font(.callout.weight(.medium))
                                            .lineLimit(1)
                                        Text(finding.verdict.chineseName)
                                            .font(.caption2)
                                            .padding(.horizontal, 6).padding(.vertical, 2)
                                            .background(verdictColor(finding.verdict).opacity(0.12),
                                                        in: Capsule())
                                            .foregroundStyle(verdictColor(finding.verdict))
                                    }
                                    Text(finding.familyName ?? "未命中族谱")
                                        .font(.caption).foregroundStyle(.secondary)
                                    Text((finding.node.path as NSString).abbreviatingWithTildeInPath)
                                        .font(.caption2).foregroundStyle(.tertiary).lineLimit(1)
                                }
                                Spacer(minLength: 4)
                                Text(finding.sizeBytes.map(SystemMetrics.bytesText) ?? "—")
                                    .font(.caption.monospacedDigit())
                                    .foregroundStyle(.secondary)
                            }
                            .padding(.horizontal, 12)
                            .padding(.vertical, 9)
                            .contentShape(Rectangle())
                            .background(
                                selectedFinding?.id == finding.id
                                    ? Color.accentColor.opacity(0.08)
                                    : Color.clear
                            )
                        }
                        .buttonStyle(.plain)
                        Divider().padding(.leading, 29)
                    }
                }
            }
            .frame(maxHeight: 520)
        }
    }

    private func findingDetail(_ finding: SoftwareFinding) -> some View {
        let hostSummary = SharedHostSummary(finding: finding)
        return ModuleCard {
            VStack(alignment: .leading, spacing: 13) {
                HStack(alignment: .top, spacing: 10) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(finding.node.name).font(.title3.weight(.semibold))
                        Text(finding.node.kind.chineseName + " · " + (finding.familyName ?? "未命中族谱"))
                            .font(.caption).foregroundStyle(.secondary)
                        Text(finding.node.path)
                            .font(.caption2).foregroundStyle(.secondary)
                            .textSelection(.enabled)
                    }
                    Spacer()
                    Text(finding.verdict.chineseName)
                        .font(.callout.weight(.semibold))
                        .padding(.horizontal, 10).padding(.vertical, 5)
                        .background(verdictColor(finding.verdict).opacity(0.12), in: Capsule())
                        .foregroundStyle(verdictColor(finding.verdict))
                }

                HStack(spacing: 18) {
                    detailPair("体积", finding.sizeBytes.map(SystemMetrics.bytesText) ?? "未统计")
                    detailPair("最近使用", finding.lastUsed.map(formatDate) ?? "没有记录")
                    detailPair("最近修改", finding.lastModified.map(formatDate) ?? "没有记录")
                }

                Divider()

                Text("关系网").font(.headline)
                VStack(alignment: .leading, spacing: 4) {
                    relationLine("家族", finding.familyName ?? "没有命中本地族谱")
                    relationLine("宿主", hostSummary.headline)
                    if hostSummary.count == 0, !finding.missingHostBundleIDs.isEmpty {
                        relationLine("未安装", finding.missingHostBundleIDs.joined(separator: "、"))
                    }
                    if hostSummary.isShared {
                        sharedHostsBlock(hostSummary)
                    }
                    ForEach(finding.evidence.filter { $0.kind == .launchAgent || $0.kind == .packageReceipt }, id: \.self) { evidence in
                        relationLine(evidence.kind == .launchAgent ? "后台服务" : "安装收据",
                                     "\(evidence.value) · \(evidence.strength.chineseName)")
                    }
                    relationLine("插件本体", finding.node.path)
                }
                .font(.callout)
                .padding(10)
                .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 8))

                Text("为什么这样判").font(.headline)
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(finding.reasons, id: \.self) { reason in
                        HStack(alignment: .top, spacing: 6) {
                            Text("·").foregroundStyle(.secondary)
                            Text(reason)
                        }
                    }
                }
                .font(.callout)

                if !finding.evidence.isEmpty {
                    Text("证据").font(.headline)
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(finding.evidence, id: \.self) { evidence in
                            HStack(alignment: .top, spacing: 6) {
                                Text(evidence.strength.chineseName)
                                    .font(.caption2)
                                    .foregroundStyle(evidence.strength == .strong ? .green : .orange)
                                Text(evidence.note)
                                Text(evidence.value)
                                    .font(.caption2).foregroundStyle(.secondary)
                                    .textSelection(.enabled)
                            }
                        }
                    }
                    .font(.caption)
                }

                InfoBanner(text: canDeleteText(finding), color: verdictColor(finding.verdict))

                if finding.verdict == .keep && !finding.node.isProtected {
                    InfoBanner(
                        text: "「保留」不等于保护清单：它表示登记的宿主还在，或同家族还有多个宿主。要清掉它，先去「卸载」页卸载宿主；卸载完重新扫描，再回到这里删除残留。",
                        color: .green
                    )
                }

                if finding.node.isProtected || finding.verdict == .protected {
                    HStack(alignment: .top, spacing: 8) {
                        Image(systemName: "lock.shield.fill").foregroundStyle(.orange)
                        VStack(alignment: .leading, spacing: 3) {
                            Text("受保护原因：\(protectionReason(finding))").font(.caption.weight(.semibold))
                            if canOverrideProtection(finding) {
                                Text("可以在「保护路径」页移除你自己加的保护；如果是家族内置保护词、许可证或凭证，只能在这里做一次“解除这一项的保护”。系统应用和 /System 节点永远不能删。")
                                    .font(.caption2).foregroundStyle(.secondary)
                            }
                        }
                    }
                    .padding(9)
                    .background(Color.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
                }

                onlineVerificationBlock(finding)

                HStack(spacing: 8) {
                    Button("在 Finder 中显示") {
                        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: finding.node.path)])
                    }
                    Button(copiedPath ? "已复制路径" : "复制路径") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(finding.node.path, forType: .string)
                        copiedPath = true
                    }
                    Spacer()
                    if canDelete(finding) {
                        Button("移到废纸篓", role: .destructive) {
                            requestDelete(finding, overrideProtection: false)
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(.red)
                    } else if canOverrideProtection(finding) {
                        Button("解除这一项的保护并删除", role: .destructive) {
                            requestDelete(finding, overrideProtection: true)
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(.red)
                        .help("只解除这一次，不会把保护清单永久改掉")
                    } else {
                        Text("这一项不提供删除")
                            .font(.caption2).foregroundStyle(.tertiary)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func canDelete(_ finding: SoftwareFinding) -> Bool {
        guard finding.verdict == .suggestedCleanup || finding.verdict == .possibleRedundancy else { return false }
        guard !finding.isShared, !finding.node.isProtected, !finding.node.isSystem else { return false }
        guard !finding.node.path.hasPrefix("/System/"),
              !finding.node.path.hasPrefix("family:") else { return false }
        return true
    }

    /// 受保护项只允许“单次解除”：系统节点、共享宿主、家族虚拟节点仍然拒绝。
    private func canOverrideProtection(_ finding: SoftwareFinding) -> Bool {
        guard finding.verdict == .protected else { return false }
        guard !finding.isShared, !finding.node.isSystem else { return false }
        guard !finding.node.path.hasPrefix("/System/"),
              !finding.node.path.hasPrefix("family:") else { return false }
        return true
    }

    private func protectionReason(_ finding: SoftwareFinding) -> String {
        if finding.node.isSystem || finding.node.path.hasPrefix("/System/") {
            return "系统自带应用或 Apple 系统组件，不允许删除"
        }
        if finding.node.kind == .license {
            return "许可证 / 授权文件，删除后软件可能要求重新激活"
        }
        let lowered = finding.node.path.lowercased()
        if ["license", "licen", "credential", "genuine", "rlm"].contains(where: lowered.contains) {
            return "路径命中家族保护词（license / credential / genuine / rlm）"
        }
        if finding.node.bundleID?.hasPrefix("com.apple.") == true {
            return "Apple 系统应用"
        }
        return "内置保护规则或你自己的保护清单命中；如果是你加的，可在「保护路径」页移除"
    }

    private func requestDelete(_ finding: SoftwareFinding, overrideProtection: Bool) {
        guard overrideProtection ? canOverrideProtection(finding) : canDelete(finding) else { return }
        let check = appModel.manualProtectionCheck
        let path = finding.node.path
        let verdict = finding.verdict
        let override = overrideProtection
        let target = (NSString(string: path).expandingTildeInPath as NSString).standardizingPath
        Task {
            let result = await Task.detached(priority: .userInitiated) {
                () -> Result<ManualDeletionPlan, Error> in
                let scoped: (@Sendable (String) -> Bool)? = {
                    guard let check else { return nil }
                    return { candidate in
                        let normalized = (NSString(string: candidate).expandingTildeInPath as NSString).standardizingPath
                        if override, normalized == target { return false }
                        return check(candidate)
                    }
                }()
                let service = ManualDeletionService(
                    protectionCheck: scoped,
                    allowedRoots: [NSHomeDirectory(), "/Library"]
                )
                do {
                    return .success(try service.preview(path: path, reason: "族谱：\(verdict.chineseName)"))
                } catch {
                    return .failure(error)
                }
            }.value
            await MainActor.run {
                switch result {
                case let .success(plan):
                    prompt = ManualDeletionPrompt(
                        plans: [plan],
                        title: override ? "解除这一项的保护并移到废纸篓？" : "把这一项移到废纸篓？",
                        message: override
                            ? "这一项被保护。你正在做一次性的解除：只删这一条，不会修改保护清单；授权/凭证删掉后软件可能需要重新激活。"
                            : "族谱判定：\(verdict.chineseName)。删除后仍可重新扫描确认；共享宿主和受保护项不会被允许删除。",
                        source: "软件族谱",
                        caution: override ? .protectedOverride
                            : (verdict == .possibleRedundancy ? .uncertain : .normal),
                        allowedRoots: [NSHomeDirectory(), "/Library"],
                        protectionOverridePaths: override ? [path] : []
                    )
                case let .failure(error):
                    noticeIsError = true
                    notice = error.localizedDescription
                }
            }
        }
    }

    private func verificationBundleID(_ finding: SoftwareFinding) -> String? {
        if let id = finding.node.bundleID, !id.isEmpty { return id }
        if let id = finding.installedHosts.first?.bundleID, !id.isEmpty { return id }
        if let id = finding.evidence.first(where: { $0.kind == .bundleIdentifier })?.value, !id.isEmpty {
            return id
        }
        if let id = finding.missingHostBundleIDs.first, !id.isEmpty { return id }
        return nil
    }

    private func onlineVerificationBlock(_ finding: SoftwareFinding) -> some View {
        let bundleID = verificationBundleID(finding)
        let resultMatches = onlineResult?.bundleID == bundleID
        return VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 6) {
                Image(systemName: "network").foregroundStyle(.blue)
                Text("联网核验身份（可选）").font(.headline)
                Spacer()
                Text(bundleID ?? "没有 Bundle ID")
                    .font(.caption2.monospaced()).foregroundStyle(.secondary).lineLimit(1)
            }
            Text("默认不联网。只有你打开下面的开关并点按钮，才会向 Apple 公开目录发送这一个 Bundle ID；不发送路径、文件名、哈希或目录列表。")
                .font(.caption2).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Toggle("允许这次发送 Bundle ID 做核验", isOn: $onlineOptIn)
                .toggleStyle(.checkbox)
                .font(.caption)

            HStack(spacing: 8) {
                Button {
                    runOnlineVerification(bundleID)
                } label: {
                    if onlineLoading {
                        HStack(spacing: 6) {
                            ProgressView().controlSize(.small)
                            Text("正在核验…")
                        }
                    } else {
                        Label("联网核验", systemImage: "arrow.up.right.circle")
                    }
                }
                .disabled(bundleID == nil || !onlineOptIn || onlineLoading)
                if resultMatches, let onlineResult {
                    Text(onlineResult.freshness.chineseName)
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(onlineResult.freshness == .stale ? .orange : .green)
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background((onlineResult.freshness == .stale ? Color.orange : Color.green).opacity(0.1), in: Capsule())
                }
                Spacer()
            }

            if let onlineError {
                Text(onlineError).font(.caption2).foregroundStyle(.red)
            }
            if resultMatches, let onlineResult {
                VStack(alignment: .leading, spacing: 3) {
                    Text(onlineResult.summary).font(.caption).foregroundStyle(.secondary)
                    if let seller = onlineResult.sellerName {
                        Text("公开目录卖家：\(seller)").font(.caption2).foregroundStyle(.secondary)
                    }
                    Text(onlineResult.freshness.note).font(.caption2).foregroundStyle(.secondary)
                    if let link = onlineResult.storeURL, let url = URL(string: link) {
                        Link("打开公开目录页面", destination: url).font(.caption2)
                    }
                }
                .padding(8)
                .background(Color.blue.opacity(0.06), in: RoundedRectangle(cornerRadius: 7))
            }
        }
        .padding(10)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
    }

    private func runOnlineVerification(_ bundleID: String?) {
        guard let bundleID, onlineOptIn, !onlineLoading else { return }
        onlineLoading = true
        onlineError = nil
        onlineBundleID = bundleID
        Task {
            do {
                let result = try await OnlineAppVerifier().verify(bundleID: bundleID)
                await MainActor.run {
                    onlineResult = result
                    onlineLoading = false
                }
            } catch {
                await MainActor.run {
                    onlineError = error.localizedDescription
                    onlineResult = nil
                    onlineLoading = false
                }
            }
        }
    }

    private func sharedHostsBlock(_ summary: SharedHostSummary) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: "square.on.square")
                    .foregroundStyle(.orange)
                Text("同家族宿主 \(summary.count) 个")
                    .font(.caption.weight(.semibold))
                Spacer()
                Text("保留，不建议删")
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(.green)
            }
            ForEach(summary.hosts) { host in
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text("·")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(host.name)
                            .font(.caption)
                        if let path = host.path {
                            Text((path as NSString).abbreviatingWithTildeInPath)
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                                .lineLimit(1)
                        }
                    }
                    Spacer(minLength: 4)
                    if let path = host.path, FileManager.default.fileExists(atPath: path) {
                        Button("定位") {
                            NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
                        }
                        .buttonStyle(.link)
                        .font(.caption2)
                    }
                }
            }
            Text(summary.conclusion)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(8)
        .background(Color.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 7))
    }

    private func detailPair(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.caption2).foregroundStyle(.secondary)
            Text(value).font(.caption).lineLimit(1)
        }
    }

    private func relationLine(_ label: String, _ value: String) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Text("└─")
                .font(.caption2)
                .foregroundStyle(.tertiary)
            Text(label)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .frame(width: 48, alignment: .leading)
            Text(value)
                .font(.caption)
                .lineLimit(2)
        }
    }

    private func canDeleteText(_ finding: SoftwareFinding) -> String {
        switch finding.verdict {
        case .suggestedCleanup:
            return "可以清理，但仍建议先看一眼宿主和共享关系；删除只进废纸篓，能恢复。"
        case .possibleRedundancy:
            return "先别直接删。它可能是残留，也可能还被别的软件用；确认宿主不在、没有共享后，再自己决定。"
        case .keep:
            return "不建议删。同一家族还有宿主装着，或无法确认宿主。"
        case .unknown:
            return "证据不够，待判断。没有族谱记录时，不要凭英文名字猜。"
        case .protected:
            return "受保护，不进入清理候选。"
        }
    }

    private func verdictColor(_ verdict: SoftwareVerdict) -> Color {
        switch verdict {
        case .suggestedCleanup: return .red
        case .possibleRedundancy: return .orange
        case .keep: return .green
        case .unknown: return .gray
        case .protected: return .blue
        }
    }

    private func formatDate(_ date: Date) -> String {
        date.formatted(date: .numeric, time: .shortened)
    }
}

// MARK: - 空间分析的中文说明卡

struct SpaceFileNote: Identifiable {
    let id = UUID()
    let title: String
    let englishName: String
    let family: String?
    let purpose: String
    let verdict: String
    let action: String
    let evidence: [String]
}

struct SpaceFileNoteCard: View {
    let note: SpaceFileNote
    let path: String
    let onReveal: () -> Void
    let onGoFamily: () -> Void
    let onGoClean: (() -> Void)?
    var onDelete: (() -> Void)? = nil

    var body: some View {
        ModuleCard {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(note.title).font(.headline)
                        Text(note.englishName + " · " + path)
                            .font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                    }
                    Spacer()
                    Text(note.verdict)
                        .font(.caption.weight(.semibold))
                        .padding(.horizontal, 8).padding(.vertical, 3)
                        .background(Color.accentColor.opacity(0.1), in: Capsule())
                }

                Text(note.purpose).font(.callout)
                Text(note.action).font(.caption).foregroundStyle(.secondary)

                if !note.evidence.isEmpty {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(note.evidence, id: \.self) { line in
                            Text("· " + line).font(.caption2).foregroundStyle(.secondary)
                        }
                    }
                }

                HStack(spacing: 8) {
                    Button("在 Finder 中显示", action: onReveal)
                    if note.family != nil {
                        Button("去软件族谱看归属", action: onGoFamily)
                    } else if let onGoClean {
                        Button("去清理页看建议", action: onGoClean)
                    }
                    if let onDelete {
                        Button("移到废纸篓", role: .destructive, action: onDelete)
                            .tint(.orange)
                    }
                    Spacer()
                    Text(onGoClean == nil
                         ? "外置盘只读分析；不进入清理判定"
                         : "删除只对当前选中的文件；先预览再确认，只进废纸篓")
                        .font(.caption2).foregroundStyle(.tertiary)
                }
            }
        }
    }
}

/// 把路径翻成用户能判断的中文说明。先查软件族谱，再查中文词条，最后才说“不认得”。
func makeSpaceFileNote(for node: SpaceNode) -> SpaceFileNote {
    let home = URL(fileURLWithPath: NSHomeDirectory())
    let store = try? SoftwareFamilyStore.loadBundled()
    let glossary = try? Glossary.loadBundled()
    let family = store?.family(matchingPath: node.path, home: home)
    let term = glossary?.terms(in: node.path).first

    let chineseName: String
    if let term, !term.zh.isEmpty {
        chineseName = term.zh
    } else if let family {
        chineseName = family.family.name + " 插件/内容"
    } else {
        chineseName = folderCN(node.name)
    }

    if let family {
        let familyName = family.family.name
        let notes = family.family.notes
        let hosts = family.family.hostBundleIDs
        let hostText = hosts.isEmpty
            ? "族谱没有登记宿主，暂时不能确认它服务于谁。"
            : "它通常给 \(hosts.joined(separator: "、")) 用。"
        return SpaceFileNote(
            title: chineseName,
            englishName: node.name,
            family: familyName,
            purpose: "\(familyName)：\(notes) \(hostText)",
            verdict: "有族谱记录",
            action: "能不能删：先确认这些宿主已经卸载、也没有别的软件共用；确认前只算“可能冗余”，不要直接删。",
            evidence: [
                "命中族谱：\(familyName)",
                "证据：\(family.evidence.note)",
                family.family.hostBundleIDs.isEmpty
                    ? "宿主：未登记"
                    : "宿主：\(family.family.hostBundleIDs.joined(separator: "、"))"
            ]
        )
    }

    if let term, !term.say.isEmpty {
        return SpaceFileNote(
            title: term.zh,
            englishName: node.name,
            family: nil,
            purpose: term.say,
            verdict: "中文词条",
            action: "能不能删：按目录类型判断；这是通用词条，不替代软件族谱。拿不准就先别删。",
            evidence: ["命中中文词条：\(term.en)", "路径：\(node.path)"]
        )
    }

    return SpaceFileNote(
        title: "未收录目录",
        englishName: node.name,
        family: nil,
        purpose: "本地族谱和中文词条都没有这条记录；它可能是项目文件、缓存、某个软件的私有目录，或你自己建的目录。光看英文名不能确认用途。",
        verdict: "待判断",
        action: "能不能删：不能凭名字判断。先别删；如果它很大，先在 Finder 里看上级目录和修改时间。",
        evidence: ["路径：\(node.path)", "建议：补进本地族谱或手动标记"]
    )
}
