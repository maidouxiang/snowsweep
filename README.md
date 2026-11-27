<!--
本文件是「公开版 README」草稿，替换仓库根的 README.md 使用。
待补齐：docs/public/ARCHITECTURE.md、RULES.md、BUILD.md、SAMPLES.md、ROADMAP.md
定稿前请再核对：规则条数、保护路径条数、测试数、最低系统版本。
-->

# 雪（SnowSweep）

开源、非商业、默认端侧的 macOS 清理与体检工具。**规则决定，模型只解释；默认不删。**

> **⚠️ 风险声明（请先读）**
> 本项目为 pre-1.0 阶段，**具备移动与删除文件的能力**。默认行为是“预览 + 移入废纸篓”，
> 不永久删除；但误判仍可能发生。请先备份重要数据，并在你自己的机器上先小范围试用。
> 本项目**不承诺**响应时间、V1 发布日期或任何商业支持。

## 它是什么

- 一句话说出想清理什么，工具把它编译成**受限意图**，只在白名单目录里只读测量体积；
- 给出“可放心清 / 要你决定 / 雪不动”三类结果，逐项中文名 + 一句人话 + 可折叠原始路径；
- 用户确认后逐项移入废纸篓，写审计记录，可回退定位；
- 支持空间分析（逐层下钻、树图、时间线与变化账单）、大文件与重复核对、
  软件族谱（插件归属与孤儿候选）、卸载残留、权限与启动项审查、电池与设备状态。

## 原则

1. **规则决定，模型解释**。模型永远不直接批准删除。
2. **默认不删**：只有 `safe` 且无需确认的项才默认勾选；先预览、默认移废纸篓、永久删除需二次确认。
3. **默认不出端**：零账号、零遥测。联网核验默认关闭，单次手动打开后只向 Apple 公开目录发送
   当前一个 Bundle ID，不发送路径、文件名、哈希或目录列表。查不到不等于文件可删。
4. **全中文标识**：中文名 + 一句人话 + 可折叠原始路径，看不懂的英文默认折叠。
5. **权限不足就降级并标注缺口**，不把“完全磁盘访问”当成稳定前提。

## 当前状态

- 版本：`v0.9.35 · 雪集`（pre-1.0，未发布正式版）
- 规则库：`Rules/rules.json`，`version 0.5.2`，**89 条规则**，**30 条保护路径**
- 测试：**392 项**（双场景 CMake/CI 各 1 项 live skip）
- V1.0 尚未开工；当前版本为可复现构建的源码快照

## 下载安装包（macOS，未签名）

不想编译也可以直接用现成包。

