#if os(iOS)
import SwiftUI

/// 直播频道全屏覆盖式选择器 - 替代 macOS 上的 390pt 抽屉
/// 采用左侧分组列表 + 右侧频道列表的双栏布局
struct ChannelOverlayView: View {
    let channelGroups: [LiveChannelGroup]
    @Binding var selectedGroupIndex: Int
    let currentChannels: [LiveChannelItem]
    let currentChannel: LiveChannelItem?
    let onSelectGroup: (Int) -> Void
    let onSelectChannel: (LiveChannelItem) -> Void
    let onDismiss: () -> Void

    @State private var dragOffset: CGFloat = 0

    /// 计算左侧分组列表宽度（屏幕宽度的 32%）
    /// - Parameter screenWidth: 屏幕宽度
    /// - Returns: 分组列表宽度，范围在 [screenWidth * 0.30, screenWidth * 0.35]
    static func computeGroupWidth(screenWidth: CGFloat) -> CGFloat {
        return screenWidth * 0.32
    }

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                // Dimmed background - tap to dismiss
                Color.black.opacity(0.5)
                    .ignoresSafeArea()
                    .onTapGesture {
                        withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) {
                            onDismiss()
                        }
                    }

                // Content panel
                VStack(spacing: 0) {
                    // Handle bar for drag-to-dismiss
                    handleBar

                    // Two-column layout
                    HStack(spacing: 0) {
                        groupList
                            .frame(width: Self.computeGroupWidth(screenWidth: geometry.size.width))

                        Divider()
                            .overlay(Color.white.opacity(0.1))

                        channelList
                    }
                }
                .frame(maxHeight: geometry.size.height * 0.85)
                .background(.ultraThinMaterial)
                .clipShape(RoundedRectangle(cornerRadius: 20))
                .offset(y: max(dragOffset, 0))
                .gesture(dismissDragGesture)
                .padding(.top, geometry.safeAreaInsets.top + 40)
            }
        }
        .transition(.move(edge: .bottom).combined(with: .opacity))
        .animation(.spring(response: 0.3, dampingFraction: 0.85), value: dragOffset)
    }

    // MARK: - Handle Bar

    private var handleBar: some View {
        VStack(spacing: 8) {
            Capsule()
                .fill(Color.white.opacity(0.4))
                .frame(width: 36, height: 5)
                .padding(.top, 10)

            Text("频道列表")
                .font(.system(size: 15, weight: .semibold))
                .foregroundColor(.white.opacity(0.9))
                .padding(.bottom, 8)
        }
        .frame(maxWidth: .infinity)
        .background(Color.white.opacity(0.05))
    }

    // MARK: - Group List (Left Column)

    private var groupList: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                if channelGroups.isEmpty {
                    Text("暂无分组")
                        .font(.system(size: 14))
                        .foregroundColor(.white.opacity(0.5))
                        .padding(.vertical, 20)
                        .frame(maxWidth: .infinity)
                } else {
                    ForEach(Array(channelGroups.enumerated()), id: \.offset) { index, group in
                        Button {
                            withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) {
                                onSelectGroup(index)
                            }
                        } label: {
                            Text(group.groupName)
                                .font(.system(size: 14, weight: selectedGroupIndex == index ? .bold : .medium))
                                .foregroundColor(selectedGroupIndex == index ? .orange : .white.opacity(0.8))
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.horizontal, 14)
                                .frame(minHeight: 48)
                                .background(
                                    selectedGroupIndex == index
                                        ? Color.white.opacity(0.1)
                                        : Color.clear
                                )
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
    }

    // MARK: - Channel List (Right Column)

    private var channelList: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                if currentChannels.isEmpty {
                    Text("暂无频道")
                        .font(.system(size: 14))
                        .foregroundColor(.white.opacity(0.5))
                        .padding(.vertical, 20)
                        .frame(maxWidth: .infinity)
                } else {
                    ForEach(currentChannels) { channel in
                        Button {
                            HapticManager.shared.mediumImpact()
                            onSelectChannel(channel)
                        } label: {
                            HStack {
                                Text(channel.channelName)
                                    .font(.system(size: 14, weight: currentChannel?.id == channel.id ? .bold : .medium))
                                    .foregroundColor(currentChannel?.id == channel.id ? .orange : .white.opacity(0.8))

                                Spacer()

                                if channel.sourceNum > 1 {
                                    Text("\(channel.sourceNum)")
                                        .font(.system(size: 10))
                                        .foregroundColor(.white.opacity(0.3))
                                        .padding(.horizontal, 6)
                                        .padding(.vertical, 2)
                                        .background(Capsule().stroke(Color.white.opacity(0.2), lineWidth: 0.5))
                                }

                                if currentChannel?.id == channel.id {
                                    Image(systemName: "speaker.wave.2.fill")
                                        .font(.system(size: 10))
                                        .foregroundColor(.orange)
                                }
                            }
                            .padding(.horizontal, 16)
                            .frame(minHeight: 48)
                            .background(
                                currentChannel?.id == channel.id
                                    ? Color.orange.opacity(0.15)
                                    : Color.clear
                            )
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
    }

    // MARK: - Drag to Dismiss Gesture

    private var dismissDragGesture: some Gesture {
        DragGesture()
            .onChanged { value in
                dragOffset = value.translation.height
            }
            .onEnded { value in
                if value.translation.height > 120 {
                    // Dismiss if dragged down far enough
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) {
                        onDismiss()
                    }
                } else {
                    // Snap back
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) {
                        dragOffset = 0
                    }
                }
            }
    }
}
#endif
