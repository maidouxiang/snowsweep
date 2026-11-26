# 规则

所有清理判断来自 `Rules/rules.json` 一个文件。当前：`version 0.5.2`，89 条规则，30 条保护路径。

## 一、判决顺序（不可更改）

1. **保护清单先拦**：命中 `protectedPaths` 的路径永不进入候选，无论规则怎么写、用户怎么配。
2. **按 priority 降序**：数值大的先判。
3. **pathPattern 特异性**：更具体的模式优先于更宽的。
4. **id 升序**：以上全等时按 id 字典序取第一条。

## 二、规则字段

| 字段 | 类型 | 说明 |
|---|---|---|
| `id` | string | 唯一标识，小写连字符 |
| `risk` | enum | `safe` / `review` / `protected` |
| `name` | string | 展示名 |
| `pathPattern` | string | 通配模式，支持 `**` |
| `owner` | string | 归属应用或系统组件 |
| `rebuildCost` | enum | `none` / `low` / `high`：删了之后重建的代价 |
| `reason` | string | 为什么会累积、删了影响什么（必须写实测事实） |
| `needConfirm` | bool | 是否逐条确认 |
| `priority` | int | 优先级 |
| `actionType` | enum | `trash` 进候选 / `guide` 只给入口 / `protect` 永不进候选 |
| `allowOverrideProtection` | bool | 是否允许用户在明确知情下越过保护清单（默认 false） |
| `requiresAppQuit` | bool | 需要先退出对应 App，只提示不代操作 |
| `minAgeDays` | int | 小于该天数的条目：`safe` 自动降级为 `review` |
| `sourceKind` | enum | `official` / `vendor` / `local-test` / `community` |
| `sourceURL` | string | `official` 与 `vendor` 必填，指向能验证该行为的原始出处 |
| `confidence` | 0–1 | 置信度 |
| `verifiedAt` | date | 最后在本机验证的日期 |
| `guide` | string | 给用户的操作引导（当 `actionType=guide` 时是正文） |

## 三、三档风险的语义

| risk | 含义 | 当前条数 |
|---|---|---|
| `safe` | 删除后不影响系统与其他应用，重建代价 none/low | 38 |
| `review` | 需要人看一眼：可能是用户数据、可能重建代价高、可能 App 正在用 | 36 |
| `protected` | 永不进候选，只用于告知这里不碰 | 15 |

`sourceKind=community` 的规则默认只能落到 `review`，不能直接给 `safe`。

## 四、保护路径

`protectedPaths` 30 条，覆盖几类"看起来像缓存、其实是用户资产"的地方，例如：

```json
["~/.ollama/**", "~/.lmstudio/**", "~/.cache/huggingface/**", "~/.claude/**"]
```

原则：模型权重、训练数据、本地知识库、密钥与凭据目录一律保护，宁可少清不可错清。

## 五、贡献一条规则的 9 条门槛

1. 有真实复现场景：在你自己机器上能稳定看到它累积，附体量（如"累积 42 GB"）
2. 说清 `rebuildCost`：删掉之后怎么恢复、恢复要多久
3. `sourceKind` 是 `official`/`vendor` 的，必须给 `sourceURL`
4. 不含任何个人信息：不写你的用户名、不写完整路径中的用户名段
5. `pathPattern` 足够窄：不用 `~`、不用 `~/Library` 这种过宽前缀，不用 `/System`、`/usr`、`/bin`
6. 填 `verifiedAt` 与 `confidence`，两者要匹配你的验证强度
7. 明确 `actionType`：拿不准就给 `guide`，不要给 `trash`
8. 本地试扫通过：用 `ReleaseSim` 在合成夹具上跑，确认只命中预期路径
9. PR 里引用对应的 `rule-missing` issue 编号

## 六、提交方式

- 先开规则缺失 issue（见 `.github/ISSUE_TEMPLATE/rule-missing.yml`），描述现象与体量
- 维护者确认方向后再提 PR，PR 模板要求贴试扫输出
- 不接受"我看它像垃圾所以想删"这类无实测依据的规则

## 七、用户本地 overlay

用户可以在本地加自己的规则，这些规则：

- `source` 永远是 `user`
- 优先级低于内置规则
- 不能穿透保护清单
- 不进仓库、不进样本、不参与社区讨论

## 八、规则版本

`Rules/rules.json` 的 `version` 与 App 版本解耦。规则更新可以比 App 更快，但公开仓库里规则版本必须与 `CHANGELOG.md` 记录一致。
