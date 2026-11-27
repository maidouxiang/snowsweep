import SwiftUI
import AppKit
import SnowSweepCore
import UniformTypeIdentifiers

/// 规则缺失报告库。这里只读展示已经由首屏保存下来的报告；
/// 不把“接近的规则”当成命中，也不提供任何删除入口。
@MainActor
final class UnknownCasesModel: ObservableObject {
    @Published var cases: [UnknownCase] = []
    @Published var selectedID: String?
    @Published var errorText: String?
    @Published var notice: String = ""
    @Published var pendingDeleteID: String?

    @Published var isHandingOff = false
    @Published var handoffError: String?
    @Published var handoffNotice: String = ""
    @Published var clarify: UnknownHandoffClarification?
    @Published var clarifyAnswers: [String: String] = [:]
    @Published var draft: UnknownHandoffDraft?
    @Published var importedDraft = false
    @Published var rejectedDraftRules: [RuleDraftRejection] = []

    let store = UnknownCaseStore()
    let provider = AssistantProviderSettings.shared

    private var registry: UserRuleRegistry?
    private var builtinURL: URL?
    private var builtinBook: RuleBook?

    var selectedCase: UnknownCase? {
        cases.first { $0.id == selectedID } ?? cases.first
    }

    var canHandoff: Bool {
        provider.route == .openAICompatible && provider.isRemoteReady && !isHandingOff
    }

    var handoffHint: String {
        if provider.route != .openAICompatible {
            return "当前模型接入是「\(provider.route.chineseName)」。云端交接需要 OpenAI 兼容 API；到设置里切换并保存地址、模型名和 Key 后才会启用。"
        }
        if !provider.configuration.remoteIsConfigured {
            return "接口地址或模型名不完整。地址要 HTTPS，模型名不能带空格。"
        }
        if !provider.hasStoredKey {
            return "还没有保存 API Key。不会发出报告。"
        }
        return "只发送这份脱敏报告和内置规则索引；不发送文件正文、聊天记录、照片或文稿。"
    }

    func configure(registry: UserRuleRegistry, builtinURL: URL) {
        guard self.registry == nil else { return }
        self.registry = registry
        self.builtinURL = builtinURL
        self.builtinBook = try? UserRuleRegistry.loadBuiltin(url: builtinURL)
    }

    func reload() {
        do {
            cases = try store.cases(limit: 100)
            if selectedID == nil || !cases.contains(where: { $0.id == selectedID }) {
                selectedID = cases.first?.id
            }
            errorText = nil
        } catch {
            errorText = "读取规则缺失报告失败：\(error.localizedDescription)"
        }
    }

    func select(_ id: String?) {
        selectedID = id
        resetHandoff()
    }

