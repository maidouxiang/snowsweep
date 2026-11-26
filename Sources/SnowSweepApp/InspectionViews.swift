import SwiftUI
import AppKit
import Darwin
import SnowSweepCore

private struct RiskTag: View {
    let level: RiskLevel

    private var label: String {
        switch level {
        case .safe: return "安全"
        case .review: return "需确认"
        case .protected: return "受保护"
        case .unknown: return "未知"
        }
    }

    private var color: Color {
        switch level {
        case .safe: return .green
        case .review: return .orange
        case .protected: return .red
        case .unknown: return .gray
        }
    }

    var body: some View {
        Text(label)
            .font(.caption2.weight(.semibold))
            .padding(.horizontal, 7).padding(.vertical, 3)
            .background(color.opacity(0.14), in: Capsule())
            .foregroundStyle(color)
    }
}

/// 权限清单：只读显示，不提供任何"关闭"开关。
private func friendlyGapMessage(_ message: String) -> String {
    let lower = message.lowercased()
    if lower.contains("authorization denied") || lower.contains("unable to open database") {
        return "系统权限数据库受保护，读不到当前的授权清单。请到「系统设置 › 隐私与安全性 › 完全磁盘访问权限」里勾选雪后再点「重新读取」。本软件只读，不会修改任何授权。"
    }
    return message
}

struct PermissionListView: View {
    @EnvironmentObject var model: ScanViewModel
    @State private var search = ""

