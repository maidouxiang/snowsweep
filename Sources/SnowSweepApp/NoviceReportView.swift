import SwiftUI
import SnowSweepCore

/// 第一次用雪时的只读报告。
/// 它不提供整目录删除，只回答“这块盘里有什么、哪些能清、哪些别动”。
struct NoviceReportSheet: View {
    let report: NoviceReport
    let spacesLoading: Bool
    let onClose: () -> Void
    let onShowCleanable: () -> Void

    var body: some View {
        ZStack {
            SnowSkin.background
            RadialGradient(
                colors: [SnowSkin.gold.opacity(0.10), .clear],
                center: .topLeading,
                startRadius: 0,
                endRadius: 620
            )
            .ignoresSafeArea()

            ScrollView(.vertical, showsIndicators: false) {
                VStack(alignment: .leading, spacing: 18) {
                    header
                    capacityCard
                    decisionCards
                    if !report.reportComplete {
                        warningCard
                    } else if let warning = report.warning {
                        gapCard(warning)
                    }
                    if !report.keepSpaces.isEmpty {
                        spaceSection(
                            title: "雪不动的 \(report.keepCount) 项",
                            detail: "只报告，不提供删除；共 \(report.keepCount) 个位置，按保护类型合并，只展示已读到的体积",
                            items: report.keepSpaces,
                            tint: SnowSkin.faint
                        )
                    }
                    spaceSection(
                        title: "系统盘的大块头",
                        detail: "系统位置只读；应用本体去「卸载」页核对",
                        items: report.systemSpaces,
                        tint: SnowSkin.gold
                    )
                    spaceSection(
                        title: "你的用户目录",
                        detail: "个人数据只报告，不会给你一键删整个目录",
                        items: report.homeSpaces,
                        tint: SnowSkin.orange
                    )
                    guidanceCard
                    footer
                }
                .padding(.horizontal, 30)
                .padding(.vertical, 26)
                .frame(maxWidth: 820, alignment: .leading)
                .frame(maxWidth: .infinity, alignment: .center)
            }
        }
        .frame(minWidth: 680, idealWidth: 820, minHeight: 560, idealHeight: 760)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 9) {
                Image(systemName: "snowflake")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(SnowSkin.gold)
                Text("新手报告")
                    .font(.system(size: 10.5, weight: .semibold))
                    .tracking(1.4)
                    .foregroundStyle(SnowSkin.gold)
                Text("只读 · 没有删除任何文件")
                    .font(.system(size: 9.5))
                    .foregroundStyle(SnowSkin.faint)
                Spacer()
            }
            Text("第一次用，先看懂这台电脑。")
                .font(.system(size: 29, weight: .semibold, design: .serif))
                .foregroundStyle(SnowSkin.text)
            Text("雪把整块盘翻了一遍，只列证据。能清的、要你决定的、不动的，分开写清楚。")
                .font(.system(size: 12))
                .foregroundStyle(SnowSkin.dim)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var capacityCard: some View {
        VStack(alignment: .leading, spacing: 11) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("这块盘现在")
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundStyle(SnowSkin.text)
                if report.totalBytes > 0 {
                    Text("已用 \(Int(report.usedFraction * 100))%")
                        .font(.system(size: 9.5, design: .monospaced))
                        .foregroundStyle(SnowSkin.faint)
                }
                Spacer()
            }

            if report.totalBytes > 0 {
                GeometryReader { proxy in
                    ZStack(alignment: .leading) {
                        Capsule().fill(SnowSkin.overlay(0.06))
                        Capsule()
                            .fill(
                                LinearGradient(
                                    colors: [SnowSkin.gold.opacity(0.85), SnowSkin.gold.opacity(0.35)],
                                    startPoint: .leading,
                                    endPoint: .trailing
                                )
                            )
                            .frame(width: max(4, proxy.size.width * CGFloat(report.usedFraction)))
                    }
                }
                .frame(height: 7)
            }

