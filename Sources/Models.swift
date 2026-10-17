import Foundation
import CryptoKit

// MARK: - 用户脚本

struct UserScript: Identifiable, Codable, Equatable {
    var id: String = UUID().uuidString
    var name: String = "未命名脚本"
    var namespace: String = ""
    var version: String = "1.0"
    var desc: String = ""
    var matches: [String] = []
    var excludes: [String] = []
    var runAt: String = "document-end"
    var enabled: Bool = true
    var source: String = ""
    var installedAt: Date = Date()

    var host: String {
        if let m = matches.first {
            return m.replacingOccurrences(of: "https://", with: "")
                .replacingOccurrences(of: "http://", with: "")
                .replacingOccurrences(of: "*.", with: "")
                .components(separatedBy: "/").first ?? m
        }
        return "全部网站"
    }

    var dict: [String: Any] {
        [
            "id": id, "name": name, "namespace": namespace, "version": version,
            "description": desc, "matches": matches, "excludes": excludes,
            "run_at": runAt, "enabled": enabled,
            "installed_at": ISO8601DateFormatter().string(from: installedAt),
            "size": source.count
        ]
    }

    /// 解析 ==UserScript== 元数据块
    static func parse(source: String) -> UserScript? {
        var s = UserScript()
        s.source = source
        var matches: [String] = []
        var excludes: [String] = []
        var foundName = false

        for raw in source.components(separatedBy: .newlines) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard line.hasPrefix("//") else {
                if !line.isEmpty && !line.hasPrefix("/*") && !line.hasPrefix("*") && !line.hasPrefix("//") { break }
                continue
            }
            let body = line.dropFirst(2).trimmingCharacters(in: .whitespaces)
            guard body.hasPrefix("@") else { continue }
            let parts = body.dropFirst().split(separator: " ", maxSplits: 1).map(String.init)
            guard let key = parts.first else { continue }
            let value = parts.count > 1 ? parts[1].trimmingCharacters(in: .whitespaces) : ""
            switch key.lowercased() {
            case "name": s.name = value; foundName = true
            case "namespace": s.namespace = value
            case "version": s.version = value
            case "description": s.desc = value
            case "match", "include": if !value.isEmpty { matches.append(value) }
            case "exclude": if !value.isEmpty { excludes.append(value) }
            case "run-at": s.runAt = value.lowercased()
            default: break
            }
        }
        guard foundName || !matches.isEmpty || source.contains("==UserScript==") else { return nil }
        s.matches = matches
        s.excludes = excludes
        return s
    }
}

// MARK: - 密码凭据

struct Credential: Identifiable, Codable, Equatable {
    var id: String = UUID().uuidString
    var title: String = ""
    var url: String = ""
    var username: String = ""
    var password: String = ""
    var note: String = ""

    var domain: String {
        guard let h = URL(string: url)?.host?.lowercased() else {
            return url.lowercased()
        }
        return h.hasPrefix("www.") ? String(h.dropFirst(4)) : h
    }

    var dict: [String: Any] {
        ["id": id, "title": title, "url": url, "username": username, "password": password, "note": note, "domain": domain]
    }
}

// MARK: - 设置

struct AppSettings: Codable, Equatable {
    var port: Int = 8899
    var token: String = AppSettings.randomToken()
    var requireToken: Bool = true
    var autoStart: Bool = true
    var keepAlive: Bool = true
    var injectScripts: Bool = true

    static func randomToken() -> String {
        let chars = Array("abcdefghijkmnpqrstuvwxyzABCDEFGHJKLMNPQRSTUVWXYZ23456789")
        return String((0..<24).map { _ in chars.randomElement()! })
    }
}

// MARK: - 加密（AES-GCM，密钥由固定种子派生，保证重装前后可解）

enum Vault {
    private static var key: SymmetricKey {
        let seed = "com.cuicsi.scriptbrowser.vault.v1::xiaolongxia"
        return SymmetricKey(data: Data(SHA256.hash(data: Data(seed.utf8))))
    }

    static func seal(_ data: Data) -> Data? {
        guard let box = try? AES.GCM.seal(data, using: key) else { return nil }
        return box.combined
    }

    static func open(_ data: Data) -> Data? {
        guard let box = try? AES.GCM.SealedBox(combined: data) else { return nil }
        return try? AES.GCM.open(box, using: key)
    }
}

// MARK: - 持久化仓库

@MainActor
final class Store: ObservableObject {
    static let shared = Store()

    @Published var scripts: [UserScript] = [] { didSet { saveScripts() } }
    @Published var credentials: [Credential] = [] { didSet { saveCredentials() } }
    @Published var settings: AppSettings = AppSettings() { didSet { saveSettings() } }

    let root: URL
    private var loading = true

    init() {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        root = docs.appendingPathComponent("ScriptBrowser", isDirectory: true)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        load()
        loading = false
    }

    // MARK: 加载

    private func load() {
        if let d = try? Data(contentsOf: root.appendingPathComponent("scripts.json")),
           let list = try? JSONDecoder().decode([UserScript].self, from: d) {
            scripts = list
        }
        if let d = try? Data(contentsOf: root.appendingPathComponent("credentials.enc")),
           let plain = Vault.open(d),
           let list = try? JSONDecoder().decode([Credential].self, from: plain) {
            credentials = list
        }
        if let d = try? Data(contentsOf: root.appendingPathComponent("settings.json")),
           let s = try? JSONDecoder().decode(AppSettings.self, from: d) {
            settings = s
        }
    }

