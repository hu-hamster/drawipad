import SwiftUI
import WebKit

protocol PadBoardSurface: AnyObject {
    func applyScene(_ json: String, completion: ((Bool) -> Void)?)
    func applyViewportPan(_ centerX: Double, _ centerY: Double)
    func applyViewportZoom(_ zoom: Double, centerX: Double, centerY: Double, peerWidth: Double, peerHeight: Double)
    func localZoom(_ factor: Double)
    func fitToContent()
}

extension PadBoardSurface {
    func applyScene(_ json: String) {
        applyScene(json, completion: nil)
    }
}

extension PadBoardWebView: PadBoardSurface {}

final class CanvasPadWebView: WKWebView, PadBoardSurface {
    var onReady: (() -> Void)?
    var onSceneChange: ((String) -> Void)?
    var onViewportPan: ((Double, Double) -> Void)?
    var onViewportZoom: ((Double, Double, Double, Double, Double) -> Void)?

    convenience init() {
        let content = WKUserContentController()
        content.add(CanvasPadProxy.shared, name: "ready")
        content.add(CanvasPadProxy.shared, name: "sceneChange")
        content.add(CanvasPadProxy.shared, name: "viewportPan")
        content.add(CanvasPadProxy.shared, name: "viewportZoom")
        let configuration = WKWebViewConfiguration()
        configuration.userContentController = content
        self.init(frame: .zero, configuration: configuration)
        CanvasPadProxy.shared.current = self
        scrollView.bounces = false
        if let html = Bundle.main.url(forResource: "canvas", withExtension: "html", subdirectory: "SharedWeb") {
            loadFileURL(html, allowingReadAccessTo: html.deletingLastPathComponent())
        }
    }

    func applyScene(_ json: String, completion: ((Bool) -> Void)? = nil) {
        let data = (try? JSONEncoder().encode(json)) ?? Data(PageMeta.emptyCanvas.utf8)
        guard let encoded = String(data: data, encoding: .utf8) else {
            completion?(false)
            return
        }
        evaluateJavaScript("window.__applyScene && window.__applyScene(\(encoded))") { result, error in
            completion?(error == nil && (result as? String) == "ok")
        }
    }

    func applyViewportPan(_ centerX: Double, _ centerY: Double) {
        evaluateJavaScript(String(format: "window.__applyViewportPan(%f, %f)", centerX, centerY), completionHandler: nil)
    }

    func applyViewportZoom(_ zoom: Double, centerX: Double, centerY: Double, peerWidth: Double, peerHeight: Double) {
        let js = String(format: "window.__applyViewportZoom(%f, %f, %f, %f, %f)", zoom, centerX, centerY, peerWidth, peerHeight)
        evaluateJavaScript(js, completionHandler: nil)
    }

    func localZoom(_ factor: Double) {
        evaluateJavaScript(String(format: "window.__localZoom(%f)", factor), completionHandler: nil)
    }

    func fitToContent() {
        evaluateJavaScript("window.__fitToContent && window.__fitToContent()", completionHandler: nil)
    }
}

final class CanvasPadProxy: NSObject, WKScriptMessageHandler {
    static let shared = CanvasPadProxy()
    weak var current: CanvasPadWebView?

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let view = current else { return }
        switch message.name {
        case "ready":
            view.onReady?()
        case "sceneChange":
            if let json = message.body as? String { view.onSceneChange?(json) }
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
}

struct CanvasPadScreen: UIViewRepresentable {
    let model: PadModel

    func makeUIView(context: Context) -> CanvasPadWebView {
        let view = CanvasPadWebView()
        view.onReady = { [weak model, weak view] in
            guard let model, let view else { return }
            model.handleWebViewReady(view)
        }
        view.onSceneChange = { [weak model] json in model?.handleLocalSceneChange(json) }
        view.onViewportPan = { [weak model] cx, cy in model?.handleLocalViewportPan(cx, cy) }
        view.onViewportZoom = { [weak model] z, cx, cy, vw, vh in
            model?.handleLocalViewportZoom(z, cx, cy, vw, vh)
        }
        model.attachWebView(view)
        return view
    }

    func updateUIView(_ uiView: CanvasPadWebView, context: Context) {}
}
