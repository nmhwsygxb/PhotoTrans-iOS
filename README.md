# PhotoTrans (iOS)

跨品牌照片/文件互传 - iOS (SwiftUI) 实现。
TCP 直连 + PT-HI 握手 + HTTP PUT 文件传输（兼容 Android 版与互传联盟协议）。

## 功能
- 近距离模式（Bonjour 发现）与远距离模式（IP 直连 / 二维码）
- 任意文件 / 文件夹 / 照片传输，显示进度、速度、剩余时间
- 格式检测模型（HEIC / HDR / Live Photo / RAW 等），支持版本管理与切换
- 接收文件保存到「文件 App -> PhotoTrans」目录，可选同步保存到相册

## 目录结构
```
project.yml                       XcodeGen 项目描述（云端自动生成 .xcodeproj）
.github/workflows/build-ios.yml   GitHub Actions 构建脚本
PhotoTrans/
  PhotoTransApp.swift             入口 + AppState
  Models/                         PhotoFormat / TransferModels / LocalModelStore
  Services/                       NetworkService(TCP+Bonjour+PT-HI) / TransferService / FormatDetector
  Views/                          ContentView / ModelManagementView / SettingsView
  Info.plist                      权限声明
```

## 云端编译（无需 Mac）
1. 本仓库 GitHub Actions 自动在 macOS 虚拟机编译，产出未签名 .ipa（Artifacts 下载）
2. Windows 上安装 [AltStore](https://altstore.io)，用 Apple ID 导入 .ipa 侧载到 iPhone（免费 Apple ID 即可，签名 7 天自动刷新）

## 本地编译（有 Mac 时）
```bash
brew install xcodegen
xcodegen generate --spec project.yml
open PhotoTrans.xcodeproj   # Xcode 里选择自己的 Team 签名后 Run
```