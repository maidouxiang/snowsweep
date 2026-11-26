import Foundation
import AppKit
import SwiftUI
import SnowSweepCore

/// 首屏一句话的只读预览：先听懂，再按目标白名单量体积。
/// 这里不生成删除入口，也不把全盘扫描当作“没听懂”的兜底。
@MainActor
final class IntentPreviewModel: ObservableObject {
    enum Phase: Equatable {
        case idle
        case resolving
        case ready
        case failed
    }

    @Published private(set) var phase: Phase = .idle
    @Published private(set) var intent: CleanIntent?
    @Published private(set) var plan: AssistantPlan?
    @Published private(set) var deltaReport: SpaceDeltaReport?
    @Published private(set) var message: String?
    @Published private(set) var providerNote: String?
    @Published private(set) var unknownCase: UnknownCase?
    @Published private(set) var reportNotice: String?

    private var task: Task<Void, Never>?

    var isResolving: Bool { phase == .resolving }

    func reset() {
        task?.cancel()
        task = nil
        phase = .idle
        intent = nil
        plan = nil
        deltaReport = nil
        message = nil
        providerNote = nil
        unknownCase = nil
        reportNotice = nil
    }

    func resolve(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        task?.cancel()
        phase = .resolving
        intent = nil
        plan = nil
        deltaReport = nil
        message = nil
        providerNote = nil
        unknownCase = nil
        reportNotice = nil

        task = Task { [weak self] in
            guard let self else { return }
            do {
                try await self.resolveNow(trimmed)
            } catch is CancellationError {
                return
            } catch {
                self.phase = .failed
                self.message = error.localizedDescription
            }
        }
    }

    private func resolveNow(_ text: String) async throws {
        let fallback = AssistantIntentParser.parse(text)
        var resolved = fallback
        var note: String?

        let provider = AssistantProviderSettings.shared
        let route = provider.route
        let configuration = provider.configuration

        if route != .rulesOnly {
            let canAsk: Bool
            switch route {
            case .rulesOnly:
                canAsk = false
            case .system:
                canAsk = AssistantModelBridge.isAvailable
                if !canAsk { note = "系统本地模型在这台 Mac 上不可用，这次按本地规则理解。" }
            case .local3B:
                canAsk = configuration.localIsConfigured
                if !canAsk { note = "本地小模型还没配置完整，这次按本地规则理解。" }
            case .openAICompatible:
                canAsk = provider.isRemoteReady
                if !canAsk { note = "云端接口还没配置完整，这次按本地规则理解。" }
            }

            if canAsk {
                let request = ModelHostRequest(
                    text: text,
                    fallback: fallback,
                    route: ModelHostRoute(providerRoute: route),
                    apiConfiguration: route == .system ? nil : configuration,
                    apiKey: route == .openAICompatible ? provider.keyForRequest() : nil,
                    localModelPath: configuration.localModelPath,
                    localRuntimePath: configuration.localRuntimePath,
                    localPort: configuration.localPort
                )
                do {
                    let response = try await ModelHostClient.shared.parse(request)
                    if let modelIntent = response.intent {
                        resolved = modelIntent
                    } else if let failure = response.failure {
                        note = "\(failure)这次按本地规则理解。"
                    }
                    try Task.checkCancellation()
                } catch {
                    note = "\(error.localizedDescription)这次按本地规则理解。"
                }
            }
        }

        // “为什么少了 40G”是确定性的空间对账请求，不让模型把它改成清理或未知。
        if SpaceDeltaQuery.isChangeQuestion(text) {
            resolved = AssistantIntentParser.parse(text)
        }

        try Task.checkCancellation()
        intent = resolved
        providerNote = note

        if SpaceDeltaQuery.isChangeQuestion(text) {
            deltaReport = await Self.makeDeltaReport(for: text)
            plan = nil
            phase = .ready
            return
        }

        guard resolved.goal != .unknown, !resolved.targets.contains(.unknown) else {
            phase = .failed
            let reason = resolved.clarification
                ?? "这句话还没对上已注册的规则。可以说“微信缓存有多大”或“Xcode 编译缓存清掉”。"
            message = reason
            let builtin = Self.builtinBook()
            unknownCase = UnknownCaseReportBuilder.build(
                query: text,
                reason: reason,
                builtin: builtin
            )
            return
        }

        let specs = AssistantCatalog.specs(for: resolved)
        guard !specs.isEmpty else {
            phase = .failed
            switch resolved.targets.first {
            case .memory:
                message = "这是查看内存的请求，不属于清理规则；请到「内存」页看实时压力。"
            case .battery:
                message = "这是查看电池的请求，不属于清理规则；请到「电池」页看健康与循环。"
            case .network:
                message = "这是查看网络的请求，不属于清理规则；请到「网络」页看实时上下行。"
            case .system:
                message = "系统目录只读不删；雪不会生成系统文件候选。"
            default:
                message = "这句话对上了目标，但当前没有可测量的白名单目录。"
            }
            return
        }

        let measurements = try await Self.measure(specs)
        try Task.checkCancellation()
        let disk = await Self.diskFreeBytes()
        let plan = AssistantPlanBuilder.build(
            intent: resolved,
            specs: specs,
            measurements: measurements,
            diskFreeBytes: disk
        )
        self.plan = plan
        phase = .ready
    }

