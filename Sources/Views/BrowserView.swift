import SwiftUI
import WebKit

struct WebViewContainer: UIViewRepresentable {
    let webView: WKWebView

    func makeUIView(context: Context) -> WKWebView { webView }

    func updateUIView(_ uiView: WKWebView, context: Context) {}
}

struct BrowserView: View {
    @ObservedObject private var browser = BrowserModel.shared
    @ObservedObject private var store = Store.shared
    @ObservedObject private var router = APIRouter.shared

    @State private var address: String = "https://www.bing.com"
    @State private var showCredentials = false
    @State private var showScripts = false
    @FocusState private var addressFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            addressBar

            if browser.progress > 0.001 && browser.progress < 1.0 {
                ProgressView(value: browser.progress)
                    .progressViewStyle(.linear)
                    .frame(height: 2)
                    .tint(Color(red: 0.42, green: 0.58, blue: 1.0))
            }

            WebViewContainer(webView: browser.webView)
                .ignoresSafeArea(.keyboard, edges: .bottom)
                .opacity(browser.isLoading ? 0.98 : 1)

            statusBar
        }
        .background(Color.black)
        .onReceive(browser.$urlString) { url in
            if !addressFocused && !url.isEmpty { address = url }
        }
        .onAppear {
            if browser.webView.url == nil {
                browser.load(URL(string: "https://www.bing.com")!)
            }
        }
        .sheet(isPresented: $showCredentials) {
            CredentialPickerSheet(url: browser.urlString)
        }
        .sheet(isPresented: $showScripts) {
            NavigationStack { ScriptsView(embedded: true) }
        }
    }

    private var addressBar: some View {
        HStack(spacing: 8) {
            Button { browser.goBack() } label: {
                Image(systemName: "chevron.backward")
            }
            .disabled(!browser.canGoBack)
            .foregroundStyle(browser.canGoBack ? .primary : .tertiary)

            HStack(spacing: 6) {
                Image(systemName: browser.isLoading ? "arrow.triangle.2.circlepath" : "lock.fill")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)

                TextField("搜索或输入网址", text: $address)
                    .textFieldStyle(.plain)
                    .keyboardType(.URL)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .focused($addressFocused)
                    .submitLabel(.go)
                    .onSubmit {
                        browser.go(address)
                        addressFocused = false
                    }

                if addressFocused {
                    Button {
                        address = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                    }
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(Color(white: 0.16))
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))

            Button { showCredentials = true } label: {
                Image(systemName: "key.fill")
            }
            .foregroundStyle(Color(red: 1.0, green: 0.78, blue: 0.35))

            Menu {
                Button { browser.reload() } label: { Label("刷新", systemImage: "arrow.clockwise") }
                Button { browser.stop() } label: { Label("停止", systemImage: "xmark") }
                Button { showScripts = true } label: { Label("用户脚本（\(store.scripts.filter(\.enabled).count) 个启用）", systemImage: "curlybraces") }
                Divider()
                Button {
                    UIPasteboard.general.string = browser.urlString
                } label: { Label("复制链接", systemImage: "doc.on.doc") }
                Button {
                    browser.load(URL(string: "https://www.bing.com")!)
                } label: { Label("回到首页", systemImage: "house") }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(Color(white: 0.10))
    }

    private var statusBar: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(router.isRunning ? Color.green : Color.orange)
                .frame(width: 6, height: 6)
            Text(router.isRunning ? "端口 \(router.port) 在线" : "端口未启动")
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
            Spacer()
            Text("\(store.scripts.filter(\.enabled).count) 个脚本 · \(store.credentials.count) 条密码")
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 4)
        .background(Color(white: 0.10))
    }
}

// MARK: - 密码快速填充

struct CredentialPickerSheet: View {
    let url: String
    @ObservedObject private var store = Store.shared
    @Environment(\.dismiss) private var dismiss
    @State private var revealed: Set<String> = []

    private var matches: [Credential] { store.credentials(for: url) }

    var body: some View {
        NavigationStack {
            Group {
                if matches.isEmpty {
                    VStack(spacing: 12) {
                        Image(systemName: "key.slash").font(.system(size: 42)).foregroundStyle(.secondary)
                        Text("这个网站没有保存的密码").foregroundStyle(.secondary)
                        Text("在「密码」页导入 Chrome 导出的 CSV").font(.caption).foregroundStyle(.tertiary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    List(matches) { c in
                        Button {
                            BrowserModel.shared.fillCredential(c) { ok in
                                if ok { dismiss() }
                            }
                        } label: {
                            HStack {
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(c.title.isEmpty ? c.domain : c.title).font(.headline)
                                    Text(c.username).font(.subheadline).foregroundStyle(.secondary)
                                    if revealed.contains(c.id) {
                                        Text(c.password).font(.system(.caption, design: .monospaced)).foregroundStyle(.green)
                                    }
                                }
                                Spacer()
                                Image(systemName: "arrow.up.forward.app")
                            }
                        }
                        .buttonStyle(.plain)
                        .swipeActions {
                            Button(revealed.contains(c.id) ? "隐藏" : "显示") {
                                if revealed.contains(c.id) { revealed.remove(c.id) } else { revealed.insert(c.id) }
                            }.tint(.orange)
                        }
                    }
                }
            }
            .navigationTitle("填充密码")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("关闭") { dismiss() }
                }
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        UIPasteboard.general.string = matches.first?.password
                    } label: { Image(systemName: "doc.on.doc") }
                    .disabled(matches.isEmpty)
                }
            }
        }
        .presentationDetents([.medium, .large])
    }
}
