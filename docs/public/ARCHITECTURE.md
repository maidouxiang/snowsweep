# 架构

雪（SnowSweep）是一个 macOS 本地清理与体检工具。默认端侧运行、默认非破坏、默认可审计。

## 一、设计约束

1. **不联网也能用**：除"可选"的 AI 意图理解外，全部功能在本地完成。
2. **不做不可确认的删除**：任何 `permanent` 动作必须经过二次确认与审计落盘。
3. **保护优先**：保护清单（`protectedPaths`）的优先级高于一切规则，用户 overlay 规则也不能穿透。
4. **每个判断可追溯**：一条路径为什么进候选、命中哪条规则、什么风险等级，都能在报告里查到。

## 二、模块划分

| 模块 | 类型 | 规模 | 职责 |
|---|---|---|---|
| `SnowSweepCore` | library | 68 文件 / 约 1.5 万行 | 扫描、规则判决、清理执行、审计回滚、报告脱敏、样本导出 |
| `SnowSweepApp` | executable（SwiftUI） | 36 文件 / 约 2.1 万行 | 菜单栏常驻、主窗口、扫描状态机、系统指标、设置与权限引导 |
| `ScannerService` | executable | 267 行 | 独立扫描进程，隔离磁盘遍历与主 App |
| `FamilyScan` | executable | 148 行 | 家族/多用户目录的批量扫描入口 |
| `CleanupE2E` | executable | 531 行 | 清理流程端到端验证 |
| `ReleaseSim` | executable | 461 行 | 规则试扫与发布前仿真（不触碰真实数据） |
| `SoakTest` | executable | 428 行 | 长时间运行稳定性测试 |
| `ModelHost` | executable | 482 行 | 本地模型宿主进程（权重不入仓、不随包分发） |

依赖关系：所有可执行目标只依赖 `SnowSweepCore`，模块之间不横向引用。无第三方 SwiftPM 依赖。

## 三、主数据流

```
磁盘遍历（ScannerService / FamilyScan）
   ↓  原始条目：路径 + 大小 + mtime + 归属
规则判决（RuleEngine + Rules/rules.json）
   ↓  保护清单先拦截 → priority 降序 → 特异性 → id 升序
候选集（risk = safe / review / protected，actionType = trash / guide / protect）
   ↓  用户确认（needConfirm、requiresAppQuit、minAgeDays 降级）
清理执行（移入废纸篓 / 备份后删除 / 永久删除）
   ↓  每一步落审计
审计日志（可回滚）
   ↓
报告生成 → ReportRedactor 脱敏 → 导出 Markdown / JSON / CSV
   ↓（可选）
样本导出器 → xue.sample/v1
```

## 四、关键不变量

| 不变量 | 落地位置 |
|---|---|
| 保护清单最高优先 | `RuleEngine` 判决顺序第一步 |
| 不可逆操作必须二次确认 | 清理执行层 + UI 确认门槛 |
| 审计可回滚 | `Audit` 记录 + 回滚路径 |
| 报告默认脱敏 | `ReportRedactor`：家目录 → `~/`、用户名 → 占位 |
| App 运行中只提示不操作 | `requiresAppQuit` 仅给引导 |
| 规则来源必须可查 | `sourceKind` + `sourceURL` 强制 |

## 五、端侧 AI 的位置

`ModelHost` 是一个独立的本地模型宿主进程，负责把自然语言意图（"帮我清一下 Xcode 缓存"）解析成候选范围。它有三个约束：

- 权重**不在仓库里**，也不随构建产物分发
- 宿主与主 App 之间只有结构化请求/响应，不传文件内容
- 模型不可用时，功能退化为"关键词匹配 + 规则直选"，不影响清理主链路

## 六、扩展点

- **规则**：往 `Rules/rules.json` 加条目，见 [RULES.md](RULES.md)
- **扫描范围**：`ScanScope` 定义（用户目录 / 整盘 / 指定根）
- **报告格式**：`ReportExporter` 的编码器
- **样本**：见 [SAMPLES.md](SAMPLES.md)

## 七、不在架构里的事

- 不做云端同步、不做账号体系、不做遥测上报
- 不做跨平台抽象层（Windows/Linux），代码可以直用 AppKit/SwiftUI
- 不做自动更新通道（当前版本只发源码）
</file_path>
