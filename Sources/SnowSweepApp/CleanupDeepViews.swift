import SwiftUI
import AppKit
import SnowSweepCore

private enum CleanupSort: String, CaseIterable, Identifiable {
    case size
    case recent
    case name

    var id: String { rawValue }

    var title: String {
        switch self {
        case .size: return "按大小"
        case .recent: return "按时间"
        case .name: return "按名称"
        }
    }
}

private struct CleanupSection: Identifiable {
    let group: CleanupGroup
    let items: [Verdict]
    var id: String { group.rawValue }
    var bytes: Int64 { items.reduce(0) { $0 + $1.item.sizeBytes } }
}

/// 清理页 V0.4.0：分组、搜索、排序、右键、保留选择、证据抽屉。
/// 安全边界不变：只展示 defaultSelected 项，预览 → 二次确认，只移废纸篓。
struct CleanView: View {
    @EnvironmentObject var model: ScanViewModel

    @State private var selected: Set<String> = []
    @State private var search = ""
    @State private var adviceLevel: CleanupAdviceLevel = .conservative
    @State private var groupFilter = "all"
    @State private var sort: CleanupSort = .size
    @State private var detailPath: String?
    @State private var collapsedGroups: Set<CleanupGroup> = []
    @State private var protectedNow: Set<String> = []
    @State private var toast = ""

    /// 安全项 + 需确认项都进列表；需确认项必须由用户显式勾选才会进预览。
    private var cleanable: [Verdict] {
        (model.report?.verdicts ?? []).filter {
            ($0.risk == .safe || $0.risk == .review)
                && !protectedNow.contains($0.item.path)
        }
    }

    private var containsReviewSelection: Bool {
        selectedVerdicts.contains { $0.risk == .review }
    }

    private var filtered: [Verdict] {
        let base = cleanable.filter { verdict in
            if groupFilter != "all", verdict.cleanupGroup.rawValue != groupFilter { return false }
            guard !search.isEmpty else { return true }
            let haystack = [
                verdict.item.path,
                (verdict.item.path as NSString).lastPathComponent,
                verdict.explanation,
                verdict.ruleID ?? "",
                model.ruleName(for: verdict.ruleID) ?? ""
            ].joined(separator: " ")
            return haystack.localizedCaseInsensitiveContains(search)
        }
        return base.sorted(by: sortVerdicts)
    }

    private var sections: [CleanupSection] {
        CleanupGroup.allCases.compactMap { group in
            let items = filtered.filter { $0.cleanupGroup == group }
            return items.isEmpty ? nil : CleanupSection(group: group, items: items)
        }
    }

    private var selectedVerdicts: [Verdict] {
        cleanable.filter { selected.contains($0.item.path) }
    }

    private var selectedBytes: Int64 {
        selectedVerdicts.reduce(0) { $0 + $1.item.sizeBytes }
    }

    private var detailVerdict: Verdict? {
        guard let detailPath else { return nil }
        return cleanable.first { $0.item.path == detailPath }
    }

