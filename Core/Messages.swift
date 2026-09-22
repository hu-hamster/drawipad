import Foundation

/// 同步协议版本，两端不一致时拒绝连接。
public let drawPadProtocolVersion = 1

/// 实时笔迹采集点（页面坐标系，原点左上，单位：点）。
public struct LivePoint: Codable, Equatable, Sendable {
    public var x: Double
    public var y: Double
    /// 归一化压力 0...1
    public var force: Double
    /// 触摸时间戳（秒，自设备启动）
    public var time: Double

    public init(x: Double, y: Double, force: Double, time: Double) {
        self.x = x
        self.y = y
        self.force = force
        self.time = time
    }
}

/// iPad 当前工具的墨迹样式，用于 Mac 端预览线与真实笔迹视觉接近。
public struct StrokeStyleInfo: Codable, Equatable, Sendable {
    public var red: Double
    public var green: Double
    public var blue: Double
    public var alpha: Double
    public var width: Double

    public init(red: Double, green: Double, blue: Double, alpha: Double, width: Double) {
        self.red = red
        self.green = green
        self.blue = blue
        self.alpha = alpha
        self.width = width
    }
}

/// iPad（客户端）→ Mac（服务端）消息。
public enum ClientMessage: Codable, Equatable, Sendable {
    /// 连接握手。服务端收到后弹出配对确认。
    case hello(deviceName: String, protocolVersion: Int)
    case requestProjectList
    /// 请求切换并打开某页（服务端会回 pageOpened）。
    case openPage(pageID: UUID)
    /// 切换当前项目文件夹。
    case projectSelect(folderID: UUID)
    /// 在文件夹内新建页面（插入到 afterPageID 之后，nil 表示末尾）。
    /// width/height 为新建页的画布尺寸（iPad 取当前屏幕大小，页面即全屏）。
    case pageCreate(folderID: UUID, afterPageID: UUID?, width: Double, height: Double)
    case pageDelete(pageID: UUID)
    /// 一笔绘制完成：携带单笔 PKStroke 编码（单笔 PKDrawing 二进制）。
    case strokeCommitted(pageID: UUID, strokeData: Data, strokeCount: Int)
    /// 实时预览：笔画开始 / 点批量 / 结束。
    case liveBegin(strokeID: UUID, pageID: UUID, style: StrokeStyleInfo)
    case livePoints(strokeID: UUID, pageID: UUID, points: [LivePoint])
    case liveEnd(strokeID: UUID, pageID: UUID)
    /// 撤销 / 橡皮 / 移动等造成差异后的整页重传。
    case fullPageResync(pageID: UUID, drawingData: Data, strokeCount: Int)
    /// 设置/替换页面底图（JPEG 数据；空 Data 表示移除底图）。
    case backgroundImageSet(pageID: UUID, imageData: Data)
}

/// Mac（服务端）→ iPad（客户端）消息。
public enum ServerMessage: Codable, Equatable, Sendable {
    case helloAccepted(serverName: String)
    case rejected(reason: String)
    /// 项目树有变化（新建/删除/重命名，或初次下发）。
    case libraryChanged(snapshot: LibrarySnapshot)
    /// 打开某页：携带整页 PKDrawing 二进制 + 可选底图 JPEG。
    case pageOpened(pageID: UUID, folderID: UUID, drawingData: Data, strokeCount: Int, backgroundImage: Data?)
    case serverError(message: String)
}
