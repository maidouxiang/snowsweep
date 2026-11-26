import SwiftUI
import AppKit
import SnowSweepCore

// MARK: - 执行结果

struct AssistantCleanupSuccess: Identifiable, Sendable {
    let path: String
    let name: String
    let bytes: Int64
    var id: String { path }
}

struct AssistantCleanupFailure: Identifiable, Sendable {
    let path: String
    let name: String
    let message: String
    var id: String { path }
}

struct AssistantCleanupOutcome: Sendable {
    let trashed: [AssistantCleanupSuccess]
    let failed: [AssistantCleanupFailure]
    let stoppedAfterFailure: Bool

    var totalBytes: Int64 { trashed.reduce(0) { $0 + $1.bytes } }
    var movedCount: Int { trashed.count }
    var failedCount: Int { failed.count }
}

// MARK: - 复用现有安全链

/// 只把计划里的 clean/confirm 候选交给 `ManualDeletionService`。
/// 每项都重新预览、捕获身份，确认时再做严格身份复核，最后只移废纸篓并写审计。
/// 只要有一项失败就停止后续，不把未知状态继续放大。
enum AssistantCleanupRunner {
    static func run(
        items: [AssistantPlanItem],
        protectionCheck: @escaping @Sendable (String) -> Bool
    ) async -> AssistantCleanupOutcome {
        await Task.detached(priority: .userInitiated) {
            let home = NSHomeDirectory()
            let service = ManualDeletionService(
                protectionCheck: protectionCheck,
                allowedRoots: [home]
            )
            var trashed: [AssistantCleanupSuccess] = []
            var failed: [AssistantCleanupFailure] = []
            var stopped = false

            for item in items {
                do {
                    let preview = try service.preview(path: item.path, reason: item.reason)
                    _ = try service.moveToTrash(preview, source: "assistant")
                    trashed.append(
                        AssistantCleanupSuccess(
                            path: item.path,
                            name: item.displayName,
                            bytes: preview.sizeBytes
                        )
                    )
                } catch {
                    failed.append(
                        AssistantCleanupFailure(
                            path: item.path,
                            name: item.displayName,
                            message: error.localizedDescription
                        )
                    )
                    stopped = true
                    break
                }
            }

            return AssistantCleanupOutcome(
                trashed: trashed,
                failed: failed,
                stoppedAfterFailure: stopped
            )
        }.value
    }
}

// MARK: - 计划 / 确认 / 结果

/// 从雪花或输入框进入的同一张计划单。
/// 先摆候选，再让用户勾选“需确认项”，确认后才执行；结果也留在这张单里。
struct AssistantCleanupSheet: View {
    let plan: AssistantPlan
    let protectionCheck: (@Sendable (String) -> Bool)?
    let onFinished: (AssistantCleanupOutcome) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var includeReview = false
    @State private var showDetails = false
    @State private var confirming = false
    @State private var isCleaning = false
    @State private var outcome: AssistantCleanupOutcome?
    @State private var localError: String?

    private var cleanItems: [AssistantPlanItem] {
        plan.items.filter { $0.role == .clean && !$0.isPartial }
    }

    private var confirmItems: [AssistantPlanItem] {
        plan.items.filter { $0.role == .confirm && !$0.isPartial }
    }

    private var partialItems: [AssistantPlanItem] {
        plan.items.filter(\.isPartial)
    }

    private var eligible: [AssistantPlanItem] {
        AssistantCleanupPolicy.eligibleItems(in: plan, includeReview: includeReview)
    }

