import Foundation

/// 把全部已启用脚本打包成一段注入到文档头部的引导代码。
/// 匹配在 JS 侧完成，因此增删脚本只需重建引导脚本并 reload。
enum ScriptEngine {

    static func bootstrap(scripts: [UserScript]) -> String {
        let enabled = scripts.filter { $0.enabled && !$0.source.isEmpty }
        let payload: [[String: Any]] = enabled.map { s in
            [
                "id": s.id,
                "name": s.name,
                "version": s.version,
                "matches": s.matches,
                "excludes": s.excludes,
                "runAt": s.runAt,
                "source": s.source
            ]
        }
        var json = "[]"
        if let data = try? JSONSerialization.data(withJSONObject: payload, options: [.withoutEscapingSlashes]),
           var str = String(data: data, encoding: .utf8) {
            str = str.replacingOccurrences(of: "\u{2028}", with: "\\u2028")
                .replacingOccurrences(of: "\u{2029}", with: "\\u2029")
            json = str
        }

        return template.replacingOccurrences(of: "__SB_SCRIPTS__", with: json)
            .replacingOccurrences(of: "__SB_COUNT__", with: "\(enabled.count)")
    }

    private static let template = """
    (function () {
      if (window.__SB_LOADED__) { return; }
      window.__SB_LOADED__ = true;
      var SCRIPTS = __SB_SCRIPTS__;
      window.__SB__ = { version: "1.0", scripts: __SB_COUNT__, native: !!(window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.sbLog) };

      function log(level, name, args) {
        try {
          console[level === 'error' ? 'error' : 'log'].apply(console, ['[脚本浏览器][' + name + ']'].concat(args));
        } catch (e) {}
        try {
          if (window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.sbLog) {
            window.webkit.messageHandlers.sbLog.postMessage({ script: name, level: level, message: Array.prototype.slice.call(args).map(function (a) { try { return typeof a === 'object' ? JSON.stringify(a) : String(a); } catch (e) { return String(a); } }).join(' ') });
          }
        } catch (e) {}
      }

      function toRe(pat) {
        if (pat === '<all_urls>') { return /^https?:\\/\\//i; }
        var esc = String(pat).replace(/[.+?^${}()|[\\]\\\\]/g, '\\\\$&').replace(/\\*/g, '.*');
        return new RegExp('^' + esc + '$', 'i');
      }

      function hit(list, url) {
        for (var i = 0; i < list.length; i++) {
          try { if (toRe(list[i]).test(url)) { return true; } } catch (e) {}
        }
        return false;
      }

      function shouldRun(s, url) {
        var m = s.matches || [];
        var x = s.excludes || [];
        if (x.length && hit(x, url)) { return false; }
        if (!m.length) { return true; }
        return hit(m, url);
      }

      function addStyle(css) {
        var el = document.createElement('style');
        el.textContent = css;
        (document.head || document.documentElement || document).appendChild(el);
        return el;
      }

      function makeGM(s) {
        var prefix = '__sb_' + s.id + '_';
        function get(k, d) {
          try { var v = localStorage.getItem(prefix + k); return v === null ? d : JSON.parse(v); } catch (e) { return d; }
        }
        function set(k, v) {
          try { localStorage.setItem(prefix + k, JSON.stringify(v)); } catch (e) {}
        }
        function del(k) { try { localStorage.removeItem(prefix + k); } catch (e) {} }
        function keys() {
          var out = [];
          try {
            for (var i = 0; i < localStorage.length; i++) {
              var k = localStorage.key(i);
              if (k && k.indexOf(prefix) === 0) { out.push(k.substring(prefix.length)); }
            }
          } catch (e) {}
          return out;
        }
        function notify(title, opts) {
          opts = opts || {};
          try {
            var t = typeof title === 'string' ? title : (title && title.text) || '脚本通知';
            var b = opts.text || '';
            log('info', s.name, ['通知: ' + t + (b ? ' — ' + b : '')]);
          } catch (e) {}
        }
        function xhr(o) {
          o = o || {};
          var opt = { method: o.method || 'GET', headers: o.headers || {} };
          if (o.data) { opt.body = o.data; }
          if (o.timeout) {
            var ctrl = new AbortController();
            opt.signal = ctrl.signal;
            setTimeout(function () { ctrl.abort(); }, o.timeout);
          }
          fetch(o.url, opt).then(function (r) { return r.text().then(function (t) { return { r: r, t: t }; }); })
            .then(function (x) {
              if (o.onload) { o.onload({ status: x.r.status, statusText: x.r.statusText, responseText: x.t, finalUrl: x.r.url, responseHeaders: '' }); }
            })
            .catch(function (e) { if (o.onerror) { o.onerror(e); } });
        }
        return { get: get, set: set, del: del, keys: keys, notify: notify, xhr: xhr };
      }

      function run(s) {
        var gm = makeGM(s);
        var info = { script: { name: s.name, version: s.version, namespace: '' }, scriptMetaStr: '', version: '1.0' };
        try {
          var fn = new Function(
            'GM_info', 'GM_setValue', 'GM_getValue', 'GM_deleteValue', 'GM_listValues',
            'GM_addStyle', 'GM_log', 'GM_notification', 'GM_xmlhttpRequest',
            'unsafeWindow', 'window', 'document', 'console',
            s.source + '\\n//# sourceURL=sb-' + s.id + '.user.js'
          );
          fn(info, gm.set, gm.get, gm.del, gm.keys, addStyle,
             function () { log('info', s.name, Array.prototype.slice.call(arguments)); },
             gm.notify, gm.xhr, window, window, document, console);
        } catch (e) {
          log('error', s.name, ['执行失败: ' + (e && e.message ? e.message : String(e))]);
        }
      }

      function startAll() {
        var url = location.href;
        for (var i = 0; i < SCRIPTS.length; i++) {
          var s = SCRIPTS[i];
          try {
            if (!shouldRun(s, url)) { continue; }
            var at = (s.runAt || 'document-end').toLowerCase();
            if (at.indexOf('start') >= 0) { run(s); }
            else if (document.readyState === 'loading') {
              (function (sc) { document.addEventListener('DOMContentLoaded', function () { run(sc); }, false); })(s);
            } else { run(s); }
          } catch (e) { log('error', s.name || '?', [String(e)]); }
        }
      }

      startAll();
    })();
    """
}
