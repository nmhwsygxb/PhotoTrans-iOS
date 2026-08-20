import SwiftUI

/// Settings: learning control, storage, about. Also provides cache-clearing
/// and (optional) save-received-media-to-Photos toggles.
struct SettingsView: View {
    @EnvironmentObject var appState: AppState

    var body: some View {
        Form {
            Section("格式学习") {
                LabeledContent("当前模型", value: LocalModelStore.defaultStore.activeModel?.displayVersion ?? "无")
                LabeledContent("版本数量", value: "\(LocalModelStore.defaultStore.installedVersions.count)")
                NavigationLink("模型管理") {
                    ModelManagementView()
                }
            }

            Section("存储") {
                LabeledContent("接收目录", value: TransferService.receiveDirectory().lastPathComponent)
                Button("清除接收缓存", role: .destructive) {
                    let dir = TransferService.receiveDirectory()
                    if let urls = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) {
                        for url in urls { try? FileManager.default.removeItem(at: url) }
                    }
                }
            }

            Section("接收设置") {
                Toggle("接收文件同步存入相册", isOn: $appState.transferService.settings.storeReceivedFilesInPhotos)
                Toggle("大文件传输警告", isOn: $appState.transferService.settings.showLargeFileWarnings)
            }

            Section("关于") {
                LabeledContent("版本", value: appVersion())
                LabeledContent("协议", value: "PhotoTrans TCP · PT-HI")
            }
        }
        .navigationTitle("设置")
    }

    private func appVersion() -> String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0"
    }
}