import Foundation
import SwiftUI
import Combine

/// 直播 ViewModel
@MainActor
class LiveViewModel: ObservableObject {
    /// 全部频道分组。
    @Published var channelGroups: [LiveChannelGroup] = []
    /// 当前选中分组索引。
    @Published var selectedGroupIndex: Int = 0
    /// 当前选中频道索引（相对于当前分组）。
    @Published private(set) var selectedChannelIndex: Int = 0
    /// 当前播放频道。
    @Published private(set) var currentChannel: LiveChannelItem?
    /// 当前频道节目单（预留）。
    @Published var epgList: [Epginfo] = []
    /// 直播列表是否仍在加载。
    @Published private(set) var isLoading = false
    /// 部分直播列表加载失败的说明。
    @Published private(set) var loadFailures: [String] = []
    /// 是否显示频道列表（预留给 TV 遥控交互）。
    @Published var showChannelList = false

    /// 订阅配置更新，支持直播频道列表实时刷新。
    private var cancellables: Set<AnyCancellable> = []

    init() {
        bindLiveChannelGroups()
    }

    /// 加载直播频道
    func loadChannels() {
        applyChannelGroups(ApiConfig.shared.liveChannelGroupList)
    }

    /// 重新加载直播列表（部分或全部失败后的重试入口）。
    func reloadChannels() {
        ApiConfig.shared.reloadLiveChannels()
    }

    /// 选择频道分组
    func selectGroup(_ index: Int) {
        guard index >= 0, index < channelGroups.count else { return }
        selectedGroupIndex = index
        if let first = channelGroups[index].channels.first {
            selectChannel(first)
        } else {
            selectedChannelIndex = 0
        }
    }

    /// 选择频道：根据频道身份同步分组与频道索引，避免视图层各自维护部分选中状态。
    func selectChannel(_ channel: LiveChannelItem) {
        if let located = locateChannel(withId: channel.id, in: channelGroups) {
            selectedGroupIndex = located.groupIndex
            selectedChannelIndex = located.channelIndex
            currentChannel = channelGroups[located.groupIndex].channels[located.channelIndex]
        } else {
            currentChannel = channel
        }
        loadEPG(for: channel)
    }

    /// 上一个频道
    func previousChannel() {
        guard !channelGroups.isEmpty else { return }
        syncSelectionWithCurrentChannel()
        var groupIndex = min(max(selectedGroupIndex, 0), channelGroups.count - 1)
        var channelIndex = selectedChannelIndex - 1

        // 向前跳过空分组；已经是第一台时保持不变。
        while channelIndex < 0 {
            guard groupIndex > 0 else { return }
            groupIndex -= 1
            channelIndex = channelGroups[groupIndex].channels.count - 1
        }

        if let channel = channelGroups[groupIndex].channels[safe: channelIndex] {
            selectChannel(channel)
        }
    }

    /// 下一个频道
    func nextChannel() {
        guard !channelGroups.isEmpty else { return }
        syncSelectionWithCurrentChannel()
        var groupIndex = min(max(selectedGroupIndex, 0), channelGroups.count - 1)
        var channelIndex = selectedChannelIndex + 1

        // 向后跳过空分组；已经是最后一台时保持不变。
        while channelIndex >= channelGroups[groupIndex].channels.count {
            guard groupIndex < channelGroups.count - 1 else { return }
            groupIndex += 1
            channelIndex = 0
        }

        if let channel = channelGroups[groupIndex].channels[safe: channelIndex] {
            selectChannel(channel)
        }
    }

    /// 切换线路
    func switchSource() {
        // `currentChannel` 为值类型，调用 mutating 方法会触发 @Published 重新发布。
        currentChannel?.nextSource()
    }

    /// 当前频道列表
    var currentChannels: [LiveChannelItem] {
        guard selectedGroupIndex < channelGroups.count else { return [] }
        return channelGroups[selectedGroupIndex].channels
    }

    /// 加载 EPG 节目单
    private func loadEPG(for channel: LiveChannelItem) {
        // 预留：后续可在此按频道名/频道 ID 请求远程 EPG。
        // 当前版本先清空，避免展示过期节目单。
        epgList = []
    }

    private func bindLiveChannelGroups() {
        ApiConfig.shared.$liveChannelGroupList
            .sink { [weak self] groups in
                self?.applyChannelGroups(groups)
            }
            .store(in: &cancellables)
        ApiConfig.shared.$isLoadingLives
            .sink { [weak self] loading in
                self?.isLoading = loading
            }
            .store(in: &cancellables)
        ApiConfig.shared.$liveLoadFailures
            .sink { [weak self] failures in
                self?.loadFailures = failures
            }
            .store(in: &cancellables)
    }

    /// 应用新的频道列表：按完整身份（分组 + 频道名）恢复用户选择，
    /// 并在当前线路仍然存在时保留它，避免刷新或增量加入列表时跳台、跳回已失败的线路。
    func applyChannelGroups(_ groups: [LiveChannelGroup]) {
        let previousChannel = currentChannel
        channelGroups = groups

        guard !groups.isEmpty else {
            selectedGroupIndex = 0
            selectedChannelIndex = 0
            currentChannel = nil
            return
        }

        if let previousChannel,
           let located = locateChannel(withId: previousChannel.id, in: groups) {
            selectedGroupIndex = located.groupIndex
            selectedChannelIndex = located.channelIndex
            var refreshed = groups[located.groupIndex].channels[located.channelIndex]
            if let previousURL = previousChannel.currentUrl,
               let preservedIndex = refreshed.channelUrls.firstIndex(of: previousURL) {
                refreshed.sourceIndex = preservedIndex
            }
            currentChannel = refreshed
            return
        }

        let clampedGroupIndex = min(max(0, selectedGroupIndex), groups.count - 1)
        selectedGroupIndex = clampedGroupIndex

        let channels = groups[clampedGroupIndex].channels
        guard !channels.isEmpty else {
            selectedChannelIndex = 0
            currentChannel = nil
            return
        }

        let clampedChannelIndex = min(max(0, selectedChannelIndex), channels.count - 1)
        selectedChannelIndex = clampedChannelIndex
        currentChannel = channels[clampedChannelIndex]
    }

    /// 以当前频道身份校准索引（频道列表在外部被替换后索引可能已失效）。
    private func syncSelectionWithCurrentChannel() {
        guard let currentChannel,
              let located = locateChannel(withId: currentChannel.id, in: channelGroups) else { return }
        selectedGroupIndex = located.groupIndex
        selectedChannelIndex = located.channelIndex
    }

    private func locateChannel(
        withId channelId: LiveChannelItem.Identity,
        in groups: [LiveChannelGroup]
    ) -> (groupIndex: Int, channelIndex: Int)? {
        for (groupIndex, group) in groups.enumerated() {
            if let channelIndex = group.channels.firstIndex(where: { $0.id == channelId }) {
                return (groupIndex, channelIndex)
            }
        }
        return nil
    }
}

// 安全数组下标访问
extension Collection {
    /// 安全下标读取，越界时返回 `nil`。
    subscript(safe index: Index) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
