import SwiftUI

struct ContentView: View {
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        TabView {
            BrowserView()
                .tabItem { Label("浏览", systemImage: "globe") }

            ScriptsView()
                .tabItem { Label("脚本", systemImage: "curlybraces") }

            PasswordsView()
                .tabItem { Label("密码", systemImage: "key.fill") }

            ServerView()
                .tabItem { Label("端口", systemImage: "antenna.radiowaves.left.and.right") }
        }
        .tint(Color(red: 0.42, green: 0.58, blue: 1.0))
        .onChange(of: scenePhase) { phase in
            switch phase {
            case .active:
                AppRuntime.shared.resume()
            case .background:
                if Store.shared.settings.keepAlive { KeepAlive.shared.start() }
            default:
                break
            }
        }
    }
}
