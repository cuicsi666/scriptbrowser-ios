import Foundation
import Network

// MARK: - 请求 / 响应

struct HTTPRequest {
    var method: String = "GET"
    var path: String = "/"
    var query: [String: String] = [:]
    var headers: [String: String] = [:]
    var body: Data = Data()
    var remote: String = ""

    var bodyString: String { String(data: body, encoding: .utf8) ?? "" }

    func jsonBody() -> [String: Any]? {
        (try? JSONSerialization.jsonObject(with: body)) as? [String: Any]
    }
}

struct HTTPResponse {
    var status: Int = 200
    var contentType: String = "application/json; charset=utf-8"
    var body: Data = Data()
    var extra: [String: String] = [:]

    static func json(_ obj: Any, status: Int = 200) -> HTTPResponse {
        let data = (try? JSONSerialization.data(withJSONObject: obj, options: [.withoutEscapingSlashes, .prettyPrinted])) ?? Data("{}".utf8)
        return HTTPResponse(status: status, contentType: "application/json; charset=utf-8", body: data)
    }

    static func text(_ s: String, status: Int = 200, type: String = "text/plain; charset=utf-8") -> HTTPResponse {
        HTTPResponse(status: status, contentType: type, body: Data(s.utf8))
    }

    static func error(_ msg: String, status: Int = 400) -> HTTPResponse {
        .json(["ok": false, "error": msg], status: status)
    }

    static func reason(_ code: Int) -> String {
        switch code {
        case 200: return "OK"
        case 201: return "Created"
        case 204: return "No Content"
        case 400: return "Bad Request"
        case 401: return "Unauthorized"
        case 403: return "Forbidden"
        case 404: return "Not Found"
        case 405: return "Method Not Allowed"
        case 413: return "Payload Too Large"
        case 500: return "Internal Server Error"
        default: return "OK"
        }
    }
}

// MARK: - HTTP 解析

enum HTTPParser {
    static func parse(_ data: Data) -> HTTPRequest? {
        guard let sep = data.range(of: Data("\r\n\r\n".utf8)) else {
            return data.count > 256 * 1024 ? HTTPRequest(method: "__BAD__") : nil
        }
        guard let head = String(data: data[data.startIndex..<sep.lowerBound], encoding: .utf8) else { return nil }
        var lines = head.components(separatedBy: "\r\n")
        guard !lines.isEmpty else { return nil }
        let first = lines.removeFirst().split(separator: " ")
        guard first.count >= 2 else { return nil }
        let method = String(first[0]).uppercased()
        let rawTarget = String(first[1])

        var path = rawTarget
        var query: [String: String] = [:]
        if let qi = rawTarget.firstIndex(of: "?") {
            path = String(rawTarget[..<qi])
            let qs = String(rawTarget[rawTarget.index(after: qi)...])
            for pair in qs.split(separator: "&") {
                let kv = pair.split(separator: "=", maxSplits: 1)
                guard let k0 = kv.first else { continue }
                let k = String(k0).replacingOccurrences(of: "+", with: " ").removingPercentEncoding ?? String(k0)
                var v = ""
                if kv.count > 1 {
                    let v0 = String(kv[1]).replacingOccurrences(of: "+", with: " ")
                    v = v0.removingPercentEncoding ?? v0
                }
                query[k] = v
            }
        }
        if let decoded = path.removingPercentEncoding { path = decoded }

        var headers: [String: String] = [:]
        for line in lines {
            guard let ci = line.firstIndex(of: ":") else { continue }
            let k = line[..<ci].trimmingCharacters(in: .whitespaces).lowercased()
            let v = line[line.index(after: ci)...].trimmingCharacters(in: .whitespaces)
            headers[k] = v
        }

        let length = Int(headers["content-length"] ?? "0") ?? 0
        if length > 64 * 1024 * 1024 { return HTTPRequest(method: "__BAD__") }
        let rest = data[sep.upperBound...]
        if rest.count < length { return nil }
        let body = Data(rest.prefix(length))
        return HTTPRequest(method: method, path: path, query: query, headers: headers, body: body)
    }
}

// MARK: - 服务器

final class HTTPServer: ObservableObject {
    @Published var running = false
    @Published var actualPort: Int = 0
    @Published var lastError: String?
    @Published var hits: Int = 0

    private var listener: NWListener?
    private let queue = DispatchQueue(label: "com.cuicsi.scriptbrowser.server")
    var handler: ((HTTPRequest, @escaping (HTTPResponse) -> Void) -> Void)?

    func start(port: UInt16) {
        stop()
        lastError = nil
        do {
            let params = NWParameters.tcp
            params.allowLocalEndpointReuse = true
            params.acceptLocalOnly = false
            let l = try NWListener(using: params, on: NWEndpoint.Port(rawValue: port)!)
            l.newConnectionHandler = { [weak self] conn in
                guard let self else { conn.cancel(); return }
                conn.start(queue: self.queue)
                self.receive(conn, buffer: Data())
            }
            l.stateUpdateHandler = { [weak self] state in
                DispatchQueue.main.async {
                    guard let self else { return }
                    switch state {
                    case .ready:
                        self.running = true
                        self.actualPort = Int(l.port?.rawValue ?? port)
                        self.lastError = nil
                    case .failed(let err):
                        self.running = false
                        self.lastError = "监听失败：\(err.localizedDescription)"
                    case .cancelled:
                        self.running = false
                    default: break
                    }
                }
            }
            l.start(queue: queue)
            listener = l
        } catch {
            lastError = "无法绑定端口 \(port)：\(error.localizedDescription)"
            running = false
        }
    }

    func stop() {
        listener?.cancel()
        listener = nil
        running = false
    }

    private func receive(_ conn: NWConnection, buffer: Data) {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 1 << 20) { [weak self] data, _, isComplete, error in
            guard let self else { conn.cancel(); return }
            var buf = buffer
            if let data, !data.isEmpty { buf.append(data) }
            if error != nil { conn.cancel(); return }
            if let req = HTTPParser.parse(buf) {
                if req.method == "__BAD__" { conn.cancel(); return }
                self.dispatch(req, conn)
                return
            }
            if isComplete { conn.cancel(); return }
            self.receive(conn, buffer: buf)
        }
    }

    private func dispatch(_ req: HTTPRequest, _ conn: NWConnection) {
        DispatchQueue.main.async {
            self.hits += 1
            guard let handler = self.handler else {
                self.send(.error("服务未就绪", status: 503), conn)
                return
            }
            handler(req) { [weak self] resp in
                self?.send(resp, conn)
            }
        }
    }

    private func send(_ resp: HTTPResponse, _ conn: NWConnection) {
        var head = "HTTP/1.1 \(resp.status) \(HTTPResponse.reason(resp.status))\r\n"
        head += "Content-Type: \(resp.contentType)\r\n"
        head += "Content-Length: \(resp.body.count)\r\n"
        head += "Access-Control-Allow-Origin: *\r\n"
        head += "Access-Control-Allow-Headers: *\r\n"
        head += "Access-Control-Allow-Methods: GET, POST, PUT, DELETE, OPTIONS\r\n"
        head += "Access-Control-Max-Age: 86400\r\n"
        head += "Cache-Control: no-store\r\n"
        for (k, v) in resp.extra { head += "\(k): \(v)\r\n" }
        head += "Connection: close\r\n\r\n"
        var out = Data(head.utf8)
        out.append(resp.body)
        conn.send(content: out, completion: .contentProcessed { _ in conn.cancel() })
    }
}
