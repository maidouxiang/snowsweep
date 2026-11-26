import Foundation

/// 清理选择的安全闸门（纯函数，可单测）。
///
/// 不可动摇原则的落地点：**默认只放 `defaultSelected`（risk==.safe && !needConfirm）
/// 的条目**。保护项/未知项永远丢弃；需确认项（review）只有在调用方显式
/// 传 `allowReview: true`、且用户已经在 UI 里勾选并要求预览时才放行。
/// 即使 UI 因 bug 误传路径，这里仍会按风险等级再过滤一次。
///
/// 这是 UI 与 DeletionCoordinator 之间的最后一道"规则决定"关口：
/// 模型/UI 只能提出候选，能不能删由规则算出的 verdict 说了算。
public enum CleanupSelection {

    /// 清理前的本机访问预检。
    ///
    /// 扫描器能拿到路径与体积，不代表当前进程能安全操作它。系统保护目录
    /// （例如 `~/Library/Caches/com.apple.HomeKit`）会在这里表现为不可读，
    /// 真正执行 `trashItem` 时才会被 TCC 拒绝。提前过滤可以避免整批清理在
    /// 中途失败，也避免用户误以为是软件删错了东西。
    public enum Readiness {
        public static func isAccessible(_ path: String, fileManager: FileManager = .default) -> Bool {
            fileManager.isReadableFile(atPath: path)
                && fileManager.isWritableFile(atPath: path)
        }

        /// 可读但不可写、或可写但不可读，都视为当前不可安全清理。
        public static func blocked(paths: Set<String>) -> Set<String> {
            Set(paths.filter { !isAccessible($0) })
        }
    }

    /// 一份待清理清单：条目 + 从证据链里提取的规则 ID。
    public struct Entry: Equatable, Sendable {
        public let verdict: Verdict
        public let ruleID: String?

        public init(verdict: Verdict, ruleID: String?) {
            self.verdict = verdict
            self.ruleID = ruleID
        }
    }

    /// 从扫描报告里安全地挑出可清理项。
    /// - Parameters:
    ///   - report: 扫描报告，必须 canClean，否则返回空。
    ///   - selectedPaths: UI 勾选路径集合。
    /// - Returns: 只含 safe 且默认勾选的条目；保护项/需确认项/未知项一律不返回。
    public static func safeEntries(from report: ScanReport, selectedPaths: Set<String>) -> [Entry] {
        entries(from: report, selectedPaths: selectedPaths, allowReview: false)
    }

    /// 清理建议三档共用入口。
    /// - Parameter allowReview: 只有「正常/激进」建议在预览时才传 true；
    ///   review 项必须已经出现在 selectedPaths 里，未勾选不会被带进来。
    public static func entries(
        from report: ScanReport,
        selectedPaths: Set<String>,
        allowReview: Bool = false
    ) -> [Entry] {
        guard report.canClean else { return [] }
        let selected = Set(selectedPaths)
        let candidates = report.verdicts.compactMap { verdict -> Entry? in
            guard selected.contains(verdict.item.path) else { return nil }
            let allowed = verdict.defaultSelected
                || (allowReview && verdict.risk == .review)
            guard allowed else { return nil }
            return Entry(verdict: verdict, ruleID: ruleID(for: verdict))
        }
        return foldingNestedEntries(candidates)
    }

    /// 报告里全部默认可清理项（用于"全选安全项"预览，不依赖 UI 勾选）。
    public static func allSafeEntries(from report: ScanReport) -> [Entry] {
        guard report.canClean else { return [] }
        let candidates = report.verdicts.compactMap { verdict -> Entry? in
            guard verdict.defaultSelected else { return nil }
            return Entry(verdict: verdict, ruleID: ruleID(for: verdict))
        }
        return foldingNestedEntries(candidates)
    }

    /// 祖先折叠：放行集合里若同时有父目录和它的子条目，只留父目录。
    ///
    /// 为什么必须做（真机实测发现的真实缺陷）：扫描器会把目录本身和目录下每个文件
    /// 都作为独立条目输出，两者都可能命中同一条 safe 规则。清理按序移废纸篓时，
    /// 父目录一旦先被移走，子条目的删除前复核就会因为 lstat 找不到路径而报
    /// `vanished`，"失败即停"会中断整批清理。移走父目录本就会带走全部子条目，
    /// 因此子条目无需单独清理，折叠后也避免释放空间被重复统计。
    ///
    /// 折叠只在**已放行集合内部**进行：父目录若是 review/protected 未被放行，
    /// 子条目仍然可以被单独清理，不会误删。
    public static func foldingNestedEntries(_ entries: [Entry]) -> [Entry] {
        let normalized = entries.map { normalizedPath($0.verdict.item.path) }
        return entries.enumerated().filter { index, _ in
            let current = normalized[index]
            return !normalized.enumerated().contains { otherIndex, other in
                guard otherIndex != index else { return false }
                // 规范化后完全相同的路径只保留第一次出现，避免互相折叠成空。
                if other == current { return otherIndex < index }
                return isAncestor(other, of: current)
            }
        }.map(\.element)
    }

    private static func normalizedPath(_ path: String) -> String {
        (NSString(string: path).expandingTildeInPath as NSString).standardizingPath
    }

    /// a 是否为 b 的祖先目录（不含自身，调用方已单独处理相等情况）。
    private static func isAncestor(_ ancestor: String, of descendant: String) -> Bool {
        let prefix = ancestor.hasSuffix("/") ? ancestor : ancestor + "/"
        return descendant.hasPrefix(prefix)
    }

    /// 从证据链提取命中的规则 ID。verdict() 写入形如 "rule:<id>" 的证据。
    public static func ruleID(for verdict: Verdict) -> String? {
        verdict.evidence.first { $0.hasPrefix("rule:") }.map { String($0.dropFirst(5)) }
    }

    /// 预览摘要：条数与总字节数。
    public static func summary(_ entries: [Entry]) -> (count: Int, bytes: Int64) {
        (entries.count, entries.reduce(Int64(0)) { $0 + $1.verdict.item.sizeBytes })
    }
}
