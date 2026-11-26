import SwiftUI
import AppKit
import SnowSweepCore
import UniformTypeIdentifiers

// MARK: - 卸载

private enum UninstallCategory: String, CaseIterable, Identifiable {
    case all = "全部"
    case unused = "未使用"
    case residuals = "有残留"
    case system = "系统"
    case store = "商店"
    var id: String { rawValue }
}

private enum UninstallSort: String, CaseIterable, Identifiable {
    case name = "名称"
    case size = "大小"
    case recent = "最近使用"
    var id: String { rawValue }
}

struct UninstallView: View {
    @EnvironmentObject var monitor: SystemMonitor
    @State private var search = ""
    @State private var includeResiduals = true
    @State private var confirmUninstall = false
    @State private var category: UninstallCategory = .all
    @State private var sort: UninstallSort = .name
    @State private var selectedPaths: Set<String> = []
    @State private var softwareReport: SoftwareGraphReport?
    @State private var isCheckingFamily = false
    @State private var pendingApps: [AppEntry] = []
    @State private var pendingIncludeResiduals = true
    @State private var uninstallImpact: UninstallImpact?
    @State private var completedImpact: UninstallImpact?
    @State private var familyCheckError: String?

    private var selectedApps: [AppEntry] {
        monitor.apps.filter { selectedPaths.contains($0.path) && $0.canUninstall }
    }

    private var filtered: [AppEntry] {
        let base = monitor.apps.filter { app in
            let textOK = search.isEmpty
                || app.name.localizedCaseInsensitiveContains(search)
                || app.bundleID.localizedCaseInsensitiveContains(search)
            guard textOK else { return false }
            switch category {
            case .all: return true
            case .unused:
                guard !app.isSystem, let last = monitor.appLastUsed[app.path] else { return false }
                return last < Date().addingTimeInterval(-90 * 24 * 3600)
            case .residuals: return app.hasResiduals
            case .system: return app.isSystem
            case .store: return app.isAppStore
            }
        }
        switch sort {
        case .name:
            return base.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        case .size:
            return base.sorted {
                let a = monitor.appSizes[$0.path] ?? -1
                let b = monitor.appSizes[$1.path] ?? -1
                if a == b { return $0.name.localizedStandardCompare($1.name) == .orderedAscending }
                return a > b
            }
        case .recent:
            return base.sorted {
                let a = monitor.appLastUsed[$0.path] ?? .distantPast
                let b = monitor.appLastUsed[$1.path] ?? .distantPast
                if a == b { return $0.name.localizedStandardCompare($1.name) == .orderedAscending }
                return a > b
            }
        }
    }

    private var uninstallTargets: [AppEntry] {
        if !selectedApps.isEmpty { return selectedApps }
        if let app = monitor.selectedApp, app.canUninstall { return [app] }
        return []
    }

    private var selectedBytes: Int64? {
        let values = selectedApps.compactMap { monitor.appSizes[$0.path] }
        guard !values.isEmpty, values.count == selectedApps.count else { return nil }
        return values.reduce(0, +)
    }

    private var measuredAppBytes: Int64 {
        monitor.appSizes.values.reduce(0, +)
    }

