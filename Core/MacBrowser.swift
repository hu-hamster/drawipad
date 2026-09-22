import Foundation
import Network

/// iPad 端：浏览局域网内运行 DrawPad 的 Mac。
/// 所有回调与外部调用均在主线程。
public final class MacBrowser {
    public struct Item: Identifiable, Equatable {
        public let id: String
        public let name: String
        public let endpoint: NWEndpoint

        public static func == (lhs: Item, rhs: Item) -> Bool {
            lhs.id == rhs.id
        }
    }

    public var onUpdate: (([Item]) -> Void)?

    private var browser: NWBrowser?

    public init() {}

    public func start() {
        guard browser == nil else { return }
        let params = NWParameters()
        params.includePeerToPeer = true
        let browser = NWBrowser(
            for: .bonjour(type: DrawPadServer.serviceType, domain: nil),
            using: params
        )
        browser.browseResultsChangedHandler = { [weak self] results, _ in
            let items = results.compactMap { result -> Item? in
                guard case let .service(name, type, domain, _) = result.endpoint else { return nil }
                let id = "\(name).\(type)\(domain)"
                return Item(id: id, name: name, endpoint: result.endpoint)
            }
            DispatchQueue.main.async {
                self?.onUpdate?(items)
            }
        }
        browser.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            if case .failed = state {
                // 浏览失败（如权限/网络切换），重启
                self.stop()
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
                    self?.start()
                }
            }
        }
        browser.start(queue: .main)
        self.browser = browser
    }

    public func stop() {
        browser?.cancel()
        browser = nil
    }
}
