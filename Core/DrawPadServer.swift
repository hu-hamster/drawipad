import Foundation
import Network

/// Mac 端服务：Bonjour 广播 + 接受单个 iPad 连接。
/// 所有回调与外部调用均在主线程。
public final class DrawPadServer {
    public static let serviceType = "_drawpad._tcp"

    /// 一次配对请求。accept/reject 只能调用一次。
    public final class PairingRequest {
        public let deviceName: String
        let connection: PeerConnection
        private weak var owner: DrawPadServer?
        private var decided = false

        init(deviceName: String, connection: PeerConnection, owner: DrawPadServer) {
            self.deviceName = deviceName
            self.connection = connection
            self.owner = owner
        }

        public func accept() {
            guard !decided else { return }
            decided = true
            owner?.acceptPairing(self)
        }

        public func reject() {
            guard !decided else { return }
            decided = true
            owner?.rejectPairing(self)
        }
    }

    /// 收到配对请求（主线程）。
    public var onPairingRequest: ((PairingRequest) -> Void)?
    public var onClientConnected: ((_ deviceName: String) -> Void)?
    public var onClientDisconnected: ((_ deviceName: String?) -> Void)?
    /// 会话内已配对的设备（按设备名记忆，断线重连时免确认）。
    public var onMessage: ((ClientMessage) -> Void)?

    private var listener: NWListener?
    private var pending: PeerConnection?
    private var active: PeerConnection?
    public private(set) var clientName: String?
    public private(set) var advertisedName: String = "Mac"
    /// 本次运行中已同意过的设备名，重连自动放行。
    private var rememberedDevices: Set<String> = []

    public init() {}

    public var hasClient: Bool { active != nil }

    public func start() throws {
        guard listener == nil else { return }
        let params = NWParameters.tcp
        params.includePeerToPeer = true
        params.allowLocalEndpointReuse = true
        let listener = try NWListener(using: params)
        advertisedName = Self.defaultServerName()
        listener.service = NWListener.Service(name: advertisedName, type: Self.serviceType)
        listener.newConnectionHandler = { [weak self] connection in
            self?.handleNew(connection)
        }
        listener.stateUpdateHandler = { [weak self] state in
            if case .failed = state {
                // 广播失败（如网络切换），稍后自动重启
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
                    guard let self, self.listener == nil else { return }
                    try? self.start()
                }
            }
        }
        listener.start(queue: .main)
        self.listener = listener
    }

    public func stop() {
        listener?.cancel()
        listener = nil
        active?.cancel()
        active = nil
        pending?.cancel()
        pending = nil
        clientName = nil
    }

    /// 主动断开当前客户端。
    public func disconnectClient() {
        active?.cancel()
    }

    public func send(_ message: ServerMessage) {
        guard let active else { return }
        sendTo(active, message)
    }

    // MARK: - Internals

    private func handleNew(_ conn: NWConnection) {
        let peer = PeerConnection(connection: conn)
        if active != nil || pending != nil {
            // 已有设备占用，直接拒绝
            peer.start()
            sendTo(peer, .rejected(reason: "已有其他设备连接这台 Mac"))
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { peer.cancel() }
            return
        }
        pending = peer
        // 握手超时：10 秒内未收到 hello 则释放，避免占用通道
        DispatchQueue.main.asyncAfter(deadline: .now() + 10.0) { [weak self, weak peer] in
            guard let self, let peer, peer === self.pending else { return }
            self.pending = nil
            peer.cancel()
        }
        peer.onMessage = { [weak self, weak peer] data in
            guard let self, let peer else { return }
            if peer === self.active {
                if let message = Wire.parse(ClientMessage.self, from: data) {
                    self.onMessage?(message)
                }
                return
            }
            guard peer === self.pending else { return }
            // 握手阶段：第一条必须是 hello
            guard let message = Wire.parse(ClientMessage.self, from: data),
                  case let .hello(name, version) = message else {
                peer.cancel()
                self.pending = nil
                return
            }
            guard version == drawPadProtocolVersion else {
                self.sendTo(peer, .rejected(reason: "版本不兼容，请两端使用相同版本的 DrawPad"))
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { peer.cancel() }
                self.pending = nil
                return
            }
            if self.rememberedDevices.contains(name) {
                // 会话内重连：自动放行
                let request = PairingRequest(deviceName: name, connection: peer, owner: self)
                request.accept()
            } else {
                let request = PairingRequest(deviceName: name, connection: peer, owner: self)
                self.onPairingRequest?(request)
            }
        }
        peer.onClosed = { [weak self, weak peer] in
            guard let self, let peer else { return }
            if peer === self.pending {
                self.pending = nil
            }
            if peer === self.active {
                let name = self.clientName
                self.active = nil
                self.clientName = nil
                self.onClientDisconnected?(name)
            }
        }
        peer.start()
    }

    func acceptPairing(_ request: PairingRequest) {
        let peer = request.connection
        guard pending === peer else { return }
        pending = nil
        active = peer
        clientName = request.deviceName
        rememberedDevices.insert(request.deviceName)
        sendTo(peer, .helloAccepted(serverName: advertisedName))
        onClientConnected?(request.deviceName)
    }

    func rejectPairing(_ request: PairingRequest) {
        let peer = request.connection
        guard pending === peer else { return }
        pending = nil
        sendTo(peer, .rejected(reason: "Mac 拒绝了连接请求"))
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { peer.cancel() }
    }

    private func sendTo(_ peer: PeerConnection, _ message: ServerMessage) {
        if let payload = Wire.json(message) {
            peer.send(payload)
        }
    }

    static func defaultServerName() -> String {
        #if os(macOS)
        let host = Host.current()
        return host.localizedName ?? host.name ?? "Mac"
        #else
        return "Mac"
        #endif
    }
}
