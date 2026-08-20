import SwiftUI

/// Model version management: list installed versions with name + creation time,
/// long-press (context menu) to switch or delete.
struct ModelManagementView: View {
    @EnvironmentObject var appState: AppState
    @State private var store: LocalModelStore = .defaultStore

    var body: some View {
        List {
            Section("统计") {
                LabeledContent("当前版本", value: store.activeModel?.displayVersion ?? "无")
                LabeledContent("已装版本", value: "\(store.installedVersions.count) 个")
                LabeledContent("支持品牌", value: store.activeModel?.supportedBrandDescription ?? "—")
            }

            Section("模型版本列表") {
                ForEach(store.installedVersions) { version in
                    ModelVersionRow(version: version,
                                    isActive: version.id == store.activeModelId,
                                    onSwitch: {
                                        if store.activate(modelID: version.id) { }
                                    },
                                    onDelete: {
                                        if store.delete(modelID: version.id) { }
                                    })
                }
            }
        }
        .navigationTitle("模型管理")
    }
}

private struct ModelVersionRow: View {
    let version: ModelVersion
    let isActive: Bool
    let onSwitch: () -> Void
    let onDelete: () -> Void

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Text(version.displayVersion)
                        .font(.subheadline.weight(.semibold))
                    if isActive {
                        Text("当前")
                            .font(.caption2.weight(.bold))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Color.green.opacity(0.2))
                            .foregroundColor(.green)
                            .clipShape(Capsule())
                    }
                }
                Text("创建: \(version.releaseDate.formatted(date: .abbreviated, time: .shortened))")
                    .font(.caption)
                    .foregroundColor(.secondary)
                Text("品牌: \(version.supportedBrandDescription)")
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }
            Spacer()
        }
        .contentShape(Rectangle())
        .onTapGesture {
            if !isActive { onSwitch() }
        }
        .contextMenu {
            if !isActive {
                Button(action: onSwitch) { Label("切换到此版本", systemImage: "checkmark.circle") }
            } else {
                Text("当前版本")
            }
            if !isActive {
                Button(role: .destructive, action: onDelete) { Label("删除此版本", systemImage: "trash") }
            }
        }
    }
}