import SwiftUI
import AppKit
import SnowSweepCore

/// 雪的首屏：只有一个对话框。
/// 说一句话 → 雪花呼吸 → 全盘体检 → 一二三四项决策单（旁边就能移废纸篓）。
/// 底层专家模式完全保留，这一层只负责“问、看、决定”。
struct LandingView: View {
    @Binding var showLanding: Bool
    @Binding var selection: String

    @EnvironmentObject private var model: ScanViewModel
    @StateObject private var audit = LandingAuditModel()
    @StateObject private var intentPreview = IntentPreviewModel()

    @State private var query = ""
    @State private var trashRequest: TrashRequest?
    @State private var showEvidence = false
    @State private var showNoviceReport = false
    @State private var showIntentPreview = false
    @State private var noviceScanPending = false
    @State private var poemIndex = 0
    @State private var poemHovered = false
    @State private var promptIndex = 0
    @AppStorage("snow.noviceReport.seen") private var noviceSeen = false
    @AppStorage("snow.appearance") private var appearance: SnowTheme = .snowDay
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @FocusState private var inputFocused: Bool

    private var trimmedQuery: String {
        query.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var compact: Bool { audit.phase != .idle }

    private var poemAnimation: Animation {
        reduceMotion ? .easeInOut(duration: 0.18) : .easeInOut(duration: 0.55)
    }

    private var promptAnimation: Animation {
        reduceMotion ? .easeInOut(duration: 0.16) : .easeInOut(duration: 0.28)
    }

    private var poemTransition: AnyTransition {
        reduceMotion ? .opacity : .opacity.combined(with: .offset(y: 6))
    }

    var body: some View {
        ZStack {
            SnowSkin.background
            RadialGradient(
                colors: [SnowSkin.accent.opacity(0.075), .clear],
                center: .top,
                startRadius: 0,
                endRadius: 760
            )
            .ignoresSafeArea()
            LinearGradient(
                colors: [.clear, SnowSkin.accent.opacity(0.035)],
                startPoint: .top,
                endPoint: .bottom
            )
            .ignoresSafeArea()

            VStack(spacing: 0) {
                brandBar
                content
                bottomBar
            }
            .padding(.horizontal, compact ? 30 : 42)
            .padding(.top, 22)
            .padding(.bottom, 14)
            .frame(maxWidth: 1120)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .preferredColorScheme(appearance.colorScheme)
        .task(id: audit.phase) {
            guard audit.phase == .idle, !reduceMotion else { return }
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 7_000_000_000)
                guard !Task.isCancelled, audit.phase == .idle, !inputFocused, !poemHovered else { continue }
                withAnimation(poemAnimation) {
                    poemIndex = (poemIndex + 1) % SnowPoem.all.count
                }
            }
        }
        .task(id: audit.phase) {
            guard audit.phase == .idle, !reduceMotion else { return }
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 6_000_000_000)
                guard !Task.isCancelled, audit.phase == .idle, trimmedQuery.isEmpty else { continue }
                withAnimation(promptAnimation) {
                    promptIndex = (promptIndex + 1) % PromptSample.all.count
                }
            }
        }
        .onAppear {
            poemIndex = Int.random(in: 0..<SnowPoem.all.count)
            promptIndex = 0
            if audit.phase == .idle { inputFocused = true; deselectInputText() }
        }
        .onReceive(NotificationCenter.default.publisher(for: .snowOpenNoviceReport)) { _ in
            switch audit.phase {
            case .idle:
                startNoviceReport()
            case .results:
                noviceSeen = true
                showNoviceReport = true
            default:
                break
            }
        }
        .onChange(of: audit.phase) { _, phase in
            if phase == .results, noviceScanPending {
                noviceScanPending = false
                showNoviceReport = true
            } else if phase == .failed {
                noviceScanPending = false
            }
            if phase == .idle {
                showEvidence = false
                inputFocused = true
                deselectInputText()
            } else if phase == .breathing {
                showEvidence = false
            }
        }
        .sheet(isPresented: $showNoviceReport, onDismiss: {
            noviceSeen = true
        }) {
            NoviceReportSheet(
                report: noviceReport,
                spacesLoading: audit.spacesLoading,
                onClose: {
                    noviceSeen = true
                    showNoviceReport = false
                },
                onShowCleanable: {
                    noviceSeen = true
                    showNoviceReport = false
                    showEvidence = true
                }
            )
        }
        .sheet(isPresented: $showIntentPreview) {
            IntentPreviewSheet(
                phase: intentPreview.phase,
                intent: intentPreview.intent,
                plan: intentPreview.plan,
                deltaReport: intentPreview.deltaReport,
                unknownCase: intentPreview.unknownCase,
                reportNotice: intentPreview.reportNotice,
                message: intentPreview.message,
                providerNote: intentPreview.providerNote,
                onClose: { showIntentPreview = false },
                onOpenTimeline: {
                    showIntentPreview = false
                    AppWindow.showMain(section: "空间分析")
                },
                onSaveReport: { intentPreview.saveReport() },
                onCopyReport: { intentPreview.copyReport() }
            )
        }
        .alert(item: $trashRequest) { request in
            switch request {
            case let .single(finding):
                return Alert(
                    title: Text("把「\(finding.title)」移入废纸篓？"),
                    message: Text("\(AssistantBytes.text(finding.bytes))。只移到废纸篓，不永久删除；随时可以还原。\(audit.result?.reportComplete == false ? "\n\n这次全盘没读全，删除已锁定。" : "")"),
                    primaryButton: .destructive(Text("移入废纸篓")) {
                        guard audit.result?.reportComplete != false else { return }
                        Task { _ = await audit.trashOne(finding, using: model) }
                    },
                    secondaryButton: .cancel(Text("先不动"))
                )
            case let .batch(findings):
                let bytes = findings.reduce(0) { $0 + $1.bytes }
                return Alert(
                    title: Text("把 \(findings.count) 项可清项移入废纸篓？"),
                    message: Text("共 \(AssistantBytes.text(bytes))。逐项复核后只移废纸篓；中途任何一项失败会立即停手。"),
                    primaryButton: .destructive(Text("全部移入废纸篓")) {
                        guard audit.result?.reportComplete != false else { return }
                        Task { await audit.trashBatch(findings, using: model) }
                    },
                    secondaryButton: .cancel(Text("先不动"))
                )
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.willCloseNotification)) { note in
            guard let window = note.object as? NSWindow,
                  window.identifier?.rawValue.contains("main") == true
            else { return }
            audit.releaseForSilent()
        }
    }

    // MARK: - 顶栏

    private var brandBar: some View {
        HStack(alignment: .center, spacing: 10) {
            Image(systemName: "snowflake")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(SnowSkin.gold.opacity(0.86))
            Text("雪")
                .font(.system(size: 16, weight: .semibold, design: .serif))
                .foregroundStyle(SnowSkin.dim)
            Text("SNOWSWEEP")
                .font(.system(size: 8, weight: .semibold))
                .tracking(2.4)
                .foregroundStyle(SnowSkin.faint)
            Spacer()
            if audit.phase == .results {
                Button {
                    openTrash()
                } label: {
                    Label("废纸篓", systemImage: "trash")
                        .font(.system(size: 11))
                        .foregroundStyle(SnowSkin.faint)
                }
                .buttonStyle(.plain)
                .help("在 Finder 里打开废纸篓")
            }
            Text("V\(AppVersion.current.number)")
                .font(.system(size: 9, weight: .medium, design: .monospaced))
                .foregroundStyle(SnowSkin.faint.opacity(0.8))
        }
    }

    // MARK: - 对话框

    private var composer: some View {
        VStack(spacing: 9) {
            HStack(spacing: 12) {
                Image(systemName: "snowflake")
                    .font(.system(size: compact ? 12 : 15, weight: .semibold))
                    .foregroundStyle(SnowSkin.accent.opacity(0.9))

                ZStack(alignment: .leading) {
                    if trimmedQuery.isEmpty {
                        Text(PromptSample.all[promptIndex].text)
                            .font(.system(size: compact ? 15 : 19, weight: .medium, design: .serif))
                            .foregroundStyle(SnowSkin.faint.opacity(0.86))
                            .lineLimit(1)
                            .minimumScaleFactor(0.78)
                            .id(promptIndex)
                            .transition(.opacity)
                            .allowsHitTesting(false)
                            .accessibilityHidden(true)
                    }

                    TextField("", text: $query)
                        .textFieldStyle(.plain)
                        .font(.system(size: compact ? 16 : 24, weight: .medium, design: .serif))
                        .foregroundStyle(SnowSkin.text)
                        .focused($inputFocused)
                        .onSubmit { submit() }
                        .accessibilityLabel("试着对我说清理垃圾")
                        .frame(maxWidth: .infinity, minHeight: compact ? 22 : 32, alignment: .leading)
                }
                .frame(maxWidth: .infinity)
                .animation(promptAnimation, value: promptIndex)

                Button {
                    submit()
                } label: {
                    Image(systemName: (audit.isBusy || intentPreview.isResolving) ? "hourglass" : "arrow.right")
                        .font(.system(size: compact ? 11 : 13, weight: .semibold))
                        .foregroundStyle(trimmedQuery.isEmpty ? SnowSkin.faint : SnowSkin.onAccent)
                        .frame(width: compact ? 30 : 38, height: compact ? 30 : 38)
                        .background(
                            trimmedQuery.isEmpty ? AnyShapeStyle(SnowSkin.overlay(0.05)) : AnyShapeStyle(SnowSkin.accent),
                            in: Circle()
                        )
                }
                .buttonStyle(.plain)
                .disabled(trimmedQuery.isEmpty || intentPreview.isResolving)
                .help("先听懂这句话，只量命中的规则目录，不执行删除")
            }
            .padding(.horizontal, compact ? 16 : 20)
            .frame(height: compact ? 50 : 62)
            .background(
                RoundedRectangle(cornerRadius: compact ? 13 : 16, style: .continuous)
                    .fill(SnowSkin.field)
            )
            .overlay(
                RoundedRectangle(cornerRadius: compact ? 13 : 16, style: .continuous)
                    .stroke(inputFocused ? SnowSkin.accent.opacity(0.55) : SnowSkin.fieldBorder,
                            lineWidth: inputFocused ? 1.2 : 1)
            )
            .shadow(color: SnowSkin.snowShadow.opacity(inputFocused ? 0.65 : 0.35),
                    radius: compact ? 16 : 24, y: 8)
            .frame(maxWidth: compact ? 760 : 680)

            if intentPreview.isResolving {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.mini)
                    Text("正在听懂这句话；首次唤醒本地小模型约需十几秒")
                        .font(.caption2)
                        .foregroundStyle(SnowSkin.faint)
                }
                .transition(.opacity)
            }
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: - 主内容

    @ViewBuilder
    private var content: some View {
        switch audit.phase {
        case .idle:
            idleContent
        case .breathing:
            breathingContent
        case .results:
            resultsContent
        case .failed:
            failedContent
        }
    }

    private var idleContent: some View {
        GeometryReader { geo in
            VStack(spacing: 0) {
                Spacer(minLength: 8)
                VStack(spacing: 16) {
                    SnowCrystal(size: 66)
                        .padding(.bottom, 2)

                    poemBlock
                        .onHover { poemHovered = $0 }

                    composer

                    Button {
                        startNoviceReport()
                    } label: {
                        HStack(spacing: 7) {
                            Image(systemName: "sparkle.magnifyingglass")
                                .font(.system(size: 10.5))
                                .foregroundStyle(SnowSkin.accent.opacity(0.92))
                            Text("第一次用？先看一份只读体检")
                                .font(.system(size: 10.5, weight: .medium))
                                .foregroundStyle(SnowSkin.accent.opacity(0.88))
                            if !noviceSeen {
                                Text("新")
                                    .font(.system(size: 8, weight: .semibold))
                                    .foregroundStyle(SnowSkin.onAccent)
                                    .padding(.horizontal, 5)
                                    .padding(.vertical, 2)
                                    .background(SnowSkin.accent, in: Capsule())
                            }
                        }
                    }
                    .buttonStyle(.plain)
                    .help("全盘只读体检：先告诉你电脑里有什么，不删任何文件")

                    Text("只读体检 · 只移废纸篓 · 不碰你的文件")
                        .font(.system(size: 10.5))
                        .foregroundStyle(SnowSkin.faint)
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: 780)
                .frame(maxWidth: .infinity)
                Spacer(minLength: 16)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            // 整组内容含下方说明与入口，几何居中会让输入框偏下；按内容高度上提，
            // 让对话框落在视觉中心，同时保持窄窗不裁切。
            // V0.9.19：在 V0.9.16 的 0.085 基础上再上提一档，上限从 68 放宽到 82。
            .offset(y: -min(82, max(34, geo.size.height * 0.100)))
        }
    }

    private var poemBlock: some View {
        let poem = SnowPoem.all[poemIndex]
        return VStack(spacing: 7) {
            ZStack {
                HStack(spacing: 14) {
                    Text(poem.first)
                    Rectangle()
                        .fill(SnowSkin.hairline.opacity(0.9))
                        .frame(width: 1, height: 17)
                    Text(poem.second)
                }
                .font(.system(size: 21, weight: .regular, design: .serif))
                .tracking(0.7)
                .foregroundStyle(SnowSkin.text.opacity(0.9))
                .lineLimit(1)
                .minimumScaleFactor(0.78)
                .id(poemIndex)
                .transition(poemTransition)
                .accessibilityElement(children: .combine)
                .accessibilityLabel("\(poem.first)，\(poem.second)")
            }
            .frame(maxWidth: 720)
            .animation(poemAnimation, value: poemIndex)

            HStack(spacing: 8) {
                Text(poem.attribution)
                    .font(.system(size: 10.5, weight: .regular, design: .serif))
                    .foregroundStyle(SnowSkin.faint)
                Button {
                    withAnimation(poemAnimation) {
                        poemIndex = (poemIndex + 1) % SnowPoem.all.count
                    }
                } label: {
                    Image(systemName: "arrow.triangle.2.circlepath")
                        .font(.system(size: 9.5))
                        .foregroundStyle(SnowSkin.faint)
                }
                .buttonStyle(.plain)
                .help("换一句雪诗")
            }
        }
        .contentShape(Rectangle())
        .onTapGesture {
            withAnimation(poemAnimation) {
                poemIndex = (poemIndex + 1) % SnowPoem.all.count
            }
        }
    }

    // MARK: - 扫描中

    private var breathingContent: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 10)
            VStack(spacing: 18) {
                BreathingSnowflake()
                    .padding(.bottom, -26)
                VStack(spacing: 7) {
                    Text("正在看这整块盘")
                        .font(.system(size: 30, weight: .semibold, design: .serif))
                        .foregroundStyle(SnowSkin.text)
                    Text("你说：\(audit.query)")
                        .font(.system(size: 12))
                        .foregroundStyle(SnowSkin.dim)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }

                scanningComposer
                scanPathTicker
            }
            .frame(maxWidth: 780)
            .frame(maxWidth: .infinity)
            Spacer(minLength: 14)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var scanningComposer: some View {
        HStack(spacing: 12) {
            Image(systemName: "snowflake")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(SnowSkin.gold.opacity(0.9))

            Text(audit.query)
                .font(.system(size: 24, weight: .medium, design: .serif))
                .foregroundStyle(SnowSkin.text)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: .infinity, alignment: .leading)

            ProgressView()
                .controlSize(.small)
                .tint(SnowSkin.gold)
                .frame(width: 24)
        }
        .padding(.horizontal, 20)
        .frame(height: 62)
        .frame(maxWidth: 680)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(SnowSkin.overlay(0.055))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(SnowSkin.gold.opacity(0.28), lineWidth: 1)
        )
        .shadow(color: SnowSkin.gold.opacity(0.08), radius: 20, y: 8)
    }

    private var scanPathTicker: some View {
        let visible = Array(audit.scanPaths.suffix(16))
        return VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text(audit.stage.isEmpty ? "正在打开全盘目录" : audit.stage)
                    .font(.system(size: 12.5, weight: .medium))
                    .foregroundStyle(SnowSkin.text)
                    .lineLimit(1)
                Spacer(minLength: 8)
                Text(audit.progress > 0 ? "\(Int(min(1, max(0, audit.progress)) * 100))%" : "准备")
                    .font(.system(size: 10.5, design: .monospaced))
                    .foregroundStyle(SnowSkin.gold.opacity(0.82))
            }

            if audit.progress > 0.005 {
                ProgressView(value: min(1, max(0.01, audit.progress)))
                    .progressViewStyle(.linear)
                    .tint(SnowSkin.gold)
            } else {
                HStack(spacing: 7) {
                    ProgressView().controlSize(.small)
                    Text("先让雪找路")
                        .font(.system(size: 10.5))
                        .foregroundStyle(SnowSkin.faint)
                }
            }

            ScrollViewReader { proxy in
                ScrollView(.vertical, showsIndicators: false) {
                    VStack(alignment: .leading, spacing: 6) {
                        if visible.isEmpty {
                            Text("正在打开目录…")
                                .font(.system(size: 10.5, design: .monospaced))
                                .foregroundStyle(SnowSkin.faint)
                        } else {
                            ForEach(Array(visible.enumerated()), id: \.offset) { index, path in
                                HStack(spacing: 7) {
                                    Circle()
                                        .fill(index == visible.count - 1
                                              ? SnowSkin.gold.opacity(0.95)
                                              : SnowSkin.overlay(0.3))
                                        .frame(width: 4, height: 4)
                                    Text(displayPath(path))
                                        .font(.system(size: 10.5, design: .monospaced))
                                        .foregroundStyle(index == visible.count - 1
                                                         ? SnowSkin.text.opacity(0.94)
                                                         : SnowSkin.overlay(0.42))
                                        .lineLimit(1)
                                        .truncationMode(.middle)
                                }
                            }
                        }
                        Color.clear.frame(height: 1).id("scan-path-bottom")
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(height: 96)
                .mask(
                    LinearGradient(
                        colors: [.clear, .black.opacity(0.9), .black],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )
                .onChange(of: audit.scanPaths.count) { _, _ in
                    withAnimation(.linear(duration: 0.38)) {
                        proxy.scrollTo("scan-path-bottom", anchor: .bottom)
                    }
                }
            }
        }
        .padding(16)
        .frame(maxWidth: 680)
        .background(SnowSkin.panel, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(SnowSkin.overlay(0.07), lineWidth: 1)
        )
    }

    private var failedContent: some View {
        VStack(spacing: 14) {
            Spacer()
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 28))
                .foregroundStyle(SnowSkin.orange)
            Text("这次没看完")
                .font(.system(size: 24, weight: .semibold, design: .serif))
                .foregroundStyle(SnowSkin.text)
            Text(audit.lastError ?? "扫描没有生成结果。")
                .font(.system(size: 12.5))
                .foregroundStyle(SnowSkin.dim)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 480)
            Button("再试一次") {
                query = audit.query
                audit.reset()
                inputFocused = true
            }
            .buttonStyle(.plain)
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(SnowSkin.gold)
            .padding(.horizontal, 18)
            .padding(.vertical, 9)
            .background(SnowSkin.gold.opacity(0.10), in: Capsule())
            .overlay(Capsule().stroke(SnowSkin.gold.opacity(0.3), lineWidth: 1))
            Spacer()
        }
    }

    // MARK: - 结果

    @ViewBuilder
    private var resultsContent: some View {
        if let result = audit.result {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    resultsHeader(result)
                    if let warning = result.warning {
                        warningCard(warning, locked: !result.reportComplete)
                    }
                    minimalResultPanel(result)
                    if result.totalDecisionCount == 0 && result.keepCount == 0 {
                        emptyResult
                    }

                    DisclosureGroup(isExpanded: $showEvidence) {
                        VStack(alignment: .leading, spacing: 20) {
                            spaceSection(result)
                            decisionSection(result)
                            keepSection(result)
                            footerNote(result)
                        }
                        .padding(.top, 10)
                    } label: {
                        HStack(spacing: 10) {
                            Text(showEvidence ? "收起完整清单" : "看完整清单")
                                .font(.system(size: 11.5, weight: .medium))
                                .foregroundStyle(SnowSkin.gold)
                            Text("空间 · 全部候选 · 不动项")
                                .font(.system(size: 9.5))
                                .foregroundStyle(SnowSkin.faint)
                            Spacer()
                        }
                        .padding(.horizontal, 14)
                        .padding(.vertical, 11)
                        .background(SnowSkin.overlay(0.035), in: RoundedRectangle(cornerRadius: 11))
                        .overlay(
                            RoundedRectangle(cornerRadius: 11)
                                .stroke(SnowSkin.overlay(0.055), lineWidth: 1)
                                .allowsHitTesting(false)
                        )
                        .contentShape(RoundedRectangle(cornerRadius: 11))
                    }
                    .tint(SnowSkin.gold)
                }
                .padding(.top, 16)
                .padding(.bottom, 24)
                .padding(.horizontal, 4)
                .frame(maxWidth: 900)
                .frame(maxWidth: .infinity)
            }
            .scrollIndicators(.never)
        } else {
            failedContent
        }
    }

    private var noviceReport: NoviceReport {
        let disk = SystemMetrics.disk()
        let home = NSHomeDirectory()
        let system = audit.spaces
            .filter { $0.path != home }
            .map { node in
                NoviceSpaceItem(
                    name: node.name,
                    path: node.path,
                    bytes: node.bytes,
                    category: node.category,
                    risk: node.risk,
                    isPersonal: false
                )
            }
        let personal = audit.homeSpaces.map { node in
            NoviceSpaceItem(
                name: node.name,
                path: node.path,
                bytes: node.bytes,
                category: node.category,
                risk: node.risk,
                isPersonal: true
            )
        }
        let keep = Dictionary(grouping: audit.result?.keep ?? [], by: \.title).map { title, findings in
            NoviceSpaceItem(
                name: title,
                path: "protected://\(title)",
                bytes: findings.reduce(0) { $0 + $1.bytes },
                category: findings.first?.category ?? "保护项",
                risk: "只读",
                isPersonal: false
            )
        }
        return NoviceReportBuilder.build(
            result: audit.result,
            totalBytes: disk.totalBytes,
            freeBytes: disk.freeBytes,
            systemSpaces: system,
            homeSpaces: personal,
            keepSpaces: keep,
            warning: audit.result?.warning
        )
    }

    private func startNoviceReport() {
        noviceSeen = true
        noviceScanPending = true
        showEvidence = false
        audit.begin("先看懂这台电脑", using: model)
    }

    private func resultsHeader(_ result: LandingAuditResult) -> some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 5) {
                Text("看完了。")
                    .font(.system(size: 30, weight: .semibold, design: .serif))
                    .foregroundStyle(SnowSkin.text)
                Text("你说：\(audit.query)")
                    .font(.system(size: 12.5))
                    .foregroundStyle(SnowSkin.dim)
                    .lineLimit(2)
            }
            Spacer()
            HStack(spacing: 8) {
                Button("新手报告") {
                    noviceSeen = true
                    showNoviceReport = true
                }
                .buttonStyle(.plain)
                .font(.system(size: 11.5))
                .foregroundStyle(SnowSkin.gold.opacity(0.86))
                .padding(.horizontal, 12)
                .padding(.vertical, 7)
                .background(SnowSkin.gold.opacity(0.075), in: Capsule())
                .overlay(Capsule().stroke(SnowSkin.gold.opacity(0.20), lineWidth: 1))
                Button("重新体检") {
                    query = audit.query
                    audit.reset()
                    inputFocused = true
                }
                .buttonStyle(.plain)
                .font(.system(size: 11.5))
                .foregroundStyle(SnowSkin.dim)
                .padding(.horizontal, 12)
                .padding(.vertical, 7)
                .background(SnowSkin.overlay(0.045), in: Capsule())
                Button {
                    openTrash()
                } label: {
                    Label("废纸篓", systemImage: "trash")
                        .font(.system(size: 11.5))
                        .foregroundStyle(SnowSkin.faint)
                }
                .buttonStyle(.plain)
            }
        }
    }

    private func minimalResultPanel(_ result: LandingAuditResult) -> some View {
        let clean = visibleClean(result)
        let cleanBytes = result.cleanBytes
        let decisions = result.confirm.filter { !audit.removedPaths.contains($0.id) }
            + result.personal.filter { !audit.removedPaths.contains($0.id) }
        let decisionBytes = result.confirmBytes + result.personalBytes

        return VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                statBlock("可清", "\(result.cleanCount) 项", AssistantBytes.text(cleanBytes), SnowSkin.green)
                statBlock("要你决定", "\(result.confirmCount + result.personalCount) 项",
                          AssistantBytes.text(decisionBytes), SnowSkin.orange)
                statBlock("不动", "\(result.keepCount) 项", nil, SnowSkin.faint)
            }

            if !clean.isEmpty {
                HStack(alignment: .center, spacing: 12) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("最该先清")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(SnowSkin.gold)
                        Text("缓存、日志、旧安装包；逐项复核后只移废纸篓。")
                            .font(.system(size: 11))
                            .foregroundStyle(SnowSkin.dim)
                            .lineLimit(1)
                    }
                    Spacer(minLength: 8)
                    Button {
                        trashRequest = .batch(clean)
                    } label: {
                        Label(result.cleanCount > clean.count ? "移入已列 \(clean.count) 项" : "全部移入废纸篓", systemImage: "trash")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(SnowSkin.onAccent)
                            .padding(.horizontal, 13)
                            .padding(.vertical, 7)
                            .background(SnowSkin.gold, in: Capsule())
                    }
                    .buttonStyle(.plain)
                    .disabled(!result.reportComplete || audit.isTrashing)
                    .opacity(result.reportComplete ? 1 : 0.45)
                    .help(result.reportComplete ? "只移入废纸篓，不永久删除" : "全盘没读全，删除已锁定")
                }
                .padding(12)
                .background(SnowSkin.overlay(0.034), in: RoundedRectangle(cornerRadius: 11))
            }

            if !decisions.isEmpty {
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: "person.crop.circle.badge.questionmark")
                        .font(.system(size: 12))
                        .foregroundStyle(SnowSkin.orange)
                        .padding(.top, 2)
                    VStack(alignment: .leading, spacing: 3) {
                        Text("要你决定 \(result.confirmCount + result.personalCount) 项")
                            .font(.system(size: 11.5, weight: .medium))
                            .foregroundStyle(SnowSkin.text)
                        Text("雪不替你判断内容；展开后逐项看证据，再决定。")
                            .font(.system(size: 10.5))
                            .foregroundStyle(SnowSkin.faint)
                    }
                    Spacer(minLength: 6)
                    Button("展开看") { showEvidence = true }
                        .buttonStyle(.plain)
                        .font(.system(size: 10.5, weight: .medium))
                        .foregroundStyle(SnowSkin.orange)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(SnowSkin.orange.opacity(0.08), in: Capsule())
                }
                .padding(12)
                .background(SnowSkin.orange.opacity(0.035), in: RoundedRectangle(cornerRadius: 11))
            }

            if result.recentPersonalCount > 0 {
                Text("最近 7 天改过的大文件 \(result.recentPersonalCount) 项 · \(AssistantBytes.text(result.recentPersonalBytes))，最可能解释“一下午少了很多空间”。")
                    .font(.system(size: 10.5))
                    .foregroundStyle(SnowSkin.dim)
            }

            if audit.removedCount > 0 {
                Text("已移废纸篓 \(audit.removedCount) 项 · \(AssistantBytes.text(audit.removedBytes))")
                    .font(.system(size: 10.5, design: .monospaced))
                    .foregroundStyle(SnowSkin.gold)
            }
        }
        .padding(16)
        .background(SnowSkin.panel, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(SnowSkin.overlay(0.075), lineWidth: 1)
        )
    }

    private func statBlock(_ title: String, _ value: String, _ bytes: String?, _ color: Color) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title)
                .font(.system(size: 9.5))
                .foregroundStyle(SnowSkin.faint)
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(value)
                    .font(.system(size: 20, weight: .semibold, design: .serif))
                    .foregroundStyle(color)
                if let bytes {
                    Text(bytes)
                        .font(.system(size: 9.5, design: .monospaced))
                        .foregroundStyle(SnowSkin.faint)
                }
            }
            .lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func warningCard(_ text: String, locked: Bool) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: locked ? "lock.fill" : "info.circle.fill")
                .font(.system(size: 12))
                .foregroundStyle(locked ? SnowSkin.orange : SnowSkin.faint)
            Text(text)
                .font(.system(size: 11.5))
                .foregroundStyle(SnowSkin.dim)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(12)
        .background((locked ? SnowSkin.orange : SnowSkin.gold).opacity(0.055),
                    in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10)
            .stroke((locked ? SnowSkin.orange : SnowSkin.gold).opacity(0.16), lineWidth: 1))
    }

    @ViewBuilder
    private func spaceSection(_ result: LandingAuditResult) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionHeader("空间去哪了", detail: "全盘关键位置，只读；系统位置不提供删除", color: SnowSkin.faint)
            if audit.spacesLoading {
                HStack(spacing: 9) {
                    ProgressView().controlSize(.small)
                    Text("空间大头还在后台算，先看下面的清单。")
                        .font(.system(size: 11))
                        .foregroundStyle(SnowSkin.dim)
                }
                .padding(13)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(SnowSkin.panel, in: RoundedRectangle(cornerRadius: 10))
            } else if let error = audit.spacesError {
                Text(error)
                    .font(.system(size: 11))
                    .foregroundStyle(SnowSkin.orange)
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(SnowSkin.orange.opacity(0.06), in: RoundedRectangle(cornerRadius: 9))
            } else if audit.spaces.isEmpty {
                Text("系统位置这次没读到大体积项。")
                    .font(.system(size: 11))
                    .foregroundStyle(SnowSkin.faint)
                    .padding(13)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(SnowSkin.panel, in: RoundedRectangle(cornerRadius: 10))
            } else {
                let maxBytes = max(1, audit.spaces.prefix(7).map(\.bytes).max() ?? 1)
                VStack(spacing: 0) {
                    ForEach(Array(audit.spaces.prefix(7).enumerated()), id: \.element.id) { index, node in
                        spaceRow(node, index: index, maxBytes: maxBytes, tint: SnowSkin.gold)
                        if index < min(audit.spaces.count, 7) - 1 {
                            Divider().overlay(SnowSkin.overlay(0.045))
                        }
                    }
                }
                .padding(.horizontal, 14)
                .background(SnowSkin.panel, in: RoundedRectangle(cornerRadius: 12))
                .overlay(RoundedRectangle(cornerRadius: 12)
                    .stroke(SnowSkin.overlay(0.055), lineWidth: 1))
            }

            if !audit.spacesLoading { homeSpaceBlock }
        }
    }

    @ViewBuilder
    private var homeSpaceBlock: some View {
        if let error = audit.homeSpacesError {
            Text("用户目录里：\(error)")
                .font(.system(size: 10.5))
                .foregroundStyle(SnowSkin.faint)
        } else if !audit.homeSpaces.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text("用户目录里")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(SnowSkin.dim)
                    Text("个人数据，只报告；不会给你一键删整个目录")
                        .font(.system(size: 9.5))
                        .foregroundStyle(SnowSkin.faint)
                    Spacer()
                    Text(AssistantBytes.text(audit.homeSpaces.reduce(0) { $0 + $1.bytes }))
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(SnowSkin.faint)
                }
                let maxBytes = max(1, audit.homeSpaces.prefix(6).map(\.bytes).max() ?? 1)
                VStack(spacing: 0) {
                    ForEach(Array(audit.homeSpaces.prefix(6).enumerated()), id: \.element.id) { index, node in
                        spaceRow(node, index: index, maxBytes: maxBytes, tint: SnowSkin.orange)
                        if index < min(audit.homeSpaces.count, 6) - 1 {
                            Divider().overlay(SnowSkin.overlay(0.045))
                        }
                    }
                }
                .padding(.horizontal, 14)
                .background(SnowSkin.overlay(0.032), in: RoundedRectangle(cornerRadius: 11))
                .overlay(RoundedRectangle(cornerRadius: 11)
                    .stroke(SnowSkin.overlay(0.045), lineWidth: 1))
            }
        }
    }

    private func spaceRow(_ node: SpaceNode, index: Int, maxBytes: Int64, tint: Color) -> some View {
        HStack(spacing: 12) {
            Text("\(index + 1)")
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(SnowSkin.faint)
                .frame(width: 16, alignment: .trailing)
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 8) {
                    Text(node.name)
                        .font(.system(size: 12.5, weight: .medium))
                        .foregroundStyle(SnowSkin.text)
                        .lineLimit(1)
                    Text(node.category)
                        .font(.system(size: 9))
                        .foregroundStyle(SnowSkin.faint)
                }
                GeometryReader { proxy in
                    Capsule()
                        .fill(LinearGradient(colors: [tint.opacity(0.75), tint.opacity(0.16)],
                                             startPoint: .leading, endPoint: .trailing))
                        .frame(width: max(3, proxy.size.width * CGFloat(node.bytes) / CGFloat(maxBytes)), height: 3)
                }
                .frame(height: 3)
            }
            Spacer(minLength: 6)
            Text(AssistantBytes.text(node.bytes))
                .font(.system(size: 11.5, weight: .medium, design: .monospaced))
                .foregroundStyle(SnowSkin.dim)
                .frame(width: 92, alignment: .trailing)
            Text(node.risk)
                .font(.system(size: 8.5))
                .foregroundStyle(SnowSkin.faint)
                .frame(width: 34, alignment: .trailing)
        }
        .padding(.vertical, 9)
    }

    @ViewBuilder
    private func decisionSection(_ result: LandingAuditResult) -> some View {
        let clean = visibleClean(result)
        let decisions = result.confirm.filter { !audit.removedPaths.contains($0.id) }
            + result.personal.filter { !audit.removedPaths.contains($0.id) }

        if !clean.isEmpty || !decisions.isEmpty {
            VStack(alignment: .leading, spacing: 12) {
                sectionHeader("一二三四，你来决定",
                       detail: "能清的默认标「可清」；你的文件一律标「需你确认」",
                       color: SnowSkin.gold)

                if !clean.isEmpty {
                    HStack(alignment: .firstTextBaseline) {
                        Text("A. 可清理")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(SnowSkin.green)
                        Text("\(result.cleanCount) 项 · \(AssistantBytes.text(result.cleanBytes))")
                            .font(.system(size: 10.5, design: .monospaced))
                            .foregroundStyle(SnowSkin.faint)
                        Spacer()
                        if result.reportComplete && !audit.isTrashing {
                            Button {
                                trashRequest = .batch(clean)
                            } label: {
                                Label(result.cleanCount > clean.count ? "移入已列 \(clean.count) 项" : "全部移入废纸篓", systemImage: "trash")
                                    .font(.system(size: 10.5, weight: .medium))
                                    .foregroundStyle(SnowSkin.gold)
                                    .padding(.horizontal, 11)
                                    .padding(.vertical, 6)
                                    .background(SnowSkin.gold.opacity(0.09), in: Capsule())
                                    .overlay(Capsule().stroke(SnowSkin.gold.opacity(0.24), lineWidth: 1))
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    LazyVStack(spacing: 8) {
                        ForEach(Array(clean.enumerated()), id: \.element.id) { index, finding in
                            decisionRow(finding, number: index + 1, result: result)
                        }
                    }
                }

                if !decisions.isEmpty {
                    HStack(alignment: .firstTextBaseline) {
                        Text("B. 需要你看过再定")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(SnowSkin.orange)
                        Text("\(result.confirmCount + result.personalCount) 项 · \(AssistantBytes.text(result.confirmBytes + result.personalBytes))")
                            .font(.system(size: 10.5, design: .monospaced))
                            .foregroundStyle(SnowSkin.faint)
                        Spacer()
                    }
                    .padding(.top, clean.isEmpty ? 0 : 8)
                    if result.recentPersonalCount > 0 {
                        Text("最近 7 天改过的 \(result.recentPersonalCount) 项排在前面；这里只列 \(result.personal.count) 个最大的和最近的，不是全部。")
                            .font(.system(size: 9.5))
                            .foregroundStyle(SnowSkin.faint)
                    }
                    LazyVStack(spacing: 8) {
                        ForEach(Array(decisions.enumerated()), id: \.element.id) { index, finding in
                            decisionRow(finding, number: clean.count + index + 1, result: result)
                        }
                    }
                }
            }
        }
    }

    private func decisionRow(_ finding: AuditFinding, number: Int, result: LandingAuditResult) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Text(String(format: "%02d", number))
                .font(.system(size: 10.5, weight: .medium, design: .monospaced))
                .foregroundStyle(SnowSkin.faint)
                .frame(width: 24, alignment: .trailing)
                .padding(.top, 3)

            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 7) {
                    Text(finding.title)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(SnowSkin.text)
                        .lineLimit(1)
                    Text(finding.decision.title)
                        .font(.system(size: 8.5))
                        .foregroundStyle(decisionColor(finding.decision))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2.5)
                        .background(decisionColor(finding.decision).opacity(0.10), in: Capsule())
                    Text(finding.category)
                        .font(.system(size: 8.5))
                        .foregroundStyle(SnowSkin.faint)
                }
                Text(finding.reason)
                    .font(.system(size: 10.5))
                    .foregroundStyle(SnowSkin.dim)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                Text(displayPath(finding.path))
                    .font(.system(size: 9.5, design: .monospaced))
                    .foregroundStyle(SnowSkin.faint.opacity(0.8))
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            Spacer(minLength: 8)

            VStack(alignment: .trailing, spacing: 7) {
                Text(AssistantBytes.text(finding.bytes))
                    .font(.system(size: 11.5, weight: .medium, design: .monospaced))
                    .foregroundStyle(SnowSkin.dim)
                Button {
                    trashRequest = .single(finding)
                } label: {
                    Label("移到废纸篓", systemImage: "trash")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(result.reportComplete ? SnowSkin.text : SnowSkin.faint)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5.5)
                        .background(SnowSkin.overlay(result.reportComplete ? 0.065 : 0.03),
                                    in: Capsule())
                        .overlay(Capsule().stroke(
                            (finding.decision == .clean ? SnowSkin.gold : SnowSkin.orange)
                                .opacity(result.reportComplete ? 0.24 : 0.08), lineWidth: 1))
                }
                .buttonStyle(.plain)
                .disabled(!result.reportComplete || audit.isTrashing)
                .help(result.reportComplete ? "只移入废纸篓，不永久删除" : "全盘没读全，删除已锁定")
            }
            .frame(width: 118, alignment: .trailing)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
        .background(SnowSkin.panel, in: RoundedRectangle(cornerRadius: 11))
        .overlay(RoundedRectangle(cornerRadius: 11)
            .stroke((finding.decision == .clean ? SnowSkin.gold : SnowSkin.orange).opacity(0.10), lineWidth: 1))
    }

    private func decisionColor(_ decision: AuditDecision) -> Color {
        switch decision {
        case .clean: return SnowSkin.green
        case .confirm: return SnowSkin.orange
        case .personal: return SnowSkin.gold
        case .keep: return SnowSkin.faint
        }
    }

    @ViewBuilder
    private func keepSection(_ result: LandingAuditResult) -> some View {
        if !result.keep.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                sectionHeader("雪不动的", detail: "保护清单、系统必需或读不准；这里没有删除按钮",
                              color: SnowSkin.faint)
                VStack(spacing: 0) {
                    ForEach(Array(result.keep.enumerated()), id: \.element.id) { index, finding in
                        HStack(alignment: .top, spacing: 12) {
                            Image(systemName: "lock.fill")
                                .font(.system(size: 10))
                                .foregroundStyle(SnowSkin.faint)
                                .frame(width: 18)
                            VStack(alignment: .leading, spacing: 4) {
                                Text(finding.title)
                                    .font(.system(size: 12, weight: .medium))
                                    .foregroundStyle(SnowSkin.dim)
                                    .lineLimit(1)
                                Text(finding.reason)
                                    .font(.system(size: 10))
                                    .foregroundStyle(SnowSkin.faint)
                                    .lineLimit(2)
                            }
                            Spacer(minLength: 8)
                            Text(AssistantBytes.text(finding.bytes))
                                .font(.system(size: 10.5, design: .monospaced))
                                .foregroundStyle(SnowSkin.faint)
                        }
                        .padding(.horizontal, 14)
                        .padding(.vertical, 9)
                        if index < result.keep.count - 1 {
                            Divider().overlay(SnowSkin.overlay(0.04))
                        }
                    }
                }
                .background(SnowSkin.overlay(0.025), in: RoundedRectangle(cornerRadius: 11))
                .overlay(RoundedRectangle(cornerRadius: 11).stroke(SnowSkin.overlay(0.04), lineWidth: 1))
            }
        }
    }

    private var emptyResult: some View {
        VStack(spacing: 8) {
            Image(systemName: "snowflake")
                .font(.system(size: 20))
                .foregroundStyle(SnowSkin.faint)
            Text("这次没找到明确可清的项。")
                .font(.system(size: 13))
                .foregroundStyle(SnowSkin.dim)
            Text("空间大头还在上面的“空间去哪了”；个人文件雪不会替你判断。")
                .font(.system(size: 10.5))
                .foregroundStyle(SnowSkin.faint)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 26)
    }

    private func footerNote(_ result: LandingAuditResult) -> some View {
        HStack(spacing: 7) {
            Image(systemName: "checkmark.shield")
                .font(.system(size: 10))
            Text("所有操作只移废纸篓，不永久删除；逐项复核身份，失败立即停手。")
                .font(.system(size: 10))
            Spacer()
            if result.personalCount > result.personal.count {
                Text("个人大文件只列 \(result.personal.count) 项，共 \(result.personalCount) 项；没有替你判断内容。")
                    .font(.system(size: 9.5))
            } else if result.cleanCount > result.clean.count {
                Text("清单只列最大的 \(result.clean.count) 项，共 \(result.cleanCount) 项。")
                    .font(.system(size: 9.5))
            }
        }
        .foregroundStyle(SnowSkin.faint.opacity(0.85))
        .padding(.top, 2)
    }

    private func sectionHeader(_ title: String, detail: String, color: Color) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 9) {
            Text(title)
                .font(.system(size: 16, weight: .semibold, design: .serif))
                .foregroundStyle(color)
            Text(detail)
                .font(.system(size: 10))
                .foregroundStyle(SnowSkin.faint)
            Spacer()
        }
    }

    private func visibleClean(_ result: LandingAuditResult) -> [AuditFinding] {
        result.clean.filter { !audit.removedPaths.contains($0.id) }
    }

    private func displayPath(_ path: String) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        if path.hasPrefix(home) { return "~" + String(path.dropFirst(home.count)) }
        return path
    }

    // MARK: - 底栏

    private var bottomBar: some View {
        HStack(spacing: 12) {
            Button {
                selection = "概览"
                showLanding = false
            } label: {
                HStack(spacing: 6) {
                    Text("专家模式")
                        .font(.system(size: 12, weight: .medium))
                        .tracking(1.0)
                    Image(systemName: "chevron.right")
                        .font(.system(size: 9, weight: .semibold))
                }
                .foregroundStyle(SnowSkin.faint)
                .frame(width: 132, height: 32)
                .background(SnowSkin.overlay(0.025), in: Capsule())
                .overlay(Capsule().stroke(SnowSkin.overlay(0.06), lineWidth: 1).allowsHitTesting(false))
                .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .help("进入完整雪界面，保留高密度清理明细")

            if let message = audit.lastMessage {
                Text(message)
                    .font(.system(size: 10))
                    .foregroundStyle(SnowSkin.green)
                    .lineLimit(1)
            } else if let error = audit.lastError, audit.phase == .results {
                Text(error)
                    .font(.system(size: 10))
                    .foregroundStyle(SnowSkin.orange)
                    .lineLimit(1)
            } else if audit.isTrashing {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text("正在逐项复核并移入废纸篓")
                        .font(.system(size: 10))
                        .foregroundStyle(SnowSkin.dim)
                }
            }

            Spacer()

            Text("只移废纸篓 · 不永久删除")
                .font(.system(size: 9.5))
                .foregroundStyle(SnowSkin.faint.opacity(0.75))
        }
        .padding(.top, 10)
    }

    // MARK: - 动作

    private func submit() {
        guard !trimmedQuery.isEmpty, !audit.isBusy, !intentPreview.isResolving else { return }
        inputFocused = false
        let text = trimmedQuery
        query = ""
        // 首屏先走“听懂 + 定向预览”，不再把任何一句话都当成整盘扫描。
        intentPreview.resolve(text)
        showIntentPreview = true
    }

    private func openTrash() {
        let trash = URL(fileURLWithPath: NSString(string: "~/.Trash").expandingTildeInPath, isDirectory: true)
        NSWorkspace.shared.open(trash)
    }

    /// 聚焦后把光标放到文字末尾，避免首屏出现整段蓝色全选。
    private func deselectInputText() {
        for delay in [0.1, 0.3, 0.55] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                if let editor = NSApp.keyWindow?.firstResponder as? NSTextView {
                    let end = (editor.string as NSString).length
                    editor.setSelectedRange(NSRange(location: end, length: 0))
                }
            }
        }
    }
}

