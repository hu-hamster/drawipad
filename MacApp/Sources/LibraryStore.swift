import Foundation
import PencilKit

/// Mac 端数据仓库：项目/页面元数据 + 每页 PKDrawing 文件。
/// 全部在主线程访问。
final class LibraryStore: ObservableObject {
    struct LibraryData: Codable {
        var version: Int = 1
        var folders: [Folder] = []
        var pages: [PageMeta] = []
    }

    @Published private(set) var library = LibraryData()

    let root: URL
    private var pagesDir: URL { root.appendingPathComponent("pages", isDirectory: true) }
    private var libraryURL: URL { root.appendingPathComponent("library.json") }
    private var thumbCache: [UUID: (Date, NSImage)] = [:]
    private var persistWork: DispatchWorkItem?

    init(root: URL? = nil) {
        let base = root
            ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("DrawPad", isDirectory: true)
        self.root = base
        try? FileManager.default.createDirectory(at: pagesDir, withIntermediateDirectories: true)
    }

    // MARK: - 加载

    func loadIfNeeded() {
        guard FileManager.default.fileExists(atPath: libraryURL.path) else {
            bootstrap()
            return
        }
        if let data = try? Data(contentsOf: libraryURL),
           let decoded = try? JSONDecoder().decode(LibraryData.self, from: data) {
            library = decoded
        } else {
            bootstrap()
        }
    }

    private func bootstrap() {
        let page = PageMeta(name: "第 1 页")
        var folder = Folder(name: "我的项目")
        folder.pageIDs = [page.id]
        library = LibraryData(folders: [folder], pages: [page])
        writeDrawingData(PKDrawing().dataRepresentation(), for: page.id)
        persist()
    }

    /// 立即写元数据（文件很小，不需要防抖）。
    private func persist() {
        if let data = try? JSONEncoder().encode(library) {
            try? data.write(to: libraryURL, options: .atomic)
        }
    }