    /// 右侧详情只对应一个已检查的应用；多选时不再复用最后一次点击的体积与残留，
    /// 否则会出现「抖音」标题配「豆包」体积/残留的串项。
    private var detailApp: AppEntry? {
        guard let selected = monitor.selectedApp,
              UninstallDetailPolicy.shows(selectedPaths: selectedApps.map(\.path), inspectedPath: selected.path)
        else { return nil }
        return selected
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            PageHeader(title: "卸载", subtitle: "按未使用、残留、系统、商店分类；可多选批量卸载。只移废纸篓，系统与雪自己不可删。")
                .padding([.top, .horizontal], 18)
                .padding(.bottom, 10)

            HStack(spacing: 10) {
                Picker("分类", selection: $category) {
                    ForEach(UninstallCategory.allCases) { item in
                        Text(item.rawValue).tag(item)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(maxWidth: 430)

                Picker("排序", selection: $sort) {
                    ForEach(UninstallSort.allCases) { item in
                        Text(item.rawValue).tag(item)
                    }
                }
                .pickerStyle(.menu)
                .frame(width: 130)

                if monitor.isLoadingApps || monitor.isLoadingAppSizes || monitor.isLoadingUsage {
                    ProgressView().controlSize(.small)
                }
                Spacer()
                Text("\(filtered.count) / \(monitor.apps.count) 个")
                    .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                if !monitor.appSizes.isEmpty {
                    Text("已统计 \(SystemMetrics.bytesText(measuredAppBytes))")
                        .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                }
                Button(allSelectableSelected ? "取消全选" : "全选当前") {
                    let selectable = filtered.filter(\.canUninstall).map(\.path)
                    uninstallImpact = nil
                    completedImpact = nil
                    if allSelectableSelected {
                        selectedPaths.removeAll()
                        monitor.clearSelection()
                    } else {
                        selectedPaths.formUnion(selectable)
                    }
                }
                .font(.caption)
                .disabled(!filtered.contains(where: \.canUninstall) && !allSelectableSelected)
                .help(filtered.contains(where: \.canUninstall) ? "选择当前列表里可卸载的应用" : "当前分类没有可卸载的应用")
            }
            .padding(.horizontal, 18)
            .padding(.bottom, 8)

            if !selectedApps.isEmpty {
                HStack(spacing: 10) {
                    Text("已选 \(selectedApps.count) 个应用").font(.callout.weight(.semibold))
                    if let bytes = selectedBytes {
                        Text(SystemMetrics.bytesText(bytes)).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                    } else {
                        Text("体积统计中…").font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    if isCheckingFamily {
                        ProgressView().controlSize(.small)
                        Text("正在核对家族影响…").font(.caption).foregroundStyle(.secondary)
                    }
                    Toggle("包含残留", isOn: $includeResiduals).toggleStyle(.checkbox).font(.caption)
                    Button("卸载选中") { requestUninstall(selectedApps) }
                        .disabled(monitor.isUninstalling || isCheckingFamily)
                }
                .padding(.horizontal, 18).padding(.vertical, 6)
                .background(Color.accentColor.opacity(0.07))
            }

            Divider()

            HSplitView {
                VStack(spacing: 0) {
                    TextField("搜索应用名或 Bundle ID", text: $search)
                        .textFieldStyle(.roundedBorder)
                        .padding(10)
                    Divider()
                    HStack(spacing: 8) {
                        Text("应用").frame(maxWidth: .infinity, alignment: .leading)
                        Text("体积").frame(width: 76, alignment: .trailing)
                    }
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(Color.primary.opacity(0.03))
                    Divider()
                    ScrollView {
                        LazyVStack(spacing: 0) {
                            if monitor.isLoadingApps {
                                HStack(spacing: 8) {
                                    ProgressView().controlSize(.small)
                                    Text("正在后台读取已安装应用…").font(.callout).foregroundStyle(.secondary)
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(12)
                            } else if monitor.isLoadingUsage && category == .unused {
                                HStack(spacing: 8) {
                                    ProgressView().controlSize(.small)
                                    Text("正在后台读取最近使用时间…").font(.callout).foregroundStyle(.secondary)
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(12)
                            } else if filtered.isEmpty {
                                Text(category == .unused
                                     ? "没有读到 90 天未使用记录。系统没有最近使用记录的应用不会归入「未使用」。"
                                     : "没有匹配的应用。")
                                    .font(.caption).foregroundStyle(.secondary)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .padding(12)
                            }
                            ForEach(filtered) { app in
                                Button {
                                    toggleSelection(app)
                                } label: {
                                    HStack(spacing: 8) {
                                        if app.canUninstall {
                                            Image(systemName: selectedPaths.contains(app.path) ? "checkmark.circle.fill" : "circle")
                                                .foregroundStyle(selectedPaths.contains(app.path) ? Color.accentColor : Color.secondary)
                                        } else {
                                            Image(systemName: "lock.fill")
                                                .foregroundStyle(.secondary)
                                                .help("系统组件或受保护应用不可选择")
                                        }
                                        Image(nsImage: NSWorkspace.shared.icon(forFile: app.path))
                                            .resizable().frame(width: 24, height: 24)
                                        VStack(alignment: .leading, spacing: 1) {
                                            Text(app.name).font(.callout)
                                            Text(app.bundleID).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                                        }
                                        Spacer()
                                        Text(monitor.appSizes[app.path].map(SystemMetrics.bytesText)
                                             ?? (monitor.isLoadingAppSizes ? "统计中" : "—"))
                                            .font(.caption.monospacedDigit().weight(.medium))
                                            .foregroundStyle(monitor.appSizes[app.path] == nil ? .tertiary : .primary)
                                            .frame(width: 76, alignment: .trailing)
                                        if app.isSystem {
                                            Text("系统").font(.caption2).foregroundStyle(.orange)
                                        } else if app.isAppStore {
                                            Text("商店").font(.caption2).foregroundStyle(.blue)
                                        }
                                        if app.isNestedInstall {
                                            Text("嵌套").font(.caption2).foregroundStyle(.teal)
                                                .help("装在厂商目录里；卸载只移动应用本体")
                                        }
                                        if app.hasResiduals {
                                            Text("残留").font(.caption2).foregroundStyle(.purple)
                                        }
                                        if isUnused(app) {
                                            Text("90 天未用").font(.caption2).foregroundStyle(.secondary)
                                        }
                                    }
                                    .padding(.horizontal, 10).padding(.vertical, 6)
                                    .contentShape(Rectangle())
                                    .background(monitor.selectedApp?.path == app.path ? Color.accentColor.opacity(0.12) : Color.clear)
                                }
                                .buttonStyle(.plain)
                                .help(app.canUninstall ? "点击切换勾选；应用名会显示在右侧详情" : "系统组件只展示，不可勾选或卸载")
                                Divider()
                            }
                        }
                    }
                }
                .frame(minWidth: 280, idealWidth: 330)

                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        if let error = familyCheckError {
                            InfoBanner(text: error, color: .orange)
                        }
                        if let completed = completedImpact {
                            completedImpactCard(completed)
                        }
                        if let impact = uninstallImpact, !selectedApps.isEmpty {
                            impactCard(impact)
                        }
                        if selectedApps.count > 1 {
                            ModuleCard {
                                VStack(alignment: .leading, spacing: 8) {
                                    Text("批量卸载 \(selectedApps.count) 个应用").font(.headline)
                                    Text(selectedApps.prefix(5).map(\.name).joined(separator: "、")
                                          + (selectedApps.count > 5 ? " 等" : ""))
                                        .font(.caption).foregroundStyle(.secondary)
                                    Toggle("同时清理每个应用的残留（可恢复）", isOn: $includeResiduals)
                                    Button("卸载选中的 \(selectedApps.count) 个应用", role: .destructive) {
                                        requestUninstall(selectedApps)
                                    }
                                    .disabled(monitor.isUninstalling || isCheckingFamily)
                                }
                            }
                        }

                        if let app = detailApp {
                            HStack(spacing: 12) {
                                Image(nsImage: NSWorkspace.shared.icon(forFile: app.path))
                                    .resizable().frame(width: 54, height: 54)
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(app.name).font(.title2.weight(.semibold))
                                    Text(app.bundleID).font(.caption.monospaced()).textSelection(.enabled)
                                    Text(app.path).font(.caption2).foregroundStyle(.secondary)
                                        .textSelection(.enabled).lineLimit(1)
                                    HStack(spacing: 8) {
                                        Text("最近使用：\(monitor.appLastUsed[app.path].map { $0.formatted(date: .numeric, time: .shortened) } ?? "系统没有记录")")
                                    }
                                    .font(.caption2).foregroundStyle(.secondary)
                                }
                                Spacer()
                                if let size = monitor.selectedAppSize ?? monitor.appSizes[app.path] {
                                    Text(SystemMetrics.bytesText(size)).font(.title3.monospacedDigit())
                                } else {
                                    ProgressView().controlSize(.small)
                                }
                            }

                            if !app.canUninstall {
                                InfoBanner(text: app.isSystem
                                    ? "这是苹果系统组件，只展示，不允许卸载。系统组件被删会直接影响开机与登录。"
                                    : "这个应用不在 /Applications，或没有可移除的应用身份；雪只展示，不执行卸载。",
                                    color: .red)
                            } else if app.isNestedInstall {
                                InfoBanner(text: "嵌套安装：应用装在 /Applications/\(app.installFolderName ?? "")/ 里。卸载只移动 .app 本体；父目录若还有更新器、模板或共享资源会保留，不会静默删除整个厂商目录。",
                                    color: .blue)
                            }

                            Text("残留文件").font(.headline)
                            if monitor.selectedResidualGroups.isEmpty {
                                Text("没有发现该应用的残留目录。").font(.callout).foregroundStyle(.secondary)
                            } else {
                                Toggle("同时把下列残留移入废纸篓（可恢复）", isOn: $includeResiduals)
                                ForEach(monitor.selectedResidualGroups) { group in
                                    VStack(alignment: .leading, spacing: 4) {
                                        HStack {
                                            Text(group.title).font(.caption.weight(.semibold))
                                            Text("\(group.paths.count) 项").font(.caption2).foregroundStyle(.secondary)
                                            Spacer()
                                        }
                                        ModuleCard(padding: 0) {
                                            VStack(spacing: 0) {
                                                ForEach(group.paths, id: \.self) { path in
                                                    HStack {
                                                        Image(systemName: "folder")
                                                        Text(NSString(string: path).abbreviatingWithTildeInPath)
                                                            .font(.caption.monospaced()).lineLimit(1).truncationMode(.middle)
                                                        Spacer()
                                                    }
                                                    .padding(.horizontal, 10).padding(.vertical, 5)
                                                }
                                            }
                                        }
                                    }
                                }
                            }

                            HStack {
                                Button("在访达中显示") {
                                    NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: app.path)])
                                }
                                Spacer()
                                if selectedApps.count <= 1 {
                                    Button("卸载并移入废纸篓", role: .destructive) {
                                        requestUninstall([app])
                                    }
                                    .disabled(!app.canUninstall || monitor.isUninstalling || isCheckingFamily)
                                }
                            }

                            if !monitor.actionMessage.isEmpty {
                                InfoBanner(text: monitor.actionMessage, color: .green)
                            }

                            InfoBanner(text: "卸载只把应用与残留移到废纸篓，不会永久删除；随时可以从废纸篓拖回来。系统组件与雪自己不会进入可卸载清单。每一步都会写本地审计日志。",
                                       color: .blue)
                        } else if selectedApps.count > 1 {
                            ContentUnavailableView("已选多个应用", systemImage: "square.grid.2x2",
                                                   description: Text("上方批量摘要用于整批卸载；右侧不再混排单个应用的体积与残留。要看单个应用详情，请只勾选一个。"))
                        } else if selectedApps.count == 1 {
                            ContentUnavailableView("已选 1 个应用", systemImage: "square.grid.2x2",
                                                   description: Text("点左侧应用名查看详情与残留；批量卸载可用上方按钮。"))
                        } else {
                            ContentUnavailableView("选一个应用", systemImage: "square.grid.2x2",
                                                   description: Text("左侧列出应用；点勾选可多选，点应用名查看残留分组。"))
                        }
                    }
                    .padding(18)
                }
                .frame(minWidth: 440)
            }
        }
        .alert(uninstallAlertTitle, isPresented: $confirmUninstall) {
            Button("取消", role: .cancel) {
                pendingApps = []
            }
            Button("移入废纸篓", role: .destructive) {
                performPendingUninstall()
            }
        } message: {
            Text(uninstallAlertMessage)
        }
        .task {
            await monitor.loadApps()
            if category == .unused { await monitor.loadUsageIfNeeded() }
            await monitor.loadAppSizesIfNeeded()
            if sort == .recent { await monitor.loadUsageIfNeeded() }
        }
        .onChange(of: category) { _, value in
            selectedPaths.removeAll()
            monitor.clearSelection()
            uninstallImpact = nil
            if value == .unused { Task { await monitor.loadUsageIfNeeded() } }
        }
        .onChange(of: sort) { _, value in
            if value == .size { Task { await monitor.loadAppSizesIfNeeded() } }
            if value == .recent { Task { await monitor.loadUsageIfNeeded() } }
        }
    }

    private func requestUninstall(_ apps: [AppEntry]) {
        guard !apps.isEmpty else { return }
        pendingApps = apps
        pendingIncludeResiduals = includeResiduals
        familyCheckError = nil
        let refs = apps.map {
            UninstallAppRef(name: $0.name, bundleID: $0.bundleID, path: $0.path)
        }
        if let report = softwareReport {
            uninstallImpact = UninstallImpactEvaluator.evaluate(report: report, selectedApps: refs)
            confirmUninstall = true
            return
        }

        isCheckingFamily = true
        Task { @MainActor in
            do {
                let report = try await Task.detached(priority: .utility) { () throws -> SoftwareGraphReport in
                    let store = try SoftwareFamilyStore.loadBundled()
                    var options = SoftwareGraphScanOptions.live()
                    options.readPackageReceipts = false
                    options.readLastUsed = false
                    options.computeSizes = false
                    options.maxEntriesPerRoot = 240
                    return SoftwareGraphScanner.scan(store: store, options: options)
                }.value
                softwareReport = report
                uninstallImpact = UninstallImpactEvaluator.evaluate(report: report, selectedApps: refs)
            } catch {
                familyCheckError = "家族影响核对失败：\(error.localizedDescription)。仍可卸载，但无法提示插件归属。"
            }
            isCheckingFamily = false
            confirmUninstall = true
        }
    }

    private func performPendingUninstall() {
        let apps = pendingApps.isEmpty ? uninstallTargets : pendingApps
        let include = pendingApps.isEmpty ? includeResiduals : pendingIncludeResiduals
        let impactBefore = uninstallImpact
        pendingApps = []
        Task { @MainActor in
            let result = await monitor.uninstall(apps: apps, includeResiduals: include)
            selectedPaths.subtract(apps.map(\.path))
            uninstallImpact = nil
            if result.hasPrefix("已") {
                SoftwareGraphSession.shared.invalidate()
                softwareReport = nil
                if let impactBefore, !impactBefore.families.isEmpty {
                    completedImpact = impactBefore
                }
            }
        }
    }

    private func impactCard(_ impact: UninstallImpact) -> some View {
        ModuleCard {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Label("卸载影响", systemImage: "point.3.connected.trianglepath.dotted")
                        .font(.headline)
                    Spacer()
                    Button("去软件族谱核对") { openSoftwareFamily() }
                        .font(.caption)
                }
                Text(impact.summaryText)
                    .font(.callout)
                    .fixedSize(horizontal: false, vertical: true)
                ForEach(impact.families) { family in
                    VStack(alignment: .leading, spacing: 3) {
                        HStack(spacing: 8) {
                            Text(family.familyName).font(.caption.weight(.semibold))
                            if family.becomesOrphan {
                                Text("会失去宿主").font(.caption2).foregroundStyle(.orange)
                            } else if family.isShared {
                                Text("共享，保留").font(.caption2).foregroundStyle(.blue)
                            } else {
                                Text("没有登记插件").font(.caption2).foregroundStyle(.secondary)
                            }
                            Spacer()
                        }
                        Text("卸载：\(family.selectedHosts.map(\.name).joined(separator: "、"))"
                              + " · 仍安装：\(family.remainingHosts.isEmpty ? "无" : family.remainingHosts.map(\.name).joined(separator: "、"))"
                              + " · 插件 \(family.pluginCount) 项")
                            .font(.caption2).foregroundStyle(.secondary)
                        if family.becomesOrphan {
                            Text("可能变孤儿：\(family.pluginFindings.prefix(4).map(\.node.name).joined(separator: "、"))"
                                  + (family.pluginFindings.count > 4 ? " 等" : ""))
                                .font(.caption2).foregroundStyle(.orange)
                        }
                    }
                    .padding(.vertical, 2)
                }
                Text("这里只提示关系；不会自动勾选，也不会自动删除。")
                    .font(.caption2).foregroundStyle(.secondary)
            }
        }
    }

    private func completedImpactCard(_ impact: UninstallImpact) -> some View {
        ModuleCard {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Label("卸载后的孤儿提示", systemImage: "exclamationmark.triangle")
                        .font(.headline)
                    Spacer()
                    Button("关闭") { completedImpact = nil }.font(.caption)
                }
                Text(impact.orphanFamilyCount > 0
                     ? "应用已移入废纸篓。预计 \(impact.orphanFamilyCount) 个家族失去宿主，\(impact.orphanPluginCount) 个插件或组件可能成为孤儿。雪没有自动清理。"
                     : "应用已移入废纸篓。涉及的家族仍有其他宿主，或没有登记插件；雪没有自动清理。")
                    .font(.callout)
                    .fixedSize(horizontal: false, vertical: true)
                ForEach(impact.families.filter(\.becomesOrphan)) { family in
                    Text("\(family.familyName)：\(family.pluginFindings.prefix(5).map(\.node.name).joined(separator: "、"))"
                          + (family.pluginFindings.count > 5 ? " 等 \(family.pluginCount) 项" : ""))
                        .font(.caption).foregroundStyle(.secondary)
                }
                Button("去软件族谱查看证据") { openSoftwareFamily() }
                    .font(.caption)
            }
        }
    }

    private func openSoftwareFamily() {
        UserDefaults.standard.set("族谱", forKey: "snow.main.selection")
    }

    private var allSelectableSelected: Bool {
        let selectable = Set(filtered.filter(\.canUninstall).map(\.path))
        return !selectable.isEmpty && selectedPaths.isSuperset(of: selectable)
    }

    private var uninstallAlertTitle: String {
        let targets = pendingApps.isEmpty ? uninstallTargets : pendingApps
        if targets.count > 1 { return "确认卸载选中的 \(targets.count) 个应用？" }
        return "确认卸载 \(targets.first?.name ?? "")？"
    }

    private var uninstallAlertMessage: String {
        let targets = pendingApps.isEmpty ? uninstallTargets : pendingApps
        var base = "应用本体\(pendingIncludeResiduals ? "和勾选的残留目录" : "")会被移到废纸篓。不会永久删除，也不会有静默清理。"
        let nestedNames = targets.filter(\.isNestedInstall).map(\.name)
        if !nestedNames.isEmpty {
            base += "\n\n嵌套安装（\(nestedNames.prefix(3).joined(separator: "、"))\(nestedNames.count > 3 ? " 等" : "")）只移动 .app 本体，父目录里其他文件会保留。"
        }
        guard let impact = uninstallImpact else { return base }
        return base + "\n\n" + impact.summaryText
    }

    private func isUnused(_ app: AppEntry) -> Bool {
        guard let last = monitor.appLastUsed[app.path] else { return false }
        return last < Date().addingTimeInterval(-90 * 24 * 3600)
    }

    private func toggleSelection(_ app: AppEntry) {
        uninstallImpact = nil
        completedImpact = nil
        guard app.canUninstall else {
            selectedPaths.remove(app.path)
            Task { await monitor.select(app: app) }
            return
        }
        if selectedPaths.contains(app.path) {
            selectedPaths.remove(app.path)
            if selectedPaths.isEmpty { monitor.clearSelection() }
        } else {
            selectedPaths.insert(app.path)
            Task { await monitor.select(app: app) }
        }
    }
}

