import Foundation
import WebKit
import Combine

/// 本地 HTTP API 路由
@MainActor
final class APIRouter: ObservableObject {

    static let shared = APIRouter()
    private let server = HTTPServer()
    private let store = Store.shared
    private let browser = BrowserModel.shared
    private var bag: AnyCancellable?

    init() {
        bag = server.objectWillChange.sink { [weak self] _ in
            Task { @MainActor in self?.objectWillChange.send() }
        }
    }

    var isRunning: Bool { server.running }
    var port: Int { server.actualPort }
    var error: String? { server.lastError }

    func start(port: Int) {
        server.handler = { [weak self] req, reply in
            self?.handle(req, reply)
        }
        server.start(port: UInt16(port))
    }

    func stop() { server.stop() }

    func restart(port: Int) {
        stop()
        start(port: port)
    }

    // MARK: 鉴权

    private func authorized(_ req: HTTPRequest) -> Bool {
        guard store.settings.requireToken else { return true }
        let token = store.settings.token
        if req.query["token"] == token { return true }
        if let h = req.headers["x-token"], h == token { return true }
        if let auth = req.headers["authorization"] {
            let v = auth.replacingOccurrences(of: "Bearer ", with: "").trimmingCharacters(in: .whitespaces)
            if v == token { return true }
        }
        return false
    }

    // MARK: 路由

    private func handle(_ req: HTTPRequest, _ reply: @escaping (HTTPResponse) -> Void) {
        if req.method == "OPTIONS" {
            reply(HTTPResponse(status: 204, contentType: "text/plain", body: Data()))
            return
        }
        if req.path == "/" || req.path == "/index.html" {
            reply(.text(Self.consoleHTML, type: "text/html; charset=utf-8"))
            return
        }
        if req.path == "/health" {
            reply(.json([
                "ok": true,
                "app": "脚本浏览器",
                "version": "1.0",
                "port": server.actualPort,
                "url": browser.urlString,
                "scripts": store.scripts.count,
                "credentials": store.credentials.count
            ]))
            return
        }
        guard authorized(req) else {
            reply(.error("令牌无效：请在请求头带 X-Token，或在 URL 加 ?token=…", status: 401))
            return
        }
        guard req.path.hasPrefix("/api") else {
            reply(.error("未知路径", status: 404))
            return
        }

        let parts = req.path.split(separator: "/").map(String.init)  // ["api", ...]

        // GET /api 文档
        if parts.count == 1 {
            reply(.json(Self.apiDoc(port: server.actualPort)))
            return
        }

        switch parts[1] {
        case "cookies": return cookies(req, parts, reply)
        case "page": return page(req, reply)
        case "html": return html(req, reply)
        case "js": return runJS(req, reply)
        case "open": return open(req, reply)
        case "userscripts", "scripts": return scripts(req, parts, reply)
        case "passwords": return passwords(req, reply)
        default: reply(.error("未知接口", status: 404))
        }
    }

    // MARK: Cookies

