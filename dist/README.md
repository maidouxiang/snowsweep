# dist/ — 预编译安装包

这里存放**当前版本**的 macOS 安装包（`.zip`，内含 `雪.app`，双击解压即可）。
对应的源码在本仓库同一版本的 tag 中，满足 GPL-3.0 的源码提供义务。

历史版本不再堆在仓库里（避免仓库体积随版本线性增胖），
请到 [Releases](https://github.com/maidouxiang/snowsweep/releases) 按 tag 下载对应附件。

## 当前版本

| 版本 | 文件 | 大小 |
| --- | --- | --- |
| v0.9.36 · 雪发 | `snowsweep-macos-v0.9.36.zip` | 约 11.3 MB |

## 校验

```bash
shasum -a 256 -c SHA256SUMS.txt
```

## 安装

1. 解压，把 `雪.app` 拖进「应用程序」；
2. 首次打开被拦时，Finder 里 **右键 → 打开**；或终端
   `xattr -dr com.apple.quarantine /Applications/雪.app`；
3. 首次扫描请求「完全磁盘访问权限」，到「系统设置 → 隐私与安全性」勾选 `雪`。

## 签名状态（务必知道）

- 安装包为 **ad-hoc / 本地自签名**，未做 Apple 公证，因此 Gatekeeper 会提示“无法验证开发者”。
- ad-hoc 签名每次构建都会变化；**跨版本覆盖安装后，系统可能重新询问磁盘权限**，属正常现象。
- 若要求可验证的签名分发，请自行用你的开发者证书重签：

```bash
codesign --force --deep --sign "Developer ID Application: 你的名字 (TEAMID)" /Applications/雪.app
```

## 不放心的替代方案

直接按仓库根的 README「构建」一节源码编译，产物与本包同源：

```bash
swift build --disable-sandbox
./install-selfuse.sh
```