// MARK: - 优化

struct OptimizeView: View {
    @AppStorage("snow.optimize.dns") private var dnsOn = true
    @AppStorage("snow.optimize.launchservices") private var launchServicesOn = false
    @AppStorage("snow.optimize.spotlight") private var spotlightOn = false
    @AppStorage("snow.optimize.purge") private var purgeOn = false
    @State private var isRunning = false
    @State private var resultText = ""
    @State private var showPreview = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                PageHeader(title: "优化", subtitle: "每一项都说明「做了什么、有什么用」。能执行的只有不需要管理员权限的安全项。")

                ModuleCard(padding: 0) {
                    VStack(spacing: 0) {
                        optimizeRow(title: "刷新 DNS 缓存", detail: "清掉本机域名解析缓存，解决个别网站打不开或解析到旧地址的问题。",
                                    enabled: $dnsOn, tag: "可执行")
                        Divider()
                        optimizeRow(title: "重建「打开方式」索引", detail: "重新登记应用与文件类型的关联。双击文件打开错应用时可用；耗时约十几秒。",
                                    enabled: $launchServicesOn, tag: "可执行")
                        Divider()
                        optimizeRow(title: "重建聚焦（Spotlight）索引", detail: "让搜索重新收录文件。需要管理员权限，当前版本只做预览，不代跑 sudo。",
                                    enabled: $spotlightOn, tag: "需管理员 · 仅预览")
                        Divider()
                        optimizeRow(title: "释放被占用的内存页", detail: "系统自带的 purge 需要管理员权限。当前版本不执行，避免未经授权改动系统内存状态。",
                                    enabled: $purgeOn, tag: "需管理员 · 仅预览")
                    }
                }

