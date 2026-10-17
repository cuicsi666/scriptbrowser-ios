import SwiftUI
import UIKit

@main
struct ScriptBrowserApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) var delegate
    @ObservedObject private var store = Store.shared

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(store)
                .preferredColorScheme(.dark)
        }
    }
}

final class AppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        Task { @MainActor in
            AppRuntime.shared.boot()
        }
        return true
    }

    func applicationDidEnterBackground(_ application: UIApplication) {
        Task { @MainActor in
            if Store.shared.settings.keepAlive { KeepAlive.shared.start() }
        }
    }
}

@MainActor
final class AppRuntime {
    static let shared = AppRuntime()
    private var booted = false

    func boot() {
        let s = Store.shared.settings
        if s.autoStart { APIRouter.shared.start(port: s.port) }
        if s.keepAlive { KeepAlive.shared.start() }
        booted = true
    }

    /// 回到前台时自愈：端口没起来就重新拉起
    func resume() {
        let s = Store.shared.settings
        if s.autoStart && !APIRouter.shared.isRunning {
            APIRouter.shared.start(port: s.port)
        }
        if s.keepAlive { KeepAlive.shared.start() }
        BrowserModel.shared.syncFromWebView()
    }

    func restartServer() {
        let s = Store.shared.settings
        APIRouter.shared.restart(port: s.port)
    }
}