    // MARK: 保存

    private func saveScripts() {
        guard !loading else { return }
        if let d = try? JSONEncoder().encode(scripts) {
            try? d.write(to: root.appendingPathComponent("scripts.json"), options: .atomic)
        }
    }

    private func saveCredentials() {
        guard !loading else { return }
        if let raw = try? JSONEncoder().encode(credentials), let d = Vault.seal(raw) {
            try? d.write(to: root.appendingPathComponent("credentials.enc"), options: .atomic)
        }
    }

    private func saveSettings() {
        guard !loading else { return }
        if let d = try? JSONEncoder().encode(settings) {
            try? d.write(to: root.appendingPathComponent("settings.json"), options: .atomic)
        }
    }

    // MARK: 脚本操作

    @discardableResult
    func install(source: String, enabled: Bool = true) -> UserScript? {
        guard var s = UserScript.parse(source: source) else { return nil }
        s.enabled = enabled
        // 同 name+namespace 视为更新
        if let idx = scripts.firstIndex(where: { $0.name == s.name && $0.namespace == s.namespace }) {
            s.id = scripts[idx].id
            s.installedAt = scripts[idx].installedAt
            scripts[idx] = s
            return s
        }
        scripts.append(s)
        return s
    }

    func removeScript(id: String) {
        scripts.removeAll { $0.id == id }
    }

    func toggleScript(id: String) {
        guard let i = scripts.firstIndex(where: { $0.id == id }) else { return }
        scripts[i].enabled.toggle()
    }

    // MARK: 密码操作

    func importCSV(_ text: String) -> (added: Int, skipped: Int) {
        let rows = CSVParser.parse(text)
        guard !rows.isEmpty else { return (0, 0) }
        var header = rows[0].map { $0.lowercased().trimmingCharacters(in: .whitespaces) }
        var start = 1
        // 没有表头则按 Chrome 顺序 name,url,username,password
        if !header.contains("url") && !header.contains("password") {
            header = ["name", "url", "username", "password"]
            start = 0
        }
        func idx(_ names: [String]) -> Int? {
            for n in names { if let i = header.firstIndex(of: n) { return i } }
            return nil
        }
        let iName = idx(["name", "title"]), iUrl = idx(["url", "website", "origin"]),
            iUser = idx(["username", "login", "user"]), iPass = idx(["password", "pass"]),
            iNote = idx(["note", "notes", "comment"])

        var added = 0, skipped = 0
        for r in rows[start...] {
            func val(_ i: Int?) -> String { (i != nil && i! < r.count) ? r[i!] : "" }
            let url = val(iUrl), user = val(iUser), pass = val(iPass)
            if url.isEmpty || (user.isEmpty && pass.isEmpty) { skipped += 1; continue }
            if credentials.contains(where: { $0.url == url && $0.username == user && $0.password == pass }) {
                skipped += 1
                continue
            }
            credentials.append(Credential(title: val(iName), url: url, username: user, password: pass, note: val(iNote)))
            added += 1
        }
        return (added, skipped)
    }

    func credentials(for urlString: String) -> [Credential] {
        let host = credentialHost(urlString)
        guard !host.isEmpty else { return [] }
        return credentials.filter { c in
            let d = c.domain
            return !d.isEmpty && (host == d || host.hasSuffix("." + d) || d.hasSuffix("." + host))
        }
    }

    private func credentialHost(_ s: String) -> String {
        guard let h = URL(string: s)?.host?.lowercased() else { return "" }
        return h.hasPrefix("www.") ? String(h.dropFirst(4)) : h
    }
}

// MARK: - RFC4180 CSV 解析

enum CSVParser {
    static func parse(_ text: String) -> [[String]] {
        var rows: [[String]] = []
        var row: [String] = []
        var field = ""
        var inQuotes = false
        var i = text.startIndex
        // 去 BOM
        var body = text
        if body.hasPrefix("\u{FEFF}") { body.removeFirst() }
        i = body.startIndex

        while i < body.endIndex {
            let c = body[i]
            if inQuotes {
                if c == "\"" {
                    let next = body.index(after: i)
                    if next < body.endIndex && body[next] == "\"" {
                        field.append("\"")
                        i = body.index(after: next)
                        continue
                    } else {
                        inQuotes = false
                    }
                } else {
                    field.append(c)
                }
            } else {
                if c == "\"" {
                    inQuotes = true
                } else if c == "," {
                    row.append(field); field = ""
                } else if c == "\n" {
                    row.append(field); field = ""
                    if !(row.count == 1 && row[0].isEmpty) { rows.append(row) }
                    row = []
                } else if c == "\r" {
                    // 忽略
                } else {
                    field.append(c)
                }
            }
            i = body.index(after: i)
        }
        if !field.isEmpty || !row.isEmpty {
            row.append(field)
            if !(row.count == 1 && row[0].isEmpty) { rows.append(row) }
        }
        return rows
    }
}
