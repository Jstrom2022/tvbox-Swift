import SwiftUI

/// 设置页 - 对应 Android 版 SettingActivity + ModelSettingFragment
struct SettingsView: View {
    enum ApiInputType {
        case vod
        case live
        
        var title: String {
            switch self {
            case .vod: return "点播接口地址"
            case .live: return "直播接口地址"
            }
        }
        
        var placeholder: String {
            switch self {
            case .vod: return "请输入点播接口地址"
            case .live: return "请输入直播接口地址（可留空跟随点播）"
            }
        }
    }
    
    @StateObject private var viewModel = SettingsViewModel()
    @StateObject private var apiConfig = ApiConfig.shared
    @ObservedObject private var subscriptionStore = VodSubscriptionStore.shared
    /// 点播 m3u8 去广告开关（默认开启，与 HLSAdFilter.isEnabled 同一个 key）
    @AppStorage(HLSAdFilter.enabledKey) private var adFilterEnabled = true
    @EnvironmentObject var appState: AppState
    @State private var showApiInput = false
    @State private var editingApiType: ApiInputType = .vod
    @State private var showAbout = false
    @State private var sourceSearchText = ""
    @State private var showingPicker: PickerType = .none
    
    enum PickerType {
        case none
        case vodPlayer
        case livePlayer
        case decode
        case vlcBuffer
        case playTimeStep
    }
    
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 24) {
                    // API 配置
                    SectionCard(title: "数据源") {
                        NavigationLink {
                            VodSubscriptionListView(onSwitched: viewModel.syncSavedUrls)
                        } label: {
                            SettingsRow(
                                icon: "film",
                                title: "点播订阅",
                                value: subscriptionSummary,
                                action: nil
                            )
                        }
                        Divider().background(Color.white.opacity(0.1))
                        SettingsRow(
                            icon: "tv",
                            title: "直播接口地址",
                            value: viewModel.liveApiUrl.isEmpty ? "跟随点播接口" : viewModel.liveApiUrl
                        ) {
                            editingApiType = .live
                            showApiInput = true
                        }
                        Divider().background(Color.white.opacity(0.1))
                        if !apiConfig.sourceBeanList.isEmpty {
                            NavigationLink {
                                sourcePickerView
                            } label: {
                                SettingsRow(icon: "server.rack", title: "主页数据源", value: apiConfig.homeSourceBean?.name ?? "", action: nil)
                            }
                        }
                    }
                    
                    // 播放设置
                    SectionCard(title: "播放设置") {
                        SettingsRow(icon: "play.rectangle", title: "点播播放器", value: viewModel.vodPlayerEngine.title) {
                            if viewModel.playerEngineOptions.count > 1 {
                                showingPicker = .vodPlayer
                            }
                        }
                        Divider().background(Color.white.opacity(0.1))
                        SettingsRow(icon: "dot.radiowaves.left.and.right", title: "直播播放器", value: viewModel.livePlayerEngine.title) {
                            if viewModel.playerEngineOptions.count > 1 {
                                showingPicker = .livePlayer
                            }
                        }
                        Divider().background(Color.white.opacity(0.1))
                        SettingsRow(icon: "cpu", title: "视频解码", value: viewModel.decodeMode.title) {
                            showingPicker = .decode
                        }
                        if PlayerEngine.isVLCAvailable {
                            Divider().background(Color.white.opacity(0.1))
                            SettingsRow(icon: "externaldrive.badge.wifi", title: "VLC缓冲", value: viewModel.vlcBufferMode.title) {
                                showingPicker = .vlcBuffer
                            }
                        }
                        Divider().background(Color.white.opacity(0.1))
                        SettingsRow(icon: "forward", title: "快进步长", value: "\(viewModel.playTimeStep)秒") {
                            showingPicker = .playTimeStep
                        }
                        Divider().background(Color.white.opacity(0.1))
                        SettingsRow(icon: "shield.checkered", title: "广告过滤", value: adFilterEnabled ? "开启" : "关闭") {
                            adFilterEnabled.toggle()
                        }
                    }
                    
                    // 功能
                    SectionCard(title: "功能") {
                        NavigationLink {
                            HistoryView()
                        } label: {
                            SettingsRow(icon: "clock", title: "播放历史", value: "", action: nil)
                        }
                        Divider().background(Color.white.opacity(0.1))
                        NavigationLink {
                            FavoritesView()
                        } label: {
                            SettingsRow(icon: "heart", title: "我的收藏", value: "", action: nil)
                        }
                    }
                    
                    // 缓存
                    SectionCard(title: "缓存") {
                        SettingsRow(icon: "trash", title: "清除缓存", value: viewModel.cacheSizeString) {
                            viewModel.clearCache()
                        }
                    }
                    
                    // 关于
                    SectionCard(title: "关于") {
                        SettingsRow(icon: "info.circle", title: "版本", value: appVersionText, action: nil)
                        Divider().background(Color.white.opacity(0.1))
                        SettingsRow(icon: "globe", title: "站点数量", value: "\(apiConfig.sourceBeanList.count)", action: nil)
                        Divider().background(Color.white.opacity(0.1))
                        SettingsRow(icon: "wand.and.stars", title: "解析数量", value: "\(apiConfig.parseBeanList.count)", action: nil)
                        Divider().background(Color.white.opacity(0.1))
                        SettingsRow(icon: "tv", title: "直播分组", value: "\(apiConfig.liveChannelGroupList.count)", action: nil)
                    }
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 24)
            }
            .background(AppTheme.primaryGradient.ignoresSafeArea())
            .navigationTitle("设置")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            .toolbarColorScheme(.dark, for: .navigationBar)
            .toolbarBackground(.hidden, for: .navigationBar)
            #endif
            .onAppear {
                viewModel.syncSavedUrls()
            }
            .sheet(isPresented: $showApiInput) {
                apiInputSheet
            }
        }
        .overlay(pickerOverlay)
    }
    
    // MARK: - 选择器 Overlay
    
    @ViewBuilder
    private var pickerOverlay: some View {
        switch showingPicker {
        case .vodPlayer:
            SelectionModal(
                title: "选择点播播放器",
                icon: "play.rectangle.fill",
                items: viewModel.playerEngineOptions,
                selectedItem: viewModel.vodPlayerEngine,
                itemTitle: { $0.title },
                onSelect: { engine in
                    viewModel.setVodPlayerEngine(engine)
                    showingPicker = .none
                },
                onCancel: { showingPicker = .none }
            )
        case .livePlayer:
            SelectionModal(
                title: "选择直播播放器",
                icon: "dot.radiowaves.left.and.right",
                items: viewModel.playerEngineOptions,
                selectedItem: viewModel.livePlayerEngine,
                itemTitle: { $0.title },
                onSelect: { engine in
                    viewModel.setLivePlayerEngine(engine)
                    showingPicker = .none
                },
                onCancel: { showingPicker = .none }
            )
        case .decode:
            SelectionModal(
                title: "视频解码模式",
                icon: "cpu.fill",
                items: viewModel.decodeModeOptions,
                selectedItem: viewModel.decodeMode,
                itemTitle: { $0.title },
                onSelect: { mode in
                    viewModel.setDecodeMode(mode)
                    showingPicker = .none
                },
                onCancel: { showingPicker = .none }
            )
        case .vlcBuffer:
            SelectionModal(
                title: "VLC 缓冲策略",
                icon: "externaldrive.fill",
                items: viewModel.vlcBufferModeOptions,
                selectedItem: viewModel.vlcBufferMode,
                itemTitle: { $0.title },
                onSelect: { mode in
                    viewModel.setVLCBufferMode(mode)
                    showingPicker = .none
                },
                onCancel: { showingPicker = .none }
            )
        case .playTimeStep:
            SelectionModal(
                title: "快进步长",
                icon: "forward.fill",
                items: viewModel.playTimeStepOptions,
                selectedItem: viewModel.playTimeStep,
                itemTitle: { "\($0) 秒" },
                onSelect: { step in
                    viewModel.setPlayTimeStep(step)
                    showingPicker = .none
                },
                onCancel: { showingPicker = .none }
            )
        case .none:
            EmptyView()
        }
    }
    
    // MARK: - API 输入弹窗
    
    private var apiInputSheet: some View {
        NavigationStack {
            VStack(spacing: 16) {
                HStack {
                    Image(systemName: "link")
                        .foregroundColor(.secondary)
                    TextField(editingApiType.placeholder, text: currentApiBinding)
                        .textFieldStyle(.plain)
                        #if os(iOS)
                        .autocapitalization(.none)
                        .keyboardType(.URL)
                        #endif
                }
                .padding()
                .background(Color.secondary.opacity(0.1))
                .cornerRadius(10)
                
                // 粘贴按钮
                HStack {
                    Button {
                        if let text = readPasteboardText() {
                            currentApiBinding.wrappedValue = text
                        }
                    } label: {
                        Label("粘贴", systemImage: "doc.on.clipboard")
                            .font(.subheadline)
                    }
                    
                    Spacer()
                }
                
                // 历史记录
                if !viewModel.apiHistory.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("历史记录")
                            .font(.caption)
                            .foregroundColor(.secondary)
                        
                        ForEach(viewModel.apiHistory, id: \.self) { url in
                            HStack {
                                Button {
                                    currentApiBinding.wrappedValue = url
                                } label: {
                                    HStack {
                                        Image(systemName: "clock")
                                            .font(.caption)
                                        Text(url)
                                            .font(.caption)
                                            .lineLimit(1)
                                    }
                                    .foregroundColor(.secondary)
                                }
                                
                                Spacer()
                                
                                Button {
                                    viewModel.removeApiHistory(url)
                                } label: {
                                    Image(systemName: "xmark.circle")
                                        .font(.caption)
                                        .foregroundColor(.gray)
                                }
                            }
                        }
                    }
                }
                
                if let error = viewModel.configError {
                    Text(error)
                        .font(.caption)
                        .foregroundColor(.red)
                }
                
                Spacer()
            }
            .padding()
            .navigationTitle(editingApiType.title)
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { showApiInput = false }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button {
                        Task {
                            await viewModel.loadConfig()
                            if viewModel.configSuccess {
                                appState.applyLoadedConfigState()
                                showApiInput = false
                            }
                        }
                    } label: {
                        if viewModel.isLoadingConfig {
                            ProgressView()
                        } else {
                            Text("确认")
                        }
                    }
                    .disabled(
                        viewModel.isLoadingConfig
                        || viewModel.vodApiUrl.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    )
                }
            }
        }
        .overlay(multiRepoSelectionOverlay)
        #if os(iOS)
        .presentationDetents([.medium, .large])
        #endif
    }
    
    @ViewBuilder
    private var multiRepoSelectionOverlay: some View {
        if let pending = viewModel.pendingMultiRepoSelection {
            SelectionModal(
                title: "选择\(pending.target.title)仓库",
                icon: "list.bullet.rectangle.portrait.fill",
                items: pending.options,
                selectedItem: nil,
                itemTitle: { $0.name },
                onSelect: { option in
                    Task {
                        await viewModel.selectPendingMultiRepoOption(option)
                        if viewModel.configSuccess {
                            appState.applyLoadedConfigState()
                            showApiInput = false
                        }
                    }
                },
                onCancel: {
                    viewModel.cancelPendingMultiRepoSelection()
                }
            )
        }
    }
    
    private var currentApiBinding: Binding<String> {
        switch editingApiType {
        case .vod:
            return $viewModel.vodApiUrl
        case .live:
            return $viewModel.liveApiUrl
        }
    }
    
    private func readPasteboardText() -> String? {
        #if os(iOS)
        UIPasteboard.general.string
        #else
        NSPasteboard.general.string(forType: .string)
        #endif
    }

    /// 「点播订阅」行右侧摘要：当前订阅名 + 总数。
    private var subscriptionSummary: String {
        let count = subscriptionStore.subscriptions.count
        guard count > 0 else { return "未配置" }
        let name = subscriptionStore.active?.name ?? "未选择"
        return count > 1 ? "\(name)（共\(count)个）" : name
    }

    // MARK: - 源选择
    
    private var filteredSources: [SourceBean] {
        let sources = apiConfig.sourceBeanList
        if sourceSearchText.isEmpty {
            return sources
        } else {
            return sources.filter { $0.name.localizedCaseInsensitiveContains(sourceSearchText) || $0.api.localizedCaseInsensitiveContains(sourceSearchText) }
        }
    }

    private var sourcePickerView: some View {
        VStack(spacing: 0) {
            // 搜索栏
            HStack {
                Image(systemName: "magnifyingglass")
                    .foregroundColor(.secondary)
                TextField("搜索数据源", text: $sourceSearchText)
                    .textFieldStyle(.plain)
                if !sourceSearchText.isEmpty {
                    Button(action: { sourceSearchText = "" }) {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundColor(.secondary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(12)
            .glassCard(cornerRadius: 12)
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
            
            ScrollView {
                LazyVStack(spacing: 12) {
                    ForEach(filteredSources) { source in
                        Button {
                            apiConfig.setHomeSource(source)
                            appState.currentSourceKey = source.key
                        } label: {
                            HStack(alignment: .center, spacing: 16) {
                                VStack(alignment: .leading, spacing: 8) {
                                    HStack(spacing: 8) {
                                        Text(source.name)
                                            .font(.system(size: 16, weight: .semibold))
                                            .foregroundColor(source.isSupportedInSwift ? .white : .white.opacity(0.5))
                                        
                                        // 类型标签
                                        Text(source.typeDescription)
                                            .font(.system(size: 10, weight: .bold))
                                            .foregroundColor(source.isSupportedInSwift ? .orange : .gray)
                                            .padding(.horizontal, 6)
                                            .padding(.vertical, 3)
                                            .background(
                                                Capsule().fill(
                                                    source.isSupportedInSwift ? Color.orange.opacity(0.2) : Color.gray.opacity(0.2)
                                                )
                                            )
                                        
                                        if !source.isSupportedInSwift {
                                            Text("暂不支持")
                                                .font(.system(size: 10, weight: .medium))
                                                .foregroundColor(.red.opacity(0.8))
                                                .padding(.horizontal, 6)
                                                .padding(.vertical, 3)
                                                .background(Capsule().fill(Color.red.opacity(0.15)))
                                        }
                                    }
                                    
                                    Text(source.api)
                                        .font(.system(size: 12))
                                        .foregroundColor(.white.opacity(0.5))
                                        .lineLimit(1)
                                }
                                
                                Spacer()
                                
                                HStack(spacing: 12) {
                                    if source.isSearchable {
                                        Image(systemName: "magnifyingglass")
                                            .font(.system(size: 14, weight: .medium))
                                            .foregroundColor(.green.opacity(0.8))
                                    }
                                    
                                    if source.key == apiConfig.homeSourceBean?.key {
                                        Image(systemName: "checkmark.circle.fill")
                                            .font(.system(size: 20))
                                            .foregroundColor(.orange)
                                    } else {
                                        Circle()
                                            .strokeBorder(Color.white.opacity(0.2), lineWidth: 1)
                                            .frame(width: 20, height: 20)
                                    }
                                }
                            }
                            .padding(16)
                            .glassCard(cornerRadius: 16)
                            .overlay(
                                RoundedRectangle(cornerRadius: 16)
                                    .stroke(
                                        source.key == apiConfig.homeSourceBean?.key ? Color.orange.opacity(0.5) : Color.clear,
                                        lineWidth: 1
                                    )
                            )
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 24)
            }
        }
        .background(AppTheme.primaryGradient.ignoresSafeArea())
        .navigationTitle("选择数据源")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
    }
}

// MARK: - 辅助组件

struct SectionCard<Content: View>: View {
    let title: String
    @ViewBuilder let content: () -> Content
    
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title)
                .font(.subheadline)
                .fontWeight(.bold)
                .foregroundColor(.white.opacity(0.6))
                .padding(.leading, 8)
            
            VStack(spacing: 0) {
                content()
            }
            .glassCard(cornerRadius: 16)
        }
    }
}

/// 当前 App 版本，形如 "1.0.4 (12)"（版本号 + 构建号）。
private var appVersionText: String {
    let info = Bundle.main.infoDictionary
    let version = info?["CFBundleShortVersionString"] as? String ?? "-"
    let build = info?["CFBundleVersion"] as? String ?? ""
    return build.isEmpty ? version : "\(version) (\(build))"
}

struct SettingsRow: View {
    let icon: String
    let title: String
    let value: String
    let action: (() -> Void)?
    
    var body: some View {
        Group {
            if let action = action {
                Button(action: action) {
                    rowContent
                }
                .buttonStyle(.plain)
            } else {
                rowContent
            }
        }
    }
    
    private var rowContent: some View {
        HStack(spacing: 16) {
            Image(systemName: icon)
                .font(.system(size: 16))
                .foregroundColor(.orange)
                .frame(width: 24)
            
            Text(title)
                .font(.body)
                .foregroundColor(.white.opacity(0.9))
            
            Spacer()
            
            Text(value)
                .font(.subheadline)
                .foregroundColor(.white.opacity(0.5))
                .lineLimit(1)
            
            Image(systemName: "chevron.right")
                .font(.system(size: 12, weight: .bold))
                .foregroundColor(.white.opacity(0.3))
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .contentShape(Rectangle())
    }
}

// MARK: - 点播订阅管理

/// 点播订阅列表：切换 / 添加 / 改名 / 删除多个点播配置地址。
struct VodSubscriptionListView: View {
    /// 切换成功后的回调（设置页据此同步输入框里的地址）。
    var onSwitched: (() -> Void)? = nil

    @ObservedObject private var store = VodSubscriptionStore.shared
    @EnvironmentObject var appState: AppState

    @State private var showAddSheet = false
    @State private var newName = ""
    @State private var newUrl = ""
    @State private var isAdding = false
    @State private var addError: String?
    @State private var renaming: VodSubscription?
    @State private var renameText = ""
    @State private var pendingDelete: VodSubscription?

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                if let error = store.lastError {
                    Text(error)
                        .font(.caption)
                        .foregroundColor(.red)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 8)
                }

                if store.subscriptions.isEmpty {
                    VStack(spacing: 12) {
                        Image(systemName: "tray")
                            .font(.largeTitle)
                            .foregroundColor(.gray)
                        Text("还没有点播订阅，点右上角「添加」")
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                    }
                    .padding(.top, 60)
                } else {
                    VStack(spacing: 0) {
                        ForEach(Array(store.subscriptions.enumerated()), id: \.element.id) { index, subscription in
                            if index > 0 {
                                Divider().background(Color.white.opacity(0.1))
                            }
                            subscriptionRow(subscription)
                        }
                    }
                    .glassCard(cornerRadius: 16)

                    Text("点一行即切换到该订阅；多仓库地址添加后会自动展开为多条。")
                        .font(.caption)
                        .foregroundColor(.white.opacity(0.4))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 8)
                }
            }
            .padding(20)
        }
        .background(AppTheme.primaryGradient.ignoresSafeArea())
        .navigationTitle("点播订阅")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    newName = ""
                    newUrl = ""
                    addError = nil
                    showAddSheet = true
                } label: {
                    Label("添加", systemImage: "plus")
                }
            }
        }
        .sheet(isPresented: $showAddSheet) {
            addSheet
        }
        .alert("重命名订阅", isPresented: Binding(
            get: { renaming != nil },
            set: { if !$0 { renaming = nil } }
        )) {
            TextField("名称", text: $renameText)
            Button("取消", role: .cancel) { renaming = nil }
            Button("保存") {
                if let target = renaming {
                    store.rename(target, to: renameText)
                }
                renaming = nil
            }
        }
        .confirmationDialog(
            "删除订阅「\(pendingDelete?.name ?? "")」？",
            isPresented: Binding(
                get: { pendingDelete != nil },
                set: { if !$0 { pendingDelete = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("删除", role: .destructive) {
                if let target = pendingDelete {
                    store.remove(target)
                }
                pendingDelete = nil
            }
            Button("取消", role: .cancel) { pendingDelete = nil }
        } message: {
            Text("只从列表移除，不影响当前已加载的内容。")
        }
    }

    private func subscriptionRow(_ subscription: VodSubscription) -> some View {
        let isActive = store.isActive(subscription)
        return HStack(spacing: 12) {
            Button {
                switchTo(subscription)
            } label: {
                HStack(spacing: 12) {
                    Group {
                        if store.switchingId == subscription.id {
                            ProgressView().controlSize(.small)
                        } else {
                            Image(systemName: isActive ? "checkmark.circle.fill" : "circle")
                                .foregroundColor(isActive ? .orange : .white.opacity(0.3))
                        }
                    }
                    .frame(width: 22)

                    VStack(alignment: .leading, spacing: 4) {
                        Text(subscription.name)
                            .font(.body.weight(isActive ? .semibold : .regular))
                            .foregroundColor(.white)
                            .lineLimit(1)
                        Text(subscription.url)
                            .font(.caption)
                            .foregroundColor(.white.opacity(0.45))
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(store.switchingId != nil)

            Menu {
                Button {
                    renameText = subscription.name
                    renaming = subscription
                } label: {
                    Label("重命名", systemImage: "pencil")
                }
                Button {
                    copyToPasteboard(subscription.url)
                } label: {
                    Label("复制地址", systemImage: "doc.on.doc")
                }
                Button(role: .destructive) {
                    pendingDelete = subscription
                } label: {
                    Label("删除", systemImage: "trash")
                }
            } label: {
                Image(systemName: "ellipsis.circle")
                    .foregroundColor(.white.opacity(0.6))
                    .frame(width: 28, height: 28)
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    /// 最近输入过、但还不在订阅列表里的地址，方便一键加入。
    private var historyCandidates: [String] {
        let saved = Set(store.subscriptions.map { ApiConfig.normalizeConfigUrl($0.url) })
        return (UserDefaults.standard.stringArray(forKey: "api_history") ?? [])
            .filter { !saved.contains(ApiConfig.normalizeConfigUrl($0)) }
    }

    private var addSheet: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 16) {
                TextField("名称（可留空，默认用域名）", text: $newName)
                    .textFieldStyle(.plain)
                    .padding()
                    .background(Color.secondary.opacity(0.1))
                    .cornerRadius(10)

                HStack {
                    Image(systemName: "link").foregroundColor(.secondary)
                    TextField("点播接口地址（支持多仓库地址）", text: $newUrl)
                        .textFieldStyle(.plain)
                        #if os(iOS)
                        .autocapitalization(.none)
                        .keyboardType(.URL)
                        #endif
                    Button {
                        if let text = readPasteboard() { newUrl = text }
                    } label: {
                        Image(systemName: "doc.on.clipboard")
                    }
                    .buttonStyle(.plain)
                }
                .padding()
                .background(Color.secondary.opacity(0.1))
                .cornerRadius(10)

                if !historyCandidates.isEmpty {
                    Text("最近使用过的地址")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    ForEach(historyCandidates, id: \.self) { url in
                        Button {
                            newUrl = url
                        } label: {
                            HStack {
                                Image(systemName: "clock").font(.caption)
                                Text(url).font(.caption).lineLimit(1)
                            }
                            .foregroundColor(.secondary)
                        }
                        .buttonStyle(.plain)
                    }
                }

                if let addError {
                    Text(addError).font(.caption).foregroundColor(.red)
                }
                Spacer()
            }
            .padding()
            .navigationTitle("添加点播订阅")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { showAddSheet = false }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button {
                        Task { await addAndSwitch() }
                    } label: {
                        if isAdding { ProgressView() } else { Text("添加并切换") }
                    }
                    .disabled(isAdding || newUrl.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
        #if os(macOS)
        .frame(minWidth: 460, minHeight: 320)
        #endif
    }

    private func addAndSwitch() async {
        isAdding = true
        addError = nil
        defer { isAdding = false }
        do {
            let added = try await store.add(url: newUrl, name: newName)
            guard let first = added.first else { return }
            if await store.activate(first, appState: appState) {
                onSwitched?()
                showAddSheet = false
            } else {
                // 地址已加入列表，但加载失败：留在弹窗里提示，可改地址重试或直接取消
                addError = store.lastError
            }
        } catch {
            addError = error.localizedDescription
        }
    }

    private func switchTo(_ subscription: VodSubscription) {
        guard !store.isActive(subscription) else { return }
        Task {
            if await store.activate(subscription, appState: appState) {
                onSwitched?()
            }
        }
    }

    private func readPasteboard() -> String? {
        #if os(iOS)
        UIPasteboard.general.string
        #else
        NSPasteboard.general.string(forType: .string)
        #endif
    }

    private func copyToPasteboard(_ text: String) {
        #if os(iOS)
        UIPasteboard.general.string = text
        #else
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        #endif
    }
}
