# PhotoTrans (iOS)

> 跨品牌照片/文件无线传输 - iOS (SwiftUI) 实现。
> TCP 直连 + PT-HI 握手 + HTTP PUT 文件传输（与 Android 和 HarmonyOS 协议兼容）。

## 功能

- 近场 (Bonjour 发现) 和远场 (IP 直连) 两种连接模式
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

### 云构建 (推荐，无需 Mac)

仓库已配置 GitHub Actions 自动构建。触发后：
1. 在 macOS 14 runner 上使用 xcodegen 生成项目
2. xcodebuild 编译为未签名 IPA
3. 上传到 Artifacts，保留 14 天

### 获取 IPA 并侧载到 iPhone

1. **下载 IPA**：进入 GitHub Actions 页面，选择最近的 build 运行，在 Artifacts 中下载 `PhotoTrans-unsigned-ipa`
2. **解压**：解压后得到一个 `.ipa` 文件
3. **侧载**：在 Windows 上安装 [AltStore](https://altstore.io/)，将 iPhone 连接到电脑，使用 Apple ID 登录后，将 `.ipa` 拖入 AltStore 安装

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

## 格式识别

支持通过文件头魔数识别：HEIC、JPEG、PNG、GIF、WebP、OPUS、ARW、DNG、NEF、RAW 等。

## 开源协议

MIT License