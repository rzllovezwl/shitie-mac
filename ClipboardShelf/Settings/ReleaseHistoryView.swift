import SwiftUI

struct ReleaseHistoryView: View {
    @Environment(\.dismiss) private var dismiss

    private let history = try? ReleaseHistory.loadFromBundle()
    private let currentVersion = ReleaseHistory.currentVersion()

    var body: some View {
        NavigationStack {
            Group {
                if let history {
                    List {
                        ForEach(history.releases) { release in
                            Section {
                                ForEach(release.changes.indices, id: \.self) { index in
                                    LucideLabel(release.changes[index], symbol: .circleCheck)
                                        .labelStyle(.titleAndIcon)
                                        .padding(.vertical, 3)
                                }
                            } header: {
                                VStack(alignment: .leading, spacing: 5) {
                                    HStack(spacing: 8) {
                                        Text("\(release.version)（\(release.build)）")
                                            .font(.headline)
                                        if release.version == currentVersion.version && release.build == currentVersion.build {
                                            Text("当前版本")
                                                .font(.caption)
                                                .foregroundStyle(.tint)
                                                .padding(.horizontal, 7)
                                                .padding(.vertical, 3)
                                                .background(Color.accentColor.opacity(0.12), in: Capsule())
                                        }
                                        Spacer()
                                        Text(release.date)
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }
                                    Text(release.title)
                                        .font(.subheadline)
                                }
                            }
                        }
                    }
                    .listStyle(.inset)
                } else {
                    VStack(spacing: 10) {
                        LucideIcon(.triangleAlert, size: 36)
                            .foregroundStyle(.secondary)
                        Text("版本记录暂不可用")
                            .font(.headline)
                        Text("请重新安装应用，或联系 584772541@qq.com。")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .navigationTitle("版本记录")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { dismiss() }
                        .keyboardShortcut(.escape, modifiers: [])
                }
            }
        }
        .frame(width: 640, height: 520)
    }
}