private struct SnowPoem {
    let first: String
    let second: String
    let attribution: String

    static let all: [SnowPoem] = [
        SnowPoem(first: "夜深知雪重", second: "时闻折竹声", attribution: "唐 · 白居易《夜雪》"),
        SnowPoem(first: "六出飞花入户时", second: "坐看青竹变琼枝", attribution: "唐 · 高骈《对雪》"),
        SnowPoem(first: "忽如一夜春风来", second: "千树万树梨花开", attribution: "唐 · 岑参《白雪歌送武判官归京》"),
        SnowPoem(first: "白雪却嫌春色晚", second: "故穿庭树作飞花", attribution: "唐 · 韩愈《春雪》"),
        SnowPoem(first: "晚来天欲雪", second: "能饮一杯无", attribution: "唐 · 白居易《问刘十九》"),
        SnowPoem(first: "天将暮，雪乱舞", second: "半梅花半飘柳絮", attribution: "元 · 马致远《寿阳曲·江天暮雪》")
    ]
}

/// 输入框里轮换的示例话术。第一句固定是“清理垃圾”，其余覆盖缓存、素材与空间。
private struct PromptSample {
    let text: String

    static let all: [PromptSample] = [
        PromptSample(text: "试着对我说清理垃圾"),
        PromptSample(text: "微信缓存太占地方，聊天记录别动"),
        PromptSample(text: "Xcode 编译缓存清掉，源码别动"),
        PromptSample(text: "谁最占空间，先别删"),
        PromptSample(text: "旧安装包还占地方吗")
    ]
}

