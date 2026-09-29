import Foundation
import Network

/// 本机 HTTP API：让 AI agent / CLI / MCP 读写画板。
/// - 仅监听 127.0.0.1；端口可配（--api-port / defaults api-port），被占用自动顺延
/// - 真实 endpoint 写入发现文件 ~/.drawpad/api.json（agent 自识别入口）
/// - 所有写操作走 MacAppModel 既有管道：画布渲染 + iPad 同步 + 落盘自动完成
final class AIAPI {
    static let shared = AIAPI()

    private var listener: NWListener?
    private(set) var port: Int = 7777
    private weak var model: MacAppModel?
    private let queue = DispatchQueue(label: "com.hujing.drawpad.aiapi")

    /// 发现文件路径（agent 自识别约定：先读它拿 endpoint）。
    static var discoveryURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".drawpad/api.json")
    }

    func start(model: MacAppModel) {
        self.model = model
        let configured = configuredPort()
        for candidate in configured..<(configured + 20) {
            do {
                let params = NWParameters.tcp
                params.requiredLocalEndpoint = NWEndpoint.hostPort(
                    host: "127.0.0.1", port: NWEndpoint.Port(rawValue: UInt16(candidate))!
                )
                let listener = try NWListener(using: params)
                listener.newConnectionHandler = { [weak self] connection in
                    self?.accept(connection)
                }
                listener.start(queue: queue)
                self.listener = listener
                port = candidate
                writeDiscoveryFile()
                print("[DrawPad] AI API 已启动: http://127.0.0.1:\(candidate)（发现文件 \(Self.discoveryURL.path)）")
                return
            } catch {
                continue
            }
        }
        print("[DrawPad] AI API 启动失败：\(configured) 起的 20 个端口都被占用")
    }

    func stop() {
        listener?.cancel()
        listener = nil
        try? FileManager.default.removeItem(at: Self.discoveryURL)
    }

    private func configuredPort() -> Int {
        if let index = CommandLine.arguments.firstIndex(of: "--api-port"),
           index + 1 < CommandLine.arguments.count,
           let value = Int(CommandLine.arguments[index + 1]), value > 1024, value < 65536 {
            return value
        }
        let defaultsValue = UserDefaults.standard.integer(forKey: "api-port")
        return defaultsValue > 1024 ? defaultsValue : 7777
    }

    private func writeDiscoveryFile() {
        let info: [String: Any] = [
            "endpoint": "http://127.0.0.1:\(port)",
            "port": port,
            "pid": ProcessInfo.processInfo.processIdentifier,
            "version": 1,
            "docs": "GET /api/health 返回能力清单；README「AI 接口」一节有完整说明",
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: info, options: [.prettyPrinted, .sortedKeys]) else {
            return
        }
        let url = Self.discoveryURL
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: url, options: .atomic)
    }

    // MARK: - HTTP 连接处理

    private var connections: [ObjectIdentifier: HTTPConnection] = [:]

    private func accept(_ connection: NWConnection) {
        let http = HTTPConnection(connection: connection) { [weak self] request in
            self?.handle(request)
        }
        connections[ObjectIdentifier(http)] = http
        http.onClose = { [weak self, weak http] in
            guard let http else { return }
            self?.connections.removeValue(forKey: ObjectIdentifier(http))
        }
        http.start()
    }

    // MARK: - 路由

    private func handle(_ request: HTTPRequest) {
        // 导入走异步路径：文件可能在 iCloud 同步目录，open() 会阻塞等待下载，
        // 决不能占用主线程。
        if request.path == "/api/import", request.method == "POST" {
            performImport(request) { [weak self] status, body in
                self?.queue.async {
                    self?.respond(request, status: status, body: body)
                }
            }
            return
        }
        // 其余路由：主线程访问模型，然后回 queue 回响应
        DispatchQueue.main.async { [weak self] in
            guard let self, let model = self.model else {
                self?.respond(request, status: "500 Internal Server Error", body: ["error": "app 未就绪"])
                return
            }
            let (status, body) = Self.route(request, model: model)
            self.queue.async {
                self.respond(request, status: status, body: body)
            }
        }
    }

    /// 后台读文件 + 解析 → 主线程建板写场景 → 回调响应。
    private func performImport(
        _ request: HTTPRequest,
        completion: @escaping (String, [String: Any]) -> Void
    ) {
        guard let rawPath = request.json?["path"] as? String else {
            completion("400 Bad Request", ["error": "需要 path"])
            return
        }
        let url = URL(fileURLWithPath: (rawPath as NSString).expandingTildeInPath)
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let text = try? String(contentsOf: url, encoding: .utf8),
                  let scene = ExcalidrawImport.parseScene(fromText: text) else {
                completion("400 Bad Request", ["error": "无法解析文件（支持 .excalidraw / .excalidraw.md；若在 iCloud 目录请确认文件已下载到本地）"])
                return
            }
            DispatchQueue.main.async { [weak self] in
                guard let self, let model = self.model else {
                    completion("500 Internal Server Error", ["error": "app 未就绪"])
                    return
                }
                let name = (request.json?["name"] as? String)
                    ?? ExcalidrawImport.pageName(fromFileName: url.lastPathComponent)
                let folderID: UUID
                if let raw = request.json?["folderId"] as? String, let uuid = UUID(uuidString: raw) {
                    folderID = uuid
                } else {
                    folderID = model.selectedFolderID ?? model.store.folders.last?.id
                        ?? model.store.createFolder(name: "导入").id
                }
                let page = model.store.createPage(folderID: folderID, name: name)
                model.apiSetScene(page.id, elementsJSON: scene)
                model.pushLibrary()
                completion("200 OK", ["id": page.id.uuidString, "name": page.name])
            }
        }
    }

    private func respond(_ request: HTTPRequest, status: String, body: [String: Any]) {
        let data = (try? JSONSerialization.data(withJSONObject: body, options: [.sortedKeys]))
            ?? Data("{}".utf8)
        request.respond(status: status, contentType: "application/json; charset=utf-8", body: data)
    }

    private static func route(_ request: HTTPRequest, model: MacAppModel) -> (String, [String: Any]) {
        let path = request.path
        let method = request.method
        let query = request.query

        // GET /api/health —— 能力自述
        if path == "/api/health", method == "GET" {
            return ("200 OK", [
                "ok": true,
                "version": 1,
                "ipad": model.clientName ?? "未连接",
                "endpoints": [
                    "GET /api/health",
                    "GET /api/folders",
                    "POST /api/folders {name}",
                    "GET /api/boards?folder=<uuid>",
                    "POST /api/boards {name, folderId?}",
                    "DELETE /api/boards/<id>",
                    "GET /api/boards/<id>/scene",
                    "PUT /api/boards/<id>/scene {elements:[...]}",
                    "POST /api/boards/<id>/elements {elements:[简写...]}",
                    "DELETE /api/boards/<id>/elements {ids:[...]}",
                    "POST /api/import {path, folderId?, name?}",
                ],
                "elementShorthand": [
                    "type": "rectangle|ellipse|diamond|text|arrow|line|freedraw",
                    "通用字段": "id,x,y,width,height,angle,stroke,fill,fillStyle,strokeWidth,opacity,roughness",
                    "text": "text,fontSize,align,textColor",
                    "shape 额外": "label（自动生成绑定文本）",
                    "arrow/line": "from,to（元素 id 自动连到中心）或 x1,y1,x2,y2；label",
                ],
            ])
        }

        // 项目
        if path == "/api/folders" {
            switch method {
            case "GET":
                let folders = model.store.folders.map { ["id": $0.id.uuidString, "name": $0.name, "boards": $0.pageIDs.count] }
                return ("200 OK", ["folders": folders])
            case "POST":
                guard let name = request.json?["name"] as? String, !name.isEmpty else {
                    return ("400 Bad Request", ["error": "需要 name"])
                }
                let folder = model.store.createFolder(name: name)
                model.pushLibrary()
                return ("200 OK", ["id": folder.id.uuidString, "name": folder.name])
            default:
                return ("405 Method Not Allowed", ["error": "不支持的方法"])
            }
        }

        // 画板列表 / 新建
        if path == "/api/boards" {
            switch method {
            case "GET":
                var folders = model.store.folders
                if let folderID = query["folder"], let uuid = UUID(uuidString: folderID) {
                    folders = folders.filter { $0.id == uuid }
                }
                let boards = folders.flatMap { folder in
                    model.store.pages(in: folder.id).map { page in
                        [
                            "id": page.id.uuidString,
                            "name": page.name,
                            "folderId": folder.id.uuidString,
                            "folderName": folder.name,
                        ] as [String: Any]
                    }
                }
                return ("200 OK", ["boards": boards])
            case "POST":
                guard let name = request.json?["name"] as? String, !name.isEmpty else {
                    return ("400 Bad Request", ["error": "需要 name"])
                }
                let folderID: UUID
                if let raw = request.json?["folderId"] as? String, let uuid = UUID(uuidString: raw) {
                    folderID = uuid
                } else {
                    folderID = model.selectedFolderID ?? model.store.folders.last?.id
                        ?? model.store.createFolder(name: "导入").id
                }
                let page = model.store.createPage(folderID: folderID, name: name)
                model.pushLibrary()
                return ("200 OK", ["id": page.id.uuidString, "name": page.name, "folderId": folderID.uuidString])
            default:
                return ("405 Method Not Allowed", ["error": "不支持的方法"])
            }
        }

        // /api/boards/<id>[/scene|/elements]
        let parts = path.components(separatedBy: "/").filter { !$0.isEmpty }
        // ["api", "boards", id, ...]
        guard parts.count >= 3, parts[0] == "api", parts[1] == "boards",
              let boardID = UUID(uuidString: parts[2]) else {
            return ("404 Not Found", ["error": "未知路径 \(path)"])
        }
        guard model.store.pageMeta(boardID) != nil else {
            return ("404 Not Found", ["error": "画板不存在"])
        }

        if parts.count == 3 {
            switch method {
            case "DELETE":
                model.deletePageLocal(boardID)
                return ("200 OK", ["ok": true])
            default:
                return ("405 Method Not Allowed", ["error": "不支持的方法"])
            }
        }

        if parts.count == 4, parts[3] == "scene" {
            switch method {
            case "GET":
                let scene = model.store.sceneJSON(boardID) ?? "[]"
                return ("200 OK", ["elements": scene])
            case "PUT":
                guard let elements = request.json?["elements"] else {
                    return ("400 Bad Request", ["error": "需要 elements"])
                }
                let json: String
                if let string = elements as? String {
                    json = string
                } else if let array = elements as? [Any],
                          let data = try? JSONSerialization.data(withJSONObject: array, options: [.sortedKeys]),
                          let string = String(data: data, encoding: .utf8) {
                    json = string
                } else {
                    return ("400 Bad Request", ["error": "elements 需为数组或 JSON 字符串"])
                }
                model.apiSetScene(boardID, elementsJSON: json)
                return ("200 OK", ["ok": true, "elements": json])
            default:
                return ("405 Method Not Allowed", ["error": "不支持的方法"])
            }
        }

        if parts.count == 4, parts[3] == "elements" {
            switch method {
            case "POST":
                guard let items = request.json?["elements"] as? [[String: Any]], !items.isEmpty else {
                    return ("400 Bad Request", ["error": "需要 elements 数组（支持简写）"])
                }
                let result = model.apiAppendElements(boardID, items: items)
                if result.success {
                    return ("200 OK", ["ok": true, "added": result.payload])
                }
                return ("400 Bad Request", ["error": result.payload])
            case "DELETE":
                guard let ids = request.json?["ids"] as? [String], !ids.isEmpty else {
                    return ("400 Bad Request", ["error": "需要 ids 数组"])
                }
                model.apiDeleteElements(boardID, ids: ids)
                return ("200 OK", ["ok": true])
            default:
                return ("405 Method Not Allowed", ["error": "不支持的方法"])
            }
        }

        return ("404 Not Found", ["error": "未知路径 \(path)"])
    }
}