    private var selectionSummary: String {
        let bytes = ByteCountFormatter.string(fromByteCount: selectedBytes, countStyle: .file)
        return selectedVerdicts.isEmpty ? "尚未选择条目" : "已选 \(selectedVerdicts.count) 项 · \(bytes)"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            if let report = model.report { countRow(report) }
            if model.report != nil { adviceBar }
            if !toast.isEmpty { toastBar }
            if !model.cleanupPreview.isEmpty { cleanupPreviewPanel }
            if model.isScanning { ProgressView(value: model.progressFraction) }

            content
            footer
        }
        .padding(16)
        .onChange(of: model.report?.scannedAt) { _, _ in
            selected.removeAll()
            detailPath = nil
            protectedNow.removeAll()
            toast = ""
        }
        .onChange(of: model.isCleaning) { oldValue, newValue in
            if oldValue && !newValue {
                selected.removeAll()
                detailPath = nil
            }
        }
    }

    private var header: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 3) {
                Text("清理").font(.largeTitle.bold())
                Text(model.report?.cleaningBlockedReason ?? "按分组查看可安全清理项；先预览，再确认移到废纸篓。")
                    .font(.callout).foregroundStyle(.secondary)
            }
            Spacer()
            if model.cleanupPreview.isEmpty {
                Button("预览清理（\(selectedVerdicts.count) 项）") {
                    model.prepareCleanup(paths: selected, allowReview: containsReviewSelection)
                }
                .disabled(!(model.report?.canClean ?? false) || selectedVerdicts.isEmpty || model.isCleaning || model.isScanning)
                .help(model.report?.cleaningBlockedReason ?? "先预览，不会删除任何文件")
            }
        }
    }

    @ViewBuilder
    private var adviceBar: some View {
        if let report = model.report {
            adviceContent(report)
        }
    }

    private func adviceContent(_ report: ScanReport) -> some View {
        let advice = CleanupAdvisor.advice(from: report, level: adviceLevel)
        let bytes = ByteCountFormatter.string(fromByteCount: advice.bytes, countStyle: .file)
        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Image(systemName: "sparkles").foregroundStyle(.blue)
                Text("清理建议").font(.headline)
                Picker("", selection: $adviceLevel) {
                    ForEach(CleanupAdviceLevel.allCases) { level in
                        Text(level.title).tag(level)
                    }
                }
                .pickerStyle(.segmented)
                .frame(width: 210)
                Spacer()
                Text("\(advice.count) 项 · \(bytes)")
                    .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            }
            Text(adviceLevel.subtitle).font(.caption).foregroundStyle(.secondary)
            HStack(spacing: 8) {
                Button("按「\(adviceLevel.title)」建议选择（\(advice.count) 项 · \(bytes)）") {
                    selected = Set(advice.verdicts.map(\.item.path))
                    detailPath = advice.verdicts.first?.item.path
                    toast = "已按「\(adviceLevel.title)」选中 \(advice.count) 项；还没删除，下一步请预览确认。"
                }
                .buttonStyle(.borderedProminent)
                .disabled(advice.verdicts.isEmpty)
                Text("只选中，不删除；预览后还要再确认一次。")
                    .font(.caption2).foregroundStyle(.secondary)
                Spacer()
            }
            if adviceLevel == .aggressive {
                Text("激进档会包含需确认项、旧安装包和废纸篓；逐条看预览，不要闭眼确认。")
                    .font(.caption2).foregroundStyle(.orange)
            }
        }
        .padding(10)
        .background(Color.blue.opacity(0.06), in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.blue.opacity(0.12)))
    }

    private func countRow(_ report: ScanReport) -> some View {
        HStack(spacing: 8) {
            CleanupCountChip(title: "全部", count: report.verdicts.count, color: .secondary)
            CleanupCountChip(title: "安全", count: report.verdicts.filter { $0.risk == .safe }.count, color: .green)
            CleanupCountChip(title: "需确认", count: report.verdicts.filter { $0.risk == .review }.count, color: .orange)
            CleanupCountChip(title: "受保护", count: report.verdicts.filter { $0.risk == .protected }.count, color: .red)
            CleanupCountChip(title: "未知", count: report.verdicts.filter { $0.risk == .unknown }.count, color: .gray)
            Spacer()
            Text(report.canClean ? "扫描完整" : "清理已锁定")
                .font(.caption.weight(.semibold))
                .foregroundStyle(report.canClean ? .green : .orange)
        }
    }

    private var toastBar: some View {
        HStack(spacing: 7) {
            Image(systemName: "info.circle").foregroundStyle(.blue)
            Text(toast).font(.caption)
            Spacer()
            Button("关闭") { toast = "" }.buttonStyle(.borderless).font(.caption)
        }
        .padding(8)
        .background(Color.blue.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
    }

    @ViewBuilder
    private var content: some View {
        if model.isScanning && model.report == nil {
            CleanupEmptyState(
                title: "正在扫描…",
                message: model.currentPath.isEmpty ? "正在读取家目录。扫描只读，不会删除任何文件；完成后才会出现可清理项。" : "正在读取 \(model.currentPath)。扫描只读，不会删除任何文件；完成后才会出现可清理项。",
                actionTitle: "取消扫描"
            ) { model.cancelScan() }
        } else if model.report == nil {
            CleanupEmptyState(
                title: "还没有扫描结果",
                message: "扫描只读，不会删除任何文件；完成后才会出现可清理项。",
                steps: [
                    "扫描只读：只读文件信息与体积，不删除任何文件。",
                    "按七组分类预览：缓存、日志、残留、废纸篓等分开看。",
                    "确认后只移到废纸篓；需要时可在「恢复清单」定位。"
                ],
                actionTitle: "开始扫描"
            ) { model.startScan() }
        } else if model.isScanning && cleanable.isEmpty {
            CleanupEmptyState(
                title: "正在重新扫描…",
                message: "旧结果已不完整，扫描完成后才会出现可清理项。",
                actionTitle: "取消扫描"
            ) { model.cancelScan() }
        } else if cleanable.isEmpty {
            CleanupEmptyState(
                title: model.report?.canClean == true ? "本次没有默认可清理项" : "清理已锁定",
                message: emptyReason,
                actionTitle: model.report?.canClean == true ? "重新扫描" : "查看扫描缺口"
            ) {
                if model.report?.canClean == true {
                    model.startScan()
                } else {
                    AppWindow.showMain(section: "缺口")
                }
            }
        } else {
            filterBar
            HStack(alignment: .top, spacing: 12) {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 12) {
                        if sections.isEmpty {
                            Text("没有匹配的清理项。可以换个关键词或切回「全部分组」。")
                                .font(.callout).foregroundStyle(.secondary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(18)
                        }
                        ForEach(sections) { section in
                            groupCard(section)
                        }
                    }
                    .padding(.bottom, 8)
                }
                .frame(maxHeight: .infinity)

                Divider()
                evidencePanel
                    .frame(width: 330)
                    .frame(maxHeight: .infinity)
            }
            .frame(maxHeight: .infinity)
        }
    }

    private var filterBar: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 8) {
                HStack(spacing: 5) {
                    Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                    TextField("搜中文名、解释、规则或路径", text: $search)
                        .textFieldStyle(.plain)
                    if !search.isEmpty {
                        Button { search = "" } label: {
                            Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 8).padding(.vertical, 5)
                .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 7))
                .frame(maxWidth: 260)

                Picker("分组", selection: $groupFilter) {
                    Text("全部分组").tag("all")
                    ForEach(CleanupGroup.allCases) { group in
                        Text(group.title).tag(group.rawValue)
                    }
                }
                .labelsHidden()
                .frame(width: 155)

                Picker("排序", selection: $sort) {
                    ForEach(CleanupSort.allCases) { option in
                        Text(option.title).tag(option)
                    }
                }
                .labelsHidden()
                .frame(width: 110)

                Spacer()
            }

            HStack(spacing: 8) {
                Button(groupFilter == "all" ? "全选当前筛选" : "全选当前组") {
                    selected.formUnion(filtered.map(\.item.path))
                }
                .disabled(filtered.isEmpty)

                Button("全选安全项") {
                    selected.formUnion(cleanable.map(\.item.path))
                }
                .disabled(cleanable.isEmpty)

                Button("清空选择") {
                    selected.removeAll()
                }
                .disabled(selected.isEmpty)

                Text(selectionSummary)
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                Text("显示 \(filtered.count) / \(cleanable.count) 项（含需确认）")
                    .font(.caption).foregroundStyle(.secondary)
            }
            .controlSize(.small)
        }
    }

    private func groupCard(_ section: CleanupSection) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Button {
                    if collapsedGroups.contains(section.group) {
                        collapsedGroups.remove(section.group)
                    } else {
                        collapsedGroups.insert(section.group)
                    }
                } label: {
                    HStack(spacing: 7) {
                        Image(systemName: collapsedGroups.contains(section.group)
                              ? "chevron.right" : "chevron.down")
                            .font(.caption2).foregroundStyle(.secondary)
                        Image(systemName: icon(for: section.group)).foregroundStyle(.blue)
                        Text(section.group.title).font(.headline)
                        Text("\(section.items.count) 项").font(.caption).foregroundStyle(.secondary)
                        Text(ByteCountFormatter.string(fromByteCount: section.bytes, countStyle: .file))
                            .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                    }
                }
                .buttonStyle(.plain)
                Spacer()
                Button("全选本组") {
                    selected.formUnion(section.items.map(\.item.path))
                }
                .buttonStyle(.borderless)
                .font(.caption)
            }
            .padding(.horizontal, 12).padding(.vertical, 9)
            .background(Color.blue.opacity(0.04))

            if !collapsedGroups.contains(section.group) {
                ForEach(section.items, id: \.item.path) { verdict in
                    cleanupRow(verdict)
                    Divider().padding(.leading, 38)
                }
            }
        }
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.secondary.opacity(0.12)))
    }

    private func cleanupRow(_ verdict: Verdict) -> some View {
        HStack(alignment: .top, spacing: 9) {
            Button {
                toggle(verdict.item.path)
            } label: {
                Image(systemName: selected.contains(verdict.item.path)
                      ? "checkmark.square.fill" : "square")
                    .foregroundStyle(selected.contains(verdict.item.path) ? Color.accentColor : .secondary)
                    .font(.system(size: 15))
            }
            .buttonStyle(.plain)

            VStack(alignment: .leading, spacing: 2) {
                Text(model.chineseLabel(for: verdict.item.path))
                    .font(.body.weight(.medium)).lineLimit(1)
                if model.showEnglishOriginal {
                    Text((verdict.item.path as NSString).lastPathComponent)
                        .font(.caption2.monospaced()).foregroundStyle(.secondary).lineLimit(1)
                }
                Text(verdict.explanation).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                HStack(spacing: 6) {
                    if verdict.risk == .review {
                        Text("需确认")
                            .font(.caption2)
                            .padding(.horizontal, 5).padding(.vertical, 1)
                            .background(Color.orange.opacity(0.12), in: Capsule())
                            .foregroundStyle(.orange)
                    }
                    if let rule = model.ruleName(for: verdict.ruleID) {
                        Text(rule).font(.caption2).foregroundStyle(.blue)
                    }
                    if model.showEnglishOriginal {
                        Text(verdict.item.path)
                            .font(.caption2.monospaced()).foregroundStyle(.tertiary).lineLimit(1)
                    }
                }
            }
            Spacer(minLength: 8)
            VStack(alignment: .trailing, spacing: 2) {
                Text(ByteCountFormatter.string(fromByteCount: verdict.item.sizeBytes, countStyle: .file))
                    .font(.callout.monospacedDigit())
                Text(verdict.item.modifiedAt?.formatted(date: .numeric, time: .omitted) ?? "无时间记录")
                    .font(.caption2).foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
        .background(detailPath == verdict.item.path ? Color.accentColor.opacity(0.08) : Color.clear)
        .contentShape(Rectangle())
        .onTapGesture { detailPath = verdict.item.path }
        .contextMenu {
            Button("快速查看") { quickLook(verdict.item.path) }
            Button("在 Finder 中显示") { reveal(verdict.item.path) }
            Button("复制路径") { copyPath(verdict.item.path) }
            Divider()
            Button(selected.contains(verdict.item.path) ? "取消勾选" : "勾选清理") {
                toggle(verdict.item.path)
            }
            Button("加入保护清单（不再清理）") { protect(verdict.item.path) }
        }
        .help(verdict.explanation)
    }

    @ViewBuilder
    private var evidencePanel: some View {
        if let verdict = detailVerdict {
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        Text("证据").font(.headline)
                        Spacer()
                        Button {
                            toggle(verdict.item.path)
                        } label: {
                            Label(selected.contains(verdict.item.path) ? "已勾选" : "勾选清理",
                                  systemImage: selected.contains(verdict.item.path)
                                  ? "checkmark.square.fill" : "square")
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    }

                    Text(model.chineseLabel(for: verdict.item.path))
                        .font(.title3.weight(.semibold))
                    if model.showEnglishOriginal {
                        Text((verdict.item.path as NSString).lastPathComponent)
                            .font(.caption.monospaced()).foregroundStyle(.secondary)
                        Text(verdict.item.path)
                            .font(.caption.monospaced()).foregroundStyle(.secondary)
                            .textSelection(.enabled)
                    } else {
                        DisclosureGroup("查看原始路径") {
                            Text(verdict.item.path)
                                .font(.caption.monospaced()).foregroundStyle(.secondary)
                                .textSelection(.enabled)
                        }
                        .font(.caption)
                    }

                    HStack(spacing: 6) {
                        Text(verdict.cleanupGroup.title)
                            .font(.caption2).padding(.horizontal, 6).padding(.vertical, 2)
                            .background(Color.blue.opacity(0.10), in: Capsule())
                        Text(verdict.risk == .safe ? "安全 · 无需确认" : "需确认 · 会先预览")
                            .font(.caption2).foregroundStyle(verdict.risk == .safe ? .green : .orange)
                    }

                    if let guide = verdict.guide, !guide.isEmpty {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("处理方式").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                            Text(guide).font(.callout)
                        }
                        .padding(10)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(SnowSkin.accent.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
                        .overlay(RoundedRectangle(cornerRadius: 8).stroke(SnowSkin.accent.opacity(0.16)))
                    }

                    Divider()
                    evidenceLine("大小", ByteCountFormatter.string(fromByteCount: verdict.item.sizeBytes, countStyle: .file))
                    evidenceLine("修改时间", verdict.item.modifiedAt?.formatted(date: .abbreviated, time: .shortened) ?? "系统没有记录")
                    evidenceLine("命中规则", model.ruleName(for: verdict.ruleID) ?? "规则库直接命中")
                    evidenceLine("规则 ID", verdict.ruleID ?? "—")
                    evidenceLine("保护状态", "未命中保护清单；若命中不会出现在本列表")

                    VStack(alignment: .leading, spacing: 4) {
                        Text("规则解释").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                        Text(verdict.explanation).font(.callout)
                    }

                    if !verdict.evidence.isEmpty {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("证据链").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                            ForEach(verdict.evidence, id: \.self) { item in
                                Text(humanEvidence(item))
                                    .font(.caption2.monospaced()).foregroundStyle(.secondary)
                                    .textSelection(.enabled)
                            }
                        }
                    }

                    if let ai = verdict.aiExplanation {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("本地模型解释").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                            Text(ai).font(.callout)
                        }
                    }

                    Divider()
                    HStack(spacing: 6) {
                        Button("快速查看") { quickLook(verdict.item.path) }
                        Button("Finder") { reveal(verdict.item.path) }
                        Button("复制路径") { copyPath(verdict.item.path) }
                    }
                    .controlSize(.small)

                    Button("加入保护清单（不再清理）") {
                        protect(verdict.item.path)
                    }
                    .controlSize(.small)
                    .disabled(protectedNow.contains(verdict.item.path))
                }
                .padding(12)
            }
            .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.secondary.opacity(0.12)))
        } else {
            VStack(alignment: .leading, spacing: 8) {
                Image(systemName: "doc.text.magnifyingglass").font(.system(size: 28)).foregroundStyle(.secondary)
                Text("点一条查看证据").font(.headline)
                Text("这里会显示规则命中、路径、修改时间、模型解释与保护状态；不会提供直接删除按钮。")
                    .font(.callout).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .padding(14)
        }
    }

    private var cleanupPreviewPanel: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(systemName: "eye").foregroundStyle(.blue)
                Text("清理预览").font(.headline)
                Spacer()
                Button("取消") { model.cancelCleanupPreview() }
                    .buttonStyle(.borderless)
            }
            Text(model.cleanupSummaryText).font(.callout)
            Text("以下是即将移到废纸篓的条目；这一步尚未删除。废纸篓内容可随时恢复。")
                .font(.caption).foregroundStyle(.secondary)

            if model.batchGate.requiresConfirmation {
                VStack(alignment: .leading, spacing: 6) {
                    Label("这批清理超过安全规模上限", systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                    ForEach(model.batchGate.reasons, id: \.self) { reason in
                        Text("· \(reason)").font(.caption)
                    }
                    Toggle("我已确认这是一次大批量清理，并会检查废纸篓", isOn: $model.batchAcknowledged)
                        .font(.callout)
                }
                .padding(10)
                .background(Color.orange.opacity(0.10), in: RoundedRectangle(cornerRadius: 8))
            }

            ScrollView {
                ForEach(model.cleanupPreview, id: \.verdict.item.path) { entry in
                    HStack(spacing: 6) {
                        Image(systemName: "checkmark.circle").foregroundStyle(.green)
                        Text(model.showEnglishOriginal
                             ? (entry.verdict.item.path as NSString).lastPathComponent
                             : model.chineseLabel(for: entry.verdict.item.path))
                            .font(.caption.monospaced()).lineLimit(1)
                        Spacer()
                        Text(ByteCountFormatter.string(
                            fromByteCount: entry.verdict.item.sizeBytes, countStyle: .file
                        )).font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            .frame(maxHeight: 100)

            HStack(alignment: .center, spacing: 10) {
                Label("只移到废纸篓，不永久删除", systemImage: "arrow.uturn.backward")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Spacer(minLength: 12)
                Button(role: .destructive) {
                    model.confirmCleanup()
                } label: {
                    HStack(spacing: 7) {
                        if model.isCleaning {
                            ProgressView().controlSize(.small).tint(.white)
                        } else {
                            Image(systemName: "trash.fill")
                        }
                        Text(model.isCleaning ? "正在移到废纸篓…" : "确认移到废纸篓（\(model.cleanupPreview.count) 项）")
                            .fontWeight(.semibold)
                    }
                }
                .buttonStyle(.borderedProminent)
                .tint(.red)
                .controlSize(.large)
                .keyboardShortcut(.defaultAction)
                .disabled(model.isCleaning || !model.batchGate.allows(acknowledged: model.batchAcknowledged))
            }
            .frame(maxWidth: .infinity, alignment: .trailing)
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.blue.opacity(0.06)))
    }

    private var footer: some View {
        HStack {
            Text(model.lastAction).font(.caption).foregroundStyle(.secondary)
            Spacer()
            if model.cleanupPreview.isEmpty {
                Button("预览全部安全项") {
                    model.prepareAllSafeCleanup()
                }
                .disabled(!(model.report?.canClean ?? false) || model.isCleaning || cleanable.isEmpty)
            }
        }
    }

    private var emptyReason: String {
        guard let report = model.report else { return "还没有扫描结果。" }
        if !report.canClean {
            let critical = report.scanGaps.filter { $0.severity == .critical }.count
            if critical > 0 {
                return "报告有 \(critical) 项全盘级缺口（条目截断或权限缺失），按安全规则禁止清理。到「扫描缺口」查看具体位置。"
            }
            return "有 \(report.scanGaps.count) 个位置未能读取，报告不完整。按安全规则，报告不完整时不允许清理。"
        }
        return "本次扫描判定 \(report.verdicts.count) 项，但没有安全项或可勾选的需确认项。受保护项与未知项不会进入清理列表。"
    }

    private func sortVerdicts(_ lhs: Verdict, _ rhs: Verdict) -> Bool {
        switch sort {
        case .size:
            if lhs.item.sizeBytes != rhs.item.sizeBytes { return lhs.item.sizeBytes > rhs.item.sizeBytes }
        case .recent:
            let left = lhs.item.modifiedAt ?? .distantPast
            let right = rhs.item.modifiedAt ?? .distantPast
            if left != right { return left > right }
        case .name:
            let order = (lhs.item.path as NSString).lastPathComponent
                .localizedStandardCompare((rhs.item.path as NSString).lastPathComponent)
            if order != .orderedSame { return order == .orderedAscending }
        }
        return lhs.item.path < rhs.item.path
    }

    private func toggle(_ path: String) {
        if selected.contains(path) {
            selected.remove(path)
        } else {
            selected.insert(path)
        }
        detailPath = path
    }

    private func quickLook(_ path: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/qlmanage")
        process.arguments = ["-p", path]
        do {
            try process.run()
            toast = "已打开快速查看：\((path as NSString).lastPathComponent)"
        } catch {
            NSWorkspace.shared.open(URL(fileURLWithPath: path))
            toast = "快速查看不可用，已用默认应用打开"
        }
    }

    private func reveal(_ path: String) {
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
        toast = "已在 Finder 中定位"
    }

    private func copyPath(_ path: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(path, forType: .string)
        toast = "路径已复制"
    }

    private func protect(_ path: String) {
        model.addProtection(path)
        if model.customProtections.contains(path) {
            protectedNow.insert(path)
            selected.remove(path)
            detailPath = nil
            toast = "已加入保护清单，本报告与后续扫描都不再清理它"
        } else {
            toast = model.errorMessage?.localizedDescription ?? "加入保护清单失败"
        }
    }

    private func icon(for group: CleanupGroup) -> String {
        switch group {
        case .systemCache: return "shippingbox"
        case .logs: return "doc.text"
        case .browser: return "globe"
        case .developer: return "hammer"
        case .trash: return "trash"
        case .installers: return "shippingbox.and.arrow.backward"
        case .other: return "ellipsis.circle"
        }
    }

    private func humanEvidence(_ evidence: String) -> String {
        if evidence.hasPrefix("rule:") { return "命中规则：\(evidence.dropFirst(5))" }
        if evidence.hasPrefix("rebuildCost:") { return "重建成本：\(evidence.dropFirst(12))" }
        if evidence.hasPrefix("path:") { return "保护路径：\(evidence.dropFirst(5))" }
        if evidence == "protected-list" { return "内置保护清单" }
        if evidence == "process-occupied-exact" { return "进程精确占用" }
        if evidence == "process-occupied-approximate" { return "进程可能占用，已降级" }
        if evidence == "no-rule" { return "规则库未覆盖" }
        if evidence.hasPrefix("protection-overridden-by:") {
            return "保护被显式规则放行：\(evidence.dropFirst(25))"
        }
        return evidence
    }

    private func evidenceLine(_ title: String, _ value: String) -> some View {
        HStack(alignment: .top) {
            Text(title).font(.caption).foregroundStyle(.secondary).frame(width: 62, alignment: .leading)
            Text(value).font(.caption).textSelection(.enabled)
            Spacer(minLength: 0)
        }
    }
}

