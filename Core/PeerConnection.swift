import Foundation
import Network

/// 单条 TCP 连接封装：负责帧编解码，回调统一派发到主线程。
/// 本类非线程安全的外部接口默认在主线程调用。
public final class PeerConnection {
    /// 收到完整帧（主线程回调）。
    public var onMessage: ((Data) -> Void)?
    /// 连接关闭（主线程回调，失败/取消/对端断开都会触发）。
    public var onClosed: (() -> Void)?

    private let connection: NWConnection
    private let queue = DispatchQueue(label: "com.hujing.drawpad.peer")
    private var accumulator = FrameAccumulator()
    private var closedReported = false

    public init(connection: NWConnection) {
        self.connection = connection
    }

    public func start() {
        connection.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                self.receive()
            case .failed, .cancelled:
                self.reportClosed()
            default:
                break
            }
        }
        connection.start(queue: queue)
    }

    public func send(_ payload: Data) {
        let frame = Wire.frame(payload)
        connection.send(content: frame, completion: .contentProcessed { _ in })
    }

    public func cancel() {
        connection.cancel()
    }

    private func receive() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 512 * 1024) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            if let data, !data.isEmpty {
                let frames = self.accumulator.feed(data)
                if !frames.isEmpty {
                    DispatchQueue.main.async {
                        for frame in frames {
                            self.onMessage?(frame)
                        }
                    }
                }
            }
            if error != nil || isComplete {
                self.reportClosed()
                return
            }
            self.receive()
        }
    }

    private func reportClosed() {
        DispatchQueue.main.async { [weak self] in
            guard let self, !self.closedReported else { return }
            self.closedReported = true
            self.onClosed?()
        }
    }
}
