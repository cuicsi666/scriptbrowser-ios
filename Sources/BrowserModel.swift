import Foundation
import WebKit
import UIKit
import Combine

@MainActor
final class BrowserModel: NSObject, ObservableObject, WKNavigationDelegate, WKUIDelegate, WKScriptMessageHandler {

    static let shared = BrowserModel()

    @Published var urlString: String = ""
    @Published var pageTitle: String = ""
    @Published var progress: Double = 0
    @Published var isLoading: Bool = false
    @Published var canGoBack: Bool = false
    @Published var canGoForward: Bool = false
    @Published var logs: [String] = []

    let webView: WKWebView
    private let config: WKWebViewConfiguration
    private let controller = WKUserContentController()
    private var observers: [NSKeyValueObservation] = []

    override private init() {
        config = WKWebViewConfiguration()
        config.allowsInlineMediaPlayback = true
        config.defaultWebpagePreferences.allowsContentJavaScript = true
        config.mediaTypesRequiringUserActionForPlayback = []
        config.userContentController = controller
        config.websiteDataStore = .default()
        webView = WKWebView(frame: .zero, configuration: config)
        super.init()

        controller.add(self, name: "sbLog")
        webView.navigationDelegate = self
        webView.uiDelegate = self
        webView.allowsBackForwardNavigationGestures = true
        if #available(iOS 16.4, *) { webView.isInspectable = true }

        observers.append(webView.observe(\.url, options: [.new]) { [weak self] wv, _ in
            Task { @MainActor in self?.syncFromWebView() }
        })
        observers.append(webView.observe(\.title, options: [.new]) { [weak self] wv, _ in
            Task { @MainActor in self?.pageTitle = wv.title ?? "" }
        })
        observers.append(webView.observe(\.estimatedProgress, options: [.new]) { [weak self] wv, _ in
            Task { @MainActor in self?.progress = wv.estimatedProgress }
        })
        observers.append(webView.observe(\.isLoading, options: [.new]) { [weak self] wv, _ in
            Task { @MainActor in self?.isLoading = wv.isLoading }
        })

        rebuildUserScripts(reload: false)
    }

    // MARK: 导航

    func go(_ text: String) {
        var s = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty else { return }
        if !s.contains("://") && !s.hasPrefix("about:") {
            let looksLikeURL = s.contains(".") && !s.contains(" ")
            s = looksLikeURL ? "https://" + s : "https://www.bing.com/search?q=" + (s.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? s)
        }
        guard let url = URL(string: s) else { return }
        webView.load(URLRequest(url: url))
    }

    func load(_ url: URL) {
        webView.load(URLRequest(url: url))
    }

    func syncFromWebView() {
        let u = webView.url?.absoluteString ?? ""
        if !u.isEmpty { urlString = u }
        pageTitle = webView.title ?? pageTitle
        canGoBack = webView.canGoBack
        canGoForward = webView.canGoForward
    }

    func goBack() { webView.goBack() }
    func goForward() { webView.goForward() }
    func reload() { webView.reload() }
    func stop() { webView.stopLoading() }

    // MARK: 用户脚本