    private var filteredGrants: [PermissionGrant] {
        guard let grants = model.permissionSnapshot?.grants else { return [] }
        let text = search.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return grants }
        return grants.filter {
            $0.appName.localizedCaseInsensitiveContains(text) ||
            $0.permissionName.localizedCaseInsensitiveContains(text) ||
            $0.rawService.localizedCaseInsensitiveContains(text) ||
            $0.settingsPath.localizedCaseInsensitiveContains(text)
        }
    }

    var body: some View {
        ScrollView {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("权限清单").font(.largeTitle.bold())
                    Text("只读查看哪些程序拿到了敏感权限，以及雪自己还有哪些目录读不到。关闭授权必须你自己去系统设置。")
                        .font(.callout).foregroundStyle(.secondary)
                }
                Spacer()
                Button("重新读取") { model.refreshInspections() }
                    .disabled(model.isInspecting)
            }

            FDAScopeCard()

            SystemPathAccessCard()

            if model.isInspecting {
                ProgressView("正在只读读取授权清单…")
            }

            if let snapshot = model.directoryAccess {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(alignment: .firstTextBaseline) {
                        Text("雪的目录访问").font(.headline)
                        Text("\(snapshot.directories.count) 个关键位置 · \(snapshot.unreadableCount) 个读不到 · \(snapshot.unverifiedCount) 个未验证")
                            .font(.caption).foregroundStyle(snapshot.unreadableCount == 0 ? .green : .orange)
                        Spacer()
                        Text("只读探测，不读取文件内容").font(.caption2).foregroundStyle(.secondary)
                    }
                    LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], alignment: .leading, spacing: 8) {
                        ForEach(snapshot.directories) { row in
                            HStack(alignment: .top, spacing: 8) {
                                Image(systemName: row.readable ? "checkmark.circle.fill" : (row.exists ? "exclamationmark.triangle.fill" : "minus.circle"))
                                    .foregroundStyle(row.readable ? Color.green : (row.exists ? Color.orange : Color.secondary))
                                VStack(alignment: .leading, spacing: 3) {
                                    HStack(spacing: 6) {
                                        Text(row.chineseName).font(.callout.weight(.semibold))
                                        Text(row.stateLabel)
                                            .font(.caption2.weight(.semibold))
                                            .foregroundStyle(row.readable ? .green : (row.exists ? .orange : .secondary))
                                    }
                                    Text(row.impact).font(.caption).foregroundStyle(.secondary)
                                    if row.exists && !row.readable {
                                        Text(row.permissionHint).font(.caption2).foregroundStyle(.orange)
                                        Button("去授权") { openSettings(for: row) }
                                            .buttonStyle(.link).font(.caption2)
                                    }
                                }
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(9)
                            .background(.quaternary.opacity(0.25), in: RoundedRectangle(cornerRadius: 8))
                        }
                    }
                }
            } else if !model.isInspecting {
                InfoBanner(text: "点「重新读取」后会逐个探测关键目录；只判断能不能列目录，不读取内容。", color: .gray)
            }

            if let snapshot = model.permissionSnapshot {
                let blocked = snapshot.gaps.contains { $0.blocksResult }
                HStack(spacing: 18) {
                    StatCard(title: "已授权项", value: blocked && snapshot.grants.isEmpty ? "未验证" : "\(snapshot.grants.count)")
                    StatCard(title: "需确认", value: blocked && snapshot.grants.isEmpty ? "未验证" : "\(snapshot.grants.filter { $0.risk == .review }.count)")
                    StatCard(title: "高敏感", value: blocked && snapshot.grants.isEmpty ? "未验证" : "\(snapshot.grants.filter { $0.risk == .protected }.count)")
                }

                ForEach(snapshot.gaps) { gap in
                    Text(friendlyGapMessage(gap.message))
                        .font(.caption)
                        .foregroundStyle(gap.blocksResult ? .red : .orange)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(10)
                        .background(Color.orange.opacity(0.10), in: RoundedRectangle(cornerRadius: 8))
                }

                HStack(spacing: 8) {
                    Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                    TextField("搜索程序名、权限或系统设置位置", text: $search)
                        .textFieldStyle(.plain)
                    if !search.isEmpty {
                        Button("清空") { search = "" }.buttonStyle(.borderless).font(.caption)
                    }
                }
                .padding(.horizontal, 9).padding(.vertical, 6)
                .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 8))

                if filteredGrants.isEmpty {
                    ContentUnavailableView("没有匹配的授权记录", systemImage: "magnifyingglass",
                                           description: Text("换个程序名或权限名试试。"))
                        .frame(maxWidth: .infinity, minHeight: 160)
                } else {
                    List(filteredGrants) { grant in
                        DisclosureGroup {
                            VStack(alignment: .leading, spacing: 7) {
                                Label(grant.explain, systemImage: "info.circle")
                                Label(grant.whyNeeded, systemImage: "questionmark.circle")
                                Label(grant.suggestion, systemImage: "lightbulb")
                                HStack(alignment: .firstTextBaseline) {
                                    Text("原始英文标识").font(.caption).foregroundStyle(.secondary)
                                    Text(grant.rawService).font(.caption.monospaced()).textSelection(.enabled)
                                    Text(grant.rawClient).font(.caption.monospaced()).textSelection(.enabled)
                                }
                                Button("前往系统设置 › \(grant.settingsPath)") {
                                    model.openPermissionSettings(for: grant)
                                }
                                .buttonStyle(.link)
                            }
                            .font(.callout)
                            .padding(.top, 6)
                        } label: {
                            HStack(spacing: 10) {
                                RiskTag(level: grant.risk)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(grant.appName).font(.body)
                                    Text(grant.permissionName).font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer()
                                Text(grant.settingsPath).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                    .listStyle(.inset)
                    .frame(minHeight: 220, maxHeight: 320)
                }
            } else if !model.isInspecting {
                ContentUnavailableView {
                    Label("还没有读取权限清单", systemImage: "hand.raised")
                } description: {
                    Text("读取过程只在本机进行，不会联网，也不会修改任何授权。")
                } actions: {
                    Button("开始只读读取") { model.refreshInspections() }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        }
        .task { if model.permissionSnapshot == nil { model.refreshInspections() } }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            if model.permissionSnapshot != nil && !model.isInspecting {
                model.refreshInspections()
            }
        }
    }

    private func openSettings(for row: RestrictedDirectoryStatus) {
        switch row.chineseName {
        case "桌面", "文稿", "下载":
            model.openPermissionSettings(for: .folders)
        case "照片图库":
            model.openPermissionSettings(for: .photos)
        default:
            model.openFullDiskAccessSettings()
        }
    }
}

/// FDA 授权范围可视化：把"系统给了谁什么权限"和"本软件想扫多远"分开讲清楚。
private struct FDAScopeCard: View {
    @EnvironmentObject var model: ScanViewModel

