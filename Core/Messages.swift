import Foundation

/// 同步协议版本，两端不一致时拒绝连接。
public let drawPadProtocolVersion = 2

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
    /// 本端视口平移变化（拖动画布，双端同步）。
    case viewportPanChanged(scrollX: Double, scrollY: Double)
    /// 本端缩放变化（捏合等，携带缩放后的滚动位置以保持锚点，双端同步 1:1）。
    case viewportZoomChanged(zoom: Double, scrollX: Double, scrollY: Double)
}

/// Mac（服务端）→ iPad（客户端）消息。
public enum ServerMessage: Codable, Equatable {
    case helloAccepted(serverName: String)
    case rejected(reason: String)
    /// 项目树有变化（新建/删除/重命名，或初次下发）。
    case libraryChanged(snapshot: LibrarySnapshot)
    /// 打开某文件：携带完整 Excalidraw 场景 JSON。
    case fileOpened(fileID: UUID, folderID: UUID, elementsJSON: String)
    /// 对端场景变化推送。
    case sceneUpdate(fileID: UUID, elementsJSON: String)
    /// 对端视口平移推送。
    case viewportPanChanged(scrollX: Double, scrollY: Double)
    /// 对端缩放推送（携带滚动位置）。
    case viewportZoomChanged(zoom: Double, scrollX: Double, scrollY: Double)
    case serverError(message: String)
}
