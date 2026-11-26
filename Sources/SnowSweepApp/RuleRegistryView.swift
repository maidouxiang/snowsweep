import SwiftUI
import AppKit
import SnowSweepCore
import UniformTypeIdentifiers

/// 用户规则注册表的界面模型。
/// 只读写规则 JSON 与启用状态；试扫只读，不执行删除。
@MainActor
final class RuleRegistryModel: ObservableObject {
    @Published var catalog = UserRuleCatalog()
    @Published var enabledIDs: Set<String> = []
    @Published var builtinRuleCount = 0
    @Published var errorText: String?
    @Published var notice: String = ""
    @Published var trialResults: [String: RuleTrialResult] = [:]
    @Published var trialingID: String?
    @Published var isImporting = false
    @Published var draftIDs: Set<String> = []
    @Published var trialedIDs: Set<String> = []

    private var registry: UserRuleRegistry?
    private var builtinURL: URL?
    private var builtinBook: RuleBook?

    var directoryPath: String { registry?.directoryURL.path ?? "" }

    func configure(registry: UserRuleRegistry, builtinURL: URL) {
        guard self.registry == nil else { return }
        self.registry = registry
        self.builtinURL = builtinURL
        self.builtinBook = try? UserRuleRegistry.loadBuiltin(url: builtinURL)
        self.builtinRuleCount = builtinBook?.rules.count ?? 0
        reload()
    }

    func reload() {
        guard let registry else { return }
        do {
            catalog = try registry.loadCatalog()
            let state = registry.loadStateLenient()
            let ids = Set(catalog.rules.map(\.id))
            enabledIDs = Set(state.enabledIDs.filter { ids.contains($0) })
            draftIDs = Set((state.draftIDs ?? []).filter { ids.contains($0) })
            trialedIDs = Set((state.trialedIDs ?? []).filter { ids.contains($0) })
            errorText = nil
        } catch {
            errorText = "读取用户规则失败：\(error.localizedDescription)"
        }
    }

    func importFile(_ url: URL) {
        guard let registry, let builtinURL else { return }
        let accessed = url.startAccessingSecurityScopedResource()
        defer { if accessed { url.stopAccessingSecurityScopedResource() } }
        do {
            let data = try Data(contentsOf: url)
            let summary = try registry.importRules(
                jsonData: data,
                source: url.lastPathComponent,
                builtinURL: builtinURL
            )
            let count = summary.importedIDs.count
            let replaced = summary.replacedIDs.isEmpty
                ? ""
                : "；覆盖同 id \(summary.replacedIDs.count) 条"
            notice = "已导入 \(count) 条用户规则\(replaced)。导入后默认停用，请先试扫，再逐条启用。"
            errorText = nil
            reload()
            trialResults.removeAll()
        } catch {
            errorText = "导入失败：\(error.localizedDescription)"
        }
    }

    func importDraftFile(_ url: URL) {
        guard let registry, let builtinURL else { return }
        isImporting = true
        defer { isImporting = false }
        let accessed = url.startAccessingSecurityScopedResource()
        defer { if accessed { url.stopAccessingSecurityScopedResource() } }
        do {
            let data = try Data(contentsOf: url)
            let summary = try registry.importDrafts(
                jsonData: data,
                source: url.lastPathComponent,
                builtinURL: builtinURL
            )
            let rejectedNote = summary.rejectedRules.isEmpty
                ? ""
                : "；\(summary.rejectedRules.count) 条未导入：\(summary.rejectedRules.map(\.summary).joined(separator: "；"))"
            notice = "已导入 \(summary.importedIDs.count) 条规则草稿，安全子集默认停用，必须先试扫，才能逐条启用\(rejectedNote)。"
            errorText = nil
            reload()
            trialResults.removeAll()
        } catch {
            errorText = "草稿导入失败：\(error.localizedDescription)"
        }
    }

    func exportDraftTemplate() {
        do {
            let data = RuleDraftImporter.templateData()
            let panel = NSSavePanel()
            panel.nameFieldStringValue = "雪-规则草稿模板.json"
            panel.allowedContentTypes = [.json]
            guard panel.runModal() == .OK, let url = panel.url else { return }
            try data.write(to: url, options: .atomic)
            notice = "已保存草稿模板；改完后用「导入规则草稿」回到本地校验。"
        } catch {
            errorText = "保存草稿模板失败：\(error.localizedDescription)"
        }
    }

    func setEnabled(_ id: String, _ enabled: Bool) {
        guard let registry else { return }
        do {
            try registry.setEnabled(id, enabled: enabled)
            notice = enabled ? "已启用 \(id)；下次扫描和手动删除都会立即生效。" : "已停用 \(id)。"
            errorText = nil
            reload()
        } catch {
            errorText = "切换启用状态失败：\(error.localizedDescription)"
        }
    }

