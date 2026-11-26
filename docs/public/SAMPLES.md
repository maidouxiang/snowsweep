# 样本：`xue.sample/v1`

样本是**机器脱敏后的结构化报告**，不是"把你的目录截图发上来"。它的用途只有一个：让维护者在不看你的隐私的前提下，判断某条规则是否该补、某个判断是否判错。

## 一、硬规则（先读这条）

**永远不收集**

- 原始路径（真实用户名、真实文件名全都不行）
- 文件内容、照片、聊天记录、浏览器历史、Keychain、shell 历史
- 屏幕截图（默认不包含；即使你主动选了，也必须先去掉 EXIF）
- 软件序列号、账号、令牌

**只收集**

- 目录**结构模式**（`~/Library/Caches/<app-id>/<hash>`）
- 数量与体积的**量级**（`100-1000` 个 / `1-5GB`）
- 版本、架构、语言环境这类不含身份的信息

## 二、包结构

```text
xue-sample-<uuid>.zip
├── manifest.json      # 清单：文件列表 + 各自 sha256
├── sample.json        # 主文件，见下
├── scan-summary.json  # 扫描摘要（覆盖率、跳过原因）
├── README.txt         # 人读说明，写清这份样本说明了什么问题
└── screenshots/       # 默认不存在；必须显式选择且已去 EXIF
```

## 三、`sample.json` 最小字段

```json
{
  "schema": "xue.sample/v1",
  "sample_id": "uuid",
  "created_at": "2026-11-27T10:00:00+08:00",
  "app":    { "version": "0.9.33", "build": "0.9.33", "bundle_id": "com.selfuse.xue" },
  "host":   { "macos": "26.x", "arch": "arm64", "locale": "zh_CN" },
  "rules":  { "version": "0.5.2", "sha256": "…" },
  "intent": { "category": "unknown", "query_redacted": "清理某个应用缓存" },
  "observation": {
    "scope": ["~/Library/Caches/<app-id>"],
    "coverage": 0.87,
    "file_count_bucket": "100-1000",
    "bytes_bucket": "1-5GB"
  },
  "paths": [
    { "pattern": "~/Library/Caches/<app-id>/<hash>", "role": "observed", "protected": false }
  ],
  "verdict": { "result": "unknown", "closest_rules": ["rule-id"], "evidence": ["evidence-id"] },
  "consent": {
    "sample_license": "CC0-1.0",
    "public_sample": true,
    "raw_paths": false,
    "screenshots": false
  }
}
```

## 四、字段说明

| 字段 | 要求 |
|---|---|
| `schema` | 固定 `xue.sample/v1`，不接受其他值 |
| `sample_id` | UUID，不复用 |
| `host.locale` | 只到语言层（`zh_CN`），不写设备名 |
| `rules.sha256` | 你当时用的 `Rules/rules.json` 指纹，便于复现判断 |
| `intent.query_redacted` | 你原话**改写后**的版本，去掉个人信息 |
| `observation.coverage` | 必填。覆盖率低于 0.5 的样本没有诊断价值 |
| `paths[].pattern` | 只写模式，`<app-id>` `<hash>` 这类占位符必须保留 |
| `paths[].protected` | 是否命中保护清单，便于核对保护逻辑 |
| `consent.public_sample` | `false` 表示只给维护者私下看，不公开 |

`bytes_bucket` 与 `file_count_bucket` 用区间而不是精确值：精确值会泄露"你机器上确实有这个文件"的细节。

## 五、许可

公开样本一律 **CC0-1.0**（公有领域贡献）。你提交即表示同意该样本可被任何人无条件使用，包括写进测试夹具。

不愿放弃权利的，把 `consent.public_sample` 设成 `false`，走私下渠道，不进仓库、不进 issue。

## 六、怎么提交

1. 用 **sample** 表单建 issue，标题写清"哪个软件 / 什么问题"
2. 把 zip 附上，或先贴上 `sample.json` 的正文
3. `README.txt` 写三句话：现象、你期望的判断、实际判断
4. 维护者会把它转成测试夹具，或在 `Rules/rules.json` 里补规则

**不要**把原始诊断文件、带路径的日志、截图直接贴到公开 issue。那类东西只走私下的安全渠道（见 [SECURITY.md](../../SECURITY.md)）。

## 七、导出工具

导出器从 **V0.9.33** 起随源码提供，命令行目标 `SampleExport`。它只读输入、脱敏、写包，**不扫描、不删除、不联网**。

```bash
# 1. 把应用里导出的“规则缺失报告”（.json）转成脱敏样本
swift run SampleExport --case 雪-规则缺失-xxxxxxxx.json --out ~/Desktop/雪样本

# 2. 生成三份合成夹具（只用 example 假路径，不碰本机数据），用于验证导出器本身
swift run SampleExport --fixture --out ~/Desktop/雪样本示例
```

输出目录结构就是上面的四件套；加 `--no-zip` 可只写目录不打 zip。

`--case` 模式会做的事：

- `/Users/<你的名字>` 与其它绝对路径 → `~/...` 模板
- 应用标识（`com.vendor.app`）与系统目录（`Library/Caches` 等）保留，其余层级 → `<name>` / `<hash>` / `<id>`
- 用户原话先脱敏再截断；含路径或残留长编号的原话直接不导出，只留 `category`
- 数量与体积只写区间

`samples/fixtures/` 下有三份合成夹具（缓存 / 容器 / 文稿），可以直接对照字段，也可以拿去写测试。

导出器不替你判断"这份样本能不能公开"——**上传前请自己再读一遍 `sample.json`**。

## 八、维护者怎么用样本

1. 先核对 `rules.sha256` 是否与当前规则一致
2. 覆盖率、`verdict.result` 对不上的，直接转成回归测试
3. 模式清楚、理由充分的，补进 `Rules/rules.json`（流程见 [RULES.md](RULES.md)）
4. 涉及新软件家族的，同时更新 `software-families.json`
