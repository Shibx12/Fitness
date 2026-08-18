import SwiftUI

struct RootView: View {
    @EnvironmentObject private var store: HealthDataStore

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                if store.dataFreshness == .stale, !store.runs.isEmpty {
                    staleDataBanner
                }

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
                            Task { await store.refresh() }
                        }
                        .buttonStyle(.borderedProminent)
                    }
                case .loaded where store.runs.isEmpty:
                    ContentUnavailableView {
                        Label("没有户外跑步数据", systemImage: "figure.run")
                    } description: {
                        Text("Apple 健康中暂时没有可分析的户外跑步体能训练。")
                    } actions: {
                        Button {
                            Task { await store.refresh() }
                        } label: {
                            if store.isRefreshing {
                                ProgressView()
                            } else {
                                Label("刷新", systemImage: "arrow.clockwise")
                            }
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(store.isRefreshing)
                        .accessibilityLabel(
                            store.isRefreshing ? "正在刷新跑步数据" : "刷新跑步数据"
                        )
                    }
                case .loaded:
                    OutdoorRunAnalyticsView(runs: store.runs)
                }
            }
        }
        .task { await store.load() }
    }

    private var staleDataBanner: some View {
        HStack(spacing: 10) {
            Image(systemName: "exclamationmark.arrow.trianglehead.2.clockwise.rotate.90")
                .foregroundStyle(.orange)
            Text("显示的是上次成功同步的数据。")
                .font(.footnote)
                .frame(maxWidth: .infinity, alignment: .leading)
            Button("重试") {
                Task { await store.refresh() }
            }
            .font(.footnote.weight(.semibold))
            .disabled(store.isRefreshing)
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
        .background(Color.orange.opacity(0.12))
    }
}
