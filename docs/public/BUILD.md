# 构建、运行与权限

## 一、环境要求

| 项 | 要求 |
|---|---|
| macOS | **26 及以上**（`Package.swift` 写死 `.macOS(.v26)`） |
| Swift | **6.2** 工具链（Xcode 26 自带） |
| 外部依赖 | **无**。没有第三方 SwiftPM 包，除首次拉仓库外不需要联网 |

## 二、构建与测试

```bash
git clone git@github.com:maidouxiang/snowsweep.git
cd snowsweep

./build.sh     # = swift build --disable-sandbox
./test.sh      # = swift test  --disable-sandbox
```

**为什么带 `--disable-sandbox`**：SwiftPM 的构建沙盒在本机会报 `sandbox_apply` 失败，两个脚本统一关掉这层包装——只关构建期沙盒，不动系统安全机制。

## 三、运行

```bash
./build.sh
.build/debug/SnowSweepApp
```

启动后菜单栏出现图标。此时大部分目录仍读不到，属正常现象，见下一节。

## 四、必须授权的两个权限

| 权限 | 位置 | 不给会怎样 |
|---|---|---|
| 完全磁盘访问 | 系统设置 → 隐私与安全性 → 完全磁盘访问 | `~/Library` 大面积不可读，规则命中率骤降 |
| App 管理 | 系统设置 → 隐私与安全性 → App 管理 | 涉及其他 App 包内文件的操作被拒 |

缺权限不会闪退，而是产出 `ScanGapReport`：跳过了哪些目录、覆盖率多少、该开哪个开关。**先看覆盖率，再看清理条数。**

## 五、自检：双场景

```bash
./ci-check.sh                          # 默认在 /tmp 干净副本里跑
SNOWSWEEP_CI_IN_PLACE=1 ./ci-check.sh  # 在原目录跑
```

两个场景都必须过：

1. 正常环境：构建 + 全量测试
2. `SNOWSWEEP_DISABLE_AI=1`：模拟没有模型框架的环境

默认复制到 `/tmp` 再跑，原因写在脚本注释里：Desktop 路径下 SwiftPM 链接测试包会卡在 `getxattr`（TCC 相关），换到非 Desktop 路径就正常。

> 仓库**不带** GitHub Actions 配置。托管 runner 没有 macOS 26 / Swift 6.2，跑出来的绿灯没有意义。要接 CI 请自建 runner。

## 六、签名与安装（可选）

仓库只发源码、不分发二进制，所以默认没有签名配置。要在本机装成真正的 `.app`：

```bash
./install-selfuse.sh
```

它会：release 构建 → 组装 `雪.app`（可执行 + 规则 + 中文词典 bundle + Info.plist）→ 用本机固定自签名身份签名 → 装到 `/Applications`。证书缺失时回退 ad-hoc。

- 固定自签身份的意义：**跨版本保留 TCC 授权**，否则每次重装都要重新授权
- keychain 默认名 `xue-signing.keychain-db`，可用环境变量 `SNOWSWEEP_SIGN_KEYCHAIN` 覆盖成你自己的
- 不公证、不上架、零网络

> 自用安装脚本是你自己用的，不是发布通道。对外分发二进制需要另做 GPL 合规评估。

## 七、版本号

```bash
./version.sh    # 从 Sources/SnowSweepCore/AppVersion.swift 读
```

版本号、代号、devtag 只有 `AppVersion.swift` 一处事实来源，脚本与界面都从它取。

## 八、常见问题

| 现象 | 原因 | 处理 |
|---|---|---|
| `sandbox_apply` 报错 | SwiftPM 构建沙盒与当前环境冲突 | 用 `./build.sh`，别裸跑 `swift build` |
| 测试链接卡住不动 | Desktop 路径的 `getxattr` / TCC | `./ci-check.sh` 会自动换到 `/tmp` |
| 扫描结果明显偏少 | 缺完全磁盘访问 | 看 `ScanGapReport` 覆盖率 |
| 重装后权限又要重授 | 签名身份变了 | 固定用同一个自签身份 |
| 无模型环境启动慢 | 在探测模型可用性 | 属正常，功能降级为关键词匹配 |