    private func schedulePersist() {
        persistWork?.cancel()
        let item = DispatchWorkItem { [weak self] in self?.persist() }
        persistWork = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: item)
    }

    // MARK: - 查询

    var folders: [Folder] { library.folders }

    func folder(_ id: UUID) -> Folder? {
        library.folders.first { $0.id == id }
    }

    func folderID(containing pageID: UUID) -> UUID? {
        library.folders.first { $0.pageIDs.contains(pageID) }?.id
    }

    func pageMeta(_ id: UUID) -> PageMeta? {
        library.pages.first { $0.id == id }
    }

    func pages(in folderID: UUID) -> [PageMeta] {
        guard let folder = folder(folderID) else { return [] }
        let byID = Dictionary(uniqueKeysWithValues: library.pages.map { ($0.id, $0) })
        return folder.pageIDs.compactMap { byID[$0] }
    }

    func snapshot() -> LibrarySnapshot {
        LibrarySnapshot(folders: library.folders, pages: library.pages)
    }

    // MARK: - 绘制数据

    func drawingData(_ pageID: UUID) -> Data? {
        let url = pagesDir.appendingPathComponent(pageID.uuidString + ".drawing")
        return try? Data(contentsOf: url)
    }

    // MARK: 页面底图（图片导入，画在其上）

    func bgImageData(_ pageID: UUID) -> Data? {
        let url = pagesDir.appendingPathComponent(pageID.uuidString + ".bg.jpg")
        guard let data = try? Data(contentsOf: url), !data.isEmpty else { return nil }
        return data
    }

    func bgImage(_ pageID: UUID) -> NSImage? {
        guard let data = bgImageData(pageID) else { return nil }
        return NSImage(data: data)
    }

    /// 保存底图；空 data 移除底图。
    func saveBgImage(_ pageID: UUID, imageData: Data) {
        let url = pagesDir.appendingPathComponent(pageID.uuidString + ".bg.jpg")
        if imageData.isEmpty {
            try? FileManager.default.removeItem(at: url)
        } else {
            try? imageData.write(to: url, options: .atomic)
        }
        thumbCache[pageID] = nil
        schedulePersist()
    }

    private func removeBgFile(_ pageID: UUID) {
        try? FileManager.default.removeItem(at: pagesDir.appendingPathComponent(pageID.uuidString + ".bg.jpg"))
    }

    func drawing(_ pageID: UUID) -> PKDrawing? {
        guard let data = drawingData(pageID) else { return nil }
        return try? PKDrawing(data: data)
    }

    func strokeCount(_ pageID: UUID) -> Int {
        drawing(pageID)?.strokes.count ?? 0
    }

    private func writeDrawingData(_ data: Data, for pageID: UUID) {
        let url = pagesDir.appendingPathComponent(pageID.uuidString + ".drawing")
        try? data.write(to: url, options: .atomic)
    }

    private func touchMeta(_ pageID: UUID) {
        if let index = library.pages.firstIndex(where: { $0.id == pageID }) {
            library.pages[index].updatedAt = Date()
        }
        thumbCache[pageID] = nil
        schedulePersist()
    }

    /// 追加一笔，返回该 PKStroke。
    func appendStroke(pageID: UUID, strokeData: Data) -> PKStroke? {
        guard let stroke = (try? PKDrawing(data: strokeData))?.strokes.first else { return nil }
        let drawing = self.drawing(pageID) ?? PKDrawing()
        let updated = PKDrawing(strokes: drawing.strokes + [stroke])
        writeDrawingData(updated.dataRepresentation(), for: pageID)
        touchMeta(pageID)
        return stroke
    }

    /// 整页替换（iPad 撤销/橡皮后的重传）。
    func replaceDrawing(pageID: UUID, drawingData: Data) {
        writeDrawingData(drawingData, for: pageID)
        touchMeta(pageID)
    }

    // MARK: - 文件夹管理

    @discardableResult
    func createFolder(name: String = "新项目") -> Folder {
        var finalName = name
        var index = 1
        while library.folders.contains(where: { $0.name == finalName }) {
            index += 1
            finalName = "\(name) \(index)"
        }
        let folder = Folder(name: finalName)
        library.folders.append(folder)
        persist()
        return folder
    }

    func renameFolder(_ id: UUID, to name: String) {
        guard !name.isEmpty,
              let index = library.folders.firstIndex(where: { $0.id == id }) else { return }
        library.folders[index].name = name
        persist()
    }

    func deleteFolder(_ id: UUID) {
        guard let folder = folder(id) else { return }
        for pageID in folder.pageIDs {
            try? FileManager.default.removeItem(at: pagesDir.appendingPathComponent(pageID.uuidString + ".drawing"))
            removeBgFile(pageID)
        }
        library.folders.removeAll { $0.id == id }
        library.pages.removeAll { folder.pageIDs.contains($0.id) }
        persist()
    }

    // MARK: - 页面管理

    @discardableResult
    func createPage(folderID: UUID, afterPageID: UUID? = nil, size: CGSize = CGSize(width: 1366, height: 1024)) -> PageMeta {
        let existingNames = Set(pages(in: folderID).map(\.name))
        var index = existingNames.count + 1
        while existingNames.contains("第 \(index) 页") {
            index += 1
        }
        let page = PageMeta(name: "第 \(index) 页", width: size.width, height: size.height)
        writeDrawingData(PKDrawing().dataRepresentation(), for: page.id)
        library.pages.append(page)
        if let folderIndex = library.folders.firstIndex(where: { $0.id == folderID }) {
            if let after = afterPageID,
               let afterIndex = library.folders[folderIndex].pageIDs.firstIndex(of: after) {
                library.folders[folderIndex].pageIDs.insert(page.id, at: afterIndex + 1)
            } else {
                library.folders[folderIndex].pageIDs.append(page.id)
            }
        }
        persist()
        return page
    }

    /// 删除页面，返回删除后应显示的相邻页（同文件夹）。
    @discardableResult
    func deletePage(_ id: UUID) -> UUID? {
        guard let folderIndex = library.folders.firstIndex(where: { $0.pageIDs.contains(id) }) else {
            return nil
        }
        let ids = library.folders[folderIndex].pageIDs
        let index = ids.firstIndex(of: id) ?? 0
        library.folders[folderIndex].pageIDs.removeAll { $0 == id }
        library.pages.removeAll { $0.id == id }
        try? FileManager.default.removeItem(at: pagesDir.appendingPathComponent(id.uuidString + ".drawing"))
        removeBgFile(id)
        persist()
        let remaining = library.folders[folderIndex].pageIDs
        if index < remaining.count {
            return remaining[index]
        }
        return remaining.last
    }

    func renamePage(_ id: UUID, to name: String) {
        guard !name.isEmpty,
              let index = library.pages.firstIndex(where: { $0.id == id }) else { return }
        library.pages[index].name = name
        persist()
    }

    // MARK: - 缩略图

    func thumbnail(for meta: PageMeta) -> NSImage? {
        if let cached = thumbCache[meta.id], cached.0 == meta.updatedAt {
            return cached.1
        }
        let drawing = drawing(meta.id)
        let bg = bgImage(meta.id)
        guard drawing != nil || bg != nil else { return nil }
        let target: CGFloat = 160
        let scale = max(min(target / meta.pageSize.width, target / meta.pageSize.height), 0.2)
        guard
            let rendered = PageRenderer.composite(
                drawing: drawing,
                background: bg,
                pageSize: meta.pageSize,
                padding: 10,
                scale: scale
            )
        else { return nil }
        thumbCache[meta.id] = (meta.updatedAt, rendered.image)
        return rendered.image
    }
}