    private var status: FDAScopeStatus { model.fdaScopeStatus }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: status.isHealthy ? "lock.shield" : "lock.shield.fill")
                    .foregroundStyle(status.isHealthy ? .green : .orange)
                Text("我的完全磁盘访问范围").font(.headline)
                Spacer()
                Text(model.scanScope.chineseName)
                    .font(.caption)
                    .padding(.horizontal, 8).padding(.vertical, 4)
                    .background(.quaternary.opacity(0.5), in: Capsule())
            }
            Text(status.title).font(.subheadline.weight(.semibold))
            Text(status.explain).font(.caption).foregroundStyle(.secondary)
            Text("当前扫描范围：\(model.scanScope.chineseName)。" + model.scanScope.explain)
                .font(.caption).foregroundStyle(.secondary)
            Text("一次授权覆盖桌面、文稿、下载、图片、音乐、影片等受保护目录；macOS 不允许雪替你勾选，也没有真正“一键自动授权”的接口。")
                .font(.caption2).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 12) {
                Button("① 一键打开完全磁盘访问") { model.openFullDiskAccessSettings() }
                Button("② 复制雪路径") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(Bundle.main.bundlePath, forType: .string)
                }
                Button("③ 授权后重启雪") { model.relaunchApplication() }
                Button("调整扫描范围") {
                    UserDefaults.standard.set("设置", forKey: "snow.main.selection")
                }
            }
            .buttonStyle(.link)
            .font(.caption)
            Text("在系统设置里点「+」，把复制的路径添加进去并打开开关；回到雪后重启一次。重装会改变本地签名，旧授权可能失效，需要再授权一次。")
                .font(.caption2).foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(12)
        .background(Color.blue.opacity(0.06), in: RoundedRectangle(cornerRadius: 10))
    }
}

/// 启动项审查：只读显示，不提供"禁用"按钮。
struct StartupListView: View {
    @EnvironmentObject var model: ScanViewModel
    @State private var search = ""
    @State private var scopeKey = "all"

    private func uniqueItems(_ snapshot: StartupSnapshot) -> [StartupItem] {
        snapshot.deduplicatedItems
    }

    private func matchesSearch(_ item: StartupItem, text: String) -> Bool {
        text.isEmpty ||
        item.displayName.localizedCaseInsensitiveContains(text) ||
        item.sourceApp.localizedCaseInsensitiveContains(text) ||
        item.rawLabel.localizedCaseInsensitiveContains(text) ||
        item.launchMethod.localizedCaseInsensitiveContains(text) ||
        item.rawCommand.localizedCaseInsensitiveContains(text)
    }

    private func visibleItems(_ all: [StartupItem]) -> [StartupItem] {
        let text = search.trimmingCharacters(in: .whitespacesAndNewlines)
        return all.filter { item in
            (scopeKey == "all" || item.scope.rawValue == scopeKey) && matchesSearch(item, text: text)
        }
    }

    private var scopeOptions: [(key: String, title: String, count: Int)] {
        let all = model.startupSnapshot.map(uniqueItems) ?? []
        return [("all", "全部", all.count)] + StartupScope.allCases.map { scope in
            (scope.rawValue, scope.chineseName, all.filter { $0.scope == scope }.count)
        }
    }

    var body: some View {
        ScrollView {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("启动项审查").font(.largeTitle.bold())
                    Text("按登录项、用户 LaunchAgents、系统 Agent 与后台服务分类。这里只读，不写任何系统配置；启停请到系统设置亲手操作。")
                        .font(.callout).foregroundStyle(.secondary)
                }
                Spacer()
                Button("重新读取") { model.refreshInspections() }
                    .disabled(model.isInspecting)
                Button("打开登录项设置") { model.openLoginItemsSettings() }
            }

            if model.isInspecting {
                ProgressView("正在只读读取启动项配置…")
            }

            if let snapshot = model.startupSnapshot {
                let all = uniqueItems(snapshot)
                let filtered = visibleItems(all)
                HStack(spacing: 18) {
                    StatCard(title: "启动项总数", value: "\(all.count)")
                    StatCard(title: "系统级", value: "\(all.filter { $0.risk == .protected }.count)")
                    StatCard(title: "需确认", value: "\(all.filter { $0.risk == .review }.count)")
                    StatCard(title: "安全", value: "\(all.filter { $0.risk == .safe }.count)")
                }

                ForEach(snapshot.gaps) { gap in
                    Text(gap.message)
                        .font(.caption).foregroundStyle(.orange)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(10)
                        .background(Color.orange.opacity(0.10), in: RoundedRectangle(cornerRadius: 8))
                }

                HStack(spacing: 8) {
                    Picker("分类", selection: $scopeKey) {
                        ForEach(scopeOptions, id: \.key) { option in
                            Text("\(option.title) \(option.count)").tag(option.key)
                        }
                    }
                    .pickerStyle(.menu)
                    .frame(minWidth: 160)

                    HStack(spacing: 6) {
                        Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                        TextField("搜索程序名、原始标识或命令", text: $search)
                            .textFieldStyle(.plain)
                        if !search.isEmpty {
                            Button("清空") { search = "" }.buttonStyle(.borderless).font(.caption)
                        }
                    }
                    .padding(.horizontal, 9).padding(.vertical, 6)
                    .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 8))

