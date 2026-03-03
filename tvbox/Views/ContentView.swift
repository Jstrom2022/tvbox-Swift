import SwiftUI

/// 根视图 - 对应 Android 版 HomeActivity 的 TabView 导航
struct ContentView: View {
    /// 首次配置页点击“最近使用”时，当前要写入的输入框目标。
    private enum ApiInputTarget {
        case vod
        case live
    }
    
    /// 全局状态（配置加载、分栏状态等）。
    @EnvironmentObject var appState: AppState
    /// 设置页 ViewModel。根视图复用它处理首次配置与多仓库选择。
    @StateObject private var settingsVM = SettingsViewModel()
    /// 当前主标签索引。
    @State private var selectedTab = 0
    /// 预留：控制首次配置页显隐（当前逻辑由 `appState.isConfigLoaded` 驱动）。
    @State private var showSetup = false
    /// 首次配置页历史回填目标输入框。
    @State private var setupInputTarget: ApiInputTarget = .vod
    
    var body: some View {
        Group {
            if appState.isConfigLoaded {
                mainTabView
            } else {
                setupView
            }
        }
        .overlay(multiRepoSelectionOverlay)
        .preferredColorScheme(.dark)
        .onAppear {
            // 自动加载已保存的配置
            let defaults = UserDefaults.standard
            let savedVodUrl = defaults.string(forKey: HawkConfig.API_URL) ?? ""
            let savedLiveUrl = defaults.string(forKey: HawkConfig.LIVE_API_URL) ?? ""
            if !savedVodUrl.isEmpty {
                // 启动自动恢复配置，避免每次重启都回到首次配置页。
                Task {
                    await appState.loadConfig(vodUrl: savedVodUrl, liveUrl: savedLiveUrl)
                }
            }
        }
    }
    
    @ViewBuilder
    private var multiRepoSelectionOverlay: some View {
        // 若配置地址解析出“多仓库入口”，在根层统一弹窗，避免被子页面导航遮挡。
        if let pending = settingsVM.pendingMultiRepoSelection {
            SelectionModal(
                title: "选择\(pending.target.title)仓库",
                icon: "list.bullet.rectangle.portrait.fill",
                items: pending.options,
                selectedItem: nil,
                itemTitle: { $0.name },
                onSelect: { option in
                    Task {
                        await settingsVM.selectPendingMultiRepoOption(option)
                        if settingsVM.configSuccess {
                            appState.applyLoadedConfigState()
                        }
                    }
                },
                onCancel: {
                    settingsVM.cancelPendingMultiRepoSelection()
                }
            )
        }
    }
    
    // MARK: - 主界面
    
    /// 主体导航容器：iOS 使用 TabView，macOS 使用 NavigationSplitView。
    private var mainTabView: some View {
        #if os(iOS)
        TabView(selection: $selectedTab) {
            HomeView()
                .tabItem {
                    Label("首页", systemImage: "house.fill")
                }
                .tag(0)
            
            LiveView()
                .tabItem {
                    Label("直播", systemImage: "tv.fill")
                }
                .tag(1)
            
            SearchView()
                .tabItem {
                    Label("搜索", systemImage: "magnifyingglass")
                }
                .tag(2)
            
            FavoritesView()
                .tabItem {
                    Label("收藏", systemImage: "heart.fill")
                }
                .tag(3)
            
            SettingsView()
                .tabItem {
                    Label("设置", systemImage: "gearshape.fill")
                }
                .tag(4)
        }
        .tint(.orange)
        #else
        NavigationSplitView(columnVisibility: $appState.splitViewVisibility) {
            List(selection: $selectedTab) {
                Label("首页", systemImage: "house.fill")
                    .tag(0)
                Label("直播", systemImage: "tv.fill")
                    .tag(1)
                Label("搜索", systemImage: "magnifyingglass")
                    .tag(2)
                Label("收藏", systemImage: "heart.fill")
                    .tag(3)
                Label("历史", systemImage: "clock.fill")
                    .tag(5)
                Label("设置", systemImage: "gearshape.fill")
                    .tag(4)
            }
            .navigationTitle("TVBox")
            .listStyle(.sidebar)
        } detail: {
            switch selectedTab {
            case 0: HomeView()
            case 1: LiveView()
            case 2: SearchView()
            case 3: FavoritesView()
            case 4: SettingsView()
            case 5: HistoryView()
            default: HomeView()
            }
        }
        #endif
    }
    
    // MARK: - 首次配置页面
    
