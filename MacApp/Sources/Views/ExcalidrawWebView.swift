import SwiftUI
import WebKit
import UniformTypeIdentifiers

/// macOS：嵌入 Excalidraw 的 WKWebView。
/// 注意：WKWebView 的 configuration 只在 init 时生效，消息处理器必须先配置再初始化。
final class BoardWebView: WKWebView {
    var onReady: (() -> Void)?
    var onSceneChange: ((String) -> Void)?
    var onBridgeError: ((String) -> Void)?
    var onFileOpenError: ((String) -> Void)?
    var onViewportPan: ((Double, Double) -> Void)?
    var onViewportZoom: ((Double, Double, Double, Double, Double) -> Void)?

    static func diag(_ text: String) {
        BoardWebViewMessageProxy.diag(text)
    }

    convenience init() {
        let content = WKUserContentController()
        content.add(BoardWebViewMessageProxy.shared, name: "ready")
        content.add(BoardWebViewMessageProxy.shared, name: "sceneChange")
        content.add(BoardWebViewMessageProxy.shared, name: "bridgeError")
        content.add(BoardWebViewMessageProxy.shared, name: "viewportPan")
        content.add(BoardWebViewMessageProxy.shared, name: "viewportZoom")
        // 页面异常上报（脚本加载失败等）
        let errorHook = """
        window.onerror = function (msg, src, line, col) {
          window.webkit.messageHandlers.bridgeError.postMessage(
            "onerror: " + msg + " @ " + (src || "?") + ":" + line + ":" + col
          );
        };
        window.addEventListener("unhandledrejection", function (e) {
          window.webkit.messageHandlers.bridgeError.postMessage("rejection: " + e.reason);
        });
        """
        content.addUserScript(
            WKUserScript(source: errorHook, injectionTime: .atDocumentStart, forMainFrameOnly: true)
        )
        let configuration = WKWebViewConfiguration()
        configuration.userContentController = content
        self.init(frame: .zero, configuration: configuration)
        commonSetup()
    }

    private func commonSetup() {
        navigationDelegate = self
        uiDelegate = self
        allowsBackForwardNavigationGestures = false
        if let html = Bundle.main.url(forResource: "index", withExtension: "html", subdirectory: "SharedWeb") {
            let access = html.deletingLastPathComponent()
            Self.diag("loading html: \(html.path)")
            loadFileURL(html, allowingReadAccessTo: access)
        } else {
            Self.diag("index.html 不在 bundle 中！")
        }
    }

    /// 挂载消息回调（消息经 MessageProxy 广播）。
    func attachHandlers() {
        BoardWebViewMessageProxy.shared.current = self
    }

    /// 下发对端场景（内部做 JS 字符串转义）。
    func applyScene(_ json: String) {
        let data = (try? JSONEncoder().encode(json)) ?? Data("[]".utf8)
        guard let encoded = String(data: data, encoding: .utf8) else {
            return
        }
        let expression = "window.__applyScene(\(encoded))"
        Self.diag("js expr 头120: \(String(expression.prefix(120)))")
        evaluateJavaScript(expression) { result, error in
            if let error {
                Self.diag("applyScene JS error: \(error.localizedDescription)")
            }
            if let resultString = result as? String, resultString != "ok" {
                Self.diag("applyScene 返回: \(resultString.prefix(200))")
            }
        }
    }

    func requestCurrentScene(completion: @escaping (String?) -> Void) {
        evaluateJavaScript("window.__getScene()") { result, _ in
            completion(result as? String)
        }
    }

    // MARK: 视口同步

    func applyViewportPan(_ centerX: Double, _ centerY: Double) {
        let js = String(format: "window.__applyViewportPan(%f, %f)", centerX, centerY)
        evaluateJavaScript(js, completionHandler: nil)
    }

    func applyViewportZoom(_ zoom: Double, centerX: Double, centerY: Double, peerWidth: Double, peerHeight: Double) {
        let js = String(format: "window.__applyViewportZoom(%f, %f, %f, %f, %f)", zoom, centerX, centerY, peerWidth, peerHeight)
        evaluateJavaScript(js, completionHandler: nil)
    }