/// 首屏的白色雪晶：白色填充在浅色背景上会“消失”，所以用霜蓝描边阴影托住。
private struct SnowCrystal: View {
    let size: CGFloat
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var breathe = false

    var body: some View {
        ZStack {
            Circle()
                .fill(SnowSkin.snowStroke.opacity(0.12))
                .frame(width: size * 1.25, height: size * 1.25)
                .blur(radius: 14)
                .scaleEffect(breathe ? 1.06 : 0.96)

            Image(systemName: "snowflake")
                .font(.system(size: size, weight: .light))
                .foregroundStyle(.white)
                .shadow(color: SnowSkin.snowStroke.opacity(0.85), radius: 2, x: 0, y: 0)
                .shadow(color: SnowSkin.snowShadow, radius: 12, y: 5)
                .scaleEffect(breathe ? 1.05 : 1.0)
        }
        .frame(width: size * 1.6, height: size * 1.6)
        .onAppear {
            if reduceMotion {
                breathe = true
                return
            }
            withAnimation(.easeInOut(duration: 1.8).repeatForever(autoreverses: true)) {
                breathe = true
            }
        }
        .accessibilityLabel("雪")
    }
}

private enum TrashRequest: Identifiable {
    case single(AuditFinding)
    case batch([AuditFinding])

