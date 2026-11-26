import SwiftUI
import AppKit
import SnowSweepCore

/// V0.9.0 大文件与重复：先做多维判读，再由用户逐项确认后移入废纸篓。
/// 页面不会自动勾选，也不会跳过确认；所有删除都复用身份复核与审计链。
struct StorageReviewView: View {
    @EnvironmentObject var monitor: SystemMonitor
    @EnvironmentObject var model: ScanViewModel
    @State private var filter = LargeFileFilter()
    @State private var dimension: StorageDimension?
    @State private var showAllLargeFiles = false
    @State private var showAllDuplicateGroups = false
    @State private var prompt: ManualDeletionPrompt?
    @State private var notice: String?
    @State private var noticeIsError = false

    private let home = NSHomeDirectory()

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .short
        formatter.timeStyle = .none
        return formatter
    }()

    private var visibleLargeFiles: [LargeFileRecord] {
        let base = filter.apply(to: monitor.bigFiles)
        guard let dimension else { return base }
        return base.filter { $0.matches(dimension, home: home) }
    }

    private var totalLargeBytes: Int64 {
        visibleLargeFiles.reduce(0) { $0 + $1.bytes }
    }

    private var dimensions: [StorageDimensionSummary] {
        StorageDimensionSummary.summarize(monitor.bigFiles, home: home)
    }


    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .top) {
                    PageHeader(
                        title: "大文件与重复",
                        subtitle: "按体积、类型、时间和路径找旧文件；重复文件按同体积 + SHA-256 成组核对。判读只给候选，删除必须逐项确认，且只进废纸篓。"
                    )
                    Spacer()
                    Button {
                        Task { await monitor.refreshBigFiles() }
                    } label: {
                        Label("重新查找", systemImage: "arrow.clockwise")
                    }
                    .disabled(monitor.isAnalyzing)
                    Button {
                        Task { await monitor.findDuplicates() }
                    } label: {
                        Label("查找重复文件", systemImage: "doc.on.doc")
                    }
                    .disabled(monitor.isFindingDuplicates || monitor.isAnalyzing)
                }

                if let notice {
                    InfoBanner(text: notice, color: noticeIsError ? .red : .green)
                }

                HStack(spacing: 12) {
                    MetricTile(
                        title: "当前筛选的大文件",
                        value: "\(visibleLargeFiles.count) 项",
                        foot: "\(SystemMetrics.bytesText(totalLargeBytes)) · 共扫描 \(monitor.bigFiles.count) 个 100 MB+ 文件",
                        color: .primary
                    )
                    MetricTile(
                        title: "重复文件",
                        value: monitor.duplicateReview.map { "\($0.groupCount) 组" } ?? "未核对",
                        foot: monitor.duplicateReview.map {
                            "重复占用 \(SystemMetrics.bytesText($0.recoverableBytes)) · 可逐组保留一份"
                        } ?? "需要手动开始；不会自动选择文件",
                        color: monitor.duplicateReview == nil ? .secondary : .orange
                    )
                }

                dimensionCard

                largeFilesCard

                duplicateCard

                InfoBanner(text: "判读只根据路径、类型和修改时间，不读取文件内容，也不假装知道“最近打开”。重复组只按内容哈希成组；照片副本、项目备份和不同用途的文件都可能被归到一组，删除前仍要看路径和项目归属。",
                           color: .blue)
            }
            .padding(18)
        }
        .task {
            if monitor.bigFiles.isEmpty && !monitor.isAnalyzing {
                await monitor.refreshBigFiles()
            }
        }
        .sheet(isPresented: $showAllLargeFiles) {
            LargeFileSheet(
                records: visibleLargeFiles,
                filter: $filter,
                dateFormatter: Self.dateFormatter,
                onDelete: { requestDelete($0) }
            )
        }
        .sheet(isPresented: $showAllDuplicateGroups) {
            DuplicateGroupSheet(
                groups: monitor.duplicateReview?.groups ?? [],
                onDelete: requestDeleteDuplicate,
                onDeleteExtras: requestDeleteExtras
            )
        }
        .manualDeletionSheet(prompt: $prompt) { result in
            switch result {
            case let .success(count):
                noticeIsError = false
                notice = "已将 \(count) 项移到废纸篓。可在废纸篓或恢复清单核对。"
                Task {
                    await monitor.refreshBigFiles()
                    if monitor.duplicateReview != nil { await monitor.findDuplicates() }
                }
            case let .failure(error):
                noticeIsError = true
                notice = error.localizedDescription
            }
        }
    }

    private var dimensionCard: some View {
        ModuleCard {
            VStack(alignment: .leading, spacing: 9) {
                HStack {
                    Text("多维候选").font(.headline)
                    Text("只看“值得先核对”的维度，不自动选择、不自动删除")
                        .font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    if dimension != nil {
                        Button("显示全部") {
                            dimension = nil
                            filter = LargeFileFilter()
                            dimension = nil
                        }
                        .buttonStyle(.link)
                        .font(.caption)
                    }
                }
                LazyVGrid(columns: [
                    GridItem(.flexible()), GridItem(.flexible()),
                    GridItem(.flexible()), GridItem(.flexible())
                ], spacing: 8) {
                    ForEach(dimensions, id: \.dimension.id) { item in
                        Button {
                            dimension = item.dimension
                            filter = LargeFileFilter(minMegabytes: 100, sort: .modified)
                        } label: {
                            VStack(alignment: .leading, spacing: 3) {
                                HStack(spacing: 5) {
                                    Text(item.dimension.title)
                                        .font(.caption.weight(.semibold))
                                        .foregroundStyle(dimension == item.dimension ? Color.accentColor : Color.primary)
                                    Spacer()
                                    if dimension == item.dimension {
                                        Image(systemName: "checkmark.circle.fill")
                                            .font(.caption2).foregroundStyle(.tint)
                                    }
                                }
                                Text(item.count == 0 ? "没有命中" : "\(item.count) 项 · \(SystemMetrics.bytesText(item.bytes))")
                                    .font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
                                Text(item.dimension.detail)
                                    .font(.caption2).foregroundStyle(.tertiary)
                                    .lineLimit(3)
                                    .multilineTextAlignment(.leading)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            .frame(maxWidth: .infinity, minHeight: 84, alignment: .topLeading)
                            .padding(8)
                            .background(
                                dimension == item.dimension
                                    ? Color.accentColor.opacity(0.09)
                                    : Color.primary.opacity(0.035),
                                in: RoundedRectangle(cornerRadius: 8)
                            )
                            .overlay(
                                RoundedRectangle(cornerRadius: 8)
                                    .stroke(dimension == item.dimension
                                            ? Color.accentColor.opacity(0.4)
                                            : Color.primary.opacity(0.06), lineWidth: 1)
                            )
                        }
                        .buttonStyle(.plain)
                        .disabled(item.count == 0)
                    }
                }
            }
        }
    }

    private var largeFilesCard: some View {
        ModuleCard {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .firstTextBaseline) {
                    Text("大文件").font(.headline)
                    Text(dimension.map { "当前维度：\($0.title)" } ?? "按体积、类型、时间和路径判读；不自动选")
                        .font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Text("\(visibleLargeFiles.count) / \(monitor.bigFiles.count) 项")
                        .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                }

                if monitor.isAnalyzing {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text(monitor.analyzeNote).font(.caption).foregroundStyle(.secondary)
                    }
                } else {
                    if !monitor.bigFilesUnreadable.isEmpty {
                        let names = monitor.bigFilesUnreadable
                            .map { URL(fileURLWithPath: $0).lastPathComponent }
                            .joined(separator: "、")
                        InfoBanner(text: "系统未允许雪读取：\(names)。列表只包含其余个人目录；可到「权限清单」逐目录授权后重新查找。",
                                   color: .red)
                    }
                    if monitor.bigFilesTimedOut {
                        InfoBanner(text: "部分个人目录没有在 12 秒时限内读完，列表只包含已读到的文件；可点右上角「重新查找」再试。",
                                   color: .orange)
                    }
                }

                largeFileFilterBar

                Divider()

                if monitor.bigFiles.isEmpty {
                    HStack(spacing: 8) {
                        Image(systemName: "tray").foregroundStyle(.secondary)
                        Text(monitor.isAnalyzing ? "正在查找 100 MB 以上的文件…" : "还没有大文件数据。点「重新查找」开始。")
                            .font(.callout).foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, minHeight: 80)
                } else if visibleLargeFiles.isEmpty {
                    HStack(spacing: 8) {
                        Image(systemName: "line.3.horizontal.decrease.circle").foregroundStyle(.secondary)
                        Text("当前条件下没有大文件。可以放宽体积下限、类型或时间。")
                            .font(.callout).foregroundStyle(.secondary)
                        Button("清除筛选") {
                            filter = LargeFileFilter()
                            dimension = nil
                        }
                        .buttonStyle(.link)
                    }
                    .frame(maxWidth: .infinity, minHeight: 70)
                } else {
                    VStack(spacing: 0) {
                        ForEach(Array(visibleLargeFiles.prefix(8))) { file in
                            LargeFileRow(
                                file: file,
                                dateFormatter: Self.dateFormatter,
                                judgement: file.judgement(home: home),
                                onDelete: { requestDelete(file) }
                            )
                            if file.id != visibleLargeFiles.prefix(8).last?.id {
                                Divider().opacity(0.55)
                            }
                        }
                    }
                    if visibleLargeFiles.count > 8 {
                        Button {
                            showAllLargeFiles = true
                        } label: {
                            HStack {
                                Text("查看全部 \(visibleLargeFiles.count) 项")
                                Image(systemName: "chevron.right").font(.caption)
                            }
                            .font(.callout)
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    private var largeFileFilterBar: some View {
        HStack(spacing: 8) {
            Picker("体积", selection: $filter.minMegabytes) {
                Text("≥ 100 MB").tag(100)
                Text("≥ 500 MB").tag(500)
                Text("≥ 1 GB").tag(1000)
                Text("≥ 2 GB").tag(2000)
            }
            .labelsHidden()
            .frame(width: 108)

            Picker("类型", selection: $filter.kind) {
                ForEach(LargeFileKind.allCases) { kind in
                    Text(kind.title).tag(kind)
                }
            }
            .labelsHidden()
            .frame(width: 126)

            Picker("时间", selection: $filter.age) {
                ForEach(LargeFileAge.allCases) { age in
                    Text(age.title).tag(age)
                }
            }
            .labelsHidden()
            .frame(width: 116)

            Picker("排序", selection: $filter.sort) {
                ForEach(LargeFileSort.allCases) { sort in
                    Text(sort.title).tag(sort)
                }
            }
            .labelsHidden()
            .frame(width: 160)

            Spacer(minLength: 4)

            TextField("搜索文件名或路径", text: $filter.query)
                .textFieldStyle(.roundedBorder)
                .frame(width: 160)
        }
    }

    private func requestDelete(_ file: LargeFileRecord) {
        makePrompt(paths: [file.path], title: "把这个大文件移到废纸篓？",
                   message: "判读：\(file.judgement(home: home).title)。\(file.judgement(home: home).reason)",
                   source: "大文件", caution: .normal)
    }

    private func requestDeleteDuplicate(_ file: DuplicateFileRecord) {
        _ = file
        makePrompt(paths: [file.path], title: "把这一份重复文件移到废纸篓？",
                   message: "同组里还有内容相同的副本；请确认这一份不是项目正在引用的那一份。",
                   source: "重复文件", caution: .uncertain)
    }

    private func requestDeleteExtras(_ group: DuplicateGroup) {
        guard let keeper = group.files.min(by: { $0.modifiedAt < $1.modifiedAt }) else { return }
        let extras = group.files.filter { $0.path != keeper.path }
        guard !extras.isEmpty else { return }
        makePrompt(
            paths: extras.map(\.path),
            title: "保留一份，其余移到废纸篓？",
            message: "将保留最早修改的一份：\(keeper.name)。其余 \(extras.count) 份内容相同，逐项复核后移入废纸篓。",
            source: "重复文件",
            caution: .batch
        )
    }

    private func makePrompt(paths: [String], title: String, message: String,
                            source: String, caution: ManualDeletionPrompt.Caution) {
        guard !paths.isEmpty else { return }
        let check = model.manualProtectionCheck
        Task {
            let result = await Task.detached(priority: .userInitiated) {
                () -> Result<[ManualDeletionPlan], Error> in
                let service = ManualDeletionService(protectionCheck: check)
                var plans: [ManualDeletionPlan] = []
                for path in paths {
                    do {
                        plans.append(try service.preview(path: path, reason: source))
                    } catch {
                        return .failure(error)
                    }
                }
                return .success(plans)
            }.value
            await MainActor.run {
                switch result {
                case let .success(plans):
                    prompt = ManualDeletionPrompt(
                        plans: plans,
                        title: title,
                        message: message,
                        source: source,
                        caution: caution
                    )
                case let .failure(error):
                    noticeIsError = true
                    notice = error.localizedDescription
                }
            }
        }
    }

    private var duplicateCard: some View {
        ModuleCard {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .firstTextBaseline) {
                    Text("重复文件").font(.headline)
                    Text("逐项确认 · 只进废纸篓").font(.caption)
                        .foregroundStyle(.orange)
                    Spacer()
                    if monitor.duplicateReview != nil {
                        Button {
                            Task { await monitor.findDuplicates() }
                        } label: {
                            Label("重新核对", systemImage: "arrow.clockwise")
                                .font(.caption)
                        }
                        .buttonStyle(.borderless)
                        .disabled(monitor.isFindingDuplicates)
                    }
                }

                Text("并发扫描桌面、文稿、下载、图片、影片、音乐里 1–600 MB 的同体积候选；只对候选读取内容算 SHA-256，最多核对 80 个、合计 3 GB。慢目录不会拖住其他目录。")
                    .font(.caption).foregroundStyle(.secondary)

                if monitor.isFindingDuplicates {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text(monitor.duplicateNote).font(.callout).foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 8)
                } else if let review = monitor.duplicateReview {
                    HStack(spacing: 16) {
                        Label("\(review.groupCount) 组", systemImage: "doc.on.doc")
                        Label("\(review.fileCount) 个文件", systemImage: "doc")
                        Label("重复占用 \(SystemMetrics.bytesText(review.recoverableBytes))", systemImage: "internaldrive")
                        if review.truncated {
                            Text("候选过多，已优先核对高浪费组").font(.caption).foregroundStyle(.orange)
                        }
                        if review.timedOut {
                            Text("枚举超时，结果可能不完整").font(.caption).foregroundStyle(.orange)
                        }
                    }
                    .font(.callout)

                    Text(monitor.duplicateNote).font(.caption).foregroundStyle(.secondary)

                    if review.groups.isEmpty {
                        HStack(spacing: 8) {
                            Image(systemName: "checkmark.seal").foregroundStyle(.green)
                            Text("没有发现同体积且内容相同的文件。")
                                .font(.callout)
                        }
                        .frame(maxWidth: .infinity, minHeight: 54)
                    } else {
                        VStack(spacing: 8) {
                            ForEach(review.groups.prefix(4)) { group in
                                DuplicateGroupRow(
                                    group: group,
                                    onDelete: requestDeleteDuplicate,
                                    onDeleteExtras: requestDeleteExtras
                                )
                            }
                        }
                        if review.groups.count > 4 {
                            Button {
                                showAllDuplicateGroups = true
                            } label: {
                                HStack {
                                    Text("查看全部 \(review.groups.count) 组")
                                    Image(systemName: "chevron.right").font(.caption)
                                }
                                .font(.callout)
                            }
                            .buttonStyle(.plain)
                            .foregroundStyle(.secondary)
                        }
                    }
                } else {
                    HStack(spacing: 12) {
                        Image(systemName: "doc.on.doc").font(.system(size: 24)).foregroundStyle(.secondary)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("还没有核对过重复文件").font(.callout)
                            Text("核对需要读文件内容，可能花几十秒；核对本身不删除。")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("开始核对") {
                            Task { await monitor.findDuplicates() }
                        }
                        .disabled(monitor.isFindingDuplicates)
                    }
                    .padding(.vertical, 6)
                }
            }
        }
    }
}

