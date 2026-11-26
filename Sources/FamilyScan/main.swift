import Foundation
import SnowSweepCore

@main
struct FamilyScan {
    static func main() {
        var json = false
        var limit = 20
        var all = false
        var readLastUsed = true
        var computeSizes = true
        var maxDepth = 1

        let args = Array(CommandLine.arguments.dropFirst())
        var index = 0
        while index < args.count {
            switch args[index] {
            case "--json":
                json = true
            case "--all":
                all = true
            case "--no-last-used":
                readLastUsed = false
            case "--no-size":
                computeSizes = false
            case "--limit":
                index += 1
                if index < args.count, let value = Int(args[index]), value > 0 {
                    limit = value
                }
            case "--max-depth":
                index += 1
                if index < args.count, let value = Int(args[index]), value >= 1 {
                    maxDepth = value
                }
            default:
                break
            }
            index += 1
        }

        let store: SoftwareFamilyStore
        do {
            store = try SoftwareFamilyStore.loadBundled()
        } catch {
            fputs("族谱库加载失败：\(error.localizedDescription)\n", stderr)
            exit(2)
        }

        let options = SoftwareGraphScanOptions(
            appRoots: SoftwareGraphScanOptions.live().appRoots,
            home: URL(fileURLWithPath: NSHomeDirectory()),
            launchRoots: SoftwareGraphScanOptions.live().launchRoots,
            maxAppDepth: 3,
            maxPluginDepth: maxDepth,
            readLastUsed: readLastUsed,
            computeSizes: computeSizes
        )
        let report = SoftwareGraphScanner.scan(store: store, options: options)

        if json {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            encoder.dateEncodingStrategy = .iso8601
            if let data = try? encoder.encode(report) {
                print(String(data: data, encoding: .utf8) ?? "{}")
            }
            return
        }

        print("雪软件族谱 · 只读原型")
        print("族谱库 \(store.schemaVersion) · 更新 \(store.updatedAt)")
        print("生成 \(formattedDate(report.generatedAt))")
        print("已安装应用 \(report.stats.appCount) · 家族 \(report.stats.familyCount) · 插件节点 \(report.stats.pluginNodeCount)")
        print("建议清理 \(report.stats.suggestedCleanupCount) · 可能冗余 \(report.stats.possibleRedundancyCount) · 保留 \(report.stats.keepCount) · 待判断 \(report.stats.unknownCount) · 受保护 \(report.stats.protectedCount)")
        print("候选体积 \(humanBytes(report.stats.totalCandidateBytes))")
        print("")
        print("注意：本工具只读，不移动、不删除任何文件；建议清理默认不勾选。")
        if !report.stats.warnings.isEmpty {
            print("读不到 \(report.stats.warnings.count) 处：")
            for warning in report.stats.warnings.prefix(5) { print("  - \(warning)") }
        }
        print("")

        let candidates = report.findings.filter {
            $0.verdict == .suggestedCleanup || $0.verdict == .possibleRedundancy
        }
        if candidates.isEmpty {
            print("没有发现孤儿插件候选。")
            print("这说明当前已安装宿主覆盖了族谱里的插件根，或族谱库还没收录这些目录。")
            return
        }

        let shown = all ? candidates : Array(candidates.prefix(limit))
        for (offset, finding) in shown.enumerated() {
            print("\(offset + 1). [\(finding.verdict.chineseName)] \(finding.node.name)")
            print("   \(finding.node.path)")
            print("   家族：\(finding.familyName ?? "未命中") · 类型：\(finding.node.kind.chineseName)")
            if finding.installedHosts.isEmpty {
                let missing = finding.missingHostBundleIDs.isEmpty
                    ? "族谱未登记宿主"
                    : finding.missingHostBundleIDs.joined(separator: "、")
                print("   主人：未安装（\(missing)）")
            } else {
                print("   主人：\(finding.installedHosts.map(\.name).joined(separator: "、"))")
            }
            if let size = finding.sizeBytes {
                print("   体积：\(humanBytes(size))")
            }
            if let lastUsed = finding.lastUsed {
                print("   最近使用：\(formattedDate(lastUsed))")
            } else {
                print("   最近使用：没有读到记录")
            }
            if let modified = finding.lastModified {
                print("   最近修改：\(formattedDate(modified))")
            }
            print("   理由：\(finding.reasons.joined(separator: "；"))")
            for evidence in finding.evidence.prefix(4) {
                print("   证据：\(evidence.strength.chineseName) · \(evidence.value)（\(evidence.note)）")
            }
            print("")
        }

        if !all, candidates.count > shown.count {
            print("还有 \(candidates.count - shown.count) 个候选，用 --all 查看全部。")
        }
    }

    static func humanBytes(_ bytes: Int64) -> String {
        if bytes <= 0 { return "0 B" }
        let units = ["B", "KB", "MB", "GB", "TB"]
        var value = Double(bytes)
        var unit = 0
        while value >= 1024, unit < units.count - 1 {
            value /= 1024
            unit += 1
        }
        return unit == 0 ? "\(Int(value)) B" : String(format: "%.2f %@", value, units[unit])
    }

    static func formattedDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        return formatter.string(from: date)
    }
}