                HStack {
                    Text("已启用 \(enabledCount) 项").font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button("预览") { showPreview = true }
                    Button("运行已启用项") { Task { await runEnabled() } }
                        .buttonStyle(.borderedProminent)
                        .disabled(isRunning)
                }

                if isRunning {
                    HStack(spacing: 8) { ProgressView().controlSize(.small); Text("正在执行…") }
                }
                if !resultText.isEmpty {
                    ModuleCard {
                        Text(resultText).font(.callout.monospaced()).textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }

                InfoBanner(text: "需要管理员权限的项目不会偷偷用 sudo 执行。要跑它们，请自己在终端执行，或等后续版本提供逐项授权。",
                           color: .orange)
            }
            .padding(18)
        }
        .alert("将运行以下项", isPresented: $showPreview) {
            Button("知道了", role: .cancel) {}
        } message: {
            Text(previewText)
        }
    }

    private var enabledCount: Int {
        [dnsOn, launchServicesOn].filter { $0 }.count
    }

    private var previewText: String {
        var lines: [String] = []
        if dnsOn { lines.append("· 刷新 DNS 缓存：dscacheutil -flushcache") }
        if launchServicesOn { lines.append("· 重建打开方式索引：lsregister -kill -r") }
        if lines.isEmpty { return "没有勾选任何可执行项。" }
        return lines.joined(separator: "\n")
    }

    private func optimizeRow(title: String, detail: String, enabled: Binding<Bool>, tag: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 8) {
                    Text(title).font(.body.weight(.medium))
                    Text(tag).font(.caption2)
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background((tag == "可执行" ? Color.green : Color.orange).opacity(0.12), in: Capsule())
                        .foregroundStyle(tag == "可执行" ? Color.green : Color.orange)
                }
                Text(detail).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            Toggle("", isOn: enabled)
                .labelsHidden()
                .disabled(tag != "可执行")
        }
        .padding(14)
    }

    private func runEnabled() async {
        isRunning = true
        var lines: [String] = []
        if dnsOn {
            let result = await Task.detached {
                SystemMetrics.execute("/usr/bin/dscacheutil", ["-flushcache"])
            }.value
            lines.append("刷新 DNS 缓存：\(result.code == 0 ? "完成" : "退出码 \(result.code)")")
        }
        if launchServicesOn {
            let path = "/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"
            let result = await Task.detached {
                SystemMetrics.execute(path, ["-kill", "-r", "-domain", "local", "-domain", "system", "-domain", "user"])
            }.value
            lines.append("重建打开方式索引：\(result.code == 0 ? "完成" : "退出码 \(result.code)")")
        }
        if lines.isEmpty { lines.append("没有勾选任何可执行项。") }
        resultText = lines.joined(separator: "\n")
        isRunning = false
    }
}