    /// 首次启动或未加载配置时的引导页面。
    private var setupView: some View {
        ZStack {
            // 背景装饰
            AppTheme.primaryGradient
                .ignoresSafeArea()
            
            // 装饰性光晕
            VStack {
                HStack {
                    Circle()
                        .fill(Color.orange.opacity(0.15))
                        .frame(width: 300, height: 300)
                        .blur(radius: 80)
                        .offset(x: -100, y: -100)
                    Spacer()
                }
                Spacer()
                HStack {
                    Spacer()
                    Circle()
                        .fill(Color.red.opacity(0.15))
                        .frame(width: 300, height: 300)
                        .blur(radius: 80)
                        .offset(x: 100, y: 100)
                }
            }
            .ignoresSafeArea()
            
            ScrollView {
                VStack(spacing: 32) {
                    // Logo 区域
                    VStack(spacing: 20) {
                        ZStack {
                            Circle()
                                .fill(AppTheme.accentGradient)
                                .frame(width: 100, height: 100)
                                .blur(radius: 20)
                                .opacity(0.5)
                            
                            Image(systemName: "play.tv.fill")
                                .font(.system(size: 80))
                                .foregroundStyle(
                                    AppTheme.accentGradient
                                )
                                .shadow(color: .red.opacity(0.3), radius: 15, x: 0, y: 10)
                        }
                        
                        VStack(spacing: 8) {
                            Text("TVBox")
                                .font(.system(size: 48, weight: .heavy, design: .rounded))
                                .foregroundColor(.white)
                                .tracking(2)
                            
                            Text("极致视听 · 简洁至上")
                                .font(.subheadline)
                                .foregroundColor(.white.opacity(0.6))
                                .tracking(4)
                        }
                    }
                    .padding(.top, 60)
                    
                    // 输入表单
                    VStack(spacing: 24) {
                        VStack(alignment: .leading, spacing: 12) {
                            Text("接口配置")
                                .font(.headline)
                                .foregroundColor(.white)
                                .padding(.leading, 4)
                            
                            HStack {
                                Image(systemName: "link")
                                    .foregroundColor(.orange)
                                TextField("请输入点播接口地址 (URL)", text: $settingsVM.vodApiUrl)
                                    .textFieldStyle(.plain)
                                    .foregroundColor(.white)
                                    .onTapGesture {
                                        setupInputTarget = .vod
                                    }
                                    #if os(iOS)
                                    .autocapitalization(.none)
                                    .keyboardType(.URL)
                                    #endif
                                
                                Button {
                                    if let text = readPasteboardText() {
                                        settingsVM.vodApiUrl = text
                                    }
                                } label: {
                                    Image(systemName: "doc.on.clipboard")
                                        .foregroundColor(.orange)
                                }
                                .buttonStyle(.plain)
                            }
                            .padding()
                            .glassCard(cornerRadius: 15)
                            
                            HStack {
                                Image(systemName: "tv")
                                    .foregroundColor(.orange)
                                TextField("请输入直播接口地址 (URL，可留空跟随点播)", text: $settingsVM.liveApiUrl)
                                    .textFieldStyle(.plain)
                                    .foregroundColor(.white)
                                    .onTapGesture {
                                        setupInputTarget = .live
                                    }
                                    #if os(iOS)
                                    .autocapitalization(.none)
                                    .keyboardType(.URL)
                                    #endif
                                
                                Button {
                                    if let text = readPasteboardText() {
                                        settingsVM.liveApiUrl = text
                                    }
                                } label: {
                                    Image(systemName: "doc.on.clipboard")
                                        .foregroundColor(.orange)
                                }
                                .buttonStyle(.plain)
                            }
                            .padding()
                            .glassCard(cornerRadius: 15)
                        }
                        
                        // 确认按钮
                        Button {
                            Task {
                                await settingsVM.loadConfig()
                                if settingsVM.configSuccess {
                                    appState.applyLoadedConfigState()
                                }
                            }
                        } label: {
                            HStack {
                                if settingsVM.isLoadingConfig {
                                    ProgressView()
                                        .tint(.white)
                                        .padding(.trailing, 8)
                                }
                                Text(settingsVM.isLoadingConfig ? "正在解析配置..." : "开启影音之旅")
                                    .fontWeight(.bold)
                            }
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 16)
                            .background(AppTheme.accentGradient)
                            .foregroundColor(.white)
                            .clipShape(Capsule())
                            .shadow(color: .red.opacity(0.4), radius: 12, x: 0, y: 6)
                        }
                        .buttonStyle(.plain)
                        .disabled(
                            settingsVM.isLoadingConfig
                            || settingsVM.vodApiUrl.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                        )
                        
                        // 历史记录
                        if !settingsVM.apiHistory.isEmpty {
                            VStack(alignment: .leading, spacing: 12) {
                                Text("最近使用")
                                    .font(.caption)
                                    .foregroundColor(.white.opacity(0.5))
                                    .padding(.horizontal, 4)
                                
                                ForEach(settingsVM.apiHistory.prefix(3), id: \.self) { url in
                                    Button {
                                        switch setupInputTarget {
                                        case .vod:
                                            settingsVM.vodApiUrl = url
                                        case .live:
                                            settingsVM.liveApiUrl = url
                                        }
                                    } label: {
                                        HStack {
                                            Image(systemName: "clock.arrow.2.circlepath")
                                                .font(.caption)
                                            Text(url)
                                                .font(.caption)
                                                .lineLimit(1)
                                            Spacer()
                                            Image(systemName: "chevron.right")
                                                .font(.system(size: 8))
                                        }
                                        .padding(.vertical, 10)
                                        .padding(.horizontal, 16)
                                        .foregroundColor(.white.opacity(0.7))
                                        .glassCard(cornerRadius: 10)
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                        }
                    }
                    .padding(.horizontal, 30)
                    
                    // 错误提示
                    if let error = settingsVM.configError {
                        HStack {
                            Image(systemName: "exclamationmark.circle.fill")
                            Text(error)
                        }
                        .font(.caption)
                        .foregroundColor(.red)
                        .padding()
                        .glassCard(cornerRadius: 10)
                        .padding(.horizontal, 30)
                    }
                    
                    Spacer(minLength: 50)
                }
            }
        }
    }
    
    private func readPasteboardText() -> String? {
        #if os(iOS)
        UIPasteboard.general.string
        #else
        // macOS 下通过 NSPasteboard 读取纯文本。
        NSPasteboard.general.string(forType: .string)
        #endif
    }
}
