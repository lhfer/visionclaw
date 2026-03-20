import SwiftUI

/// Settings window: connection status, shrimp state debug, open immersive space
struct ControlPanelView: View {
    @EnvironmentObject var session: SessionManager
    @Environment(\.openImmersiveSpace) var openImmersiveSpace
    @Environment(\.dismissImmersiveSpace) var dismissImmersiveSpace

    var body: some View {
        NavigationStack {
            VStack(spacing: 20) {
                connectionSection
                stateSection
                actionSection
                Spacer()
            }
            .padding(32)
            .navigationTitle("ShrimpXR")
        }
        .frame(minWidth: 420, minHeight: 550)
    }

    // MARK: - Connection Section

    private var connectionSection: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 10) {
                // Mac Mini connection
                HStack {
                    Circle()
                        .fill(statusColor)
                        .frame(width: 10, height: 10)
                    Text("Mac Mini: \(session.connectionStatus.displayText)")
                        .font(.body)
                }

                // OpenClaw status
                HStack {
                    Circle()
                        .fill(session.network.openclawReachable ? .green : .gray)
                        .frame(width: 10, height: 10)
                    Text("OpenClaw: \(session.network.openclawReachable ? "可用" : "未确认")")
                        .font(.body)
                }

                HStack(spacing: 10) {
                    if !session.connectionStatus.isConnected {
                        Button("搜索 Mac Mini") {
                            session.connect()
                        }
                    } else {
                        Button("检查 OpenClaw") {
                            session.network.checkOpenClawStatus()
                        }
                        Button("断开连接") {
                            session.disconnect()
                        }
                        .tint(.red)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(8)
        } label: {
            Text("连接状态")
        }
    }

    // MARK: - State Section

    private var stateSection: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("虾的状态:")
                    Text(session.shrimpState.rawValue)
                        .font(.headline)
                        .foregroundStyle(.blue)
                }

                if !session.lastResponse.isEmpty {
                    Divider()
                    Text("最近回复:")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(session.lastResponse)
                        .font(.body)
                        .lineLimit(5)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(8)
        } label: {
            Text("状态")
        }
    }

    // MARK: - Action Section

    private var actionSection: some View {
        VStack(spacing: 12) {
            Button(action: {
                Task {
                    if session.isImmersiveOpen {
                        await dismissImmersiveSpace()
                        session.isImmersiveOpen = false
                        session.isShrimpLoading = false  // Reset loading state
                    } else {
                        let result = await openImmersiveSpace(id: "ShrimpSpace")
                        switch result {
                        case .opened:
                            session.isImmersiveOpen = true
                        case .error:
                            session.isImmersiveOpen = false
                            session.isShrimpLoading = false
                            session.statusMessage = "打开沉浸空间失败"
                        case .userCancelled:
                            session.isImmersiveOpen = false
                            session.isShrimpLoading = false
                        @unknown default:
                            session.isImmersiveOpen = false
                            session.isShrimpLoading = false
                        }
                    }
                }
            }) {
                HStack(spacing: 8) {
                    if session.isShrimpLoading {
                        ProgressView()
                        Text("虾虾加载中...")
                    } else {
                        Label(
                            session.isImmersiveOpen ? "收回虾虾" : "放出虾虾",
                            systemImage: session.isImmersiveOpen ? "arrow.down.circle" : "arrow.up.circle"
                        )
                    }
                }
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .tint(session.isImmersiveOpen ? .red : (session.isShrimpLoading ? .orange : .blue))
            .disabled(session.isShrimpLoading)

            // Relocate shrimp in front of user
            if session.isImmersiveOpen && !session.isShrimpLoading {
                Button(action: {
                    session.relocateShrimp()
                }) {
                    Label("找虾虾", systemImage: "location.viewfinder")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .tint(.green)
            }

            // Listening controls
            if session.isListening {
                HStack(spacing: 10) {
                    Button(action: {
                        session.stopAndSendListening()
                    }) {
                        Label("发送", systemImage: "paperplane.fill")
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.green)

                    Button(action: {
                        session.cancelListening()
                    }) {
                        Label("取消", systemImage: "xmark")
                    }
                    .buttonStyle(.bordered)
                    .tint(.red)
                }
            }

            // Test: send a real message to OpenClaw
            Button(action: {
                session.sendTestMessage("你好，做个自我介绍吧")
            }) {
                Label("测试对话", systemImage: "bubble.left.fill")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .disabled(!session.connectionStatus.isConnected)

            // Debug state buttons
            HStack {
                Button("idle") { session.shrimpState = .idle }
                Button("work") { session.shrimpState = .working }
                Button("win") { session.shrimpState = .success }
                Button("fail") { session.shrimpState = .error }
            }
            .font(.caption)
        }
    }

    // MARK: - Helpers

    private var statusColor: Color {
        switch session.connectionStatus {
        case .disconnected: return .red
        case .discovering:  return .orange
        case .connecting:   return .yellow
        case .connected:    return .green
        }
    }
}