// MARK: - 自定义保护路径

struct ProtectManagerView: View {
    @EnvironmentObject var model: ScanViewModel
    @State private var newPath = ""
    @State private var message = ""

    private struct Preset: Identifiable {
        let id: String
        let title: String
        let detail: String
        let symbol: String
        let paths: [String]
    }

    private let presets: [Preset] = [
        .init(id: "dev", title: "开发目录", detail: "代码、依赖与构建产物",
              symbol: "hammer", paths: ["~/Developer/**", "~/Projects/**", "~/Code/**"]),
        .init(id: "photo", title: "摄影素材", detail: "原片、导出与拍摄项目",
              symbol: "camera", paths: ["~/Pictures/**", "~/Desktop/摄影/**"]),
        .init(id: "work", title: "工作文档", detail: "合同、方案与客户资料",
              symbol: "doc.text", paths: ["~/Documents/工作/**", "~/Desktop/工作/**"])
    ]

    private var overlaps: [ProtectionOverlap] {
        ProtectionOverlapDetector.inspect(
            paths: model.customProtections,
            builtInPatterns: model.builtInProtectionPaths
        )
    }

    private var errorText: String? {
        model.errorMessage?.errorDescription
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .top) {
                    PageHeader(title: "自定义保护路径", subtitle: "你亲手加进来的目录，连同它的全部子目录，永远不会进入清理候选。")
                    Spacer()
                    Button("导入清单") { importPaths() }
                    Button("导出清单") { exportPaths() }
                        .disabled(model.customProtections.isEmpty)
                }

