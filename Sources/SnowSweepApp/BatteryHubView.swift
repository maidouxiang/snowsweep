import SwiftUI

/// 「电池」一项，内部再分「健康」和「守护」。
/// 侧栏不再放两条同类型入口；旧选中值在 MainWindow 里迁移。
struct BatteryHubView: View {
    /// V0.8.0：三页签与普通设置一致，按本机保存；旧版两页签的值统一落到「当前状态」。
    @AppStorage("snow.battery.tab") private var tab = 0

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Picker("", selection: $tab) {
                    Text("当前状态").tag(0)
                    Text("日常趋势").tag(1)
                    Text("建议").tag(2)
                }
                .pickerStyle(.segmented)
                .frame(width: 300)
                Spacer()
                Text("同一份电池数据 · 本地记录")
                    .font(.caption2).foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 18)
            .padding(.top, 14)
            .padding(.bottom, 4)

            switch tab {
            case 1:
                BatteryGuardView(sections: [.trend])
            case 2:
                BatteryGuardView(sections: [.advice])
            default:
                BatteryView()
            }
        }
        .onChange(of: tab) { _, value in
            if !(0...2).contains(value) { tab = 0 }
        }
    }
}
