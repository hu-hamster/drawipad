import Foundation

/// 同步协议版本，两端不一致时拒绝连接。
public let drawPadProtocolVersion = 3

/// 项目树快照（Excalidraw 场景文件的组织结构：文件夹 → 文件）。
/// 页面即一个 Excalidraw 场景（scene JSON），顺序由 Folder.pageIDs 决定。
public typealias FileMeta = PageMeta

/// iPad（客户端）→ Mac（服务端）消息。
public enum ClientMessage: Codable, Equatable {
    /// 连接握手。服务端收到后弹出配对确认。
    case hello(deviceName: String, protocolVersion: Int)
    case requestProjectList
    /// 请求切换并打开某文件（服务端会回 fileOpened）。
    case openFile(fileID: UUID)
    /// 切换当前项目文件夹。
    case projectSelect(folderID: UUID)
    /// 在文件夹内新建文件（插入到 afterFileID 之后，nil 表示末尾）。
    case fileCreate(folderID: UUID, afterFileID: UUID?)
    case fileDelete(fileID: UUID)
    /// 本端场景发生变化（Excalidraw elements JSON，防抖后发送）。
    case sceneUpdate(fileID: UUID, elementsJSON: String)
    /// 本端视口平移变化（以画面中心点对齐，双端同步）。
    case viewportPanChanged(centerX: Double, centerY: Double)
    /// 本端缩放变化（接收端按屏幕比例换算，使对端画面完整映射到本端）。
    case viewportZoomChanged(zoom: Double, centerX: Double, centerY: Double, viewWidth: Double, viewHeight: Double)
}

/// Mac（服务端）→ iPad（客户端）消息。
public enum ServerMessage: Codable, Equatable {
    case helloAccepted(serverName: String)
    case rejected(reason: String)
    /// Mac 主动结束当前会话；iPad 收到后停止自动重连并返回连接页。
    case sessionEnded(reason: String)
    /// 项目树有变化（新建/删除/重命名，或初次下发）。
    case libraryChanged(snapshot: LibrarySnapshot)
    /// 打开某文件：携带完整 Excalidraw 场景 JSON。
    case fileOpened(fileID: UUID, folderID: UUID, elementsJSON: String)
    /// 对端场景变化推送。
    case sceneUpdate(fileID: UUID, elementsJSON: String)
    /// 对端视口平移推送。
    case viewportPanChanged(centerX: Double, centerY: Double)
    /// 对端缩放推送（含中心点与对端屏幕尺寸）。
    case viewportZoomChanged(zoom: Double, centerX: Double, centerY: Double, viewWidth: Double, viewHeight: Double)
    case serverError(message: String)
}