    var id: String {
        switch self {
        case let .single(finding): return "one:\(finding.id)"
        case let .batch(findings): return "batch:\(findings.count):\(findings.first?.id ?? "")"
        }
    }
}

/// 雪花呼吸：不是转圈加载，而是缓慢放大、缩小、变亮。
/// 呼吸一次约 1.8 秒；扫描没结束时它会一直呼吸。
private struct BreathingSnowflake: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var inhale = false

    var body: some View {
        ZStack {
            Circle()
                .fill(SnowSkin.snowStroke.opacity(0.10))
                .frame(width: 190, height: 190)
                .scaleEffect(inhale ? 1.06 : 0.96)
                .blur(radius: 16)

            Circle()
                .stroke(SnowSkin.snowStroke.opacity(0.22), lineWidth: 1)
                .frame(width: 150, height: 150)
                .scaleEffect(inhale ? 1.05 : 0.98)
                .opacity(inhale ? 0.75 : 0.34)

            Circle()
                .stroke(SnowSkin.snowStroke.opacity(0.12), lineWidth: 1)
                .frame(width: 112, height: 112)
                .scaleEffect(inhale ? 1.0 : 1.03)
                .opacity(inhale ? 0.55 : 0.85)

            Image(systemName: "snowflake")
                .font(.system(size: 48, weight: .light))
                .foregroundStyle(.white)
                .shadow(color: SnowSkin.snowStroke.opacity(0.85), radius: 2, x: 0, y: 0)
                .shadow(color: SnowSkin.snowShadow, radius: inhale ? 18 : 8)
                .scaleEffect(inhale ? 1.05 : 1.0)
                .opacity(inhale ? 1 : 0.72)
        }
        .frame(width: 200, height: 200)
        .onAppear {
            if reduceMotion {
                inhale = true
                return
            }
            withAnimation(.easeInOut(duration: 1.8).repeatForever(autoreverses: true)) {
                inhale = true
            }
        }
        .accessibilityLabel("雪正在呼吸，读取全盘")
    }
}
