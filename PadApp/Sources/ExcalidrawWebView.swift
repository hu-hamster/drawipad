import SwiftUI
import WebKit

/// iOS：嵌入 Excalidraw 的 WKWebView。
/// 注意：configuration 只在 init 时生效，消息处理器必须先配置再初始化（经代理转发）。
final class PadBoardWebView: WKWebView {
    var onReady: (() -> Void)?
    var onSceneChange: ((String) -> Void)?
    var onBridgeError: ((String) -> Void)?
    var onViewportPan: ((Double, Double) -> Void)?
    var onViewportZoom: ((Double, Double, Double, Double, Double) -> Void)?

    convenience init() {
        let proxy = PadBridgeProxy.shared
        let content = WKUserContentController()
        content.add(proxy, name: "ready")
        content.add(proxy, name: "sceneChange")
        content.add(proxy, name: "bridgeError")
        content.add(proxy, name: "viewportPan")
        content.add(proxy, name: "viewportZoom")
        let configuration = WKWebViewConfiguration()
        configuration.userContentController = content
        self.init(frame: .zero, configuration: configuration)
        proxy.current = self
        commonSetup()
    }

    private func commonSetup() {
        allowsBackForwardNavigationGestures = false
        allowsLinkPreview = false
        scrollView.bounces = false
        if let html = Bundle.main.url(forResource: "index", withExtension: "html", subdirectory: "SharedWeb") {
            let access = html.deletingLastPathComponent()
            loadFileURL(html, allowingReadAccessTo: access)
        } else {
            print("[DrawPad] index.html 不在 bundle 中")
        }
    }

    /// 下发对端场景（内部做 JS 字符串转义）。
    func applyScene(_ json: String) {
        let data = (try? JSONEncoder().encode(json)) ?? Data("[]".utf8)
        guard let encoded = String(data: data, encoding: .utf8) else {
            return
        }
        evaluateJavaScript("window.__applyScene && window.__applyScene(\(encoded))") { _, error in
            if let error {
                print("[DrawPad] applyScene: \(error.localizedDescription)")
            }
        }
    }

    func applyViewportPan(_ centerX: Double, _ centerY: Double) {
        let js = String(format: "window.__applyViewportPan(%f, %f)", centerX, centerY)
        evaluateJavaScript(js, completionHandler: nil)
    }

    func applyViewportZoom(_ zoom: Double, centerX: Double, centerY: Double, peerWidth: Double, peerHeight: Double) {
        let js = String(format: "window.__applyViewportZoom(%f, %f, %f, %f, %f)", zoom, centerX, centerY, peerWidth, peerHeight)
        evaluateJavaScript(js, completionHandler: nil)
    }

    /// 本地缩放（不广播）。
    func localZoom(_ factor: Double) {
        let js = String(format: "window.__localZoom(%f)", factor)
        evaluateJavaScript(js, completionHandler: nil)
    }
}

/// 消息代理：避免 WKScriptMessageHandler 强持有 webview 造成循环。
final class PadBridgeProxy: NSObject, WKScriptMessageHandler {
    static let shared = PadBridgeProxy()
    weak var current: PadBoardWebView?

    func userContentController(
        _ userContentController: WKUserContentController,
        didReceive message: WKScriptMessage
    ) {
        guard let view = current else { return }
        switch message.name {
        case "ready":
            print("[DrawPad] 网页消息通道 ✓ ready")
            view.onReady?()
        case "sceneChange":
            if let json = message.body as? String {
                view.onSceneChange?(json)
            }
        case "bridgeError":
            print("[DrawPad] 桥错误: \(message.body)")
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
}

/// SwiftUI 桥接。
struct ExcalidrawPadWebView: UIViewRepresentable {
    let model: PadModel

    func makeUIView(context: Context) -> PadBoardWebView {
        let view = PadBoardWebView()
        view.onReady = { [weak model] in
            print("[DrawPad] iPad 画布就绪 ✓ (Excalidraw mounted)")
            guard let model else { return }
            model.webViewReady = true
            if let pending = model.pendingScene {
                model.pendingScene = nil
                print("[DrawPad] 应用暂存场景 \(pending.count) 字节")
                model.webView?.applyScene(pending)
            }
        }
        view.onSceneChange = { [weak model] json in
            model?.handleLocalSceneChange(json)
        }
        view.onViewportPan = { [weak model] sx, sy in
            model?.handleLocalViewportPan(sx, sy)
        }
        view.onViewportZoom = { [weak model] z, cx, cy, vw, vh in
            model?.handleLocalViewportZoom(z, cx, cy, vw, vh)
        }
        view.onBridgeError = { err in
            print("[DrawPad] 桥错误: \(err)")
        }
        model.webView = view
        return view
    }

    func updateUIView(_ view: PadBoardWebView, context: Context) {}
}