    private func cookies(_ req: HTTPRequest, _ parts: [String], _ reply: @escaping (HTTPResponse) -> Void) {
        if req.method == "GET" {
            let domain = req.query["domain"] ?? ""
            browser.allCookies { all in
                let filtered = domain.isEmpty ? all : all.filter {
                    $0.domain.contains(domain) || domain.contains($0.domain.replacingOccurrences(of: ".", with: ""))
                }
                let list: [[String: Any]] = filtered.map { c in
                    var d: [String: Any] = [
                        "name": c.name, "value": c.value, "domain": c.domain,
                        "path": c.path, "secure": c.isSecure, "httpOnly": c.isHTTPOnly,
                        "session": c.expiresDate == nil
                    ]
                    if let e = c.expiresDate { d["expires"] = Int(e.timeIntervalSince1970) }
                    return d
                }
                // 方便直接给 Playwright / curl 用的字符串
                let cookieHeader = filtered.map { "\($0.name)=\($0.value)" }.joined(separator: "; ")
                reply(.json([
                    "ok": true, "count": list.count,
                    "url": self.browser.urlString,
                    "cookie_header": cookieHeader,
                    "cookies": list
                ]))
            }
            return
        }

        if req.method == "POST" || req.method == "PUT" {
            var items: [[String: Any]] = []
            if let obj = req.jsonBody() {
                if let arr = obj["cookies"] as? [[String: Any]] {
                    items = arr
                } else if obj["name"] != nil {
                    items = [obj]
                }
            }
            var parsed: [HTTPCookie] = []
            for item in items {
                guard let name = item["name"] as? String, let value = item["value"] as? String else { continue }
                var props: [HTTPCookiePropertyKey: Any] = [
                    .name: name, .value: value,
                    .domain: (item["domain"] as? String) ?? "localhost",
                    .path: (item["path"] as? String) ?? "/"
                ]
                if let exp = item["expires"] as? TimeInterval {
                    props[.expires] = Date(timeIntervalSince1970: exp)
                }
                if let s = item["secure"] as? Bool, s { props[.secure] = "TRUE" }
                if let h = item["httpOnly"] as? Bool, h { props[HTTPCookiePropertyKey("HttpOnly")] = "TRUE" }
                if let c = HTTPCookie(properties: props) { parsed.append(c) }
            }
            browser.setCookies(parsed) {
                reply(.json(["ok": true, "set": parsed.count]))
            }
            return
        }

        if req.method == "DELETE" {
            let domain = req.query["domain"] ?? ""
            browser.deleteCookies(domain: domain) { n in
                reply(.json(["ok": true, "deleted": n, "domain": domain]))
            }
            return
        }
        reply(.error("方法不允许", status: 405))
    }

    // MARK: 页面

    private func page(_ req: HTTPRequest, _ reply: @escaping (HTTPResponse) -> Void) {
        reply(.json([
            "ok": true,
            "url": browser.urlString,
            "title": browser.pageTitle,
            "canGoBack": browser.canGoBack,
            "canGoForward": browser.canGoForward
        ]))
    }

    private func html(_ req: HTTPRequest, _ reply: @escaping (HTTPResponse) -> Void) {
        browser.runJS("document.documentElement.outerHTML") { result, error in
            if let error { reply(.error("取页面失败：\(error.localizedDescription)", status: 500)); return }
            reply(.text(result as? String ?? "", type: "text/html; charset=utf-8"))
        }
    }

    // MARK: 执行 JS

    private func runJS(_ req: HTTPRequest, _ reply: @escaping (HTTPResponse) -> Void) {
        var code = req.bodyString
        if code.isEmpty { code = req.query["script"] ?? req.query["js"] ?? "" }
        if code.isEmpty, let obj = req.jsonBody(), let s = obj["script"] as? String { code = s }
        guard !code.isEmpty else { reply(.error("缺少 script 参数", status: 400)); return }
        browser.runJS(code) { result, error in
            if let error {
                reply(.json(["ok": false, "error": error.localizedDescription], status: 500))
                return
            }
            var payload: [String: Any] = ["ok": true]
            if let r = result {
                if JSONSerialization.isValidJSONObject(r) {
                    payload["result"] = r
                } else {
                    payload["result"] = String(describing: r)
                }
            }
            reply(.json(payload))
        }
    }

    private func open(_ req: HTTPRequest, _ reply: @escaping (HTTPResponse) -> Void) {
        var url = req.query["url"] ?? ""
        if url.isEmpty, let obj = req.jsonBody(), let u = obj["url"] as? String { url = u }
        if url.isEmpty, !req.bodyString.isEmpty { url = req.bodyString.trimmingCharacters(in: .whitespacesAndNewlines) }
        guard !url.isEmpty, let u = URL(string: url) else { reply(.error("缺少 url", status: 400)); return }
        browser.load(u)
        reply(.json(["ok": true, "opened": url]))
    }

