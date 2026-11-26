# 治理

## 现状

本项目为个人维护的开源项目（pre-1.0）。治理目标只有一个：**保证删除判定不会被劣化**。

## 角色

| 角色 | 人数（当前） | 职责 | 权限 |
|---|---|---|---|
| Maintainer | 1 | 合并、发版、规则最终否决、许可证与治理文件变更 | 全部 |
| Rules reviewer | 1（暂由 Maintainer 兼任） | 审规则、试扫复核、保护路径冲突检查 | 审查 `Rules/` |
| Security reviewer | 1（暂由 Maintainer 兼任） | 处理私密漏洞报告 | 审查安全修复 |
| Contributor | 不限 | PR / issue / 规则草案 / 样本 | 无写权限 |

新增 reviewer 的条件：连续 3 个月有效贡献（≥5 个被合并的规则 PR 或 ≥3 个被合并的代码 PR），
且由现有 Maintainer 邀请。reviewer 不因贡献量获得任何形式的收益分成。

## 决定权

- **代码合并**：Maintainer 最终决定。
- **规则合并**：Rules reviewer 建议，Maintainer 最终决定；规则改动需两人复核。
- **许可证**：仅 Maintainer 决定；首次公开后不再更换（GPL 不可撤回）。
- **治理文件**（GOVERNANCE / SECURITY / CODE_OF_CONDUCT / TRADEMARK）：
  Maintainer 决定，公开征求意见至少 7 天。
- **品牌**：见 TRADEMARK.md。

## 规则争议如何升级

1. 在对应 PR 内讨论，贴样本与试扫结果；
2. 双方无法一致时，开一个 `rule-dispute` issue，附两边证据；
3. Rules reviewer 给出书面结论（采纳 / 拒绝 / 改为 `review` 分级 / 需要更多样本）；
4. 仍有异议由 Maintainer 裁定并记录结论；
5. 裁定记录写入该规则的 `source` / `verifiedAt` / `reviewer` 字段。

**默认保守**：证据不足时，规则保持停用或从 `safe` 降为 `review`，不因“多数人觉得可以删”而放行。

## 分支与发布

- `main` 保护：禁止直推、禁止 force push、至少 1 个 review、CI 必过。
- 规则改动单独 PR；重构与规则改动不混。
- 版本标签沿用既有版本号（首版快照为 `v0.9.32`），不为开源自造版本。
- Releases 只放：源码、校验和；**首版不提供预编译 `.app`**。
- 国内镜像（Gitee）只读；issue/PR 唯一入口在 GitHub。

## 维护者退出与交接

若维护者无法继续维护：

1. 在仓库置顶 issue 说明现状与时间预期；
2. 至少提前 30 天公开告知，允许社区 fork 接手；
3. 代码与规则库保持可构建、可复现；不因停止维护而删除历史；
4. 品牌名与 Releases 渠道随交接一并说明，避免 fork 冒充官方。

## 明确不做

- 不设付费支持、不设优先级队列、不接商业定制；
- 不承诺响应时间、不承诺 V1 发布日期；
- 不接受以“贡献量”换取规则放行或品牌授权。