    func copy(_ report: UnknownCase) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(report.markdown, forType: .string)
        notice = "已复制报告 Markdown。对方只能返回规则草稿，不能要求雪执行删除。"
    }

    func requestDelete(_ report: UnknownCase) {
        pendingDeleteID = report.id
    }

    func confirmDelete() {
        guard let id = pendingDeleteID else { return }
        pendingDeleteID = nil
        do {
            try store.remove(id: id)
            reload()
            notice = "已从报告库移除这一条报告；没有删除任何文件，内置规则与保护清单未受影响。"
        } catch {
            errorText = "删除报告失败：\(error.localizedDescription)"
        }
    }

    func startHandoff(_ report: UnknownCase) async {
        guard canHandoff else {
            handoffError = handoffHint
            return
        }
        resetHandoff()
        isHandingOff = true
        handoffNotice = "正在把这份脱敏报告发给已配置的 API；最多追问一轮。"
        defer { isHandingOff = false }

        let client = UnknownHandoffClient(
            provider: provider.configuration,
            apiKey: provider.keyForRequest()
        )
        do {
            let reply = try await client.send(report: report, builtin: builtinBook)
            apply(reply)
        } catch {
            handoffError = error.localizedDescription
            handoffNotice = ""
        }
    }

    func continueHandoff(_ report: UnknownCase) async {
        guard canHandoff else {
            handoffError = handoffHint
            return
        }
        guard let clarify else { return }
        let unanswered = clarify.questions.filter {
            (clarifyAnswers[$0.id] ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        guard unanswered.isEmpty else {
            handoffError = "先把云端追问的 \(clarify.questions.count) 个问题填完；不知道可以写“不确定”。"
            return
        }
        isHandingOff = true
        handoffError = nil
        handoffNotice = "正在带上补充信息请求草稿；这次云端不能再追问。"
        defer { isHandingOff = false }

        let client = UnknownHandoffClient(
            provider: provider.configuration,
            apiKey: provider.keyForRequest()
        )
        do {
            let reply = try await client.send(
                report: report,
                builtin: builtinBook,
                clarification: UnknownHandoffClarificationContext(
                    assistantJSON: clarify.rawJSON,
                    answers: clarifyAnswers
                )
            )
            if case .clarify = reply {
                throw UnknownHandoffError.clarificationExhausted
            }
            apply(reply)
        } catch {
            handoffError = error.localizedDescription
            handoffNotice = ""
        }
    }

    func importDraft(_ report: UnknownCase) {
        guard let registry, let builtinURL, let draft else {
            handoffError = "本地规则目录还没有准备好，这次没有导入。"
            return
        }
        do {
            let summary = try registry.importDrafts(
                jsonData: Data(draft.rawJSON.utf8),
                source: "cloud-handoff-\(report.id.prefix(8))",
                builtinURL: builtinURL
            )
            importedDraft = true
            clarify = nil
            rejectedDraftRules = summary.rejectedRules
            let rejectedNote = summary.rejectedRules.isEmpty
                ? ""
                : "；另有 \(summary.rejectedRules.count) 条因保护路径重叠或单条校验失败未导入"
            handoffNotice = "已导入 \(summary.importedIDs.count) 条云端草稿\(rejectedNote)。安全子集仍是停用状态；去侧栏「规则」试扫成功后，才能逐条启用。"
            handoffError = nil
        } catch {
            importedDraft = false
            rejectedDraftRules = []
            handoffError = "云端草稿没有通过本地导入：\(error.localizedDescription)"
        }
    }

    func saveDraft(_ report: UnknownCase) {
        guard let draft else { return }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "雪-云端规则草稿-\(report.id.prefix(8)).json"
        panel.allowedContentTypes = [.json]
        panel.title = "保存云端规则草稿"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try Data(draft.rawJSON.utf8).write(to: url, options: .atomic)
            handoffNotice = "草稿已保存；导入后仍默认停用，必须试扫后才能启用。"
        } catch {
            handoffError = "保存草稿失败：\(error.localizedDescription)"
        }
    }

    func discardDraft() {
        draft = nil
        importedDraft = false
        rejectedDraftRules = []
        handoffNotice = ""
        handoffError = nil
    }

    func resetHandoff() {
        clarify = nil
        clarifyAnswers = [:]
        draft = nil
        importedDraft = false
        rejectedDraftRules = []
        handoffError = nil
        handoffNotice = ""
    }

    private func apply(_ reply: UnknownHandoffReply) {
        switch reply {
        case let .clarify(clarification):
            clarify = clarification
            clarifyAnswers = Dictionary(
                uniqueKeysWithValues: clarification.questions.map { ($0.id, "") }
            )
            draft = nil
            importedDraft = false
            rejectedDraftRules = []
            handoffError = nil
            handoffNotice = "云端只追问了一轮；回答后必须直接给草稿。"
        case let .draft(value):
            draft = value
            clarify = nil
            clarifyAnswers = [:]
            importedDraft = false
            rejectedDraftRules = []
            handoffError = nil
            handoffNotice = "云端返回 \(value.ruleCount) 条草稿，本地 schema 已通过；还没有导入。"
        }
    }

    func export(_ report: UnknownCase) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "雪-规则缺失-\(report.id.prefix(8)).md"
        panel.allowedContentTypes = [.plainText]
        panel.title = "导出规则缺失报告"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try Data(report.markdown.utf8).write(to: url, options: .atomic)
            try report.jsonData().write(
                to: url.deletingPathExtension().appendingPathExtension("json"),
                options: .atomic
            )
            notice = "已导出 .md 与同名 .json。报告已脱敏。"
        } catch {
            errorText = "导出失败：\(error.localizedDescription)"
        }
    }

    /// 导出 `xue.sample/v1` 样本包。全程本地：读内置规则库算校验值、脱敏、写包、打 zip。
    /// 不扫描、不联网；只把当前这份报告转成可公开的结构化样本。
    func exportSample(_ report: UnknownCase) {
        guard let builtinURL, let builtinBook else {
            errorText = "读不到内置规则库，无法生成样本。"
            return
        }
        do {
            let digest = try SampleExporter.ruleBookDigest(at: builtinURL)
            let sample = SampleExporter.sample(
                from: report,
                ruleBookVersion: builtinBook.version,
                ruleBookSHA256: digest
            )
            let bundle = FileManager.default.temporaryDirectory
                .appendingPathComponent("雪样本-\(report.id.prefix(8))", isDirectory: true)
            try? FileManager.default.removeItem(at: bundle)
            try SampleExporter.write(sample, to: bundle)

            let panel = NSSavePanel()
            panel.nameFieldStringValue = "雪样本-\(report.id.prefix(8)).zip"
            panel.allowedContentTypes = [.zip]
            panel.title = "保存脱敏样本包"
            guard panel.runModal() == .OK, let url = panel.url else { return }

            if FileManager.default.fileExists(atPath: url.path) {
                try FileManager.default.removeItem(at: url)
            }
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
            process.arguments = ["-c", "-k", "--sequesterRsrc", "--keepParent", bundle.path, url.path]
            try process.run()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else {
                throw SampleExportFailure.zipFailed(process.terminationStatus)
            }
            notice = "已导出脱敏样本包。上传前请自己再读一遍 sample.json。"
            NSWorkspace.shared.activateFileViewerSelecting([url])
        } catch {
            errorText = "导出样本失败：\(error.localizedDescription)"
        }
    }

    private enum SampleExportFailure: LocalizedError {
        case zipFailed(Int32)

        var errorDescription: String? {
            switch self {
            case .zipFailed(let code): return "打包失败，ditto 退出码 \(code)"
            }
        }
    }

    func exportTemplate() {
        do {
            let data = RuleDraftImporter.templateData()
            let panel = NSSavePanel()
            panel.nameFieldStringValue = "雪-规则草稿模板.json"
            panel.allowedContentTypes = [.json]
            guard panel.runModal() == .OK, let url = panel.url else { return }
            try data.write(to: url, options: .atomic)
            notice = "已保存草稿模板。导入时仍会过本地 schema、保护检查与试扫门禁。"
        } catch {
            errorText = "保存模板失败：\(error.localizedDescription)"
        }
    }

    func openFolder() {
        try? FileManager.default.createDirectory(
            at: store.fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        if FileManager.default.fileExists(atPath: store.fileURL.path) {
            NSWorkspace.shared.activateFileViewerSelecting([store.fileURL])
        } else {
            NSWorkspace.shared.open(store.fileURL.deletingLastPathComponent())
        }
    }
}