    private static func builtinBook() -> RuleBook? {
        let url = Bundle.main.url(forResource: "rules", withExtension: "json")
            ?? Bundle.main.url(forResource: "rules", withExtension: "json", subdirectory: "Rules")
        guard let url else { return nil }
        return try? UserRuleRegistry.loadBuiltin(url: url)
    }

    /// 保存两个文件：Markdown 给人看，JSON 给独立 agent 读。保存时才写入本机报告库。
    func saveReport() {
        guard let unknownCase else { return }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "雪-规则缺失-\(unknownCase.id.prefix(8)).md"
        panel.allowedContentTypes = [.plainText]
        panel.title = "保存规则缺失报告"
        panel.message = "会同时保存同名 .json；报告已脱敏，不含文件正文。"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try Data(unknownCase.markdown.utf8).write(to: url, options: .atomic)
            let jsonURL = url.deletingPathExtension().appendingPathExtension("json")
            try unknownCase.jsonData().write(to: jsonURL, options: .atomic)
            try UnknownCaseStore().append(unknownCase)
            reportNotice = "已保存 \(url.lastPathComponent) 与 \(jsonURL.lastPathComponent)，并记入本机规则缺失库。"
        } catch {
            reportNotice = "保存报告失败：\(error.localizedDescription)"
        }
    }

    func copyReport() {
        guard let unknownCase else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(unknownCase.markdown, forType: .string)
        reportNotice = "报告 Markdown 已复制。粘贴给独立 agent 时，它只能返回规则草稿。"
    }

    private static func measure(_ specs: [AssistantPathSpec]) async throws -> [AssistantMeasurement] {
        var results: [AssistantMeasurement] = []
        let chunkSize = 4
        var index = 0
        while index < specs.count {
            let end = min(index + chunkSize, specs.count)
            let chunk = Array(specs[index..<end])
            let measured = await withTaskGroup(of: AssistantMeasurement.self) { group in
                for spec in chunk {
                    group.addTask {
                        await Task.detached(priority: .utility) {
                            let path = spec.expandedPath()
                            let exists = FileManager.default.fileExists(atPath: path)
                            guard exists else {
                                return AssistantMeasurement(
                                    specID: spec.id, path: path, bytes: nil,
                                    exists: false, isPartial: false
                                )
                            }
                            let slice = SystemMetrics.directorySize(path, timeout: 45)
                            return AssistantMeasurement(
                                specID: spec.id,
                                path: path,
                                bytes: slice.bytes,
                                exists: true,
                                isPartial: slice.isPartial
                            )
                        }.value
                    }
                }
                var values: [AssistantMeasurement] = []
                for await value in group { values.append(value) }
                return values
            }
            try Task.checkCancellation()
            results.append(contentsOf: measured)
            index = end
        }
        return results
    }

    /// 直接读本机 JSONL；没有快照时返回“数据不足”的报告，不编原因。
    private static func makeDeltaReport(for text: String) async -> SpaceDeltaReport {
        await Task.detached(priority: .utility) {
            let query = SpaceDeltaQuery.parse(text)
            do {
                return try SpaceSnapshotStore().report(for: text)
            } catch {
                return SpaceDeltaDiagnostic.insufficient(
                    query: query,
                    reason: "读取本机快照失败：\(error.localizedDescription)"
                )
            }
        }.value
    }

    private static func diskFreeBytes() async -> Int64? {
        await Task.detached(priority: .utility) {
            SystemMetrics.disk().freeBytes
        }.value
    }
}

