#if os(iOS)
import SwiftUI

/// 个人中心页 - 合并收藏、历史、设置入口为统一 Profile Hub
struct ProfileView: View {
    var body: some View {
        NavigationStack {
            List {
                // Header section
                Section {
                    profileHeader
                }
                .listRowBackground(Color.clear)

                // Navigation entries
                Section {
                    NavigationLink(destination: FavoritesView()) {
                        profileRow(icon: "heart.fill", title: "我的收藏", color: .red)
                    }
                    NavigationLink(destination: HistoryView()) {
                        profileRow(icon: "clock.fill", title: "播放历史", color: .orange)
                    }
                    NavigationLink(destination: SettingsView()) {
                        profileRow(icon: "gearshape.fill", title: "设置", color: .gray)
                    }
                }
            }
            .navigationTitle("个人中心")
            .navigationBarTitleDisplayMode(.large)
            .background(AppTheme.primaryGradient)
            .scrollContentBackground(.hidden)
        }
    }

    // MARK: - Profile Header

    private var profileHeader: some View {
        VStack(spacing: 12) {
            Image("AppIcon")
                .resizable()
                .frame(width: 72, height: 72)
                .clipShape(RoundedRectangle(cornerRadius: 16))
            Text("TVBox v\(Bundle.main.appVersionDescription)")
                .font(.caption)
                .foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 20)
    }

    // MARK: - Profile Row

    private func profileRow(icon: String, title: String, color: Color) -> some View {
        HStack(spacing: 14) {
            Image(systemName: icon)
                .foregroundColor(color)
                .frame(width: 28)
            Text(title)
                .font(.body)
        }
        .frame(minHeight: 44)
    }
}
#endif
