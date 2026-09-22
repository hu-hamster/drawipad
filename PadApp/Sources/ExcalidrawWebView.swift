import SwiftUI
import WebKit

/// iOS：嵌入 Excalidraw 的 WKWebView。
final class PadBoardWebView: WKWebView {
    var onReady: (() -> Void)?
    var onSceneChange: ((String) -> Void)?
    var onBridgeError: ((String) -> Void)?

    func setup() {
        let content = WKUserContentController()
        content.add(self, name: "ready")
        content.add(self, name: "sceneChange")
        content.add(self, name: "bridgeError")
        configuration.userContentController = content
        allowsBackForwardNavigationGestures = false
        allowsLinkPreview = false
        scrollView.bounces = false
        scrollView.panGestureRecognizer.minimumNumberOfTouches = 3
        if #available(iOS 16.4, *) {
            isInspectable = false
        }
        if let html = Bundle.main.url(forResource: "index", withExtension: "html", subdirectory: "SharedWeb") {
            let access = html.deletingLastPathComponent()
            loadFileURL(html, allowingReadAccessTo: access)
        } else {
            NSLog("DrawPad: index.html 不在 bundle 中")
        }
    }

    /// 下发对端场景（内部做 JS 字符串转义）。
    func applyScene(_ json: String) {
        let data = (try? JSONEncoder().encode(json)) ?? Data("[]".utf8)
        guard let encoded = String(data: data, encoding: .utf8) else {
            return
        }
        evaluateJavaScript("window.__applyScene(\(encoded))") { _, error in
            if let error {
                NSLog("DrawPad applyScene error: \(error)")
            }
        }
    }
}

extension PadBoardWebView: WKScriptMessageHandler {
    func userContentController(
        _ userContentController: WKUserContentController,
        didReceive message: WKScriptMessage
    ) {
        switch message.name {
        case "ready":
            onReady?()
        case "sceneChange":
            if let json = message.body as? String {
                onSceneChange?(json)
            }
        case "bridgeError":
            onBridgeError?(String(describing: message.body))
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
            model?.webViewReady = true
        }
        view.onSceneChange = { [weak model] json in
            model?.handleLocalSceneChange(json)
        }
        view.onBridgeError = { NSLog("DrawPad bridge: \($0)") }
        view.setup()
        model.webView = view
        return view
    }

    func updateUIView(_ view: PadBoardWebView, context: Context) {}
}
