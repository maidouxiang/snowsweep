import SwiftUI
import AppKit
import SnowSweepCore

/// App 内置帮助：把风险等级和判定边界写成用户看得懂的话，并支持本地即时搜索。
struct HelpView: View {
    @EnvironmentObject var model: ScanViewModel
    /// 导出脱敏默认开启：报告会隐藏真实用户名，只保留目录结构与判定。
    @State private var redactOnExport = true
    @State private var query = ""

    private enum Kind { case text, risks, shortcuts, export }

    private struct Topic: Identifiable {
        let id: String
        let title: String
        let keywords: String
        let paragraphs: [String]
        var kind: Kind = .text
    }

    private let topics: [Topic] = [
        Topic(id: "risk", title: "四种颜色分别是什么意思",
              keywords: "颜色 红 橙 绿 紫 风险 等级 可安全删 需你确认 受保护 待判断",
              paragraphs: [], kind: .risks),
        Topic(id: "locked", title: "为什么有时清理按钮是灰的",
              keywords: "清理 按钮 灰 锁定 扫描缺口 权限 全盘 未扫完",
              paragraphs: ["只要扫描没扫完整（比如没有完全磁盘访问权限、目录读不了、条目达到上限），报告就会被锁定。这是为了防止「只看到一部分」时误删——你可以点开「扫描缺口」看具体少了哪些位置。"]),
        Topic(id: "storage", title: "大文件与重复文件",
              keywords: "大文件 重复 同体积 SHA-256 只读 不勾选 不删除 筛选 类型 修改时间 权限 超时",
              paragraphs: ["大文件按体积、类型、修改时间和文件名筛选；类型只按扩展名解释，不推断文件内容。扫描只读取文件元数据，不会读取文件正文。",
                           "重复文件先按体积分组，只有同体积的候选才会读取内容计算 SHA-256；同体积、同摘要且至少两份才算一组。重复占用按「只保留一份」估算。",
                           "这里的重复只代表内容相同，不代表应该删除：照片副本、项目备份和素材原件都可能成组。页面不提供勾选、删除，也不会把这些文件加入清理批处理。",
                           "如果提示某个个人目录未被允许读取，请到「权限清单」按目录授权后重新查找；如果提示超时，列表只是时限内已读到的部分。"]),
        Topic(id: "battery-guard", title: "电池守护与日常记录",
              keywords: "电池 日常 记录 趋势 插电 循环 温度 热压力 周报 本地 样本 寿命",
              paragraphs: ["日常记录按运行模式采样：静默 30 分钟、均衡 10 分钟、性能 5 分钟；只在雪运行时记录，退出后不补采。记录保存在 ~/Library/Application Support/雪/daily-metrics.jsonl，不上传。",
                           "页面里的「插电样本占比」是样本比例，不是连续分钟数；温度读不到时留空，不估算。周报只复述本机记录和规则命中的建议，不调用模型。",
                           "建议只能提醒行为：避免长期高电量插电、高温和频繁深度放电。雪不会修改系统设置，也不会把建议当作删文件依据。"]),
        Topic(id: "delete", title: "删除是怎么执行的",
              keywords: "删除 废纸篓 永久 确认 审计 日志 恢复 备份",
              paragraphs: ["默认只移到废纸篓，失败会停下来让你选择跳过或备份到指定目录，绝不静默改成永久删除。永久删除需要在设置里单独开启，并输入确认短语。每一步都写进本机审计日志。",
                           "删错了就打开「恢复」，按精确位置放回；如果恢复失败，可回到「废纸篓」手动拖回。"]),
        Topic(id: "english", title: "英文路径看不懂怎么办",
              keywords: "英文 路径 词典 中文 对照 glossary 翻译 主行 次行",
              paragraphs: ["列表主行先显示中文名，英文原名放在下面作为对照；每个词条都说明它是什么、干什么用、能不能删。中文名来自 Rules/glossary.json 词典；没收录时明确写「未收录」，不硬编一个中文名。"]),
        Topic(id: "runmode", title: "静默 / 均衡 / 性能怎么选",              keywords: "静默 均衡 性能 运行模式 省电 刷新 扫描 临时 低电量 30",
              paragraphs: ["静默最省：菜单栏 5 分钟刷新一次，日常记录 30 分钟一次，不在后台读审计、蓝牙、启动项和权限。均衡适合日常：1 分钟刷新一次，记录 10 分钟一次。性能最积极：15 秒刷新一次，记录 5 分钟一次。",
                           "扫描开始会自动临时切到性能，扫描结束后保留 60 秒再回退。电量低于 30% 或系统开了低电量模式时，会强制静默，优先省电。",
                           "模式只改刷新节奏，不改扫描范围、判定和删除权限。"]),
        Topic(id: "sensors", title: "电池、温度、蓝牙数据从哪来",
              keywords: "接口 API 数据来源 电池 温度 蓝牙 电量 IOPS ioreg 公开 读不到",
              paragraphs: ["电量、充电状态、是否接电源、剩余时间优先用公开的 IOPS 电源接口；循环次数、设计容量和温度在 AppleSmartBattery 存在时读取，缺失才回退公开值。",
                           "macOS 没有公开的摄氏温度接口：系统只给「正常 / 偏热 / 过热」这类热压力档位，读不到温度时界面直接写「读不到」，不猜。",
                           "蓝牙外设电量优先读系统蓝牙概览，再用 HID 电源键兜底；设备自己不上报电量时不显示估算值。"]),
        Topic(id: "menubar", title: "菜单栏与快速面板",
              keywords: "菜单栏 状态栏 雪花 快速面板 开关 磁盘 内存 电池 快速清理",
              paragraphs: ["菜单栏只常驻一枚雪花，点击才展开快速面板；面板顶部显示当前运行模式，磁盘、内存、电池等状态放在面板里，不占顶栏宽度。",
                           "在设置里可以单独关掉面板里的磁盘、内存、电池、温度、快速清理入口；关掉只影响显示，扫描和判定照常进行。"]),
        Topic(id: "unit", title: "MB / GB 是怎么显示的",
              keywords: "单位 MB GB 显示 存储 自动 容量 换算",
              paragraphs: ["默认「自动」按数值大小选 MB 或 GB；也可以固定为 MB 或 GB 便于横向比较。只改变显示格式，底层字节数、判定与清理都不受影响。"]),
        Topic(id: "config", title: "配置导入导出",
              keywords: "配置 导入 导出 JSON 换机 备份 保护路径 菜单栏 单位",
              paragraphs: ["导出文件包含：保护路径、菜单栏开关、模型档位、显示单位、扫描范围、日常记录开关。不含扫描结果、审计日志或任何用户文件内容。",
                           "导入时会先校验保护路径语法，再落盘；格式不对或来自更高版本的配置会被拒绝，不会半应用。"]),
        Topic(id: "shortcuts", title: "快捷键",
              keywords: "快捷键 键盘 命令 ⌘ command 菜单",
              paragraphs: [], kind: .shortcuts),
        Topic(id: "export", title: "导出报告",
              keywords: "导出 报告 JSON CSV Excel 脱敏 用户名",
              paragraphs: ["导出只包含判定结果和解释，不会导出你的个人文件内容，也不会发送任何网络请求。"], kind: .export),
        Topic(id: "privacy", title: "许可与隐私",
              keywords: "许可 隐私 GPL 联网 遥测 账号 上传 分发",
              paragraphs: ["雪遵循 GPL-3.0，个人自用、不联网、不上传、无账号。如果将来对外分发二进制，需要按 GPL-3.0 开放对应源码并重新做合规评估。"])
    ]