    func remove(_ id: String) {
        guard let registry else { return }
        do {
            try registry.remove(id)
            trialResults[id] = nil
            notice = "已删除用户规则 \(id)；内置规则与保护清单未受影响。"
            errorText = nil
            reload()
        } catch {
            errorText = "删除失败：\(error.localizedDescription)"
        }
    }

    func trial(_ rule: Rule) {
        guard let builtinBook, let registry else {
            errorText = "内置规则库或用户规则目录读取失败，无法试扫。"
            return
        }
        trialingID = rule.id
        let home = NSHomeDirectory()
        Task {
            let result = await Task.detached(priority: .utility) {
                UserRuleRegistry.trial(rule: rule, builtin: builtinBook, home: home)
            }.value
            trialResults[rule.id] = result
            trialingID = nil
            if draftIDs.contains(rule.id), result.errorMessage == nil {
                do {
                    try registry.markTrialed(rule.id)
                    notice = "草稿 \(rule.id) 已试扫通过，现在可以启用；启用后仍需逐次确认删除。"
                    reload()
                } catch {
                    errorText = "记录试扫状态失败：\(error.localizedDescription)"
                }
            }
        }
    }

    func openRulesFolder() {
        guard let registry else { return }
        try? registry.ensureDirectory()
        NSWorkspace.shared.activateFileViewerSelecting([registry.directoryURL])
    }

    func exportRules() {
        guard let registry else { return }
        do {
            let data = try registry.exportCatalog()
            let panel = NSSavePanel()
            panel.nameFieldStringValue = "雪-用户规则.json"
            panel.allowedContentTypes = [.json]
            guard panel.runModal() == .OK, let url = panel.url else { return }
            try data.write(to: url, options: .atomic)
            notice = "已导出用户规则；启用状态不会跟着走。"
        } catch {
            errorText = "导出失败：\(error.localizedDescription)"
        }
    }
}

struct RuleRegistryView: View {
    private enum ImportMode { case rule, draft }

