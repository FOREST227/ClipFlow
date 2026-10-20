# 开发与构建

[返回首页](../README.md)

ClipFlow 使用 SwiftUI 和 AppKit 构建。本文面向需要从源码运行、测试或打包应用的开发者。

## 本地运行

开发需要 Swift 6 和完整 Xcode；最低运行系统为 macOS 12。macOS 12 的开机启动需在系统“用户与群组 → 登录项”中手动添加，macOS 13 及以上可在应用内管理。

```bash
swift build
swift run ClipFlowApp
```

运行回归测试需要包含 XCTest 的完整 Xcode：

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test
```

## 构建应用

本机首次构建前，创建固定自签名身份：

```bash
zsh scripts/setup_signing.sh
```

证书为 `ClipFlow Local Development`，有效期 10 年，私钥保存在登录钥匙串。
脚本重复执行会复用原身份；构建过程不会生成新证书或静默退回临时签名。
公钥证书及指纹配置保存在 `~/Library/Application Support/ClipFlow/signing/`，不包含私钥。

```bash
./scripts/build_app.sh
open dist/ClipFlow.app
```

日常使用请将构建后的应用替换安装到固定位置 `/Applications/ClipFlow.app`，并从该位置启动。
从旧的临时签名切换到固定签名后，可能需要重新授予一次辅助功能等权限；之后保持同一证书、`com.clipflow.app` 标识和安装路径，便可维持稳定的代码身份。
系统重置隐私设置、证书更换或权限规则变化仍可能要求重新授权。

请在“钥匙串访问”中妥善备份该证书及私钥（加密的 `.p12`），不要提交到仓库。
换电脑时应导入原身份；重新创建同名证书并不等于同一身份。
也可用 `CLIPFLOW_SIGNING_IDENTITY` 指定已有代码签名证书的 40 位 SHA-1 指纹。

GitHub 托管构建机没有本机私钥，因此现有发布流程显式使用 `CLIPFLOW_ADHOC_SIGN=1`。
该 CI 产物仍为临时签名，不具备上述本机固定签名的权限连续性；本机常规构建不要设置此变量。

生成三种架构的安装包：

```bash
zsh scripts/build_release_dmg.sh v0.0.6
```