    private var eligibleBytes: Int64 {
        AssistantCleanupPolicy.totalBytes(of: eligible)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider().overlay(SnowSkin.overlay(0.08))

            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if let outcome {
                        resultView(outcome)
                    } else {
                        planView
                        if isCleaning {
                            cleaningView
                        } else {
                            actionView
                        }
                    }
                }
                .padding(20)
            }
        }
        .frame(minWidth: 580, idealWidth: 620, minHeight: 320, idealHeight: 408)
        .background(SnowSkin.background)
        .confirmationDialog(
            "确认移到废纸篓？",
            isPresented: $confirming,
            titleVisibility: .visible
        ) {
            Button("移到废纸篓（\(eligible.count) 项，\(AssistantBytes.text(eligibleBytes))）", role: .destructive) {
                Task { await clean() }
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("只移入废纸篓，不会永久删除。聊天记录、照片、文稿和系统目录不在候选里；需要时可以从废纸篓找回。")
        }
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(systemName: "snowflake")
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(SnowSkin.gold)
            VStack(alignment: .leading, spacing: 3) {
                Text("这次的清理单")
                    .font(.system(size: 20, weight: .semibold, design: .serif))
                    .foregroundStyle(SnowSkin.text)
                Text("先看清单，再决定；确认后只移废纸篓。")
                    .font(.caption)
                    .foregroundStyle(SnowSkin.faint)
            }
            Spacer()
            Button {
                dismiss()
            } label: {
                Image(systemName: "xmark")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(SnowSkin.dim)
                    .frame(width: 26, height: 26)
                    .background(SnowSkin.overlay(0.06), in: Circle())
            }
            .buttonStyle(.plain)
            .disabled(isCleaning)
            .help("关闭")
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 15)
    }

    private var planView: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 6) {
                Text(plan.headline)
                    .font(.system(size: 24, weight: .semibold, design: .serif))
                    .foregroundStyle(SnowSkin.text)
                    .fixedSize(horizontal: false, vertical: true)
                Text(plan.summary)
                    .font(.system(size: 13.5))
                    .foregroundStyle(SnowSkin.dim)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack(spacing: 7) {
                Image(systemName: "quote.opening")
                    .font(.caption2)
                    .foregroundStyle(SnowSkin.gold)
                Text(plan.intent.interpretation)
                    .font(.caption)
                    .foregroundStyle(SnowSkin.dim)
                    .lineLimit(2)
            }
            .padding(9)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(SnowSkin.overlay(0.045), in: RoundedRectangle(cornerRadius: 9))

            HStack(spacing: 0) {
                statBlock("可清", count: cleanItems.count,
                          bytes: AssistantCleanupPolicy.totalBytes(of: cleanItems), color: SnowSkin.green)
                Divider().overlay(SnowSkin.overlay(0.08))
                statBlock("要你决定", count: confirmItems.count,
                          bytes: AssistantCleanupPolicy.totalBytes(of: confirmItems), color: SnowSkin.orange)
                Divider().overlay(SnowSkin.overlay(0.08))
                statBlock("不动", count: untouchedCount, bytes: nil, color: SnowSkin.faint)
            }
            .padding(.vertical, 11)
            .background(SnowSkin.overlay(0.04), in: RoundedRectangle(cornerRadius: 11))

            if !partialItems.isEmpty {
                Label("有 \(partialItems.count) 项读不全，已自动排除，不会被清理。", systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(SnowSkin.orange)
            }

            if !confirmItems.isEmpty {
                Toggle(isOn: $includeReview) {
                    HStack(spacing: 6) {
                        Text("连需确认项一起处理")
                            .font(.caption.weight(.medium))
                            .foregroundStyle(SnowSkin.text)
                        Text("\(confirmItems.count) 项")
                            .font(.caption2.monospacedDigit())
                            .foregroundStyle(SnowSkin.faint)
                    }
                }
                .toggleStyle(.switch)
                .tint(SnowSkin.gold)
            }

            if let localError {
                Label(localError, systemImage: "xmark.octagon.fill")
                    .font(.caption)
                    .foregroundStyle(.red.opacity(0.85))
            }

            DisclosureGroup(isExpanded: $showDetails) {
                VStack(alignment: .leading, spacing: 10) {
                    if plan.items.isEmpty {
                        Text("这次没有可移入废纸篓的候选。雪只把能确认的缓存、日志和旧安装包列出来；用户数据、聊天记录和系统目录不动。")
                            .font(.caption)
                            .foregroundStyle(SnowSkin.dim)
                    } else {
                        ForEach(plan.items) { item in
                            candidateRow(item)
                        }
                    }

                    if !plan.excluded.isEmpty {
                        VStack(alignment: .leading, spacing: 5) {
                            Label("这次不会动", systemImage: "hand.raised.fill")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(SnowSkin.gold)
                            Text(plan.excluded.prefix(3).map(\.displayName).joined(separator: "、")
                                 + (plan.excluded.count > 3 ? " 等 \(plan.excluded.count) 项" : ""))
                                .font(.caption)
                                .foregroundStyle(SnowSkin.faint)
                        }
                        .padding(10)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(SnowSkin.overlay(0.032), in: RoundedRectangle(cornerRadius: 9))
                    }

                    if !plan.warnings.isEmpty {
                        VStack(alignment: .leading, spacing: 4) {
                            ForEach(plan.warnings.prefix(3), id: \.self) { warning in
                                Label(warning, systemImage: "exclamationmark.triangle")
                                    .font(.caption)
                                    .foregroundStyle(SnowSkin.orange)
                            }
                        }
                    }
                }
                .padding(.top, 8)
            } label: {
                Text("看完整清单")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(SnowSkin.gold)
            }
            .tint(SnowSkin.gold)
        }
    }

    private var untouchedCount: Int {
        plan.items.filter { $0.role == .protected }.count + plan.excluded.count
    }

    private func statBlock(_ title: String, count: Int, bytes: Int64?, color: Color) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.caption2)
                .foregroundStyle(SnowSkin.faint)
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text("\(count) 项")
                    .font(.system(size: 20, weight: .semibold, design: .serif))
                    .foregroundStyle(color)
                if let bytes, bytes > 0 {
                    Text(AssistantBytes.text(bytes))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(SnowSkin.dim)
                }
            }
        }
        .padding(.horizontal, 14)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func candidateRow(_ item: AssistantPlanItem) -> some View {
        let selected = eligible.contains { $0.id == item.id }
        return HStack(alignment: .top, spacing: 10) {
            Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(selected ? SnowSkin.green : SnowSkin.faint)
                .frame(width: 18)

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(item.displayName)
                        .font(.callout.weight(.medium))
                        .foregroundStyle(SnowSkin.text)
                    badge(for: item)
                }
                Text(item.reason)
                    .font(.caption)
                    .foregroundStyle(SnowSkin.dim)
                    .lineLimit(2)
                Text(item.path)
                    .font(.caption2.monospaced())
                    .foregroundStyle(SnowSkin.faint)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            Spacer(minLength: 8)
            Text(item.isPartial ? (item.bytes > 0 ? "≥ \(AssistantBytes.text(item.bytes))" : "未读到") : AssistantBytes.text(item.bytes))
                .font(.callout.monospacedDigit())
                .foregroundStyle(SnowSkin.text)
                .frame(minWidth: 76, alignment: .trailing)
        }
        .padding(9)
        .background(SnowSkin.overlay(selected ? 0.045 : 0.024), in: RoundedRectangle(cornerRadius: 9))
        .opacity(selected ? 1 : 0.66)
    }

    private func badge(for item: AssistantPlanItem) -> some View {
        let text: String
        let color: Color
        if item.isPartial {
            text = "读不全"
            color = SnowSkin.orange
        } else if item.role == .clean {
            text = "可清"
            color = SnowSkin.green
        } else {
            text = includeReview ? "需确认 · 已选" : "需确认"
            color = SnowSkin.orange
        }
        return Text(text)
            .font(.caption2.weight(.semibold))
            .foregroundStyle(color)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(color.opacity(0.13), in: Capsule())
    }

    private var actionView: some View {
        VStack(alignment: .leading, spacing: 10) {
            if protectionCheck == nil {
                Label("保护清单还没加载，这次不执行清理。回到雪后重试。", systemImage: "lock.slash")
                    .font(.caption)
                    .foregroundStyle(SnowSkin.orange)
            }

            HStack(spacing: 10) {
                Button {
                    confirming = true
                } label: {
                    Label(
                        eligible.isEmpty ? "没有可清理项" : "确认移到废纸篓（\(eligible.count) 项）",
                        systemImage: "trash"
                    )
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(CleanupGoldButton())
                .disabled(eligible.isEmpty || protectionCheck == nil)

                Button("取消") { dismiss() }
                    .buttonStyle(CleanupSecondaryButton())
            }

            Text("只移废纸篓，可在「恢复」清单里找回；不会永久删除。")
                .font(.caption2)
                .foregroundStyle(SnowSkin.faint)
        }
        .padding(.top, 2)
    }

    private var cleaningView: some View {
        HStack(spacing: 12) {
            ProgressView()
                .controlSize(.small)
            VStack(alignment: .leading, spacing: 2) {
                Text("正在复核身份并移入废纸篓…")
                    .font(.callout.weight(.medium))
                    .foregroundStyle(SnowSkin.text)
                Text("一项一项做；任何一项失败都会立刻停下。")
                    .font(.caption)
                    .foregroundStyle(SnowSkin.faint)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(SnowSkin.overlay(0.04), in: RoundedRectangle(cornerRadius: 10))
    }

    private func resultView(_ outcome: AssistantCleanupOutcome) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                Image(systemName: outcome.failedCount == 0 ? "checkmark.seal.fill" : "exclamationmark.triangle.fill")
                    .font(.system(size: 30))
                    .foregroundStyle(outcome.failedCount == 0 ? SnowSkin.green : SnowSkin.orange)
                VStack(alignment: .leading, spacing: 3) {
                    Text(outcome.failedCount == 0 ? "已经清完" : "清理中途停下")
                        .font(.system(size: 23, weight: .semibold, design: .serif))
                        .foregroundStyle(SnowSkin.text)
                    Text("移入废纸篓 \(outcome.movedCount) 项 · \(AssistantBytes.text(outcome.totalBytes))"
                         + (outcome.failedCount > 0 ? "；失败 \(outcome.failedCount) 项" : ""))
                        .font(.callout)
                        .foregroundStyle(SnowSkin.dim)
                }
            }

            if !outcome.trashed.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text("已经移走")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(SnowSkin.faint)
                    ForEach(outcome.trashed) { item in
                        HStack {
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundStyle(SnowSkin.green)
                            Text(item.name)
                                .font(.callout)
                                .foregroundStyle(SnowSkin.text)
                            Spacer()
                            Text(AssistantBytes.text(item.bytes))
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(SnowSkin.dim)
                        }
                    }
                }
            }

            if !outcome.failed.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text("没有继续")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(SnowSkin.faint)
                    ForEach(outcome.failed) { item in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(item.name)
                                .font(.callout.weight(.medium))
                                .foregroundStyle(SnowSkin.text)
                            Text(item.message)
                                .font(.caption)
                                .foregroundStyle(SnowSkin.orange)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    if outcome.stoppedAfterFailure {
                        Text("后面的候选没有执行；刷新后可以重新确认。")
                            .font(.caption2)
                            .foregroundStyle(SnowSkin.faint)
                    }
                }
            }

            HStack(spacing: 10) {
                Button("打开废纸篓") { openTrash() }
                    .buttonStyle(CleanupSecondaryButton())
                Spacer()
                Button("完成") { dismiss() }
                    .buttonStyle(CleanupGoldButton())
            }

            Text("没有永久删除。需要找回时，在废纸篓里拖回原位置。")
                .font(.caption2)
                .foregroundStyle(SnowSkin.faint)
        }
    }

    @MainActor
    private func clean() async {
        guard let protectionCheck else {
            localError = "保护清单未加载，已取消。"
            return
        }
        guard !eligible.isEmpty else { return }
        localError = nil
        isCleaning = true
        let items = eligible
        let result = await AssistantCleanupRunner.run(items: items, protectionCheck: protectionCheck)
        isCleaning = false
        outcome = result
        onFinished(result)
    }

    private func openTrash() {
        let trash = URL(fileURLWithPath: NSString(string: "~/.Trash").expandingTildeInPath, isDirectory: true)
        NSWorkspace.shared.open(trash)
    }
}


struct CleanupGoldButton: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(SnowSkin.onAccent)
            .padding(.horizontal, 16)
            .padding(.vertical, 9)
            .background(
                LinearGradient(
                    colors: [SnowSkin.gold, SnowSkin.gold.opacity(0.78)],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                ),
                in: Capsule()
            )
            .opacity(configuration.isPressed ? 0.82 : 1)
    }
}

struct CleanupSecondaryButton: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.caption.weight(.medium))
            .foregroundStyle(SnowSkin.text)
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .background(SnowSkin.overlay(configuration.isPressed ? 0.12 : 0.07), in: Capsule())
            .overlay(Capsule().stroke(SnowSkin.overlay(0.10), lineWidth: 1))
    }
}