    // MARK: 用户脚本

    private func scripts(_ req: HTTPRequest, _ parts: [String], _ reply: @escaping (HTTPResponse) -> Void) {
        // /api/userscripts
        if parts.count == 2 {
            switch req.method {
            case "GET":
                reply(.json(["ok": true, "count": store.scripts.count, "scripts": store.scripts.map { $0.dict }]))
            case "POST":
                installScript(req, reply)
            default:
                reply(.error("方法不允许", status: 405))
            }
            return
        }

        let id = parts[2]
        guard let script = store.scripts.first(where: { $0.id == id || $0.name == id }) else {
            reply(.error("脚本不存在", status: 404))
            return
        }

        // /api/userscripts/{id}
        if parts.count == 3 {
            switch req.method {
            case "GET":
                reply(.json(["ok": true, "script": script.dict, "source": script.source]))
            case "DELETE":
                store.removeScript(id: script.id)
                browser.rebuildUserScripts()
                reply(.json(["ok": true, "deleted": script.id]))
            case "PUT", "POST":
                if let obj = req.jsonBody() {
                    guard var updated = fromJSON(obj, base: script) else { reply(.error("内容不合法")); return }
                    updated.id = script.id
                    if let i = store.scripts.firstIndex(where: { $0.id == script.id }) { store.scripts[i] = updated }
                    browser.rebuildUserScripts()
                    reply(.json(["ok": true, "script": updated.dict]))
                } else {
                    reply(.error("需要 JSON"))
                }
            default:
                reply(.error("方法不允许", status: 405))
            }
            return
        }

        // /api/userscripts/{id}/source | toggle | enable | disable
        switch parts[3] {
        case "source":
            reply(.text(script.source, type: "text/javascript; charset=utf-8"))
        case "toggle":
            store.toggleScript(id: script.id)
            browser.rebuildUserScripts()
            reply(.json(["ok": true, "id": script.id, "enabled": !script.enabled]))
        case "enable", "disable":
            let on = parts[3] == "enable"
            if let i = store.scripts.firstIndex(where: { $0.id == script.id }) {
                store.scripts[i].enabled = on
                browser.rebuildUserScripts()
            }
            reply(.json(["ok": true, "id": script.id, "enabled": on]))
        default:
            reply(.error("未知操作", status: 404))
        }
    }

    private func installScript(_ req: HTTPRequest, _ reply: @escaping (HTTPResponse) -> Void) {
        var source = req.bodyString
        var enabled = true
        if let obj = req.jsonBody() {
            if let s = obj["source"] as? String { source = s }
            if let e = obj["enabled"] as? Bool { enabled = e }
            if let u = obj["url"] as? String, source.isEmpty, let url = URL(string: u) {
                reply(.json(["ok": false, "error": "服务端不代下载，请把脚本内容放在 body 里"], status: 400))
                return
            }
        }
        source = source.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !source.isEmpty else {
            reply(.error("body 为空：直接 POST 脚本源码（text/plain）即可安装", status: 400))
            return
        }
        // 兼容 base64 传输（避免某些客户端转义问题）
        if req.query["base64"] == "1", let d = Data(base64Encoded: source), let s = String(data: d, encoding: .utf8) {
            source = s
        }
        guard let script = store.install(source: source, enabled: enabled) else {
            reply(.error("解析失败：缺少 ==UserScript== 元数据块或 @name", status: 422))
            return
        }
        browser.rebuildUserScripts()
        reply(.json(["ok": true, "script": script.dict], status: 201))
    }

