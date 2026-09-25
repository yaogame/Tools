import SwiftUI

@main
struct BridgeReplayApp: App {
    @StateObject private var store = BoardStore()

    var body: some Scene {
        WindowGroup {
            HomeView()
                .environmentObject(store)
                .tint(Theme.felt)
        }
    }
}

/// 导航目标。
enum Route: Hashable {
    case board(UUID)
    case play(UUID, PlayLaunch)
    case review(UUID, UUID)
}

/// 开始一次坐庄需要的参数。
struct PlayLaunch: Hashable {
    var mode: PracticeMode
    var robotLevel: RobotLevel
    var contract: Contract
    /// 从这些已出的牌之后开始（恢复点 / 从第 n 墩重打）。
    var startPlays: [Play]
}
