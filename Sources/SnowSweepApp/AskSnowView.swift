import SwiftUI

/// 专家模式唯一的“问雪”入口：只解释当前页面，不接模型、不生成计划、不执行删除。
/// 它不是一个常驻聊天窗，也不是第二套助手；点开、看完、关掉。
struct AskSnowPanel: View {
    let page: String

    @Environment(\.dismiss) private var dismiss
    @State private var questionIndex = 0

    private let questions = [
        "这块空间是什么",
        "为什么有些项不能删",
        "问雪会替我执行吗"
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider().overlay(SnowSkin.hairline)
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    currentPageCard
                    questionPicker
                    answerCard
                    footer
                }
                .padding(20)
            }
        }
        .frame(width: 540, height: 480)
        .background(SnowSkin.background)
    }

    private var header: some View {
        HStack(spacing: 12) {
            ZStack {
                Circle()
                    .fill(SnowSkin.goldDim)
                    .frame(width: 38, height: 38)
                Image(systemName: "snowflake")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(SnowSkin.accent)
            }
            VStack(alignment: .leading, spacing: 3) {
                Text("问雪")
                    .font(.system(size: 20, weight: .semibold, design: .serif))
                    .foregroundStyle(SnowSkin.text)
                Text("只解释，不执行")
                    .font(.system(size: 10.5, weight: .medium))
                    .foregroundStyle(SnowSkin.accent)
            }
            Spacer()
            Button {
                dismiss()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(SnowSkin.faint)
                    .frame(width: 28, height: 28)
                    .background(SnowSkin.overlay(0.04), in: Circle())
            }
            .buttonStyle(.plain)
            .keyboardShortcut(.cancelAction)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 16)
    }

    private var currentPageCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("当前页面")
                .font(.system(size: 9.5, weight: .semibold))
                .tracking(1.2)
                .foregroundStyle(SnowSkin.faint)
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(page)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(SnowSkin.text)
                Text(pageSummary)
                    .font(.system(size: 10.5))
                    .foregroundStyle(SnowSkin.dim)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(SnowSkin.panel, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(SnowSkin.hairline, lineWidth: 1))
    }

    private var questionPicker: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text("可以问这三句")
                .font(.system(size: 9.5, weight: .semibold))
                .tracking(1.2)
                .foregroundStyle(SnowSkin.faint)
            ForEach(Array(questions.enumerated()), id: \.offset) { index, question in
                Button {
                    withAnimation(.easeInOut(duration: 0.18)) {
                        questionIndex = index
                    }
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: questionIndex == index ? "circle.inset.filled" : "circle")
                            .font(.system(size: 10))
                            .foregroundStyle(questionIndex == index ? SnowSkin.accent : SnowSkin.faint)
                        Text(question)
                            .font(.system(size: 12, weight: questionIndex == index ? .medium : .regular))
                            .foregroundStyle(questionIndex == index ? SnowSkin.text : SnowSkin.dim)
                        Spacer()
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 9)
                    .background(
                        questionIndex == index ? SnowSkin.goldDim : SnowSkin.panel,
                        in: RoundedRectangle(cornerRadius: 9)
                    )
                }
                .buttonStyle(.plain)
            }
        }
    }

    private var answerCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 7) {
                Image(systemName: "text.magnifyingglass")
                    .font(.system(size: 11))
                    .foregroundStyle(SnowSkin.accent)
                Text(questions[questionIndex])
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(SnowSkin.text)
            }
            Text(answer)
                .font(.system(size: 12))
                .foregroundStyle(SnowSkin.dim)
                .lineSpacing(3)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(SnowSkin.panel, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(SnowSkin.hairline, lineWidth: 1))
    }

    private var footer: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "lock.shield")
                .font(.system(size: 10))
                .foregroundStyle(SnowSkin.faint)
            Text("问雪只读当前界面，不接模型、不生成清理计划。所有删除仍然只走原有确认与废纸篓流程。")
                .font(.system(size: 10))
                .foregroundStyle(SnowSkin.faint)
                .lineSpacing(2)
            Spacer(minLength: 0)
        }
        .padding(.top, 2)
    }

    private var pageSummary: String {
        switch page {
        case "清理": return "逐项看证据，再决定"
        case "空间分析": return "看空间去哪了，不做删除"
        case "概览": return "先看总量，再进具体页"
        case "内存": return "看压力和占用，不杀进程"
        case "电池": return "看容量与温度，只给建议"
        case "蓝牙": return "只读系统上报电量"
        case "网络": return "看流量与连接，不抓内容"
        case "状态": return "看机身温度与负载"
        case "族谱": return "按软件归属核对残留"
        case "大文件": return "先核对，再逐项确认"
        case "卸载": return "看应用与残留，逐项确认"
        case "优化": return "只读建议，不改系统"
        case "历史": return "每次操作都可追溯"
        case "保护": return "这些路径不会被删除"
        case "权限": return "能读到什么、缺什么"
        case "启动项": return "只分类定位，不自动禁用"
        case "恢复": return "给出精确路径，手动恢复"
        case "缺口": return "没读全的位置单独列出"
        case "设置": return "外观、模型与扫描范围"
        case "帮助": return "解释口径，不产生动作"
        default: return "专家模式的高密度明细"
        }
    }

    private var answer: String {
        switch questionIndex {
        case 0:
            switch page {
            case "清理":
                return "这里列的是扫描后按规则分出的候选：可清、要你决定、雪不动。每一行都应带体积、风险、原因和路径；体积不是删除理由，规则和你的确认才是。带「处理方式」的项，先把前提做完再决定。"
            case "空间分析":
                return "这里回答“空间去哪了”，只读统计系统和用户目录的大头。它不会把某个目录直接变成删除按钮；个人数据只报告。"
            case "概览":
                return "概览只给总量和健康评分，帮你判断要不要进清理。它不替你选项目，也不把评分当成删除建议。"
            case "内存":
                return "内存页看压缩内存、交换和进程占用。清缓存不等于释放活动内存；雪不会在这里杀进程，也不会替你改内存策略。"
            case "电池":
                return "电池页看最大容量、循环次数、温度和耗电记录。它只给使用建议，不改系统电源设置，也不假装能修复电池。"
            case "蓝牙":
                return "外设页只读系统上报的 Battery Level，不主动连接设备、不发指令。系统没上报就写「未上报电量」，未连接就不读。"
            case "网络":
                return "网络页看当前上下行和连接状态，不抓包、不读内容，也不按流量判断哪个应用“有问题”。"
            case "状态":
                return "机身状态页看温度、负载和散热压力；读数来自系统，不做硬件诊断，也不建议你拆机。"
            case "族谱":
                return "族谱按应用、安装收据和插件归属归类，用来判断“这是谁的残留”。共享宿主和受保护项只报告，不提供删除。"
            case "大文件":
                return "大文件按体积、修改时间、类型和路径判读；重复文件还要同体积加 SHA-256 核对。判读只给候选，不会自动替你选。"
            case "卸载":
                return "卸载页列出应用本体、收据和可能的残留；删除仍逐项确认，只进废纸篓。系统应用和受保护项不提供删除。"
            case "优化":
                return "优化页给只读建议，比如启动项、后台占用和可清理项。它不会自动重启服务、改系统参数或替你执行命令。"
            case "历史":
                return "历史记录每次清理的时间、项目、体积和结果，方便追溯。这里只读记录，不会重放删除，也不会把旧记录当成新候选。"
            case "保护":
                return "保护路径是雪的硬边界：命中后只报告、不提供删除。它优先于普通缓存规则，用来兜住聊天记录、照片、文稿、密钥和云盘目录。"
            case "权限":
                return "权限页说明每个目录能读到什么、缺哪种权限、缺权限会跳过什么。它不会替你点系统授权，也不会把没读到当成 0 字节。"
            case "启动项":
                return "启动项页只做分类、搜索和 Finder 定位，不自动禁用、不删 plist。要不要关，由你在系统设置里决定。"
            case "恢复":
                return "恢复清单给出精确路径和分组，方便你去废纸篓或原位置手动恢复。雪不自动搬回文件，避免覆盖你后来写的新版本。"
            case "缺口":
                return "缺口是这次没读全的位置，常见原因是权限、超时或目录正在写入。缺口存在时，全盘结论不完整，删除会被锁定。"
            case "设置":
                return "设置页改外观、单位、扫描范围和模型接入；所有改动只影响之后的读取与显示，不会自动开始扫描或删除。"
            case "帮助":
                return "帮助页解释判定口径、风险分级和废纸篓流程，不产生扫描、不生成计划，也不会替你执行任何动作。"
            default:
                return "\(page) 页保留专家模式的高密度信息：分类、体积、风险、原因和路径都在同一张表里。这里不做额外的 AI 计划，只让你核对。"
            }
        case 1:
            switch page {
            case "保护":
                return "保护页里的路径不是“暂时不能删”，而是硬边界：聊天记录、照片、文稿、密钥、云盘和系统关键数据都在这里。普通缓存规则不能越过它。"
            case "空间分析":
                return "空间分析里的个人目录只报告，不给删除按钮。这是刻意的：体积大不等于可以删，尤其是照片、工程和备份。"
            case "缺口":
                return "缺口存在时删除会被锁定，不是因为规则保守，而是这次没读全。先补权限或重试，再谈清理，避免拿不完整的结果下结论。"
            default:
                return "常见原因有四类：命中保护路径；这次全盘没有读全；规则本身要求你逐项确认；应用正在运行，缓存可能还在写入。前两类是硬锁定，后两类需要你明确点头。"
            }
        default:
            switch page {
            case "清理":
                return "不会。问雪没有删除按钮，也不会调用清理服务。清理页的勾选、确认和废纸篓流程仍由你完成；带「处理方式」的项只提示前提，不替你操作。"
            case "设置":
                return "不会。问雪和设置页都不会因为你打开或改选项就自动扫描、删除或改系统。所有删除仍然只走清理页的逐项确认。"
            default:
                return "不会。问雪没有删除按钮，也不会调用清理服务。它只解释当前页和规则；真正的删除仍然在原有清单里，逐项确认后只移入废纸篓，不永久删除。"
            }
        }
    }
}
