import Foundation

/// 卸载页右侧详情只允许在「未多选」且「详情身份与勾选一致」时显示。
/// 多选时隐藏单应用详情，避免标题、体积、残留来自不同应用。
public enum UninstallDetailPolicy {
    public static func shows(selectedPaths: [String], inspectedPath: String?) -> Bool {
        guard selectedPaths.count <= 1, let inspectedPath else { return false }
        if let only = selectedPaths.first, only != inspectedPath { return false }
        return true
    }
}

/// 模型自检失败时的中文口径。系统原始错误可能是英文，不允许直接展示给用户。
public enum SelfCheckFailureCopy {
    public static func isUnsupportedDevice(_ raw: String) -> Bool {
        let lower = raw.lowercased()
        return lower.contains("does not support")
            || lower.contains("not supported")
            || lower.contains("apple intelligence")
    }

    public static func message(for raw: String) -> String {
        if isUnsupportedDevice(raw) {
            return "当前设备或系统不支持 Apple Intelligence 端侧模型。所有名称仍由内置中文词典解释，不影响清理判定。"
        }
        return "自检没有完成：系统端侧模型暂时不可用。请确认已开启 Apple Intelligence，或切回「关闭」档；内置中文词典不受影响。"
    }
}
