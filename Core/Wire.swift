import Foundation

/// 协议编解码与帧化：4 字节大端长度前缀 + JSON 载荷。
public enum Wire {
    public static let maxFrameSize = 64 * 1024 * 1024

    private static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.outputFormatting = [.sortedKeys]
        return e
    }()
    private static let decoder = JSONDecoder()

    public static func json<T: Encodable>(_ value: T) -> Data? {
        try? encoder.encode(value)
    }

    public static func parse<T: Decodable>(_ type: T.Type, from data: Data) -> T? {
        try? decoder.decode(type, from: data)
    }

    public static func frame(_ payload: Data) -> Data {
        let length = UInt32(payload.count).bigEndian
        return withUnsafeBytes(of: length) { Data($0) } + payload
    }
}

/// 流式拆包：喂入任意切块到达的 TCP 数据，吐出完整帧载荷。
public struct FrameAccumulator {
    private var buffer = Data()

    public init() {}

    public mutating func feed(_ chunk: Data) -> [Data] {
        buffer.append(chunk)
        var frames: [Data] = []
        while buffer.count >= 4 {
            let length = buffer.prefix(4).reduce(into: 0) { $0 = ($0 << 8) | Int($1) }
            guard length >= 0, length <= Wire.maxFrameSize else {
                // 帧长度非法，丢弃缓冲（对端会因协议错断开）
                buffer.removeAll()
                return frames
            }
            guard buffer.count >= 4 + length else { break }
            frames.append(buffer.subdata(in: 4..<(4 + length)))
            buffer.removeSubrange(0..<(4 + length))
        }
        return frames
    }
}