            HStack(spacing: 0) {
                capacityValue("总容量", report.totalBytes)
                capacityValue("已用", report.usedBytes)
                capacityValue("可用", report.freeBytes)
            }
        }
        .padding(14)
        .background(SnowSkin.panel, in: RoundedRectangle(cornerRadius: 13, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 13, style: .continuous)
                .stroke(SnowSkin.overlay(0.065), lineWidth: 1)
        )
    }

    private func capacityValue(_ title: String, _ bytes: Int64) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title)
                .font(.system(size: 9.5))
                .foregroundStyle(SnowSkin.faint)
            Text(AssistantBytes.text(bytes))
                .font(.system(size: 16, weight: .medium, design: .serif))
                .foregroundStyle(SnowSkin.text)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var decisionCards: some View {
        HStack(spacing: 10) {
            decisionCard(
                "可放心清",
                "\(report.cleanCount) 项",
                report.cleanBytes,
                SnowSkin.green,
                "缓存、日志、旧安装包"
            )
            decisionCard(
                "要你决定",
                "\(report.decideCount) 项",
                report.decideBytes,
                SnowSkin.orange,
                "你的文件、聊天数据"
            )
            decisionCard(
                "雪不动",
                "\(report.keepCount) 项",
                0,
                SnowSkin.faint,
                "系统、应用、保护项"
            )
        }
    }

    private func decisionCard(
        _ title: String,
        _ count: String,
        _ bytes: Int64,
        _ tint: Color,
        _ note: String
    ) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title)
                .font(.system(size: 9.5))
                .foregroundStyle(tint)
            Text(count)
                .font(.system(size: 22, weight: .semibold, design: .serif))
                .foregroundStyle(SnowSkin.text)
            if bytes > 0 {
                Text(AssistantBytes.text(bytes))
                    .font(.system(size: 10.5, design: .monospaced))
                    .foregroundStyle(SnowSkin.dim)
            } else {
                Text("只解释，不删除")
                    .font(.system(size: 9.5))
                    .foregroundStyle(SnowSkin.faint)
            }
            Text(note)
                .font(.system(size: 9))
                .foregroundStyle(SnowSkin.faint)
                .lineLimit(1)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(tint.opacity(0.045), in: RoundedRectangle(cornerRadius: 11))
        .overlay(
            RoundedRectangle(cornerRadius: 11)
                .stroke(tint.opacity(0.16), lineWidth: 1)
        )
    }

    private var warningCard: some View {
        HStack(alignment: .top, spacing: 9) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 11))
                .foregroundStyle(SnowSkin.orange)
                .padding(.top, 2)
            Text(report.warning ?? "这次有位置没读全，报告只代表读到的部分。删除已锁定；先补完全磁盘访问再清。")
                .font(.system(size: 10.5))
                .foregroundStyle(SnowSkin.dim)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(11)
        .background(SnowSkin.orange.opacity(0.055), in: RoundedRectangle(cornerRadius: 10))
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(SnowSkin.orange.opacity(0.18), lineWidth: 1)
        )
    }

    private func gapCard(_ warning: String) -> some View {
        HStack(alignment: .top, spacing: 9) {
            Image(systemName: "info.circle.fill")
                .font(.system(size: 11))
                .foregroundStyle(SnowSkin.orange)
                .padding(.top, 2)
            Text(warning)
                .font(.system(size: 10.5))
                .foregroundStyle(SnowSkin.dim)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(11)
        .background(SnowSkin.orange.opacity(0.055), in: RoundedRectangle(cornerRadius: 10))
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(SnowSkin.orange.opacity(0.18), lineWidth: 1)
        )
    }

    @ViewBuilder
    private func spaceSection(
        title: String,
        detail: String,
        items: [NoviceSpaceItem],
        tint: Color
    ) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(title)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(SnowSkin.text)
                Text(detail)
                    .font(.system(size: 9.5))
                    .foregroundStyle(SnowSkin.faint)
                    .lineLimit(1)
                Spacer()
            }

            if spacesLoading && items.isEmpty {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("目录体积还在后台算，先把已读到的清单给你。")
                        .font(.system(size: 10.5))
                        .foregroundStyle(SnowSkin.faint)
                }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(SnowSkin.overlay(0.032), in: RoundedRectangle(cornerRadius: 10))
            } else if items.isEmpty {
                Text("这次没有读到体积明显的目录。")
                    .font(.system(size: 10.5))
                    .foregroundStyle(SnowSkin.faint)
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(SnowSkin.overlay(0.032), in: RoundedRectangle(cornerRadius: 10))
            } else {
                let maxBytes = max(1, items.map(\.bytes).max() ?? 1)
                VStack(spacing: 0) {
                    ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                        spaceRow(item, index: index, maxBytes: maxBytes, tint: tint)
                        if index < items.count - 1 {
                            Divider().overlay(SnowSkin.overlay(0.045))
                        }
                    }
                }
                .padding(.horizontal, 13)
                .background(SnowSkin.overlay(0.032), in: RoundedRectangle(cornerRadius: 11))
                .overlay(
                    RoundedRectangle(cornerRadius: 11)
                        .stroke(SnowSkin.overlay(0.05), lineWidth: 1)
                )
            }
        }
    }

    private func spaceRow(
        _ item: NoviceSpaceItem,
        index: Int,
        maxBytes: Int64,
        tint: Color
    ) -> some View {
        HStack(spacing: 11) {
            Text("\(index + 1)")
                .font(.system(size: 9.5, design: .monospaced))
                .foregroundStyle(SnowSkin.faint)
                .frame(width: 15, alignment: .trailing)

            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 7) {
                    Text(item.name)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(SnowSkin.text)
                        .lineLimit(1)
                    Text(item.category)
                        .font(.system(size: 8.5))
                        .foregroundStyle(SnowSkin.faint)
                    if item.isPersonal {
                        Text("你的文件")
                            .font(.system(size: 8.5))
                            .foregroundStyle(SnowSkin.orange)
                    }
                }
                GeometryReader { proxy in
                    Capsule()
                        .fill(
                            LinearGradient(
                                colors: [tint.opacity(0.7), tint.opacity(0.14)],
                                startPoint: .leading,
                                endPoint: .trailing
                            )
                        )
                        .frame(width: max(3, proxy.size.width * CGFloat(item.bytes) / CGFloat(maxBytes)), height: 3)
                }
                .frame(height: 3)
            }

            Spacer(minLength: 6)
            Text(AssistantBytes.text(item.bytes))
                .font(.system(size: 10.5, weight: .medium, design: .monospaced))
                .foregroundStyle(SnowSkin.dim)
                .frame(width: 88, alignment: .trailing)
            Text(item.risk)
                .font(.system(size: 8.5))
                .foregroundStyle(SnowSkin.faint)
                .frame(width: 34, alignment: .trailing)
        }
        .padding(.vertical, 8)
    }

    private var guidanceCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("雪的建议")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(SnowSkin.text)
            ForEach(Array(report.guidance.enumerated()), id: \.offset) { index, line in
                HStack(alignment: .top, spacing: 9) {
                    Text("\(index + 1)")
                        .font(.system(size: 9.5, design: .monospaced))
                        .foregroundStyle(SnowSkin.gold)
                        .frame(width: 15, alignment: .trailing)
                    Text(line)
                        .font(.system(size: 10.5))
                        .foregroundStyle(SnowSkin.dim)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .padding(14)
        .background(SnowSkin.gold.opacity(0.045), in: RoundedRectangle(cornerRadius: 12))
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(SnowSkin.gold.opacity(0.16), lineWidth: 1)
        )
    }

    private var footer: some View {
        HStack(spacing: 10) {
            Text("报告只读；清理仍需你逐项点头，只移废纸篓。")
                .font(.system(size: 9.5))
                .foregroundStyle(SnowSkin.faint)
            Spacer()
            Button("先只看") {
                onClose()
            }
            .buttonStyle(.plain)
            .font(.system(size: 11))
            .foregroundStyle(SnowSkin.dim)
            .padding(.horizontal, 13)
            .padding(.vertical, 8)
            .background(SnowSkin.overlay(0.045), in: Capsule())

            Button("去看可清项") {
                onShowCleanable()
            }
            .buttonStyle(.plain)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(SnowSkin.onAccent)
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(SnowSkin.gold, in: Capsule())
        }
    }
}
