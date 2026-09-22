import Foundation
import Network
#if canImport(UIKit)
import UIKit
#endif

/// iPad 端客户端：连接指定 Mac，断线后指数退避自动重连。
/// 所有回调与外部调用均在主线程。
public final class DrawPadClient {
    public enum Phase: Equatable {
        case idle
        case connecting
        case waitingAccept
        case connected
        case failed(String)
        case reconnecting(attemptDelay: Double)
    }

    public var onPhase: ((Phase) -> Void)?
    public var onMessage: ((ServerMessage) -> Void)?

    private var peer: PeerConnection?
    private var endpoint: NWEndpoint?
    private var wantsConnection = false
    private var retryCount = 0
    private var retryWork: DispatchWorkItem?
    public private(set) var phase: Phase = .idle

    public init() {}

    public func connect(to endpoint: NWEndpoint) {
        wantsConnection = true
        retryCount = 0
        open(endpoint, initial: true)
    }

    public func disconnect() {
        wantsConnection = false
        retryWork?.cancel()
        retryWork = nil
        peer?.cancel()
        peer = nil
        setPhase(.idle)
    }

    public func send(_ message: ClientMessage) {
        guard let peer, let payload = Wire.json(message) else { return }
        peer.send(payload)
    }

    private func open(_ endpoint: NWEndpoint, initial: Bool) {
        retryWork?.cancel()
        retryWork = nil
        peer?.cancel()
        self.endpoint = endpoint
        let params = NWParameters.tcp
        params.includePeerToPeer = true
        let connection = NWConnection(to: endpoint, using: params)
        let peer = PeerConnection(connection: connection)
        peer.onMessage = { [weak self] data in
            guard let message = Wire.parse(ServerMessage.self, from: data) else { return }
            self?.handle(message)
        }
        peer.onClosed = { [weak self] in self?.handleClosed() }
        self.peer = peer
        setPhase(initial ? .connecting : .waitingAccept)
        peer.start()
        if let hello = Wire.json(
            ClientMessage.hello(deviceName: Self.deviceName(), protocolVersion: drawPadProtocolVersion)
        ) {
            peer.send(hello)
        }
    }

    private func handle(_ message: ServerMessage) {
        switch message {
        case .helloAccepted:
            retryCount = 0
            setPhase(.connected)
        case .rejected(let reason):
            wantsConnection = false
            setPhase(.failed(reason))
            peer?.cancel()
            peer = nil
        default:
            onMessage?(message)
        }
    }

    private func handleClosed() {
        peer = nil
        guard wantsConnection, endpoint != nil else {
            setPhase(.idle)
            return
        }
        retryCount += 1
        let delay = min(pow(2.0, Double(retryCount - 1)), 6.0)
        setPhase(.reconnecting(attemptDelay: delay))
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.wantsConnection, let endpoint = self.endpoint else { return }
            self.open(endpoint, initial: false)
        }
        retryWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    private func setPhase(_ newPhase: Phase) {
        phase = newPhase
        onPhase?(newPhase)
    }

    static func deviceName() -> String {
        #if os(iOS)
        return UIDevice.current.name
        #else
        return Host.current().localizedName ?? "Device"
        #endif
    }
}