                    Spacer()
                    Text("显示 \(filtered.count) / \(all.count)").font(.caption).foregroundStyle(.secondary)
                }

                Text("只读说明：配置文件里没有可靠的“当前启用/禁用”字段，本软件不猜测状态；系统设置里的开关才是准的。")
                    .font(.caption2).foregroundStyle(.secondary)

                if filtered.isEmpty {
                    ContentUnavailableView("没有匹配的启动项", systemImage: "line.3.horizontal.decrease.circle",
                                           description: Text("换一个分类或清空搜索词试试。"))
                        .frame(maxWidth: .infinity, minHeight: 160)
                } else {
                    List {
                        ForEach(StartupScope.allCases, id: \.self) { scope in
                            let scoped = filtered.filter { $0.scope == scope }
                            if !scoped.isEmpty {
                                Section("\(scope.chineseName) · \(scoped.count)") {
                                    ForEach(scoped) { item in
                                        DisclosureGroup {
                                            VStack(alignment: .leading, spacing: 7) {
                                                Label(item.why, systemImage: "info.circle")
                                                Label(item.suggestion, systemImage: "lightbulb")
                                                Label("来源：\(item.sourceApp) · \(item.launchMethod)", systemImage: "app.badge")
                                                HStack(alignment: .firstTextBaseline) {
                                                    Text("原始英文标识").font(.caption).foregroundStyle(.secondary)
                                                    Text(item.rawLabel).font(.caption.monospaced()).textSelection(.enabled)
                                                }
                                                if !item.rawCommand.isEmpty {
                                                    Text("实际命令：\(item.rawCommand)")
                                                        .font(.caption.monospaced()).textSelection(.enabled)
                                                }
                                                HStack(spacing: 12) {
                                                    Button("在 Finder 中显示配置文件") {
                                                        NSWorkspace.shared.activateFileViewerSelecting(
                                                            [URL(fileURLWithPath: item.rawPath)]
                                                        )
                                                    }
                                                    Button("复制配置路径") {
                                                        NSPasteboard.general.clearContents()
                                                        NSPasteboard.general.setString(item.rawPath, forType: .string)
                                                    }
                                                    Button("去系统设置 › 登录项") {
                                                        model.openLoginItemsSettings()
                                                    }
                                                }
                                                .buttonStyle(.link)
                                            }
                                            .font(.callout)
                                            .padding(.top, 6)
                                        } label: {
                                            HStack(spacing: 10) {
                                                RiskTag(level: item.risk)
                                                VStack(alignment: .leading, spacing: 2) {
                                                    Text(item.displayName).font(.body)
                                                    Text("\(item.sourceApp) · \(item.launchMethod)")
                                                        .font(.caption).foregroundStyle(.secondary)
                                                }
                                                Spacer()
                                                Text(item.scope.chineseName)
                                                    .font(.caption2).foregroundStyle(.secondary)
                                            }
                                        }
                                    }
                                }
                            }
                        }
                    }
                    .listStyle(.inset)
                    .frame(minHeight: 240, maxHeight: 360)
                }
            } else if !model.isInspecting {
                ContentUnavailableView {
                    Label("还没有读取启动项", systemImage: "paperclip")
                } description: {
                    Text("只读取配置文件，不会禁用任何服务，也不会联网。")
                } actions: {
                    Button("开始只读读取") { model.refreshInspections() }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        }
        .task { if model.startupSnapshot == nil { model.refreshInspections() } }
    }
}

private struct StatCard: View {
    let title: String
    let value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.title3.weight(.semibold))
        }
        .frame(minWidth: 92, alignment: .leading)
        .padding(10)
        .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 9))
    }
}

private struct SystemPathAccessRow: Identifiable {
    let path: String
    let label: String
    let exists: Bool
    let readable: Bool
    let detail: String
    var id: String { path }
}

/// 完全磁盘访问只解决 TCC 那一层；SIP 和 root 拥有目录仍然不可写。
/// 这张卡把“能列目录 / 无权限 / 不存在 / 被系统策略拒绝”分开，不笼统说没权限。
private struct SystemPathAccessCard: View {
    @State private var rows: [SystemPathAccessRow] = []
    @State private var isLoading = false
    @State private var checkedAt: Date?