    private func fromJSON(_ obj: [String: Any], base: UserScript) -> UserScript? {
        var s = base
        if let v = obj["name"] as? String { s.name = v }
        if let v = obj["namespace"] as? String { s.namespace = v }
        if let v = obj["version"] as? String { s.version = v }
        if let v = obj["description"] as? String { s.desc = v }
        if let v = obj["matches"] as? [String] { s.matches = v }
        if let v = obj["excludes"] as? [String] { s.excludes = v }
        if let v = obj["run_at"] as? String { s.runAt = v }
        if let v = obj["enabled"] as? Bool { s.enabled = v }
        if let v = obj["source"] as? String { s.source = v }
        return s
    }

    // MARK: 密码

    private func passwords(_ req: HTTPRequest, _ reply: @escaping (HTTPResponse) -> Void) {
        let domain = req.query["domain"] ?? browser.urlString
        let list = store.credentials(for: domain)
        reply(.json(["ok": true, "count": list.count, "domain": domain, "credentials": list.map { $0.dict }]))
    }

    // MARK: 文档

    static func apiDoc(port: Int) -> [String: Any] {
        let base = "http://<设备IP>:\(port)"
        return [
            "ok": true,
            "app": "脚本浏览器 HTTP API",
            "auth": "请求头 X-Token: <令牌>，或 URL 参数 ?token=<令牌>",
            "endpoints": [
                "GET /health": "健康检查（免鉴权）",
                "GET /api": "本说明",
                "GET /api/cookies?domain=": "读取全部 Cookie（含 HttpOnly），返回 cookie_header 可直接用",
                "POST /api/cookies": "写入 Cookie，body: {\"cookies\":[{\"name\":\"a\",\"value\":\"b\",\"domain\":\".example.com\",\"path\":\"/\"}]}",
                "DELETE /api/cookies?domain=": "清除指定域 Cookie",
                "GET /api/page": "当前页面 URL / 标题",
                "GET /api/html": "当前页面完整 HTML",
                "POST /api/js": "在当前页执行 JS，body: {\"script\":\"…\"}",
                "POST /api/open": "让 App 打开网址，body: {\"url\":\"https://…\"}",
                "GET /api/userscripts": "已安装脚本列表",
                "POST /api/userscripts": "安装/更新脚本，body 直接放 .user.js 源码（text/plain）",
                "GET /api/userscripts/{id}": "脚本详情 + 源码",
                "DELETE /api/userscripts/{id}": "卸载脚本",
                "PUT /api/userscripts/{id}": "更新脚本 JSON",
                "POST /api/userscripts/{id}/toggle": "启用/停用",
                "GET /api/userscripts/{id}/source": "下载源码",
                "GET /api/passwords?domain=": "按域名匹配密码（需令牌）"
            ],
            "examples": [
                "curl -H 'X-Token: TOKEN' '\(base)/api/cookies?domain=example.com'",
                "curl -X POST -H 'X-Token: TOKEN' --data-binary @script.user.js '\(base)/api/userscripts'",
                "curl -X POST -H 'X-Token: TOKEN' -H 'Content-Type: application/json' -d '{\"script\":\"document.title\"}' '\(base)/api/js'"
            ]
        ]
    }

    // MARK: 网页控制台