private struct LargeFileRow: View {
    let file: LargeFileRecord
    let dateFormatter: DateFormatter
    let judgement: LargeFileJudgement
    let onDelete: (() -> Void)?

    var body: some View {
        HStack(spacing: 9) {
            Image(systemName: icon)
                .font(.callout)
                .foregroundStyle(.secondary)
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(file.name).font(.callout).lineLimit(1)
                    Text(judgement.title)
                        .font(.caption2)
                        .foregroundStyle(badgeColor)
                        .padding(.horizontal, 6).padding(.vertical, 1)
                        .background(badgeColor.opacity(0.11), in: Capsule())
                }
                Text(NSString(string: (file.path as NSString).deletingLastPathComponent).abbreviatingWithTildeInPath)
                    .font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                if judgement.isDimensionCandidate {
                    Text(judgement.reason)
                        .font(.caption2).foregroundStyle(.tertiary).lineLimit(1)
                }
            }
            Spacer(minLength: 6)
            Text(file.kind.title)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 6).padding(.vertical, 2)
                .background(Color.secondary.opacity(0.10), in: Capsule())
            Text(dateFormatter.string(from: file.modifiedAt))
                .font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
            Text(SystemMetrics.bytesText(file.bytes))
                .font(.caption.monospacedDigit()).frame(width: 68, alignment: .trailing)
            Button("显示") {
                NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: file.path)])
            }
            .buttonStyle(.link)
            .font(.caption)
            if let onDelete {
                Button("移废纸篓", action: onDelete)
                    .buttonStyle(.link)
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .help("先确认路径和用途，再按身份复核后移入废纸篓；不会永久删除")
            }
        }
        .padding(.vertical, 6)
        .help(judgement.reason)
    }

    private var badgeColor: Color {
        switch judgement.level {
        case .priority: return .orange
        case .review: return .blue
        case .personal: return .green
        case .recent: return .secondary
        }
    }

    private var icon: String {
        switch file.kind {
        case .video: return "film"
        case .image: return "photo"
        case .audio: return "waveform"
        case .archive: return "archivebox"
        case .document: return "doc.text"
        case .installer: return "shippingbox"
        default: return "doc"
        }
    }
}