/// 只读预览单：没有删除按钮，没有“顺手清理”的入口。
struct IntentPreviewSheet: View {
    let phase: IntentPreviewModel.Phase
    let intent: CleanIntent?
    let plan: AssistantPlan?
    let deltaReport: SpaceDeltaReport?
    let unknownCase: UnknownCase?
    let reportNotice: String?
    let message: String?
    let providerNote: String?
    let onClose: () -> Void
    let onOpenTimeline: () -> Void
    let onSaveReport: () -> Void
    let onCopyReport: () -> Void

    @State private var showPaths = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider().overlay(SnowSkin.overlay(0.08))
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if let deltaReport {
                        SpaceDeltaReportView(report: deltaReport, compact: true, onOpenTimeline: {
                            onOpenTimeline()
                        })
                    } else if let plan {
                        planView(plan)
                    } else if phase == .resolving {
                        HStack(spacing: 10) {
                            ProgressView().controlSize(.small)
                            Text("正在把这句话对到已注册规则……")
                                .font(.callout)
                                .foregroundStyle(SnowSkin.dim)
                        }
                        .padding(.vertical, 16)
                    } else if let unknownCase {
                        unknownCaseView(unknownCase)
                    } else if let message {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("这句话我没法直接处理")
                                .font(.system(size: 20, weight: .semibold, design: .serif))
                                .foregroundStyle(SnowSkin.text)
                            Text(message)
                                .font(.callout)
                                .foregroundStyle(SnowSkin.dim)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        Text("雪不会因为“没听懂”就改成全盘扫描；你可以换一种说法，或点右下角“关闭”后走首屏的「第一次用？先看一份只读体检」。")
                            .font(.caption)
                            .foregroundStyle(SnowSkin.faint)
                            .fixedSize(horizontal: false, vertical: true)
                    } else {
                        Text("还没有结果。")
                            .font(.callout)
                            .foregroundStyle(SnowSkin.dim)
                    }
                }
                .padding(20)
            }
            Divider().overlay(SnowSkin.overlay(0.08))
            footer
        }
        .frame(minWidth: 620, idealWidth: 680, minHeight: 420, idealHeight: 560)
        .background(SnowSkin.background)
    }

    private func unknownCaseView(_ report: UnknownCase) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 8) {
                Text("这句话我没法直接处理")
                    .font(.system(size: 20, weight: .semibold, design: .serif))
                    .foregroundStyle(SnowSkin.text)
                Text(report.reason)
                    .font(.callout)
                    .foregroundStyle(SnowSkin.dim)
                    .fixedSize(horizontal: false, vertical: true)
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("这是一份规则缺失报告，不是删除请求")
                    .font(.callout.weight(.semibold))
                Text("雪不会因为“没听懂”就改成全盘扫描。报告只包含脱敏原话、最接近的内置规则和路径线索；不包含文件正文、聊天记录、照片或文稿。")
                    .font(.caption)
                    .foregroundStyle(SnowSkin.faint)
                    .fixedSize(horizontal: false, vertical: true)
                if !report.observedPaths.isEmpty {
                    Text(report.observedPaths.joined(separator: "  ·  "))
                        .font(.caption2.monospaced())
                        .foregroundStyle(SnowSkin.dim)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(SnowSkin.overlay(0.05), in: RoundedRectangle(cornerRadius: 10))

            if !report.closestRules.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text("现有规则里最接近的").font(.caption.weight(.semibold))
                    ForEach(report.closestRules) { hint in
                        HStack(alignment: .firstTextBaseline, spacing: 6) {
                            Text(hint.name).font(.caption.weight(.medium))
                            Text(hint.pathPattern).font(.caption2.monospaced()).foregroundStyle(SnowSkin.faint)
                            Spacer()
                            Text("接近度 \(hint.score)").font(.caption2).foregroundStyle(SnowSkin.faint)
                        }
                    }
                }
            }

            HStack(spacing: 8) {
                Button("保存报告 .md + .json", action: onSaveReport)
                    .buttonStyle(.borderedProminent)
                    .tint(SnowSkin.accent)
                Button("复制 Markdown", action: onCopyReport)
                Spacer()
            }
            Text("把报告交给独立 agent 或人工补规则。对方只能返回 snow-rule-draft 草稿；草稿会先过本地 schema、保护检查，并且必须试扫后才能启用。")
                .font(.caption2)
                .foregroundStyle(SnowSkin.faint)
                .fixedSize(horizontal: false, vertical: true)
            if let reportNotice {
                Text(reportNotice)
                    .font(.caption)
                    .foregroundStyle(SnowSkin.green)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(systemName: "snowflake")
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(SnowSkin.accent)
            VStack(alignment: .leading, spacing: 3) {
                Text(deltaReport == nil ? "我先这样理解" : "这件事我只对账")
                    .font(.system(size: 20, weight: .semibold, design: .serif))
                    .foregroundStyle(SnowSkin.text)
                Text(deltaReport == nil
                     ? "只读预览：先看范围、体积和风险；这次不执行删除。"
                     : "空间时间线：只比较两次本机快照，不猜原因、不执行删除。")
                    .font(.caption)
                    .foregroundStyle(SnowSkin.faint)
            }
            Spacer()
            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(SnowSkin.dim)
                    .frame(width: 26, height: 26)
                    .background(SnowSkin.overlay(0.06), in: Circle())
            }
            .buttonStyle(.plain)
            .help("关闭")
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 15)
    }

    private func planView(_ plan: AssistantPlan) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 6) {
                Text(plan.headline)
                    .font(.system(size: 24, weight: .semibold, design: .serif))
                    .foregroundStyle(SnowSkin.text)
                    .fixedSize(horizontal: false, vertical: true)
                Text(plan.summary)
                    .font(.system(size: 13))
                    .foregroundStyle(SnowSkin.dim)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack(spacing: 7) {
                Image(systemName: "quote.opening")
                    .font(.caption2)
                    .foregroundStyle(SnowSkin.accent)
                Text(plan.intent.interpretation)
                    .font(.caption)
                    .foregroundStyle(SnowSkin.dim)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 6)
                Text(plan.intent.origin.chineseName)
                    .font(.caption2)
                    .foregroundStyle(SnowSkin.faint)
            }
            .padding(9)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(SnowSkin.overlay(0.045), in: RoundedRectangle(cornerRadius: 9))

            HStack(spacing: 0) {
                stat("可清", plan.items.filter { $0.role == .clean && !$0.isPartial }.count,
                     plan.cleanBytes, SnowSkin.green)
                Divider().overlay(SnowSkin.overlay(0.08))
                stat("需确认", plan.items.filter { $0.role == .confirm && !$0.isPartial }.count,
                     plan.confirmBytes, SnowSkin.orange)
                Divider().overlay(SnowSkin.overlay(0.08))
                stat("只统计", plan.observations.count + plan.excluded.count, nil, SnowSkin.faint)
            }
            .padding(.vertical, 10)
            .background(SnowSkin.overlay(0.04), in: RoundedRectangle(cornerRadius: 11))

            HStack(spacing: 10) {
                Text("只看命中的规则目录")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(SnowSkin.text)
                Spacer()
                Button(showPaths ? "收起原始路径" : "查看原始路径") {
                    showPaths.toggle()
                }
                .buttonStyle(.plain)
                .font(.caption2)
                .foregroundStyle(SnowSkin.accent)
            }

            if plan.items.isEmpty && plan.observations.isEmpty {
                Text("这次没有可统计的候选。雪只按白名单目录量体积，不会扩大到全盘。")
                    .font(.caption)
                    .foregroundStyle(SnowSkin.dim)
            } else {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(plan.items) { item in
                        row(
                            title: item.displayName,
                            bytes: item.bytes,
                          badge: item.role == .clean ? "可清" : "需确认",
                            tint: item.role == .clean ? SnowSkin.green : SnowSkin.orange,
                            detail: item.reason,
                            path: item.path,
                            partial: item.isPartial
                        )
                    }
                    ForEach(plan.observations) { item in
                        row(
                            title: item.displayName,
                            bytes: item.bytes,
                            badge: "只统计",
                            tint: SnowSkin.faint,
                            detail: item.reason,
                            path: nil,
                            partial: false
                        )
                    }
                    ForEach(plan.excluded) { item in
                        row(
                            title: item.displayName,
                            bytes: item.bytes ?? 0,
                            badge: "不动",
                            tint: SnowSkin.faint,
                            detail: item.reason,
                            path: nil,
                            partial: false
                        )
                    }
                }
                .background(SnowSkin.overlay(0.03), in: RoundedRectangle(cornerRadius: 10))
            }

            ForEach(plan.warnings, id: \.self) { warning in
                Label(warning, systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(SnowSkin.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if let providerNote {
                Text(providerNote)
                    .font(.caption2)
                    .foregroundStyle(SnowSkin.faint)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Text("这次只做只读预览，不会移入废纸篓；要清理时仍请到清理页逐项确认。")
                .font(.caption2)
                .foregroundStyle(SnowSkin.faint)
        }
    }

    private func row(title: String, bytes: Int64, badge: String, tint: Color,
                     detail: String, path: String?, partial: Bool) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(title)
                    .font(.callout.weight(.medium))
                    .foregroundStyle(SnowSkin.text)
                Text(badge)
                    .font(.caption2)
                    .foregroundStyle(tint)
                if partial {
                    Text("读不全")
                        .font(.caption2)
                        .foregroundStyle(SnowSkin.orange)
                }
                Spacer()
                Text(AssistantBytes.text(bytes))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(SnowSkin.dim)
            }
            Text(detail)
                .font(.caption2)
                .foregroundStyle(SnowSkin.faint)
                .fixedSize(horizontal: false, vertical: true)
            if showPaths, let path {
                Text(path)
                    .font(.caption2.monospaced())
                    .foregroundStyle(SnowSkin.faint.opacity(0.8))
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .overlay(alignment: .bottom) {
            Divider().overlay(SnowSkin.overlay(0.06))
        }
    }

    private func stat(_ title: String, _ count: Int, _ bytes: Int64?, _ tint: Color) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.caption2)
                .foregroundStyle(SnowSkin.faint)
            HStack(alignment: .firstTextBaseline, spacing: 5) {
                Text("\(count)")
                    .font(.system(size: 17, weight: .semibold, design: .monospaced))
                    .foregroundStyle(tint)
                if let bytes {
                    Text(AssistantBytes.text(bytes))
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(SnowSkin.dim)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 12)
    }

    private var footer: some View {
        HStack(spacing: 10) {
            Text(footerRuleLabel)
                .font(.caption2)
                .foregroundStyle(SnowSkin.faint)
            Spacer()
            Button("关闭", action: onClose)
                .buttonStyle(.borderedProminent)
                .tint(SnowSkin.accent)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
    }

    private var footerRuleLabel: String {
        if deltaReport != nil { return "规则：space-delta 空间变化账单" }
        if unknownCase != nil { return "规则：未命中，只生成报告" }
        if phase == .resolving { return "正在理解这句话" }
        guard let intent, !intent.targetSummary.isEmpty else { return "没有命中规则" }
        return "规则：\(intent.targetSummary)"
    }
}
