import SwiftUI
import UIKit
import Darwin

struct ServerView: View {
    @ObservedObject private var store = Store.shared
    @ObservedObject private var router = APIRouter.shared
    @ObservedObject private var keepAlive = KeepAlive.shared
    @ObservedObject private var browser = BrowserModel.shared

    @State private var portText = ""
    @State private var copied = false
    @State private var showLogs = false

    private var lanIP: String { NetworkInfo.localIP() }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    HStack(spacing: 14) {
                        ZStack {
                            Circle()
                                .fill(router.isRunning ? Color.green.opacity(0.15) : Color.orange.opacity(0.15))
                                .frame(width: 52, height: 52)
                            Image(systemName: router.isRunning ? "antenna.radiowaves.left.and.right" : "bolt.slash")
                                .font(.system(size: 22))
                                .foregroundStyle(router.isRunning ? .green : .orange)
                        }
                        VStack(alignment: .leading, spacing: 4) {
                            Text(router.isRunning ? "端口已开启" : "端口未开启")
                                .font(.system(size: 17, weight: .semibold))
                            if router.isRunning {
                                Text("http://\(lanIP):\(router.port)")
                                    .font(.system(.caption, design: .monospaced))
                                    .foregroundStyle(.secondary)
                                    .textSelection(.enabled)
                            } else if let e = router.error {
                                Text(e).font(.caption).foregroundStyle(.orange)
                            } else {
                                Text("打开后可在电脑浏览器访问 API").font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        Spacer()
                        Toggle("", isOn: Binding(
                            get: { router.isRunning },
                            set: { on in
                                if on { APIRouter.shared.start(port: store.settings.port) }
                                else { APIRouter.shared.stop() }
                            }
                        )).labelsHidden()
                    }
                    .padding(.vertical, 4)
                }

                Section("配置") {
                    HStack {
                        Text("端口")
                        Spacer()
                        TextField("8899", text: $portText)
                            .keyboardType(.numberPad)
                            .multilineTextAlignment(.trailing)
                            .frame(width: 90)
                        Button("应用") {
                            if let p = Int(portText), p > 1024, p < 65536 {
                                store.settings.port = p
                                APIRouter.shared.restart(port: p)
                            }
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    }

                    Toggle("需要令牌", isOn: $store.settings.requireToken)
                    Toggle("静音保活（后台保持端口）", isOn: $store.settings.keepAlive)
                    Toggle("启动时自动开端口", isOn: $store.settings.autoStart)
                }

                Section {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text(store.settings.token)
                                .font(.system(.caption, design: .monospaced))
                                .lineLimit(2)
                                .textSelection(.enabled)
                            Spacer()
                            Button {
                                UIPasteboard.general.string = store.settings.token
                                copied = true
                                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { copied = false }
                            } label: {
                                Image(systemName: copied ? "checkmark" : "doc.on.doc")
                            }
                            .buttonStyle(.plain)
                        }
                        if copied {
                            Text("已复制").font(.caption2).foregroundStyle(.green)
                        }
                        Button("重置令牌") {
                            store.settings.token = AppSettings.randomToken()
                        }
                        .font(.caption)
                        .buttonStyle(.bordered)
                    }
                } header: {
                    Text("访问令牌")
                } footer: {
                    Text("请求头加 X-Token: <令牌>，或 URL 加 ?token=<令牌>。关掉「需要令牌」后局域网内任何设备都能直接访问（不建议）。")
                }

                Section("快捷命令") {
                    codeBlock("查看全部 Cookie", "curl -H 'X-Token: TOKEN' 'http://\(lanIP):\(store.settings.port)/api/cookies'")
                    codeBlock("安装用户脚本", "curl -X POST -H 'X-Token: TOKEN' --data-binary @foo.user.js 'http://\(lanIP):\(store.settings.port)/api/userscripts'")
                    codeBlock("执行 JS", "curl -X POST -H 'X-Token: TOKEN' -H 'Content-Type: application/json' -d '{\"script\":\"document.title\"}' 'http://\(lanIP):\(store.settings.port)/api/js'")
                }