                InfoBanner(text: "保护清单只做加法：内置规则覆盖不到这里，用户规则也不能穿透保护。导入支持雪清单与旧版字符串数组。",
                           color: .blue)

                HStack(spacing: 7) {
                    TextField("例如 ~/Documents/私人资料/**", text: $newPath)
                        .textFieldStyle(.roundedBorder)
                    Button("添加路径") {
                        let trimmed = newPath.trimmingCharacters(in: .whitespacesAndNewlines)
                        guard !trimmed.isEmpty else { return }
                        model.addProtection(trimmed)
                        if model.errorMessage == nil {
                            newPath = ""
                            message = "已加入保护清单"
                        }
                    }
                    .buttonStyle(.borderedProminent)
                }

                VStack(alignment: .leading, spacing: 8) {
                    Text("快速预设").font(.headline)
                    Text("只加入路径模式，不会移动、读取或删除任何文件；已有条目会自动跳过。")
                        .font(.caption).foregroundStyle(.secondary)
                    HStack(spacing: 8) {
                        ForEach(presets) { preset in
                            Button {
                                addPreset(preset)
                            } label: {
                                HStack(spacing: 7) {
                                    Image(systemName: preset.symbol)
                                    VStack(alignment: .leading, spacing: 1) {
                                        Text(preset.title).font(.callout.weight(.semibold))
                                        Text(preset.detail).font(.caption2).foregroundStyle(.secondary)
                                    }
                                }
                                .padding(.horizontal, 10).padding(.vertical, 7)
                            }
                            .buttonStyle(.bordered)
                        }
                    }
                }
                .padding(12)
                .background(.quaternary.opacity(0.28), in: RoundedRectangle(cornerRadius: 10))