    @EnvironmentObject var model: ScanViewModel
    @StateObject private var registryModel = RuleRegistryModel()
    @State private var showImporter = false
    @State private var importMode: ImportMode = .rule
    @State private var pendingDelete: Rule?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .top) {
                    PageHeader(
                        title: "规则",
                        subtitle: "规则是数据：导入 JSON 即可新增，不需要重新打包 App。导入后默认停用，先试扫，再决定是否启用。"
                    )
                    Spacer()
                    Button("草稿模板") { registryModel.exportDraftTemplate() }
                    Button("打开规则目录") { registryModel.openRulesFolder() }
                    Button("导入规则 JSON") {
                        importMode = .rule
                        showImporter = true
                    }
                    .disabled(registryModel.isImporting)
                    Button("导入规则草稿") {
                        importMode = .draft
                        showImporter = true
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(registryModel.isImporting)
                }

                InfoBanner(
                    text: "内置 \(registryModel.builtinRuleCount) 条规则；用户 \(registryModel.catalog.rules.count) 条，已启用 \(registryModel.enabledIDs.count) 条。用户规则只能落在 ~/ 家目录；内置保护规则与保护清单不可被覆盖。",
                    color: .blue
                )

                if !registryModel.notice.isEmpty {
                    Text(registryModel.notice)
                        .font(.caption)
                        .foregroundStyle(SnowSkin.green)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(10)
                        .background(SnowSkin.green.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
                }

                if let error = registryModel.errorText {
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.red)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(10)
                        .background(Color.red.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
                }

                HStack {
                    Text("我导入的规则").font(.headline)
                    Text("\(registryModel.catalog.rules.count) 条").font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button("刷新") { registryModel.reload() }
                    Button("导出") { registryModel.exportRules() }
                        .disabled(registryModel.catalog.rules.isEmpty)
                }

                if registryModel.catalog.rules.isEmpty {
                    VStack(alignment: .leading, spacing: 7) {
                        Text("还没有用户规则").font(.callout.weight(.semibold))
                        Text("云端或独立 agent 只能给你规则草稿；把草稿保存成 JSON 后在这里导入。草稿会先过本地 schema、路径与保护检查，再进入停用列表。")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .padding(16)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(.quaternary.opacity(0.22), in: RoundedRectangle(cornerRadius: 10))
                } else {
                    VStack(spacing: 0) {
                        ForEach(Array(registryModel.catalog.rules.enumerated()), id: \.element.id) { index, rule in
                            ruleRow(rule)
                            if index < registryModel.catalog.rules.count - 1 {
                                Divider().padding(.leading, 12)
                            }
                        }
                    }
                    .background(.quaternary.opacity(0.22), in: RoundedRectangle(cornerRadius: 10))
                }

                HStack(spacing: 12) {
                    Image(systemName: "checkmark.shield")
                        .foregroundStyle(SnowSkin.accent)
                    Text("启用后的用户规则会参与下一次扫描；草稿还多一道门禁：没试扫就不能启用。删除仍由你逐次确认，模型与规则都不能直接执行删除。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(SnowSkin.accent.opacity(0.07), in: RoundedRectangle(cornerRadius: 10))
            }
            .padding(18)
        }
        .onAppear {
            registryModel.configure(
                registry: model.userRuleRegistry,
                builtinURL: model.builtinRulesURL
            )
        }
        .fileImporter(
            isPresented: $showImporter,
            allowedContentTypes: [.json, .plainText],
            allowsMultipleSelection: false
        ) { result in
            if case let .success(urls) = result, let url = urls.first {
                if importMode == .draft {
                    registryModel.importDraftFile(url)
                } else {
                    registryModel.importFile(url)
                }
            } else if case let .failure(error) = result {
                registryModel.errorText = "选择文件失败：\(error.localizedDescription)"
            }
        }
        .confirmationDialog(
            "删除用户规则「\(pendingDelete?.name ?? "")」？",
            isPresented: Binding(
                get: { pendingDelete != nil },
                set: { if !$0 { pendingDelete = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("删除规则", role: .destructive) {
                if let id = pendingDelete?.id { registryModel.remove(id) }
                pendingDelete = nil
            }
            Button("取消", role: .cancel) { pendingDelete = nil }
        } message: {
            Text("只从用户规则目录删除这一条数据；不会删除任何文件，也不会改动内置规则和保护清单。")
        }
    }

    @ViewBuilder
    private func ruleRow(_ rule: Rule) -> some View {
        let enabled = registryModel.enabledIDs.contains(rule.id)
        let trial = registryModel.trialResults[rule.id]
        VStack(alignment: .leading, spacing: 7) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(rule.name)
                    .font(.callout.weight(.semibold))
                riskBadge(rule.risk)
                Text(rule.actionType.rawValue)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                if registryModel.draftIDs.contains(rule.id) {
                    Text(registryModel.trialedIDs.contains(rule.id) ? "草稿·已试扫" : "草稿·待试扫")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(registryModel.trialedIDs.contains(rule.id) ? SnowSkin.green : SnowSkin.orange)
                }
                if enabled {
                    Text("已启用")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(SnowSkin.green)
                } else {
                    Text("未启用")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Toggle("", isOn: Binding(
                    get: { enabled },
                    set: { registryModel.setEnabled(rule.id, $0) }
                ))
                .toggleStyle(.switch)
                .labelsHidden()
                .controlSize(.small)
                .help(enabled ? "停用这条规则" : (registryModel.draftIDs.contains(rule.id) && !registryModel.trialedIDs.contains(rule.id) ? "草稿必须先试扫" : "启用这条规则"))
            }

            Text(rule.pathPattern)
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(.secondary)
                .textSelection(.enabled)

            HStack(spacing: 8) {
                Text(rule.reason)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                Spacer(minLength: 8)
                if let trial {
                    trialBadge(trial)
                }
                Button(registryModel.trialingID == rule.id ? "试扫中…" : "试扫") {
                    registryModel.trial(rule)
                }
                .controlSize(.small)
                .disabled(registryModel.trialingID != nil)
                Button("删除") { pendingDelete = rule }
                    .controlSize(.small)
                    .buttonStyle(.plain)
                    .foregroundStyle(.red)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }

    private func riskBadge(_ risk: RiskLevel) -> some View {
        let color: Color
        switch risk {
        case .safe: color = SnowSkin.green
        case .review: color = SnowSkin.orange
        case .protected: color = .red
        case .unknown: color = .secondary
        }
        return Text(risk.rawValue)
            .font(.caption2.weight(.semibold))
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .foregroundStyle(color)
            .background(color.opacity(0.12), in: Capsule())
    }

    @ViewBuilder
    private func trialBadge(_ result: RuleTrialResult) -> some View {
        if let error = result.errorMessage {
            Text("试扫失败：\(error)")
                .font(.caption2)
                .foregroundStyle(.red)
                .lineLimit(2)
        } else {
            let hits = result.itemCount == 0
                ? "0 命中"
                : "\(result.itemCount) 项 · \(AssistantBytes.text(result.totalBytes))"
            let gaps = result.gapsCount > 0 ? " · \(result.gapsCount) 缺口" : ""
            Text("试扫 \(hits)\(gaps)\(result.truncated ? " · 已截断" : "")")
                .font(.caption2)
                .foregroundStyle(result.itemCount == 0 ? .secondary : SnowSkin.accent)
                .lineLimit(1)
        }
    }
}
