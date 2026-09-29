import SwiftUI
import WebKit

/// 白板（分页 Excalidraw）画布：加载 SharedWeb/whiteboard.html，
/// 桥契约与 Canvas 画布一致（场景 JSON 为整个分页文档）。
final class WhiteboardBoardWebView: WKWebView, BoardSurface {
    var onReady: (() -> Void)?
    var onSceneChange: ((String) -> Void)?
    var onViewportPan: ((Double, Double) -> Void)?
    var onViewportZoom: ((Double, Double, Double, Double, Double) -> Void)?

    convenience init() {
        let content = WKUserContentController()
        content.add(WhiteboardBoardProxy.shared, name: "ready")
        content.add(WhiteboardBoardProxy.shared, name: "sceneChange")
        content.add(WhiteboardBoardProxy.shared, name: "viewportPan")
        content.add(WhiteboardBoardProxy.shared, name: "viewportZoom")
        let configuration = WKWebViewConfiguration()
        configuration.userContentController = content
        self.init(frame: .zero, configuration: configuration)
        WhiteboardBoardProxy.shared.current = self
        if let html = Bundle.main.url(forResource: "whiteboard", withExtension: "html", subdirectory: "SharedWeb") {
            loadFileURL(html, allowingReadAccessTo: html.deletingLastPathComponent())
        }
    }

    func applyScene(_ json: String) {
        let data = (try? JSONEncoder().encode(json)) ?? Data(PageMeta.emptyWhiteboard.utf8)
        guard let encoded = String(data: data, encoding: .utf8) else { return }
        evaluateJavaScript("window.__applyScene && window.__applyScene(\(encoded))", completionHandler: nil)
    }

    func applyViewportPan(_ centerX: Double, _ centerY: Double) {
        evaluateJavaScript(String(format: "window.__applyViewportPan(%f, %f)", centerX, centerY), completionHandler: nil)
    }

    func applyViewportZoom(_ zoom: Double, centerX: Double, centerY: Double, peerWidth: Double, peerHeight: Double) {
        let js = String(format: "window.__applyViewportZoom(%f, %f, %f, %f, %f)", zoom, centerX, centerY, peerWidth, peerHeight)
        evaluateJavaScript(js, completionHandler: nil)
    }

    func fitToContent() {
        evaluateJavaScript("window.__fitToContent && window.__fitToContent()", completionHandler: nil)
    }

    func requestViewport(completion: @escaping ((cx: Double, cy: Double, z: Double, vw: Double, vh: Double)?) -> Void) {
        evaluateJavaScript("window.__getViewport && window.__getViewport()") { result, _ in
            guard let json = result as? String,
                  let data = json.data(using: .utf8),
                  let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Double],
                  let cx = dict["cx"], let cy = dict["cy"], let z = dict["z"],
                  let vw = dict["vw"], let vh = dict["vh"] else {
                completion(nil)
                return
            }
            completion((cx, cy, z, vw, vh))
        }
    }

    func toolbarProbe() {}
}

final class WhiteboardBoardProxy: NSObject, WKScriptMessageHandler {
    static let shared = WhiteboardBoardProxy()
    weak var current: WhiteboardBoardWebView?

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let view = current else { return }
        switch message.name {
        case "ready":
            view.onReady?()
        case "sceneChange":
            if let json = message.body as? String { view.onSceneChange?(json) }
        case "viewportPan":
            if let value = Self.point(message.body) { view.onViewportPan?(value.cx, value.cy) }
        case "viewportZoom":
            if let value = Self.zoom(message.body) {
                view.onViewportZoom?(value.z, value.cx, value.cy, value.vw, value.vh)
            }
        default:
            break
        }
    }

    private static func point(_ body: Any) -> (cx: Double, cy: Double)? {
        guard let json = body as? String,
              let data = json.data(using: .utf8),
              let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Double],
              let cx = dict["cx"], let cy = dict["cy"] else { return nil }
        return (cx, cy)
    }

    private static func zoom(_ body: Any) -> (z: Double, cx: Double, cy: Double, vw: Double, vh: Double)? {
        guard let json = body as? String,
              let data = json.data(using: .utf8),
              let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Double],
              let z = dict["z"], let cx = dict["cx"], let cy = dict["cy"],
              let vw = dict["vw"], let vh = dict["vh"] else { return nil }
        return (z, cx, cy, vw, vh)
    }
}

struct WhiteboardMacWebView: NSViewRepresentable {
    let model: MacAppModel

    func makeNSView(context: Context) -> WhiteboardBoardWebView {
        let view = WhiteboardBoardWebView()
        view.onReady = { [weak model, weak view] in
            guard let view else { return }
            model?.handleWebViewReady(view)
        }
        view.onSceneChange = { [weak model, weak view] json in
            guard let view else { return }
            model?.handleLocalSceneChange(json, from: view)
        }
        view.onViewportPan = { [weak model, weak view] cx, cy in
            guard let model, let view, model.webView === view else { return }
            model.handleLocalViewportPan(cx, cy)
        }
        view.onViewportZoom = { [weak model, weak view] z, cx, cy, vw, vh in
            guard let model, let view, model.webView === view else { return }
            model.handleLocalViewportZoom(z, cx, cy, vw, vh)
        }
        model.attachWebView(view)
        return view
    }

    func updateNSView(_ nsView: WhiteboardBoardWebView, context: Context) {}
}