                if let errorText {
                    Text(errorText)
                        .font(.caption).foregroundStyle(.red)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(10)
                        .background(Color.red.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
                }

                HStack {
                    Text("我保护的路径").font(.headline)
                    Text("\(model.customProtections.count) 条").font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    if !message.isEmpty { Text(message).font(.caption).foregroundStyle(.green) }
                }

                if !overlaps.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        Label("与内置清单有重叠", systemImage: "exclamationmark.triangle.fill")
                            .font(.callout.weight(.semibold))
                            .foregroundStyle(.orange)
                        ForEach(overlaps) { overlap in
                            VStack(alignment: .leading, spacing: 2) {
                                Text(overlap.path).font(.caption.monospaced())
                                Text(overlap.message).font(.caption).foregroundStyle(.secondary)
                                if !overlap.builtInPatterns.isEmpty {
                                    Text("内置：\(overlap.builtInPatterns.joined(separator: "、"))")
                                        .font(.caption2).foregroundStyle(.secondary)
                                }
                            }
                            .padding(.vertical, 3)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(11)
                    .background(Color.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 9))
                }

                if model.customProtections.isEmpty {
                    InfoBanner(text: "还没有自定义保护路径。可以从上面的预设开始，或手动添加一条。", color: .gray)
                } else {
                    ModuleCard(padding: 0) {
                        VStack(spacing: 0) {
                            ForEach(model.customProtections, id: \.self) { path in
                                HStack(spacing: 8) {
                                    Image(systemName: "shield")
                                        .foregroundStyle(.green)
                                    Text(path).font(.callout.monospaced()).textSelection(.enabled)
                                    Spacer()
                                    if let overlap = overlaps.first(where: { $0.path == path }) {
                                        Text(overlap.kind == .broaderThanBuiltIn ? "范围更宽" : "已内置覆盖")
                                            .font(.caption2)
                                            .foregroundStyle(.orange)
                                    }
                                    Button("移除") { model.removeProtection(path) }
                                        .buttonStyle(.borderless)
                                }
                                .padding(.horizontal, 12).padding(.vertical, 8)
                                Divider()
                            }
                        }
                    }
                }

                Text("内置永不清理清单").font(.headline)
                Text("规则库共 \(model.builtInProtectionPaths.count) 条保护模式；它们比用户清单优先，用户规则不能穿透。")
                    .font(.caption).foregroundStyle(.secondary)
                ModuleCard {
                    LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], alignment: .leading, spacing: 6) {
                        ForEach(["本地 AI 工具整根（含私钥与配置）", "手机备份与同步", "iCloud 本地文件", "密码钥匙串",
                                 "系统关键路径", "APFS 数据卷", "Homebrew", "应用程序", "外接卷", "运行中的 App 数据"], id: \.self) {
                            Text("· \($0)").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    if !model.builtInProtectionPaths.isEmpty {
                        DisclosureGroup("查看 \(model.builtInProtectionPaths.count) 条内置模式") {
                            VStack(alignment: .leading, spacing: 4) {
                                ForEach(model.builtInProtectionPaths, id: \.self) { path in
                                    Text(path).font(.caption2.monospaced()).textSelection(.enabled)
                                }
                            }
                            .padding(.top, 6)
                        }
                        .font(.caption)
                        .padding(.top, 8)
                    }
                }
            }
            .padding(18)
        }
    }

    private func addPreset(_ preset: Preset) {
        let added = model.importProtections(preset.paths)
        if let errorText = model.errorMessage?.errorDescription {
            message = errorText
        } else if added == 0 {
            message = "「\(preset.title)」已在保护清单里，没有重复添加"
        } else {
            message = "已加入「\(preset.title)」\(added) 条"
        }
    }

    private func exportPaths() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.canCreateDirectories = true
        panel.nameFieldStringValue = "雪-保护路径.json"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let data = try ProtectionTransfer.encode(paths: model.customProtections)
            try data.write(to: url, options: .atomic)
            message = "已导出 \(model.customProtections.count) 条"
        } catch {
            message = "导出失败：\(error.localizedDescription)"
        }
    }

    private func importPaths() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let data = try Data(contentsOf: url)
            let paths = try ProtectionTransfer.decode(data)
            let added = model.importProtections(paths)
            if let errorText = model.errorMessage?.errorDescription {
                message = errorText
            } else {
                message = added == 0 ? "清单里没有新路径" : "已导入 \(added) 条新路径"
            }
        } catch {
            message = "导入失败：\(error.localizedDescription)"
        }
    }
}

// MARK: - 模型自检