// MARK: - HTTP 连接与请求解析（极简 HTTP/1.1，Connection: close）

final class HTTPConnection {
    private let connection: NWConnection
    private let handler: (HTTPRequest) -> Void
    private var buffer = Data()
    var onClose: (() -> Void)?

    init(connection: NWConnection, handler: @escaping (HTTPRequest) -> Void) {
        self.connection = connection
        self.handler = handler
    }

    func start() {
        connection.stateUpdateHandler = { [weak self] state in
            if case .failed = state { self?.finish() }
            if case .cancelled = state { self?.finish() }
        }
        connection.start(queue: DispatchQueue(label: "com.hujing.drawpad.httpconn"))
        receive()
    }

    private func receive() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 1 << 20) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            if let data { self.buffer.append(data) }
            if let request = HTTPRequest.parse(from: self.buffer, connection: self.connection) {
                self.handler(request)
                return
            }
            if error != nil || isComplete {
                self.finish()
                return
            }
            self.receive()
        }
    }

    private func finish() {
        onClose?()
    }
}

struct HTTPRequest {
    let method: String
    let path: String
    let query: [String: String]
    let json: [String: Any]?
    private let connection: NWConnection

    static func parse(from data: Data, connection: NWConnection) -> HTTPRequest? {
        guard let headerEnd = data.range(of: Data("\r\n\r\n".utf8)) else { return nil }
        let headerData = data[..<headerEnd.lowerBound]
        guard let headerText = String(data: headerData, encoding: .utf8) else { return nil }
        let lines = headerText.components(separatedBy: "\r\n")
        guard let requestLine = lines.first else { return nil }
        let segments = requestLine.components(separatedBy: " ")
        guard segments.count >= 2 else { return nil }

        var contentLength = 0
        for line in lines.dropFirst() {
            let pair = line.split(separator: ":", maxSplits: 1)
            if pair.count == 2, pair[0].lowercased() == "content-length" {
                contentLength = Int(pair[1].trimmingCharacters(in: .whitespaces)) ?? 0
            }
        }
        let bodyStart = headerEnd.upperBound
        guard data.count - bodyStart >= contentLength else { return nil }
        let bodyData = data.subdata(in: bodyStart..<data.count).prefix(contentLength)

        let rawTarget = segments[1]
        var path = rawTarget
        var query: [String: String] = [:]
        if let questionMark = rawTarget.firstIndex(of: "?") {
            path = String(rawTarget[..<questionMark])
            let queryString = String(rawTarget[rawTarget.index(after: questionMark)...])
            for pair in queryString.components(separatedBy: "&") {
                let kv = pair.components(separatedBy: "=")
                if kv.count == 2 {
                    query[kv[0]] = kv[1].removingPercentEncoding ?? kv[1]
                }
            }
        }
        var json: [String: Any]?
        if !bodyData.isEmpty {
            json = try? JSONSerialization.jsonObject(with: Data(bodyData)) as? [String: Any]
        }
        return HTTPRequest(
            method: segments[0], path: path, query: query, json: json, connection: connection)
    }

    func respond(status: String, contentType: String, body: Data) {
        var response = Data("HTTP/1.1 \(status)\r\nContent-Type: \(contentType)\r\n".utf8)
        response += Data("Content-Length: \(body.count)\r\nConnection: close\r\n\r\n".utf8)
        response += body
        connection.send(content: response, completion: .contentProcessed { _ in
            connection.cancel()
        })
    }
}
