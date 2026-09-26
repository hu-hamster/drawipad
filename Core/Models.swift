import Foundation

/// 项目文件夹（即"项目"），包含有序的页面列表。
public struct Folder: Codable, Identifiable, Equatable, Hashable, Sendable {
    public var id: UUID
    public var name: String
    public var createdAt: Date
    /// 父目录；nil 表示根目录。可选字段保证旧版 library.json / 协议载荷仍可解码。
    public var parentID: UUID?
    public var pageIDs: [UUID]

    public init(
        id: UUID = UUID(),
        name: String,
        createdAt: Date = Date(),
        parentID: UUID? = nil,
        pageIDs: [UUID] = []
    ) {
        self.id = id
        self.name = name
        self.createdAt = createdAt
        self.parentID = parentID
        self.pageIDs = pageIDs
    }
}

/// 页面元数据。页面墨迹内容单独存为 PKDrawing 二进制文件。
public struct PageMeta: Codable, Identifiable, Equatable, Hashable, Sendable {
    public var id: UUID
    public var name: String
    public var createdAt: Date
    public var updatedAt: Date
    /// 页面画布逻辑尺寸（点）。创建时由 iPad 屏幕方向或 Mac 默认值决定，
    /// 两端渲染共用同一坐标系，保证笔迹坐标一致。
    public var width: Double
    public var height: Double
    /// 文件后缀。缺省是 excalidraw，保证旧库和旧协议载荷仍按画板处理。
    public var fileExtension: String?

    public init(
        id: UUID = UUID(),
        name: String,
        createdAt: Date = Date(),
        updatedAt: Date = Date(),
        width: Double = 1366,
        height: Double = 1024,
        fileExtension: String? = nil
    ) {
        self.id = id
        self.name = name
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.width = width
        self.height = height
        self.fileExtension = fileExtension
    }

    public var pageSize: CGSize { CGSize(width: width, height: height) }

    public var documentExtension: String {
        fileExtension == "canvas" ? "canvas" : "excalidraw"
    }

    public var isCanvas: Bool { documentExtension == "canvas" }

    public static let emptyCanvas = "{\"nodes\":[],\"edges\":[]}"
}

/// 传输用的项目树快照（页面的显示顺序由 Folder.pageIDs 决定）。
public struct LibrarySnapshot: Codable, Equatable, Sendable {
    public var folders: [Folder]
    public var pages: [PageMeta]

    public init(folders: [Folder] = [], pages: [PageMeta] = []) {
        self.folders = folders
        self.pages = pages
    }
}
