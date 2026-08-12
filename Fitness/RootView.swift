import SwiftUI

struct RootView: View {
    @EnvironmentObject private var store: HealthDataStore

    var body: some View {
        NavigationStack {
            Group {
                switch store.state {
                case .idle, .loading:
                    ProgressView("正在读取健康数据…")
                case .unavailable:
                    ContentUnavailableView {
                        Label("需要健康数据权限", systemImage: "heart.text.square")
                    } description: {
                        Text("无法读取健康数据。请在“设置”中允许此 App 读取体能训练数据。")
                    } actions: {
                        Button("重试") {
                            Task { await store.load() }
                        }
                        .buttonStyle(.borderedProminent)
                    }
                case .loaded where store.runs.isEmpty:
                    ContentUnavailableView(
                        "没有户外跑步数据",
                        systemImage: "figure.run",
                        description: Text("Apple 健康中暂时没有可分析的户外跑步体能训练。")
                    )
                case .loaded:
                    OutdoorRunAnalyticsView(runs: store.runs)
                }
            }
        }
        .task { await store.load() }
    }
}
