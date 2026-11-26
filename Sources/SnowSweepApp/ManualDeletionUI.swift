import SwiftUI
import SnowSweepCore

/// 所有页共用的删除确认。确认前先捕获文件身份；确认后按身份复核，只进废纸篓。
struct ManualDeletionPrompt: Identifiable {
    enum Caution {
        case normal
        case uncertain
        case batch
        /// 用户主动解除单项保护（授权/凭证/家族保护词）；只允许这一次，不写回保护清单。
        case protectedOverride
    }

    let id = UUID()
    let plans: [ManualDeletionPlan]
    let title: String
    let message: String
    let source: String
    let caution: Caution
    let allowedRoots: [String]
    let protectionOverridePaths: [String]

    init(plans: [ManualDeletionPlan], title: String, message: String,
         source: String, caution: Caution = .normal,
         allowedRoots: [String] = [NSHomeDirectory()],
         protectionOverridePaths: [String] = []) {
        self.plans = plans
        self.title = title
        self.message = message
        self.source = source
        self.caution = caution
        self.allowedRoots = allowedRoots
        self.protectionOverridePaths = protectionOverridePaths
    }

    var bytes: Int64 { plans.reduce(0) { $0 + $1.sizeBytes } }
}

struct ManualDeletionConfirmSheet: View {
    @EnvironmentObject private var model: ScanViewModel
    @Environment(\.dismiss) private var dismiss

    let prompt: ManualDeletionPrompt
    let onComplete: (Result<Int, Error>) -> Void

    @State private var acknowledged = false
    @State private var isWorking = false
    @State private var errorText: String?

    private var requiresAcknowledgement: Bool {
        prompt.caution != .normal || prompt.plans.count > 1
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "trash")
                    .font(.system(size: 24, weight: .semibold))
                    .foregroundStyle(.orange)
                    .frame(width: 42, height: 42)
                    .background(Color.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 10))
                VStack(alignment: .leading, spacing: 4) {
                    Text(prompt.title).font(.title3.weight(.semibold))
                    Text(prompt.message)
                        .font(.callout).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            if prompt.caution == .uncertain {
                InfoBanner(text: "这一项的归属证据不完整。雪不会替你判断它一定没用；只有你确认宿主已经不用它，才继续。", color: .orange)
            }
            if prompt.caution == .batch {
                InfoBanner(text: "这是批量操作：会保留一份，其余逐项复核后移入废纸篓。任何一项身份变化都会立即停止。", color: .orange)
            }
            if prompt.caution == .protectedOverride {
                InfoBanner(text: "这一项被保护清单或家族保护词挡住。你正在做的是“只解除这一次”的删除，不会把保护永久移除；授权/凭证文件删掉后，对应软件可能需要重新激活。", color: .red)
            }

            VStack(alignment: .leading, spacing: 7) {
                HStack {
                    Text("将处理 \(prompt.plans.count) 项")
                        .font(.callout.weight(.medium))
                    Spacer()
                    Text(SystemMetrics.bytesText(prompt.bytes))
                        .font(.callout.monospacedDigit()).foregroundStyle(.secondary)
                }
                ScrollView {
                    VStack(spacing: 0) {
                        ForEach(Array(prompt.plans.enumerated()), id: \.offset) { _, plan in
                            HStack(alignment: .top, spacing: 8) {
                                Image(systemName: plan.identity.kind == .directory ? "folder" : "doc")
                                    .font(.caption).foregroundStyle(.secondary).padding(.top, 2)
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(plan.displayName).font(.callout).lineLimit(1)
                                    Text(NSString(string: plan.path).abbreviatingWithTildeInPath)
                                        .font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                                    Text(plan.reason).font(.caption2).foregroundStyle(.tertiary).lineLimit(1)
                                }
                                Spacer(minLength: 8)
                                Text(SystemMetrics.bytesText(plan.sizeBytes))
                                    .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                            }
                            .padding(.vertical, 6)
                            Divider().opacity(0.5)
                        }
                    }
                }
                .frame(maxHeight: 220)
            }
            .padding(10)
            .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 9))

            if let errorText {
                InfoBanner(text: errorText, color: .red)
            }

            if requiresAcknowledgement {
                Toggle(prompt.caution == .protectedOverride
                       ? "我确认解除这一项的保护并删除；如果它是授权或凭证，相关软件可能要重新激活"
                       : "我确认这些文件可以先移出原位；之后我会自己检查废纸篓或恢复清单",
                       isOn: $acknowledged)
                    .toggleStyle(.checkbox)
                    .font(.caption)
            }

            HStack {
                Text("只移到废纸篓，不永久删除。")
                    .font(.caption2).foregroundStyle(.secondary)
                Spacer()
                Button("取消") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                    .disabled(isWorking)
                Button {
                    perform()
                } label: {
                    if isWorking {
                        HStack(spacing: 6) {
                            ProgressView().controlSize(.small)
                            Text("正在移…")
                        }
                    } else {
                        Text("移到废纸篓")
                    }
                }
                .buttonStyle(.borderedProminent)
                .tint(.orange)
                .disabled(isWorking || (requiresAcknowledgement && !acknowledged))
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 580)
    }

    private func perform() {
        guard !isWorking else { return }
        isWorking = true
        errorText = nil
        let protectionCheck = model.manualProtectionCheck
        let plans = prompt.plans
        let source = prompt.source
        let allowedRoots = prompt.allowedRoots
        let overridePaths = Set(prompt.protectionOverridePaths.map {
            (NSString(string: $0).expandingTildeInPath as NSString).standardizingPath
        })
        Task {
            let result = await Task.detached(priority: .userInitiated) { () -> Result<Int, Error> in
                let scopedCheck: (@Sendable (String) -> Bool)? = {
                    guard let protectionCheck else { return nil }
                    return { path in
                        let standardized = (NSString(string: path).expandingTildeInPath as NSString).standardizingPath
                        if overridePaths.contains(standardized) { return false }
                        return protectionCheck(path)
                    }
                }()
                let service = ManualDeletionService(
                    protectionCheck: scopedCheck,
                    allowedRoots: allowedRoots
                )
                var moved = 0
                for plan in plans {
                    do {
                        _ = try service.moveToTrash(plan, source: source)
                        moved += 1
                    } catch {
                        return .failure(error)
                    }
                }
                return .success(moved)
            }.value
            await MainActor.run {
                isWorking = false
                switch result {
                case let .success(count):
                    onComplete(.success(count))
                    dismiss()
                case let .failure(error):
                    errorText = error.localizedDescription
                    onComplete(.failure(error))
                }
            }
        }
    }
}

extension View {
    func manualDeletionSheet(
        prompt: Binding<ManualDeletionPrompt?>,
        onComplete: @escaping (Result<Int, Error>) -> Void
    ) -> some View {
        sheet(item: prompt) { value in
            ManualDeletionConfirmSheet(prompt: value, onComplete: onComplete)
        }
    }
}
