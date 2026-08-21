# PhotoTrans (iOS)

> 跨品牌照片/文件无线传输 - iOS (SwiftUI) 实现。
> TCP 直连 + PT-HI 握手 + HTTP PUT 文件传输（与 Android 和 HarmonyOS 协议兼容）。

![Build iOS App](https://github.com/nmhwsygxb/PhotoTrans-iOS/actions/workflows/build-ios.yml/badge.svg)

## 功能

- 近场 (Bonjour 发现) 和远场 (IP/扫码直连) 两种连接模式
- 文件 / 文件夹 / 照片批量传输
- 智能格式识别 (HEIC / HDR / Live Photo / RAW 等)
- 自动保存到相册

## 项目结构

```
project.yml                         XcodeGen 项目描述
.github/workflows/build-ios.yml     GitHub Actions 构建配置
PhotoTrans/
  PhotoTransApp.swift               入口 + AppState
  Models/                           PhotoFormat / TransferModels / LocalModelStore
  Services/                         NetworkService(TCP+Bonjour+PT-HI) / TransferService / FormatDetector
  Views/                            ContentView / ModelManagementView / SettingsView
  Info.plist                        应用配置
```

## 构建方式

### 云构建 (无需 Mac)

仓库已配置 GitHub Actions（macOS 15 + Xcode 16）自动构建未签名 IPA：

1. `push` 到 `main` 或手动触发 `workflow_dispatch`
2. xcodegen 生成项目 → xcodebuild 编译（CODE_SIGNING_ALLOWED=NO）
3. 构建产物 `PhotoTrans-unsigned-ipa` 上传到 Artifacts，保留 14 天

### 获取 IPA 并侧载到 iPhone

1. 打开 [Actions 页面](https://github.com/nmhwsygxb/PhotoTrans-iOS/actions)，选择最新的成功运行
2. 在 Artifacts 下载 `PhotoTrans-unsigned-ipa`，解压得到 `.ipa`
3. 用 [AltStore](https://altstore.io/) / Sideloadly 等工具，以你的 Apple ID 签名并安装
   （未签名 IPA 无法直接安装，需自签）

### 本地构建 (需要 Mac)

```bash
brew install xcodegen
xcodegen generate --spec project.yml
open PhotoTrans.xcodeproj   # 在 Xcode 中打开并 Run
```

## 传输协议 (与 Android/HarmonyOS 兼容)

### 握手
```
S→R:  PT-HI <deviceName>\n
R→S:  PT-HI <deviceName>\n
```
### 文件传输
```
S→R:  PUT /<filename> HTTP/1.1\r\nContent-Length: <n>\r\n\r\n<raw bytes>
R→S:  HTTP/1.1 200 OK\r\n\r\n
```
默认端口：**47808**

## 格式识别

支持通过文件头魔数识别：HEIC、JPEG、PNG、GIF、WebP、OPUS、ARW、DNG、NEF、RAW 等。

## 开源协议

MIT License