private struct DuplicateGroupRow: View {
    let group: DuplicateGroup
    let onDelete: ((DuplicateFileRecord) -> Void)?
    let onDeleteExtras: ((DuplicateGroup) -> Void)?

    private var keeper: DuplicateFileRecord? {
        group.files.min { $0.modifiedAt < $1.modifiedAt }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Image(systemName: "equal.circle").foregroundStyle(.orange)
                Text("\(group.count) 份相同内容")
                    .font(.callout.weight(.medium))
                Text("每份 \(SystemMetrics.bytesText(group.bytes))")
                    .font(.caption).foregroundStyle(.secondary)
                Text("重复占用 \(SystemMetrics.bytesText(group.recoverableBytes))")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                Text("SHA-256 \(group.digest.prefix(10))…")
                    .font(.caption2.monospaced()).foregroundStyle(.tertiary)
                if let onDeleteExtras {
                    Button("保留一份，其余移废纸篓") {
                        onDeleteExtras(group)
                    }
                    .buttonStyle(.link)
                    .font(.caption)
                    .foregroundStyle(.orange)
                }
            }
            ForEach(group.files.prefix(4)) { file in
                HStack(spacing: 7) {
                    Image(systemName: "doc").font(.caption2).foregroundStyle(.secondary)
                    Text(file.name).font(.caption).lineLimit(1)
                    Text(NSString(string: (file.path as NSString).deletingLastPathComponent).abbreviatingWithTildeInPath)
                        .font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                    if file.path == keeper?.path {
                        Text("最早修改 · 建议保留")
                            .font(.caption2)
                            .foregroundStyle(.green)
                            .padding(.horizontal, 5).padding(.vertical, 1)
                            .background(Color.green.opacity(0.09), in: Capsule())
                    }
                    Spacer()
                    Button("显示") {
                        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: file.path)])
                    }
                    .buttonStyle(.link).font(.caption2)
                    if let onDelete {
                        Button("删除这份") { onDelete(file) }
                            .buttonStyle(.link)
                            .font(.caption2)
                            .foregroundStyle(.orange)
                    }
                }
            }
            if group.count > 4 {
                Text("另有 \(group.count - 4) 个同内容文件，展开「全部」查看并逐份确认。")
                    .font(.caption2).foregroundStyle(.secondary)
            }
        }
        .padding(10)
        .background(Color.secondary.opacity(0.05), in: RoundedRectangle(cornerRadius: 8))
    }
}