    static let consoleHTML = #"""
<!doctype html>
<html lang="zh-CN"><head>
<meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<title>脚本浏览器 · 本地 API</title>
<style>
  :root { color-scheme: dark; }
  * { box-sizing: border-box; }
  body { margin:0; font:15px/1.6 -apple-system,BlinkMacSystemFont,"PingFang SC",sans-serif; background:#0f1116; color:#e6e8ee; }
  header { padding:18px 20px; background:linear-gradient(135deg,#1b2440,#0f1116); border-bottom:1px solid #23283a; }
  h1 { margin:0; font-size:19px; } h1 span { color:#7aa2ff; }
  .sub { color:#8892a6; font-size:12px; margin-top:4px; }
  main { padding:16px 20px 60px; max-width:900px; margin:0 auto; }
  section { background:#161a24; border:1px solid #23283a; border-radius:12px; padding:14px 16px; margin-bottom:14px; }
  h2 { font-size:14px; margin:0 0 10px; color:#9fb3d1; letter-spacing:.5px; }
  input,textarea,button { font:inherit; }
  input,textarea { width:100%; background:#0d1018; border:1px solid #2a3145; color:#e6e8ee; border-radius:8px; padding:9px 11px; }
  textarea { min-height:130px; font-family:ui-monospace,Menlo,monospace; font-size:12px; }
  button { background:#2b5cff; border:0; color:#fff; border-radius:8px; padding:9px 16px; font-weight:600; }
  button.ghost { background:#232a3a; color:#c9d4e6; }
  .row { display:flex; gap:8px; align-items:center; margin-top:8px; flex-wrap:wrap; }
  table { width:100%; border-collapse:collapse; font-size:12px; }
  th,td { text-align:left; padding:6px 8px; border-bottom:1px solid #1f2432; vertical-align:top; word-break:break-all; }
  th { color:#7f8ba3; font-weight:500; }
  code { font-family:ui-monospace,Menlo,monospace; color:#7ee0b0; font-size:12px; }
  .ok { color:#4ade80 } .err { color:#f87171 }
  .pill { display:inline-block; padding:1px 8px; border-radius:999px; background:#1d2436; font-size:11px; color:#9fb3d1; }
</style></head>
<body>
<header><h1>🦞 脚本浏览器 <span>本地 API</span></h1>
<div class="sub">Cookie 读取 · 用户脚本安装 · 页面控制</div></header>
<main>
<section>
  <h2>令牌</h2>
  <input id="token" placeholder="在 App「端口」页复制令牌粘贴到这里">
  <div class="row"><button onclick="saveToken()">保存</button><span id="tstate" class="sub"></span></div>
</section>

<section>
  <h2>状态</h2>
  <div id="health" class="sub">加载中…</div>
</section>

<section>
  <h2>Cookie 查询</h2>
  <input id="domain" placeholder="域名过滤，如 example.com（留空=全部）">
  <div class="row"><button onclick="loadCookies()">读取 Cookie</button>
  <button class="ghost" onclick="copyCookie()">复制 Cookie 头</button></div>
  <div id="cookies" style="margin-top:10px;max-height:320px;overflow:auto"></div>
</section>

<section>
  <h2>安装用户脚本</h2>
  <textarea id="us" placeholder="把 .user.js 全文粘贴到这里（含 // ==UserScript== 元数据块）"></textarea>
  <div class="row"><button onclick="installScript()">安装脚本</button><span id="istate" class="sub"></span></div>
</section>

<section>
  <h2>已安装脚本</h2>
  <div id="scripts" class="sub">—</div>
</section>

<section>
  <h2>执行 JS / 打开网址</h2>
  <input id="js" placeholder="document.title">
  <div class="row"><button onclick="runJS()">执行</button><span id="jstate" class="sub"></span></div>
  <input id="openurl" placeholder="https://example.com" style="margin-top:8px">
  <div class="row"><button class="ghost" onclick="openURL()">在 App 中打开</button></div>
</section>
</main>
<script>
var T = localStorage.getItem('sb_token') || '';
document.getElementById('token').value = T;
function saveToken(){ T = document.getElementById('token').value.trim(); localStorage.setItem('sb_token', T); document.getElementById('tstate').textContent = '已保存'; refresh(); }
function h(extra){ var o = { 'X-Token': T }; if (extra) for (var k in extra) o[k]=extra[k]; return o; }
function api(path, opt){ return fetch(path, opt || {}).then(function(r){ return r.text().then(function(t){ var j; try{ j = JSON.parse(t); }catch(e){ j = {raw:t}; } j._status = r.status; return j; }); }); }
function refresh(){
  api('/health').then(function(j){
    document.getElementById('health').innerHTML = j.ok
      ? ('<span class="ok">● 运行中</span> · 端口 <code>'+j.port+'</code> · 脚本 '+j.scripts+' 个 · 密码 '+j.credentials+' 项<br>当前页面：<code>'+(j.url||'—')+'</code>')
      : '<span class="err">● 未运行</span>';
  });
  api('/api/userscripts').then(function(j){
    if(!j.ok) { document.getElementById('scripts').innerHTML = '<span class="err">'+j.error+'</span>'; return; }
    if(!j.scripts.length) { document.getElementById('scripts').textContent='还没有脚本'; return; }
    document.getElementById('scripts').innerHTML = '<table><tr><th>名称</th><th>匹配</th><th>状态</th><th></th></tr>' +
      j.scripts.map(function(s){
        return '<tr><td>'+esc(s.name)+' <span class="pill">v'+esc(s.version)+'</span></td><td><code>'+esc((s.matches||[]).join(', ')||'全部')+'</code></td>'+
        '<td>'+(s.enabled?'✅':'⏸')+'</td><td><button class="ghost" onclick="toggle(\''+s.id+'\')">切换</button> <button class="ghost" onclick="del(\''+s.id+'\')">卸载</button></td></tr>';
      }).join('') + '</table>';
  });
}
function esc(s){ return String(s==null?'':s).replace(/[&<>"]/g, function(c){ return {'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;'}[c]; }); }
function loadCookies(){
  var d = document.getElementById('domain').value.trim();
  api('/api/cookies?domain='+encodeURIComponent(d), {headers:h()}).then(function(j){
    if(!j.ok){ document.getElementById('cookies').innerHTML='<span class="err">'+esc(j.error)+'</span>'; return; }
    if(!j.cookies.length){ document.getElementById('cookies').textContent='没有匹配的 cookie'; return; }
    window.__ch = j.cookie_header;
    document.getElementById('cookies').innerHTML = '<div class="sub">共 '+j.count+' 条</div><table><tr><th>域名</th><th>名称</th><th>值</th><th>属性</th></tr>'+
      j.cookies.map(function(c){ return '<tr><td>'+esc(c.domain)+'</td><td>'+esc(c.name)+'</td><td><code>'+esc(c.value)+'</code></td><td class="sub">'+(c.httpOnly?'HttpOnly ':'')+(c.secure?'Secure ':'')+(c.session?'Session':'')+'</td></tr>'; }).join('')+'</table>';
  });
}
function copyCookie(){ if(window.__ch){ navigator.clipboard.writeText(window.__ch); alert('已复制 Cookie 头'); } }
function installScript(){
  var src = document.getElementById('us').value;
  api('/api/userscripts', { method:'POST', headers:h({'Content-Type':'text/plain'}), body: src }).then(function(j){
    document.getElementById('istate').innerHTML = j.ok ? '<span class="ok">✅ 已安装 '+esc(j.script.name)+'</span>' : '<span class="err">'+esc(j.error)+'</span>';
    refresh();
  });
}
function toggle(id){ api('/api/userscripts/'+id+'/toggle',{method:'POST',headers:h()}).then(refresh); }
function del(id){ if(confirm('确定卸载？')) api('/api/userscripts/'+id,{method:'DELETE',headers:h()}).then(refresh); }
function runJS(){
  api('/api/js',{method:'POST',headers:h({'Content-Type':'application/json'}),body:JSON.stringify({script:document.getElementById('js').value})}).then(function(j){
    document.getElementById('jstate').innerHTML = j.ok ? '<span class="ok">'+esc(JSON.stringify(j.result))+'</span>' : '<span class="err">'+esc(j.error)+'</span>';
  });
}
function openURL(){
  api('/api/open',{method:'POST',headers:h({'Content-Type':'application/json'}),body:JSON.stringify({url:document.getElementById('openurl').value})}).then(function(j){
    alert(j.ok ? '已发送' : j.error);
  });
}
refresh();
setInterval(refresh, 5000);
</script>
</body></html>
"""#
}