                Section {
                    NavigationLink {
                        APIDocView()
                    } label: {
                        Label("完整接口文档", systemImage: "book")
                    }
                    NavigationLink {
                        LogsView()
                    } label: {
                        Label("运行日志（\(browser.logs.count)）", systemImage: "list.bullet.rectangle")
                    }
                }

                Section {
                    HStack {
                        Text("保活状态")
                        Spacer()
                        Text(keepAlive.active ? "运行中" : "未启用")
                            .foregroundStyle(keepAlive.active ? .green : .secondary)
                    }
                    HStack {
                        Text("保活自愈次数")
                        Spacer()
                        Text("\(keepAlive.recoverCount)").foregroundStyle(.secondary)
                    }
                    HStack {
                        Text("已安装脚本 / 密码")
                        Spacer()
                        Text("\(store.scripts.count) / \(store.credentials.count)").foregroundStyle(.secondary)
                    }
                }
            }
            .navigationTitle("端口")
            .onAppear { portText = "\(store.settings.port)" }
            .onChange(of: store.settings.port) { portText = "\($0)" }
        }
    }

    private func codeBlock(_ title: String, _ cmd: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(cmd)
                .font(.system(size: 10, design: .monospaced))
                .textSelection(.enabled)
                .foregroundStyle(.green)
                .lineLimit(nil)
                .fixedSize(horizontal: false, vertical: true)
            Button {
                UIPasteboard.general.string = cmd.replacingOccurrences(of: "TOKEN", with: store.settings.token)
            } label: {
                Text("复制").font(.caption2)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.blue)
        }
        .padding(.vertical, 3)
    }
}

// MARK: - 接口文档

struct APIDocView: View {
    @ObservedObject private var store = Store.shared

    private var doc: [String: Any] { APIRouter.apiDoc(port: store.settings.port) }

    var body: some View {
        List {
            Section("鉴权") {
                Text("请求头 X-Token: \(store.settings.token)，或 URL 参数 ?token=…；/health 免鉴权。")
                    .font(.caption)
                    .textSelection(.enabled)
            }
            Section("接口") {
                ForEach(Array(endpoints.enumerated()), id: \.offset) { _, item in
                    VStack(alignment: .leading, spacing: 3) {
                        Text(item.0)
                            .font(.system(size: 12, design: .monospaced))
                            .foregroundStyle(.green)
                        Text(item.1).font(.caption).foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 2)
                }
            }
            Section("示例") {
                ForEach(examples, id: \.self) { e in
                    Text(e)
                        .font(.system(size: 10, design: .monospaced))
                        .textSelection(.enabled)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .navigationTitle("接口文档")
        .navigationBarTitleDisplayMode(.inline)
    }

    private var endpoints: [(String, String)] {
        guard let list = doc["endpoints"] as? [String: String] else { return [] }
        return list.sorted { $0.key < $1.key }
    }

    private var examples: [String] {
        (doc["examples"] as? [String]) ?? []
    }
}

struct LogsView: View {
    @ObservedObject private var browser = BrowserModel.shared

    var body: some View {
        List {
            if browser.logs.isEmpty {
                Text("暂无日志。用户脚本里的 console.log / 报错会显示在这里。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(Array(browser.logs.enumerated()), id: \.offset) { _, line in
                    Text(line)
                        .font(.system(size: 11, design: .monospaced))
                        .textSelection(.enabled)
                }
            }
        }
        .navigationTitle("运行日志")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button("清空") { browser.logs.removeAll() }
            }
        }
    }
}

// MARK: - 网络信息

enum NetworkInfo {
    static func localIP() -> String {
        var address = "127.0.0.1"
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0, let first = ifaddr else { return address }
        defer { freeifaddrs(ifaddr) }
        var ptr: UnsafeMutablePointer<ifaddrs>? = first
        while let p = ptr {
            let flags = Int32(p.pointee.ifa_flags)
            if let sa = p.pointee.ifa_addr, sa.pointee.sa_family == UInt8(AF_INET),
               (flags & (IFF_UP | IFF_RUNNING)) == (IFF_UP | IFF_RUNNING),
               (flags & IFF_LOOPBACK) == 0 {
                var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                if getnameinfo(sa, socklen_t(sa.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 {
                    address = String(cString: host)
                }
            }
            ptr = p.pointee.ifa_next
        }
        return address
    }
}