struct SelfCheckView: View {
    @EnvironmentObject var model: ScanViewModel
    @State private var rows: [SelfCheckRow] = []
    @State private var metricsText = ""
    @State private var errorText = ""
    @State private var isRunning = false
    @State private var unsupported = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .top) {
                    PageHeader(title: "本地模型自检", subtitle: "开发验证页，不参与真实扫描和删除判定。模型只做描述，规则仍决定能不能删。")
                    Spacer()
                    Button("运行自检") { Task { await runCheck() } }
                        .buttonStyle(.borderedProminent)
                        .disabled(isRunning)
                }

                InfoBanner(text: "样例固定为 3 条：正常缓存、个人文档、工具配置。模型说出「可以全部删除」这类指令会被拦截，不会改变任何判定。",
                           color: .blue)

                ModuleCard {
                    HStack {
                        VStack(alignment: .leading, spacing: 3) {
                            Text("解释档位").font(.body.weight(.medium))
                            Text("关闭＝零调用；混合模板＝中文模板＋模型填空；完整 AI＝模型生成大白话。")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Picker("", selection: $model.aiMode) {
                            Text("关闭").tag(AIMode.off)
                            Text("混合模板").tag(AIMode.hybrid)
                            Text("完整 AI").tag(AIMode.full)
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()
                        .frame(width: 280)
                    }
                }

                if unsupported && errorText.isEmpty {
                    InfoBanner(text: "当前系统或构建不支持端侧模型，所有名称仍由内置中文词典解释，不影响清理判定。",
                               color: .orange)
                }
                if !errorText.isEmpty {
                    InfoBanner(text: errorText, color: .orange)
                }
                if !metricsText.isEmpty {
                    InfoBanner(text: metricsText, color: .green)
                }

                if rows.isEmpty {
                    ModuleCard {
                        Text(emptyStateText)
                            .font(.callout).foregroundStyle(.secondary)
                    }
                } else {
                    ModuleCard(padding: 0) {
                        VStack(spacing: 0) {
                            HStack {
                                Text("原始路径").frame(maxWidth: .infinity, alignment: .leading)
                                Text("模型中文输出").frame(maxWidth: .infinity, alignment: .leading)
                                Text("置信度").frame(width: 64, alignment: .trailing)
                                Text("判定").frame(width: 64, alignment: .trailing)
                            }
                            .font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                            .padding(10)
                            Divider()
                            ForEach(rows) { row in
                                HStack(alignment: .top) {
                                    Text(row.path).font(.caption.monospaced()).frame(maxWidth: .infinity, alignment: .leading)
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(row.what).font(.caption)
                                        Text(row.impact).font(.caption2).foregroundStyle(.secondary)
                                        if row.flagged {
                                            Text("含删除指令词，已拦截").font(.caption2).foregroundStyle(.red)
                                        }
                                    }
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    Text(String(format: "%.2f", row.confidence))
                                        .font(.caption.monospacedDigit()).frame(width: 64, alignment: .trailing)
                                    Text(row.level).font(.caption2)
                                        .foregroundStyle(row.level == "安全" ? Color.green : (row.level == "受保护" ? Color.red : Color.orange))
                                        .frame(width: 64, alignment: .trailing)
                                }
                                .padding(10)
                                Divider()
                            }
                        }
                    }
                }
            }
            .padding(18)
        }
    }

    private var emptyStateText: String {
        if isRunning { return "正在跑三条样例…" }
        if !errorText.isEmpty { return "本次自检没有完成；清理判定与内置中文词典不受影响。" }
        if unsupported { return "没有可展示的自检结果；内置中文词典仍正常工作。" }
        return "尚未运行。点右上角「运行自检」开始；档位为「关闭」时不会调用模型。"
    }

    private func runCheck() async {
        guard model.aiMode != .off else {
            errorText = "当前档位是「关闭」，不会调用模型。先切到「混合模板」或「完整 AI」。"
            rows = []
            metricsText = ""
            unsupported = false
            return
        }
        isRunning = true
        errorText = ""
        metricsText = ""
        unsupported = false
        #if canImport(FoundationModels) && !SNOWSWEEP_DISABLE_AI
        if #available(macOS 26.0, *) {
            do {
                let planner = AIPlanner(policy: AIPolicy(mode: model.aiMode))
                let report = try await planner.runSelfCheck()
                rows = report.results.map { result in
                    SelfCheckRow(
                        path: result.path,
                        what: result.suggestion.what,
                        impact: result.suggestion.impact,
                        confidence: result.suggestion.confidence,
                        level: levelText(result.suggestion.level),
                        flagged: result.suggestion.hallucinationFlagged
                    )
                }
                let metrics = report.metrics
                metricsText = "样例 \(metrics.samples) 条 · 中文达标 \(metrics.chineseSamples) 条 · 危险输出 \(metrics.dangerousOutputs) 条 · 平均置信度 \(String(format: "%.2f", metrics.averageConfidence)) · \(metrics.passed ? "通过" : "需复核")"
            } catch {
                let raw = error.localizedDescription
                unsupported = SelfCheckFailureCopy.isUnsupportedDevice(raw)
                errorText = SelfCheckFailureCopy.message(for: raw)
            }
        } else {
            unsupported = true
        }
        #else
        unsupported = true
        #endif
        isRunning = false
    }

    private func levelText(_ level: RiskLevel) -> String {
        switch level {
        case .safe: return "安全"
        case .review: return "需确认"
        case .protected: return "受保护"
        case .unknown: return "未知"
        }
    }
}

private struct SelfCheckRow: Identifiable {
    let id = UUID()
    let path: String
    let what: String
    let impact: String
    let confidence: Double
    let level: String
    let flagged: Bool
}