struct UnknownCasesView: View {
    @EnvironmentObject var appModel: ScanViewModel
    @StateObject private var model = UnknownCasesModel()

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .top) {
                    PageHeader(
                        title: "规则缺失",
                        subtitle: "没听懂时留下的只读报告。报告只写原话、最接近的规则和路径线索；不给删除建议，也不自动全盘扫描。"
                    )
                    Spacer()
                    Button("草稿模板") { model.exportTemplate() }
                    Button("打开报告库") { model.openFolder() }
                    Button("刷新") { model.reload() }
                }

                InfoBanner(
                    text: "首屏未命中并点「保存报告」后，报告才会写入本机；用户名已替换为 ~。云端或独立 agent 只能返回 snow-rule-draft 草稿，草稿必须本地校验、试扫，再由你启用。",
                    color: .blue
                )

                if !model.notice.isEmpty {
                    Text(model.notice)
                        .font(.caption)
                        .foregroundStyle(SnowSkin.green)
                }
                if let error = model.errorText {
                    InfoBanner(text: error, color: .red)
                }

                if model.cases.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("还没有保存过规则缺失报告").font(.callout.weight(.semibold))
                        Text("在首屏问一句现有规则接不住的话，出现「这句话我没法直接处理」时，点「保存报告 .md + .json」。雪不会因为没听懂就转成全盘扫描。")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(18)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(.quaternary.opacity(0.22), in: RoundedRectangle(cornerRadius: 10))
                } else {
                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        Text("已保存 \(model.cases.count) 份报告").font(.headline)
                        Spacer()
                        Picker("查看报告", selection: Binding(
                            get: { model.selectedCase?.id },
                            set: { model.select($0) }
                        )) {
                            ForEach(model.cases) { item in
                                Text("\(Self.dateText(item.createdAt)) · \(item.query)")
                                    .tag(Optional(item.id))
                            }
                        }
                        .pickerStyle(.menu)
                        .frame(maxWidth: 420)
                    }

                    if let report = model.selectedCase {
                        reportDetail(report)
                            .padding(16)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(.quaternary.opacity(0.18), in: RoundedRectangle(cornerRadius: 10))
                    }
                }
            }
            .padding(18)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .defaultScrollAnchor(.top)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .id("unknown-cases-page")
        .onAppear {
            model.configure(
                registry: appModel.userRuleRegistry,
                builtinURL: appModel.builtinRulesURL
            )
            model.reload()
        }
        .alert("删除这份报告？", isPresented: Binding(
            get: { model.pendingDeleteID != nil },
            set: { if !$0 { model.pendingDeleteID = nil } }
        )) {
            Button("取消", role: .cancel) { model.pendingDeleteID = nil }
            Button("删除报告", role: .destructive) { model.confirmDelete() }
        } message: {
            Text("只从本机报告库移除这一条记录；不会删除任何文件，也不会改动用户规则、内置规则或保护清单。")
        }
    }

    private func reportDetail(_ report: UnknownCase) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline) {
                Text("规则缺失报告").font(.headline)
                Text(report.id.prefix(8)).font(.caption2.monospaced()).foregroundStyle(.secondary)
                Spacer()
                Button("复制 Markdown") { model.copy(report) }
                Button("导出 .md + .json") { model.export(report) }
                    .buttonStyle(.borderedProminent)
                    .tint(SnowSkin.accent)
                Button("导出样本包（脱敏）") { model.exportSample(report) }
                    .help("生成 xue.sample/v1 样本包：路径模板化、原话脱敏，不含截图与原始路径")
                Button("删除") { model.requestDelete(report) }
                    .foregroundStyle(.red)
            }

            cloudSection(report)

            group("用户原话") {
                Text(report.query)
                    .font(.callout)
                    .textSelection(.enabled)
            }
            group("为什么现有规则没命中") {
                Text(report.reason)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            group("现有规则里最接近的") {
                if report.closestRules.isEmpty {
                    Text("没有找到明显接近的内置规则。").font(.caption).foregroundStyle(.secondary)
                } else {
                    ForEach(report.closestRules) { hint in
                        HStack(alignment: .firstTextBaseline, spacing: 7) {
                            Text(hint.name).font(.caption.weight(.medium))
                            Text(hint.pathPattern)
                                .font(.caption2.monospaced())
                                .foregroundStyle(.secondary)
                            Spacer()
                            Text("接近度 \(hint.score)")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
            group("已知路径线索") {
                ForEach(report.observedPaths, id: \.self) { path in
                    Text(path)
                        .font(.caption.monospaced())
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            group("允许的只读探测") {
                ForEach(report.allowedProbes, id: \.self) { probe in
                    Text("· \(probe)").font(.caption).foregroundStyle(.secondary)
                }
            }

            Text(report.boundary)
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(SnowSkin.overlay(0.05), in: RoundedRectangle(cornerRadius: 9))

            Text("期望返回：snow-rule-draft 草稿。不会直接生效；本地校验通过后仍默认停用，试扫成功才允许启用。")
                .font(.caption2)
                .foregroundStyle(SnowSkin.faint)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func cloudSection(_ report: UnknownCase) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Label("云端交接（可选）", systemImage: "cloud")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(SnowSkin.accent)
                Spacer()
                if model.clarify != nil || model.draft != nil {
                    Button("清空结果") { model.resetHandoff() }
                        .font(.caption)
                }
                Button {
                    Task { await model.startHandoff(report) }
                } label: {
                    Text(model.isHandingOff ? "正在交接…" : "交给云端分析")
                }
                .buttonStyle(.borderedProminent)
                .tint(SnowSkin.accent)
                .disabled(!model.canHandoff)
                .help(model.handoffHint)
            }

            Text(model.handoffHint)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if let error = model.handoffError {
                InfoBanner(text: error, color: .red)
            }
            if !model.handoffNotice.isEmpty {
                Text(model.handoffNotice)
                    .font(.caption)
                    .foregroundStyle(SnowSkin.green)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if let clarification = model.clarify {
                clarifyCard(clarification, report: report)
            }
            if let draft = model.draft {
                draftCard(draft, report: report)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(SnowSkin.accent.opacity(0.06), in: RoundedRectangle(cornerRadius: 10))
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(SnowSkin.accent.opacity(0.16), lineWidth: 1)
        )
    }

    private func clarifyCard(_ clarification: UnknownHandoffClarification, report: UnknownCase) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("云端追问 · \(clarification.questions.count) 个")
                    .font(.callout.weight(.semibold))
                Spacer()
                Text("只追问一轮")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            ForEach(clarification.questions) { question in
                VStack(alignment: .leading, spacing: 4) {
                    Text("\(question.field.chineseName)：\(question.prompt)")
                        .font(.caption.weight(.medium))
                        .fixedSize(horizontal: false, vertical: true)
                    TextField(
                        question.placeholder.isEmpty ? question.field.chineseName : question.placeholder,
                        text: answerBinding(question.id)
                    )
                    .textFieldStyle(.roundedBorder)
                    if !question.why.isEmpty {
                        Text(question.why)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }

            HStack {
                Button("继续分析") {
                    Task { await model.continueHandoff(report) }
                }
                .buttonStyle(.borderedProminent)
                .tint(SnowSkin.accent)
                .disabled(!model.canHandoff)
                Button("取消") { model.resetHandoff() }
            }
            Text("这次回答后，云端必须直接返回草稿，不能再追问。")
                .font(.caption2)
                .foregroundStyle(SnowSkin.faint)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(SnowSkin.overlay(0.05), in: RoundedRectangle(cornerRadius: 9))
    }

    private func draftCard(_ draft: UnknownHandoffDraft, report: UnknownCase) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(alignment: .firstTextBaseline) {
                Text("云端草稿 · \(draft.ruleCount) 条")
                    .font(.callout.weight(.semibold))
                Text(model.importedDraft ? "已导入，待试扫" : "未导入")
                    .font(.caption2)
                    .foregroundStyle(model.importedDraft ? SnowSkin.green : .secondary)
                Spacer()
            }

            if let notes = draft.draft.notes, !notes.isEmpty {
                Text(notes)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            ForEach(draft.draft.rules, id: \.id) { rule in
                VStack(alignment: .leading, spacing: 3) {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text(rule.name).font(.caption.weight(.semibold))
                        Text(rule.id).font(.caption2.monospaced()).foregroundStyle(.secondary)
                        Spacer()
                        Text("\(rule.risk.rawValue) · \(rule.actionType.rawValue)")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    Text(rule.pathPattern)
                        .font(.caption2.monospaced())
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(rule.reason)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(SnowSkin.overlay(0.04), in: RoundedRectangle(cornerRadius: 7))
            }

            if !model.rejectedDraftRules.isEmpty {
                VStack(alignment: .leading, spacing: 5) {
                    Text("未导入 · \(model.rejectedDraftRules.count) 条")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(SnowSkin.orange)
                    ForEach(model.rejectedDraftRules, id: \.id) { rejection in
                        Text(rejection.summary)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(SnowSkin.orange.opacity(0.06), in: RoundedRectangle(cornerRadius: 7))
            }

            HStack {
                Button("导入安全子集（仍需试扫）") { model.importDraft(report) }
                    .buttonStyle(.borderedProminent)
                    .tint(SnowSkin.accent)
                    .disabled(model.importedDraft)
                Button("保存 JSON") { model.saveDraft(report) }
                Button("放弃") { model.discardDraft() }
            }
            Text("只导入通过本地保护检查的安全条目；重叠条目单独列出，不会拖垮整批。导入后默认停用，试扫有结果才允许启用。")
                .font(.caption2)
                .foregroundStyle(SnowSkin.faint)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(SnowSkin.overlay(0.06), in: RoundedRectangle(cornerRadius: 9))
    }

    private func answerBinding(_ id: String) -> Binding<String> {
        Binding(
            get: { model.clarifyAnswers[id] ?? "" },
            set: { model.clarifyAnswers[id] = $0 }
        )
    }

    private func group<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.caption.weight(.semibold))
            content()
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(SnowSkin.overlay(0.04), in: RoundedRectangle(cornerRadius: 9))
    }

    private static func dateText(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "M月d日 HH:mm"
        return formatter.string(from: date)
    }
}
