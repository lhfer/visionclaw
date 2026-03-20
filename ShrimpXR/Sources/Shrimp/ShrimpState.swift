import Foundation

/// All possible states of the shrimp, driven by user interaction + OpenClaw status
enum ShrimpState: String, CaseIterable {
    // Interaction states
    case idle           // 悠闲散步，清理触须
    case attentive      // 用户注视，虾抬头看你
    case listening      // 用户说话中，虾竖起触须认真听

    // Command states
    case sendingCommand // 双钳张开，发出涟漪光波
    case waitingResult  // 单钳托腮，小腿点桌面
    case thinking       // 身体微微蓝色脉冲

    // Execution states
    case working        // 快速挥动小腿，上下浮动
    case longTask       // 挖洞蹲进去，只露触须

    // Result states
    case success        // 跳起甩尾，泛金色光
    case error          // 翻身肚皮朝上挣扎

    // Special
    case waitingInput   // 钳子敲桌面，看着你
    case sleeping       // 蜷在角落，微微呼吸

    /// How long this state's intro animation takes (seconds)
    var introDuration: TimeInterval {
        switch self {
        case .idle:           return 0.5
        case .attentive:      return 0.3
        case .listening:      return 0.4
        case .sendingCommand: return 0.6
        case .waitingResult:  return 0.5
        case .thinking:       return 0.4
        case .working:        return 0.3
        case .longTask:       return 1.2
        case .success:        return 0.5
        case .error:          return 0.6
        case .waitingInput:   return 0.4
        case .sleeping:       return 1.0
        }
    }

    /// Whether the shrimp should loop its animation in this state
    var isLooping: Bool {
        switch self {
        case .success, .error, .sendingCommand:
            return false
        default:
            return true
        }
    }

    /// States where the shrimp is actively busy (don't start sleep timer)
    var isActive: Bool {
        switch self {
        case .listening, .sendingCommand, .waitingResult, .thinking, .working, .longTask:
            return true
        default:
            return false
        }
    }
}

/// Status reported by OpenClaw via WebSocket
enum OpenClawStatus: String, Codable {
    case idle
    case thinking
    case working
    case longTask = "long_task"
    case waitingInput = "waiting_input"
    case error
}

/// Result of an OpenClaw task
struct TaskResult: Codable {
    let success: Bool
    let text: String
    let taskId: String?
}

/// Connection status to Mac Mini
enum ConnectionStatus: Equatable {
    case disconnected
    case discovering
    case connecting
    case connected(hostName: String)

    var displayText: String {
        switch self {
        case .disconnected:          return "未连接"
        case .discovering:           return "搜索中..."
        case .connecting:            return "连接中..."
        case .connected(let host):   return "已连接: \(host)"
        }
    }

    var isConnected: Bool {
        if case .connected = self { return true }
        return false
    }
}