- **GitHub：[Releases](https://github.com/maidouxiang/snowsweep/releases)**（推荐，带版本说明与下载计数）
- **Gitee 镜像**：本仓 `dist/` 目录按版本存放同名 zip，配套 `dist/SHA256SUMS.txt` 校验值

| 版本 | 文件 | 校验 |
| --- | --- | --- |
| v0.9.35 · 雪集 | [`dist/snowsweep-macos-v0.9.35.zip`](dist/snowsweep-macos-v0.9.35.zip)（约 11 MB） | 见 `dist/SHA256SUMS.txt` |

安装步骤：

1. 下载 zip，解压得到 `雪.app`，拖进「应用程序」；
2. 首次打开若提示“无法验证开发者”，在 Finder 里 **右键 → 打开**，或在终端执行
   `xattr -dr com.apple.quarantine /Applications/雪.app`；
3. 首次扫描会请求「完全磁盘访问权限」，请在「系统设置 → 隐私与安全性」里勾选 `雪`。

> **为什么提示未签名**：本项目是本地自签名/ad-hoc 签名的免费软件，**没有 Apple 开发者
> 证书、不做公证**。拒绝签名不等于代码有问题，源码就在本仓，可自行比对、自行编译。
> 每个安装包都提供 SHA256，下载后可用 `shasum -a 256 文件` 核对。

## 构建

要求：macOS 26 或更高、Xcode 命令行工具、Swift 6.x（`Package.swift` 为 `swift-tools-version: 6.2`、
`.macOS(.v26)`）。无外部 SwiftPM 依赖。

```bash
git clone https://github.com/maidouxiang/snowsweep.git
cd snowsweep

swift build --disable-sandbox
./test.sh
```

- 本机 SwiftPM 默认沙盒可能报 `sandbox_apply` 错误，故需 `--disable-sandbox`。
- `./ci-check.sh` 跑双场景（有/无端侧模型）编译与测试。
- 详细构建、签名、权限说明见 [`docs/public/BUILD.md`](docs/public/BUILD.md)。

## 运行

```bash
./build.sh
# 产物在 .build/out/Products/ 下；也可用 Xcode 打开 Package.swift 运行
```

首次运行需要授予磁盘访问权限：

- 优先按文件夹授权（扫描/监控默认按目录授权）；
- 未授权时工具会降级运行，并在界面标注“未读到 / 权限缺口”，不把读不到当作可删；
- **不要**为了省事长期开启全盘完全磁盘访问；系统保护路径即使授权也可能不可读，这是系统行为。

本地打包为 `.app`（自用版）：

```bash
./scripts/setup-signing-identity.sh   # 首次：建立本机自签名身份
./install-selfuse.sh                  # 打包并安装到 /Applications/雪.app
```

- 使用自签名身份，Bundle ID 为 `com.selfuse.xue`；App 名称显示为“雪”。
- 未签名的构建会被 Gatekeeper 拦截，属预期行为。
- 卸载：把 `雪.app` 移入废纸篓；用户数据在 `~/Library/Application Support/雪/`。

## Mole CLI（可选）

V0.9.x 以 [Mole CLI](https://github.com/tw93/Mole)（GPL-3.0）为清理执行兼容基座。
未安装、版本过低或探测失败时，自动降级到内置扫描器，判定功能不受影响。
第三方许可与义务见 [`NOTICE`](NOTICE)。

## 规则与样本

- 规则结构、保护路径、贡献与试扫流程： [`docs/public/RULES.md`](docs/public/RULES.md)
- 样本格式与脱敏硬规则： [`docs/public/SAMPLES.md`](docs/public/SAMPLES.md)
- 欢迎提交“规则未命中”：用 `rule-missing` issue 模板，附已脱敏的 `xue.sample/v1` JSON

**公开渠道只接受脱敏样本**：不含原始路径、文件名、截图、聊天记录、照片、浏览器历史、
Keychain 内容或 shell 历史。原始诊断请走私密渠道，不要贴在公开 issue。

## 架构

9 个主入口（今天、案卷、清理、空间、设备、访问、安全、隐私、设置）+ Agent 全局层与菜单栏速览；
核心库 `SnowSweepCore`（规则引擎、判定、扫描、审计）与 `SnowSweepApp`（SwiftUI 界面、系统集成）分离。
详见 [`docs/public/ARCHITECTURE.md`](docs/public/ARCHITECTURE.md)。

## 文档

| 文档 | 用途 |
|---|---|
| [`docs/public/BUILD.md`](docs/public/BUILD.md) | 构建、签名、TCC 与降级行为 |
| [`docs/public/RULES.md`](docs/public/RULES.md) | 规则 schema、保护路径、贡献与试扫 |
| [`docs/public/SAMPLES.md`](docs/public/SAMPLES.md) | `xue.sample/v1`、脱敏规则、提交方式 |
| [`docs/public/ARCHITECTURE.md`](docs/public/ARCHITECTURE.md) | 模块划分与数据流 |
| [`docs/public/ROADMAP.md`](docs/public/ROADMAP.md) | V1.0 范围、已知不做项 |
| [`CHANGELOG.md`](CHANGELOG.md) | 版本变更 |
| [`SECURITY.md`](SECURITY.md) | 漏洞报告与披露节奏 |
| [`CONTRIBUTING.md`](CONTRIBUTING.md) | 贡献流程与禁止项 |
| [`GOVERNANCE.md`](GOVERNANCE.md) | 决定权与争议升级 |
| [`TRADEMARK.md`](TRADEMARK.md) | 品牌与 fork 命名 |

## 社区

- **唯一讨论区在 GitHub**（Issues / Discussions）。
- Gitee 镜像为**只读副本**，不接受 issue/PR。
- 官方产物只从本仓库 Releases 获取；任何第三方打包均非官方版本。
- 本项目不收集遥测；样本提交必须手动导出、手动上传。

## 许可

[GNU General Public License v3.0](LICENSE)，与 Mole CLI 保持一致。完整正文见 `LICENSE`，
第三方组件与资产许可见 [`NOTICE`](NOTICE)。

## 致谢

感谢 [Mole](https://github.com/tw93/Mole) 提供的开源清理基座，以及所有提交规则与样本的贡献者。

## 镜像

- 主仓库：<https://github.com/maidouxiang/snowsweep>
- 国内只读镜像：<https://gitee.com/photographer-jiang-xiao/snowsweep>

镜像仅同步 commit，issue 与 PR 只在 GitHub 受理。