    func rebuildUserScripts(reload: Bool = true) {
        controller.removeAllUserScripts()
        let js = ScriptEngine.bootstrap(scripts: Store.shared.scripts)
        controller.addUserScript(WKUserScript(source: js, injectionTime: .atDocumentStart, forMainFrameOnly: false))
        if reload { webView.reload() }
    }

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard message.name == "sbLog" else { return }
        var text = ""
        if let d = message.body as? [String: Any] {
            let name = d["script"] as? String ?? "?"
            let level = d["level"] as? String ?? "info"
            let msg = d["message"] as? String ?? ""
            text = "[\(level)] \(name): \(msg)"
        } else {
            text = String(describing: message.body)
        }
        let line = "\(Self.timeFormatter.string(from: Date())) \(text)"
        logs.append(line)
        if logs.count > 300 { logs.removeFirst(logs.count - 300) }
    }

    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "HH:mm:ss"; return f
    }()

    // MARK: Cookie

    func allCookies(completion: @escaping ([HTTPCookie]) -> Void) {
        webView.configuration.websiteDataStore.httpCookieStore.getAllCookies { completion($0) }
    }

    func setCookies(_ cookies: [HTTPCookie], completion: @escaping () -> Void) {
        let store = webView.configuration.websiteDataStore.httpCookieStore
        var remaining = cookies.count
        guard remaining > 0 else { completion(); return }
        for c in cookies {
            store.setCookie(c) {
                remaining -= 1
                if remaining == 0 { completion() }
            }
        }
    }

    func deleteCookies(domain: String, completion: @escaping (Int) -> Void) {
        allCookies { cookies in
            let matched = cookies.filter { domain.isEmpty || $0.domain.contains(domain) }
            let store = self.webView.configuration.websiteDataStore.httpCookieStore
            var remaining = matched.count
            guard remaining > 0 else { DispatchQueue.main.async { completion(0) }; return }
            for c in matched {
                store.delete(c) {
                    remaining -= 1
                    if remaining == 0 { DispatchQueue.main.async { completion(matched.count) } }
                }
            }
        }
    }

    // MARK: JS

    func runJS(_ js: String, completion: @escaping (Any?, Error?) -> Void) {
        webView.evaluateJavaScript(js) { result, error in
            DispatchQueue.main.async { completion(result, error) }
        }
    }

    func fillCredential(_ cred: Credential, completion: @escaping (Bool) -> Void) {
        let u = Self.jsString(cred.username)
        let p = Self.jsString(cred.password)
        let js = """
        (function(){
          function setVal(el, v) {
            var proto = el.tagName === 'TEXTAREA' ? window.HTMLTextAreaElement.prototype : window.HTMLInputElement.prototype;
            var setter = Object.getOwnPropertyDescriptor(proto, 'value').set;
            setter.call(el, v);
            el.dispatchEvent(new Event('input', { bubbles: true }));
            el.dispatchEvent(new Event('change', { bubbles: true }));
          }
          var pw = document.querySelector('input[type=password]');
          if (!pw) { return 'no-password-field'; }
          var form = pw.form || document;
          var inputs = form.querySelectorAll('input[type=text],input[type=email],input[type=tel],input:not([type])');
          var uf = null;
          for (var i = 0; i < inputs.length; i++) {
            if (pw.compareDocumentPosition(inputs[i]) & Node.DOCUMENT_POSITION_FOLLOWING) { uf = inputs[i]; break; }
          }
          if (uf) { setVal(uf, \(u)); }
          setVal(pw, \(p));
          pw.focus();
          return 'filled';
        })();
        """
        webView.evaluateJavaScript(js) { result, _ in
            DispatchQueue.main.async { completion((result as? String) == "filled") }
        }
    }

    static func jsString(_ s: String) -> String {
        if let d = try? JSONSerialization.data(withJSONObject: [s], options: [.fragmentsAllowed]),
           let str = String(data: d, encoding: .utf8) {
            return String(str.dropFirst().dropLast())
        }
        return "\"\""
    }

    // MARK: WKNavigationDelegate

    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        guard let url = navigationAction.request.url else { decisionHandler(.allow); return }
        let scheme = url.scheme?.lowercased() ?? ""
        if ["http", "https", "about", "file", "data", "blob", "javascript"].contains(scheme) {
            decisionHandler(.allow)
        } else {
            UIApplication.shared.open(url)
            decisionHandler(.cancel)
        }
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        syncFromWebView()
    }

    func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
        syncFromWebView()
    }

    // MARK: WKUIDelegate（target=_blank 同窗口打开）

    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        if let url = navigationAction.request.url {
            webView.load(URLRequest(url: url))
        }
        return nil
    }

    func webView(_ webView: WKWebView, runJavaScriptAlertPanelWithMessage message: String,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping () -> Void) {
        let alert = UIAlertController(title: webView.url?.host, message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "好", style: .default) { _ in completionHandler() })
        topViewController()?.present(alert, animated: true)
    }

    func webView(_ webView: WKWebView, runJavaScriptConfirmPanelWithMessage message: String,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping (Bool) -> Void) {
        let alert = UIAlertController(title: webView.url?.host, message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "取消", style: .cancel) { _ in completionHandler(false) })
        alert.addAction(UIAlertAction(title: "确定", style: .default) { _ in completionHandler(true) })
        topViewController()?.present(alert, animated: true)
    }

    func webView(_ webView: WKWebView, runJavaScriptTextInputPanelWithPrompt prompt: String,
                 defaultText: String?, initiatedByFrame frame: WKFrameInfo,
                 completionHandler: @escaping (String?) -> Void) {
        let alert = UIAlertController(title: webView.url?.host, message: prompt, preferredStyle: .alert)
        alert.addTextField { $0.text = defaultText }
        alert.addAction(UIAlertAction(title: "取消", style: .cancel) { _ in completionHandler(nil) })
        alert.addAction(UIAlertAction(title: "确定", style: .default) { _ in
            completionHandler(alert.textFields?.first?.text)
        })
        topViewController()?.present(alert, animated: true)
    }

    private func topViewController() -> UIViewController? {
        let scene = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first
        var vc = scene?.windows.first(where: { $0.isKeyWindow })?.rootViewController
        while let p = vc?.presentedViewController { vc = p }
        return vc
    }
}