    private let targets: [(String, String)] = [
        ("/Applications", "应用程序"),
        ("/Library", "共享资源库"),
        ("/System/Library", "系统本体"),
        ("/usr", "Unix 工具"),
        ("/private/var/log", "系统日志"),
        ("/Users", "用户目录"),
        ("/Volumes", "外置卷")
    ]

    var body: some View {
        ModuleCard {
            VStack(alignment: .leading, spacing: 9) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Label("系统路径只读体检", systemImage: "internaldrive")
                        .font(.headline)
                    Spacer()
                    Button(isLoading ? "检测中…" : "重新检测") {
                        probe()
                    }
                    .controlSize(.small)
                    .disabled(isLoading)
                }
                Text("只判断能不能列出目录，不读文件内容、不尝试修改。完全磁盘访问不等于能删系统文件：SIP 和 root 权限仍会拦住写入。")
                    .font(.caption2).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                if isLoading && rows.isEmpty {
                    ProgressView().controlSize(.small)
                } else {
                    LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], alignment: .leading, spacing: 7) {
                        ForEach(rows, id: \.path) { row in
                            HStack(alignment: .top, spacing: 8) {
                                Image(systemName: row.readable ? "checkmark.circle.fill" : (row.exists ? "exclamationmark.triangle.fill" : "minus.circle"))
                                    .foregroundStyle(row.readable ? Color.green : (row.exists ? Color.orange : Color.secondary))
                                VStack(alignment: .leading, spacing: 2) {
                                    HStack(spacing: 6) {
                                        Text(row.label).font(.callout.weight(.semibold))
                                        Text(row.readable ? "可列目录" : (row.exists ? "读不到" : "不存在"))
                                            .font(.caption2.weight(.semibold))
                                            .foregroundStyle(row.readable ? Color.green : (row.exists ? Color.orange : Color.secondary))
                                    }
                                    Text(row.path).font(.caption2.monospaced()).foregroundStyle(Color.secondary).lineLimit(1)
                                    Text(row.detail).font(.caption2).foregroundStyle(row.readable ? Color.secondary : Color.orange)
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                            }
                            .padding(8)
                            .background(.quaternary.opacity(0.22), in: RoundedRectangle(cornerRadius: 8))
                        }
                    }
                    if let checkedAt {
                        Text("检测时间：\(checkedAt.formatted(date: .omitted, time: .standard))")
                            .font(.caption2).foregroundStyle(.tertiary)
                    }
                }

                Text("如果这里能列目录、空间分析却仍标「读不到」，那是某个子目录需要 root 或被 SIP 保护，不是 TCC 没给。空间分析会对具体目录显示「读不到」。")
                    .font(.caption2).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .task { if rows.isEmpty { probe() } }
    }

    private func probe() {
        isLoading = true
        let targets = targets
        Task {
            let result = await Task.detached(priority: .userInitiated) { () -> [SystemPathAccessRow] in
                targets.map { path, label in
                    var isDirectory: ObjCBool = false
                    let exists = FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory)
                    guard exists else {
                        return SystemPathAccessRow(path: path, label: label, exists: false,
                                                  readable: false, detail: "路径不存在，不是权限失败。")
                    }
                    errno = 0
                    if let dir = opendir(path) {
                        let first = readdir(dir)
                        let ok = first != nil || errno == 0
                        closedir(dir)
                        if ok {
                            return SystemPathAccessRow(path: path, label: label, exists: true,
                                                      readable: true, detail: "当前可列目录；可读不代表可写。")
                        }
                        return SystemPathAccessRow(path: path, label: label, exists: true,
                                                  readable: false, detail: Self.permissionText(errno))
                    }
                    let code = errno
                    return SystemPathAccessRow(path: path, label: label, exists: true,
                                              readable: false, detail: Self.permissionText(code))
                }
            }.value
            await MainActor.run {
                rows = result
                checkedAt = Date()
                isLoading = false
            }
        }
    }

    nonisolated private static func permissionText(_ code: Int32) -> String {
        switch code {
        case EACCES:
            return "无权限：TCC 未覆盖这个路径，或目录由 root 独占。"
        case EPERM:
            return "被系统策略拒绝：通常是 SIP 保护，不是完全磁盘访问能解决的。"
        default:
            let text = strerror(code).map { String(cString: $0) } ?? "未知错误"
            return "枚举失败：\(text)（errno \(code)）。"
        }
    }
}