private struct LargeFileSheet: View {
    let records: [LargeFileRecord]
    @Binding var filter: LargeFileFilter
    let dateFormatter: DateFormatter
    let onDelete: (LargeFileRecord) -> Void

    private let home = NSHomeDirectory()

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("全部大文件").font(.title2.bold())
                    Text("\(records.count) 项 · \(SystemMetrics.bytesText(records.reduce(0) { $0 + $1.bytes })) · 逐项确认后只进废纸篓")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Picker("体积", selection: $filter.minMegabytes) {
                    Text("≥ 100 MB").tag(100)
                    Text("≥ 500 MB").tag(500)
                    Text("≥ 1 GB").tag(1000)
                    Text("≥ 2 GB").tag(2000)
                }
                .frame(width: 130)
                Picker("类型", selection: $filter.kind) {
                    ForEach(LargeFileKind.allCases) { Text($0.title).tag($0) }
                }
                .frame(width: 140)
                Picker("时间", selection: $filter.age) {
                    ForEach(LargeFileAge.allCases) { Text($0.title).tag($0) }
                }
                .frame(width: 130)
            }
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(records) { file in
                        LargeFileRow(
                            file: file,
                            dateFormatter: dateFormatter,
                            judgement: file.judgement(home: home),
                            onDelete: { onDelete(file) }
                        )
                        Divider().opacity(0.5)
                    }
                }
            }
        }
        .padding(18)
        .frame(minWidth: 860, minHeight: 520)
    }
}

private struct DuplicateGroupSheet: View {
    let groups: [DuplicateGroup]
    let onDelete: (DuplicateFileRecord) -> Void
    let onDeleteExtras: (DuplicateGroup) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("全部重复文件组").font(.title2.bold())
            Text("\(groups.count) 组 · 内容相同不代表用途相同；可保留一份，其余逐项确认后移入废纸篓。")
                .font(.callout).foregroundStyle(.secondary)
            ScrollView {
                LazyVStack(spacing: 8) {
                    ForEach(groups) { group in
                        DuplicateGroupRow(
                            group: group,
                            onDelete: onDelete,
                            onDeleteExtras: onDeleteExtras
                        )
                    }
                }
            }
        }
        .padding(18)
        .frame(minWidth: 880, minHeight: 560)
    }
}