    func fitToContent() {
        evaluateJavaScript("window.__fitToContent && window.__fitToContent()", completionHandler: nil)
    }

    func requestViewport(completion: @escaping ((cx: Double, cy: Double, z: Double, vw: Double, vh: Double)?) -> Void) {
        evaluateJavaScript("window.__getViewport()") { result, _ in
            guard let json = result as? String,
                  let data = json.data(using: .utf8),
                  let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Double],
                  let cx = dict["cx"], let cy = dict["cy"], let z = dict["z"],
                  let vw = dict["vw"], let vh = dict["vh"]
            else {
                completion(nil)
                return
            }
            completion((cx, cy, z, vw, vh))
        }
    }
}

/// 消息代理：WKScriptMessageHandler 强持有 handler，经此单例转发给当前 webview，
/// 避免 WKWebView 自引用造成的循环。
final class BoardWebViewMessageProxy: NSObject, WKScriptMessageHandler {
    static let shared = BoardWebViewMessageProxy()
    weak var current: BoardWebView?

    func userContentController(
        _ userContentController: WKUserContentController,
        didReceive message: WKScriptMessage
    ) {
        guard let view = current else { return }
        switch message.name {
        case "ready":
            Self.diag("webview ready ✓ (Excalidraw mounted)")
            view.onReady?()
        case "sceneChange":
            if let json = message.body as? String {
                view.onSceneChange?(json)
            }
        case "bridgeError":
            Self.diag("bridgeError: \(message.body)")
            view.onBridgeError?(String(describing: message.body))
        case "viewportPan":
            if let json = message.body as? String,
               let data = json.data(using: .utf8),
               let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Double],
               let cx = dict["cx"], let cy = dict["cy"] {
                view.onViewportPan?(cx, cy)
            }
        case "viewportZoom":
            if let json = message.body as? String,
               let data = json.data(using: .utf8),
               let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Double],
               let z = dict["z"], let cx = dict["cx"], let cy = dict["cy"],
               let vw = dict["vw"], let vh = dict["vh"] {
                view.onViewportZoom?(z, cx, cy, vw, vh)
            }
        default:
            break
        }
    }

    /// 调试日志（写到沙盒容器临时目录，NSLog 会被系统过滤）。
    static func diag(_ text: String) {
        let line = "\(Date().formatted(.dateTime.hour().minute().second())) \(text)\n"
        let url = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("drawpad_diag.log")
        if let handle = try? FileHandle(forWritingTo: url) {
            handle.seekToEndOfFile()
            handle.write(Data(line.utf8))
            try? handle.close()
        } else {
            try? Data(line.utf8).write(to: url)
        }
        NSLog("DrawPad: \(text)")
    }
}

