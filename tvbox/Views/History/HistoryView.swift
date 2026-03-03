import SwiftUI
import SwiftData

/// 历史记录页 - 对应 Android 版 HistoryActivity
struct HistoryView: View {
    /// 按最近播放时间倒序展示历史记录。
    @Query(sort: \VodRecord.updateTime, order: .reverse)
    private var records: [VodRecord]
    /// SwiftData 上下文，用于删除单条记录或清空历史。
    @Environment(\.modelContext) private var modelContext
    
    #if os(iOS)
    /// iOS 网格配置。
    private let columns = [
        GridItem(.adaptive(minimum: 120, maximum: 160), spacing: 12)
    ]
    #else
    /// macOS 网格配置。
    private let columns = [
        GridItem(.adaptive(minimum: 140, maximum: 180), spacing: 16)
    ]
    #endif
    
    var body: some View {
        NavigationStack {
            Group {
                if records.isEmpty {
                    emptyState
                } else {
                    ScrollView {
                        LazyVGrid(columns: columns, spacing: 16) {
                            // 记录卡片支持跳转详情与右键删除。
                            ForEach(records) { item in
                                NavigationLink(value: movieVideo(from: item)) {
                                    recordCard(item)
                                }
                                .buttonStyle(.plain)
                                .contextMenu {
                                    Button(role: .destructive) {
                                        modelContext.delete(item)
                                        do {
                                            try modelContext.save()
                                        } catch {
                                            print("删除历史记录失败: \(error)")
                                        }
                                    } label: {
                                        Label("删除记录", systemImage: "trash")
                                    }
                                }
                            }
                        }
                        .padding(.horizontal, 20)
                        .padding(.vertical, 12)
                    }
                }
            }
            .background(Color(red: 0.08, green: 0.08, blue: 0.1))
            .navigationTitle("历史记录")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                if !records.isEmpty {
                    ToolbarItem(placement: .automatic) {
                        // 清空历史使用统一缓存服务，确保行为与其他入口一致。
                        Button {
                            Task {
                                CacheStore.shared.clearHistory(context: modelContext)
                            }
                        } label: {
                            Text("清空")
                                .foregroundColor(.orange)
                        }
                    }
                }
            }
            // 与首页/搜索/收藏共用同一种详情路由模型。
            .navigationDestination(for: Movie.Video.self) { video in
                DetailView(video: video)
            }
        }
    }
    
    /// 无历史时的占位视图。
    private var emptyState: some View {
        EmptyStateView(
            icon: "clock.arrow.circlepath",
            title: "暂无播放记录",
            message: "您还没有看任何视频，赶快去首页探索吧！"
        )
        .padding(40)
    }
    
    /// 历史卡片。
    /// 除海报和标题外，额外显示播放进度与更新时间，便于快速续播。
    private func recordCard(_ item: VodRecord) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            ZStack(alignment: .bottomLeading) {
                CachedAsyncImage(url: URL.posterURL(from: item.vodPic)) { image in
                    image.resizable().aspectRatio(2/3, contentMode: .fill)
                } placeholder: {
                    Rectangle().fill(Color.gray.opacity(0.3))
                        .aspectRatio(2/3, contentMode: .fill)
                        .overlay(Image(systemName: "film").foregroundColor(.gray))
                }
                .clipShape(RoundedRectangle(cornerRadius: 8))
                
                // 播放进度标签
                if !item.playNote.isEmpty {
                    Text(item.playNote)
                        .font(.system(size: 9))
                        .foregroundColor(.white)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 3)
                        .background(Color.black.opacity(0.7))
                        .cornerRadius(4)
                        .padding(4)
                }
            }
            
            Text(item.vodName)
                .font(.caption)
                .foregroundColor(.white)
                .lineLimit(2)
            
            Text(item.updateTime.displayString)
                .font(.system(size: 10))
                .foregroundColor(.gray)
        }
    }
    
    /// 将历史记录转换为详情页的入参模型。
    private func movieVideo(from item: VodRecord) -> Movie.Video {
        Movie.Video(id: item.vodId, name: item.vodName, pic: item.vodPic, sourceKey: item.sourceKey)
    }
}