    private var noviceReportCard: some View {
        HStack(alignment: .center, spacing: 14) {
            Image(systemName: "snowflake")
                .font(.system(size: 22, weight: .semibold))
                .foregroundStyle(.orange)
                .frame(width: 42, height: 42)
                .background(.orange.opacity(0.10), in: RoundedRectangle(cornerRadius: 11))
            VStack(alignment: .leading, spacing: 4) {
                Text("第一次用？先看一份只读体检")
                    .font(.headline)
                Text("整盘容量、可放心清 / 要你决定 / 雪不动、保护清单和目录大头。只读，不删任何文件。")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 12)
            Button("打开新手报告") {
                AppWindow.showNoviceReport()
            }
            .buttonStyle(.borderedProminent)
            .tint(.orange)
        }
        .padding(15)
        .background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(.orange.opacity(0.22)))
    }

    private var filteredTopics: [Topic] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return topics }
        return topics.filter {
            HelpSearch.matches(query: trimmed, title: $0.title,
                               keywords: $0.keywords,
                               body: $0.paragraphs.joined(separator: " "))
        }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                PageHeader(title: "使用帮助",
                           subtitle: "每一条都先由规则判定，本地模型只负责把规则说成人话，永远不会替你批准删除。")

                noviceReportCard

                HStack(spacing: 10) {
                    Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                    TextField("搜索：废纸篓、权限、快捷键、导出…", text: $query)
                        .textFieldStyle(.plain)
                    if !query.isEmpty {
                        Button {
                            query = ""
                        } label: {
                            Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                        .help("清空搜索")
                    }
                }
                .padding(10)
                .background(.quaternary.opacity(0.25), in: RoundedRectangle(cornerRadius: 9))
                .overlay(RoundedRectangle(cornerRadius: 9).stroke(.quaternary.opacity(0.5)))
                .frame(maxWidth: 560, alignment: .leading)

                Text(query.isEmpty ? "共 \(topics.count) 个主题" : "找到 \(filteredTopics.count) / \(topics.count) 个主题")
                    .font(.caption).foregroundStyle(.secondary)

                if filteredTopics.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("没有匹配的主题").font(.headline)
                        Text("换个更短的关键词试试，比如「权限」「导出」「⌘」。").font(.caption).foregroundStyle(.secondary)
                        Button("清空搜索") { query = "" }
                    }
                    .padding(16)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(.quaternary.opacity(0.2), in: RoundedRectangle(cornerRadius: 12))
                } else {
                    ForEach(filteredTopics) { topic in
                        topicCard(topic)
                    }
                }
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    @ViewBuilder
    private func topicCard(_ topic: Topic) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(topic.title).font(.headline)
            switch topic.kind {
            case .text:
                ForEach(topic.paragraphs, id: \.self) { paragraph in
                    Text(paragraph).font(.callout).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            case .risks:
                riskLine("可安全删", "规则确认是可重建的缓存或临时文件，默认勾选；列表里仍会显示原始路径。", .green)
                riskLine("需你确认", "可能是有用的数据（归档、手机备份、废纸篓），默认不勾选，必须你逐项确认。", .orange)
                riskLine("受保护", "系统文件、密码钥匙串、本地 AI 模型与会话、个人文档等，永不进入清理候选。", .red)
                riskLine("待判断", "规则没有覆盖。本地模型最多把它降为「需你确认」，不会直接变成可删。", .purple)
            case .shortcuts:
                shortcutRow("⌘0", "打开主界面（窗口被关掉也能重建）")
                shortcutRow("⌘R", "开始扫描；扫描中再按一次取消")
                shortcutRow("⌘,", "打开设置")
                shortcutRow("⌘⇧/", "打开这个帮助页（中文键盘即 ⌘?）")
                Text("菜单栏图标：点击打开快速面板；面板里的入口会跳到对应页面。")
                    .font(.caption).foregroundStyle(.secondary).padding(.top, 2)
            case .export:
                ForEach(topic.paragraphs, id: \.self) { paragraph in
                    Text(paragraph).font(.callout).foregroundStyle(.secondary)
                }
                Toggle("导出时隐藏用户名（默认开启）", isOn: $redactOnExport)
                    .font(.callout)
                Text(redactOnExport
                     ? "路径里的用户名会变成 ~ 或占位符；目录结构、判定和证据链都保留。"
                     : "当前会导出原始路径，请确认报告只留在本机或可信的地方。")
                    .font(.caption).foregroundStyle(redactOnExport ? Color.secondary : Color.orange)
                HStack {
                    Button("导出 JSON") { export(.json) }
                    Button("导出 CSV（Excel 可直接打开）") { export(.csv) }
                }
                .disabled(model.report == nil)
                if model.report == nil {
                    Text("先完成一次扫描，才有报告可导出。").font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 12))
    }

    private func riskLine(_ title: String, _ detail: String, _ color: Color) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Circle().fill(color).frame(width: 10, height: 10).padding(.top, 5)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.subheadline.bold())
                Text(detail).font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private func shortcutRow(_ key: String, _ detail: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(key)
                .font(.system(size: 12, weight: .semibold, design: .monospaced))
                .padding(.horizontal, 7).padding(.vertical, 3)
                .background(.quaternary.opacity(0.6), in: RoundedRectangle(cornerRadius: 5))
                .frame(width: 54, alignment: .center)
            Text(detail).font(.callout)
            Spacer(minLength: 0)
        }
    }

    private enum ExportKind { case json, csv }

    private func export(_ kind: ExportKind) {
        guard let report = model.report else { return }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = kind == .json ? "雪报告.json" : "雪报告.csv"
        panel.allowedContentTypes = [kind == .json ? .json : .commaSeparatedText]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let redactor = ReportRedactor(isEnabled: redactOnExport)
            if kind == .json {
                try ReportExporter.json(report: report, redactor: redactor).write(to: url)
            } else {
                try ReportExporter.csv(report: report, redactor: redactor)
                    .write(to: url, atomically: true, encoding: .utf8)
            }
            model.lastAction = "报告已导出：\(url.lastPathComponent)"
        } catch {
            model.errorMessage = .export("\(error)")
        }
    }
}