extension BoardWebView: WKNavigationDelegate, WKUIDelegate, WKDownloadDelegate {
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        Self.diag("page loaded: \(webView.url?.path ?? "?")")
        // JS 探针：区分"脚本未执行"与"消息通道不通"
        webView.evaluateJavaScript(
            "JSON.stringify({react: typeof window.React, lib: typeof window.ExcalidrawLib, bridge: typeof window.__isReady})"
        ) { result, error in
            if let error {
                Self.diag("js probe error: \(error.localizedDescription)")
            } else {
                Self.diag("js probe: \(result ?? "nil")")
            }
        }
    }

    /// 工具栏位置探针：测量各 UI 元素真实位置。
    func toolbarProbe() {
        let js = """
        (function () {
          function info(el) {
            var r = el.getBoundingClientRect();
            var cs = getComputedStyle(el);
            return {
              cls: (el.className || "").toString().slice(0, 60),
              parent: el.parentElement ? (el.parentElement.className || "").toString().slice(0, 50) : "?",
              l: Math.round(r.left), t: Math.round(r.top),
              w: Math.round(r.width), h: Math.round(r.height),
              pos: cs.position, right: cs.right, flexDir: cs.flexDirection
            };
          }
          var bars = [];
          document.querySelectorAll(".excalidraw .App-toolbar").forEach(function (el) { bars.push(info(el)); });
          var hamburger = document.querySelector(".excalidraw-ui-top-left");
          var children = [];
          var island = document.querySelector(".excalidraw .App-toolbar");
          if (island) {
            island.querySelectorAll(":scope > *").forEach(function (c) {
              var r = c.getBoundingClientRect();
              children.push({ cls: (c.className || "").toString().slice(0, 70), w: Math.round(r.width), h: Math.round(r.height), cs: getComputedStyle(c).flexDirection });
            });
            var gc = [];
            island.querySelectorAll(":scope > * > *").forEach(function (c) {
              var r = c.getBoundingClientRect();
              gc.push({ cls: (c.className || "").toString().slice(0, 60), w: Math.round(r.width), h: Math.round(r.height) });
            });
          }
          return JSON.stringify({ bars: bars, children: children, grandchildren: gc.slice(0, 6), hamburger: hamburger ? info(hamburger) : null, vw: window.innerWidth, vh: window.innerHeight });
        })()
        """
        evaluateJavaScript(js) { result, error in
            Self.diag("UI probe: \(result ?? "err:\(error?.localizedDescription ?? "?")")")
        }
    }

    /// 分步深探针：定位 __applyScene 内部哪一步失败。
    func deepProbe(_ json: String) {
        let data = (try? JSONEncoder().encode(json)) ?? Data()
        guard let enc = String(data: data, encoding: .utf8) else { return }
        let js = """
        (function () {
          var out = {};
          try { var s = JSON.parse(\(enc)); out.p1 = "ok len=" + s.length; } catch (e) { out.p1 = "ERR " + e; }
          try { var arr = JSON.parse(JSON.parse(\(enc))); out.p2 = "ok elements=" + arr.length + " type0=" + (arr[0] && arr[0].type); } catch (e) { out.p2 = "ERR " + e; }
          try { window.__excal.updateScene({ elements: JSON.parse(JSON.parse(\(enc))) }); out.p3 = "ok"; } catch (e) { out.p3 = "ERR " + (e && e.stack ? String(e.stack).slice(0, 400) : String(e)); }
          try { out.p4 = "count=" + window.__excal.getSceneElements().length; } catch (e) { out.p4 = "ERR " + e; }
          return JSON.stringify(out);
        })()
        """
        evaluateJavaScript(js) { result, error in
            Self.diag("deepProbe: \(result ?? "JSerr:\(error?.localizedDescription ?? "?")")")
        }
    }

    /// 视口/渲染状态探针（诊断画布不可见问题）。
    func renderProbe() {
        let experiment = """
        (function () {
          try {
            var api = window.__excal;
            if (!api) return JSON.stringify({noApi: true});
            var mk = function (id) { return {type:"rectangle",id:id,x:20,y:20,width:80,height:60,angle:0,strokeColor:"#1e1e1e",backgroundColor:"#a5d8ff",fillStyle:"solid",strokeWidth:2,strokeStyle:"solid",roughness:1,opacity:100,groupIds:[],frameId:null,roundness:null,seed:123,version:1,versionNonce:1,isDeleted:false,boundElements:null,updated:1,link:null,locked:false}; };
            var direct = api.getSceneElements().length;
            api.updateScene({ elements: [mk("probe-direct")] });
            var afterDirect = api.getSceneElements().length;
            var t1 = window.__applyScene(JSON.stringify(JSON.stringify([mk("probe-double")])));  // 生产路径：双重编码
            var t2 = window.__applyScene(JSON.stringify([mk("probe-single")]));                 // 单层编码
            var final = api.getSceneElements().length;
            return JSON.stringify({direct: direct, afterDirect: afterDirect, double: t1, single: t2, final: final});
          } catch (e) { return "err:" + e; }
        })()
        """
        evaluateJavaScript(experiment) { result, error in
            if let error {
                Self.diag("probe error: \(error.localizedDescription)")
            } else {
                Self.diag("api 实验: \(result ?? "nil")")
            }
        }
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        Self.diag("page FAILED: \(error.localizedDescription)")
    }

    func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationResponse: WKNavigationResponse,
        decisionHandler: @escaping (WKNavigationResponsePolicy) -> Void
    ) {
        if navigationResponse.canShowMIMEType {
            decisionHandler(.allow)
        } else {
            decisionHandler(.download)
        }
    }

    /// Excalidraw 的“打开”通过 HTML file input 触发；WKWebView 需要原生 open panel 才能选取本地文件。
    func webView(
        _ webView: WKWebView,
        runOpenPanelWith parameters: WKOpenPanelParameters,
        initiatedByFrame frame: WKFrameInfo,
        completionHandler: @escaping ([URL]?) -> Void
    ) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = parameters.allowsMultipleSelection

        // Excalidraw's HTML input only declares its native extensions.  On
        // macOS that makes Obsidian's `.excalidraw.md` visible but disabled.
        // Accept data files here; native Excalidraw files continue through to
        // WebKit, while Markdown is parsed by our native importer below.
        panel.allowedContentTypes = [.data]
        panel.begin { [weak self] response in
            guard response == .OK, !panel.urls.isEmpty else {
                completionHandler(nil)
                return
            }

            if panel.urls.count == 1,
               panel.urls[0].pathExtension.lowercased() == "md" {
                // Cancel the HTML file input because Excalidraw itself cannot
                // decode Obsidian's `compressed-json` Markdown payload.
                completionHandler(nil)
                self?.openExcalidrawMarkdown(panel.urls[0])
            } else {
                completionHandler(panel.urls)
            }
        }
    }

    private func openExcalidrawMarkdown(_ url: URL) {
        let accessed = url.startAccessingSecurityScopedResource()
        defer {
            if accessed { url.stopAccessingSecurityScopedResource() }
        }

        do {
            let text = try String(contentsOf: url, encoding: .utf8)
            guard let scene = ExcalidrawImport.parseScene(fromText: text) else {
                onFileOpenError?("未能从“\(url.lastPathComponent)”找到有效的 Excalidraw 场景。")
                return
            }

            // Match Excalidraw's native Open behavior: replace the current
            // canvas.  Persist explicitly as well, so the scene is retained
            // even if the embedded app does not emit an immediate onChange.
            applyScene(scene)
            onSceneChange?(scene)
        } catch {
            onFileOpenError?("无法读取“\(url.lastPathComponent)”：\(error.localizedDescription)")
        }
    }

    func webView(
        _ webView: WKWebView,
        navigationAction: WKNavigationAction,
        didBecome download: WKDownload
    ) {
        download.delegate = self
    }

    func webView(
        _ webView: WKWebView,
        navigationResponse: WKNavigationResponse,
        didBecome download: WKDownload
    ) {
        download.delegate = self
    }

    func download(
        _ download: WKDownload,
        decideDestinationUsing response: URLResponse,
        suggestedFilename: String,
        completionHandler: @escaping (URL?) -> Void
    ) {
        let directory = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)[0]
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        completionHandler(directory.appendingPathComponent(suggestedFilename))
    }
}

/// SwiftUI 桥接。
struct ExcalidrawWebView: NSViewRepresentable {
    let model: MacAppModel

    final class Coordinator {
        var installed = false
    }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> BoardWebView {
        let view = BoardWebView()
        view.onReady = { [weak model, weak view] in
            guard let view else { return }
            model?.handleWebViewReady(view)
        }
        view.onSceneChange = { [weak model, weak view] json in
            guard let view else { return }
            model?.handleLocalSceneChange(json, from: view)
        }
        view.onViewportPan = { [weak model, weak view] sx, sy in
            guard let model, let view, model.webView === view else { return }
            model.handleLocalViewportPan(sx, sy)
        }
        view.onViewportZoom = { [weak model, weak view] z, cx, cy, vw, vh in
            guard let model, let view, model.webView === view else { return }
            model.handleLocalViewportZoom(z, cx, cy, vw, vh)
        }
        view.onBridgeError = { error in
            BoardWebViewMessageProxy.diag("bridge callback: \(error)")
        }
        view.onFileOpenError = { [weak model] message in
            model?.importError = message
        }
        view.attachHandlers()
        model.attachWebView(view)
        context.coordinator.installed = true
        return view
    }

    func updateNSView(_ view: BoardWebView, context: Context) {}
}