private struct CleanupCountChip: View {
    let title: String
    let count: Int
    let color: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(title).font(.caption2).foregroundStyle(.secondary)
            Text("\(count)").font(.callout.weight(.semibold)).foregroundStyle(color)
        }
        .padding(.horizontal, 10).padding(.vertical, 6)
        .background(color.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
    }
}

private struct CleanupEmptyState: View {
    let title: String
    let message: String
    var steps: [String] = []
    let actionTitle: String
    let action: () -> Void

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "snowflake")
                .font(.system(size: 34))
                .foregroundStyle(.secondary)
            VStack(spacing: 5) {
                Text(title).font(.headline)
                Text(message)
                    .font(.callout).foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .lineSpacing(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if !steps.isEmpty {
                VStack(alignment: .leading, spacing: 7) {
                    ForEach(Array(steps.enumerated()), id: \.offset) { index, step in
                        HStack(alignment: .top, spacing: 8) {
                            Text("\(index + 1)")
                                .font(.caption2.weight(.semibold))
                                .foregroundStyle(.secondary)
                                .frame(width: 17, height: 17)
                                .background(Color.secondary.opacity(0.12), in: Circle())
                            Text(step)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineSpacing(1)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
                .padding(.top, 2)
            }
            if primaryAction {
                Button(actionTitle, action: action)
                    .buttonStyle(.borderedProminent)
                    .padding(.top, 2)
            } else {
                Button(actionTitle, action: action)
                    .padding(.top, 2)
            }
        }
        .padding(24)
        .frame(width: 540)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(Color.primary.opacity(0.07), lineWidth: 1))
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(20)
    }

    private var primaryAction: Bool {
        actionTitle == "开始扫描" || actionTitle == "重新扫描"
    }
}
