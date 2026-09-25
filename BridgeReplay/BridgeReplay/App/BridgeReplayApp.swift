import SwiftUI

@main
struct BridgeReplayApp: App {
    @StateObject private var store = BoardStore()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(store)
                .tint(Theme.felt)
        }
    }
}

/// 底部标签页：复盘、坐庄、防守、叫牌、牌例。
struct RootView: View {
    var body: some View {
        TabView {
            NavigationTab { HomeView() }
                .tabItem { Label("复盘", systemImage: "camera.viewfinder") }
            NavigationTab { PracticeHomeView(kind: .declarer) }
                .tabItem { Label("坐庄", systemImage: "suit.spade.fill") }
            NavigationTab { PracticeHomeView(kind: .defense) }
                .tabItem { Label("防守", systemImage: "shield.lefthalf.filled") }
            NavigationTab { BiddingHomeView() }
                .tabItem { Label("叫牌", systemImage: "list.number") }
            NavigationTab { ExamplesView() }
                .tabItem { Label("牌例", systemImage: "star") }
        }
    }
}

/// 每个标签页自己的导航栈，共用同一套页面路由。
struct NavigationTab<Content: View>: View {
    private let content: () -> Content
    @State private var path: [Route] = []

    init(@ViewBuilder content: @escaping () -> Content) {
        self.content = content
    }

    var body: some View {
        NavigationStack(path: $path) {
            content()
                .navigationDestination(for: Route.self) { RouteView(route: $0) }
        }
        .environment(\.navigator, Navigator(
            push: { path.append($0) },
            replaceTop: { route in
                if !path.isEmpty { path.removeLast() }
                path.append(route)
            }))
    }
}

/// 导航目标。
enum Route: Hashable {
    case board(UUID)
    case play(UUID, PlayLaunch)
    case review(UUID, UUID)
    case practiceLevel(PracticeKind, PracticeLevel)
    case practice(String)
    case bidding(String)
    case example(UUID)
}

/// 开始一次出牌需要的参数。
struct PlayLaunch: Hashable {
    var mode: PracticeMode
    var robotLevel: RobotLevel
    var contract: Contract
    /// 从这些已出的牌之后开始（恢复点 / 从第 n 墩重打 / 牌例保存的位置）。
    var startPlays: [Play]
    /// 坐在下方的一家；不填就是庄家。
    var viewer: Seat? = nil
    /// 分级练习牌库的编号。
    var practiceID: String? = nil
}

/// 让页面里也能跳转（例如"下一副"）。
struct Navigator {
    var push: (Route) -> Void = { _ in }
    var replaceTop: (Route) -> Void = { _ in }
}

private struct NavigatorKey: EnvironmentKey {
    static let defaultValue = Navigator()
}

extension EnvironmentValues {
    var navigator: Navigator {
        get { self[NavigatorKey.self] }
        set { self[NavigatorKey.self] = newValue }
    }
}

struct RouteView: View {
    let route: Route
    @EnvironmentObject private var store: BoardStore

    var body: some View {
        switch route {
        case .board(let id):
            BoardDetailView(boardID: id)
        case .play(let id, let launch):
            if let board = store.board(id) {
                PlayView(board: board, launch: launch)
            } else {
                ContentUnavailableView("找不到这副牌", systemImage: "questionmark.circle")
            }
        case .review(let id, let attemptID):
            ReviewView(boardID: id, attemptID: attemptID)
        case .practiceLevel(let kind, let level):
            PracticeLevelView(kind: kind, level: level)
        case .practice(let id):
            PracticePlayContainer(practiceID: id)
        case .bidding(let id):
            BiddingView(dealID: id)
        case .example(let id):
            ExampleDetailView(exampleID: id)
        }
    }
}
