import Foundation

/// Mac 端数据仓库：项目/文件元数据 + 每个文件的 Excalidraw 场景 JSON。
/// 全部在主线程访问。
final class LibraryStore: ObservableObject {
    struct LibraryData: Codable {
        var version: Int = 3
        var folders: [Folder] = []
        var pages: [PageMeta] = []
    }

    @Published private(set) var library = LibraryData()

    let root: URL
    private var scenesDir: URL { root.appendingPathComponent("scenes", isDirectory: true) }
    private var libraryURL: URL { root.appendingPathComponent("library.json") }
    private var persistWork: DispatchWorkItem?
    private var sceneSaveWork: DispatchWorkItem?
    private var pendingSceneSaves: [UUID: String] = [:]

    init(root: URL? = nil) {
        let base = root
            ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("DrawPad", isDirectory: true)
        self.root = base
        try? FileManager.default.createDirectory(at: scenesDir, withIntermediateDirectories: true)
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
            library.version = 3
        } else {
            bootstrap()
        }
    }

    private func bootstrap() {
        let page = PageMeta(name: "未命名画板 1")
        var folder = Folder(name: "我的项目")
        folder.pageIDs = [page.id]
        library = LibraryData(folders: [folder], pages: [page])
        writeScene("[]", for: page.id)
        persist()
    }

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

    var rootFolders: [Folder] {
        library.folders.filter { $0.parentID == nil }
    }

    func folder(_ id: UUID) -> Folder? {
        library.folders.first { $0.id == id }
    }

    func childFolders(of parentID: UUID) -> [Folder] {
        library.folders.filter { $0.parentID == parentID }
    }

    func containsFolder(_ descendantID: UUID?, within ancestorID: UUID) -> Bool {
        guard var currentID = descendantID else { return false }
        var visited = Set<UUID>()
        while visited.insert(currentID).inserted {
            if currentID == ancestorID { return true }
            guard let parentID = folder(currentID)?.parentID else { return false }
            currentID = parentID
        }
        return false
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

    // MARK: - 场景数据

    func sceneJSON(_ pageID: UUID) -> String? {
        let url = scenesDir.appendingPathComponent(pageID.uuidString + ".excalidraw")
        guard let data = try? Data(contentsOf: url), !data.isEmpty else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private func writeScene(_ json: String, for pageID: UUID) {
        let url = scenesDir.appendingPathComponent(pageID.uuidString + ".excalidraw")
        try? Data(json.utf8).write(to: url, options: .atomic)
    }

    /// 防抖保存场景（150ms），高频编辑不落盘。
    func scheduleSaveScene(_ pageID: UUID, json: String) {
        pendingSceneSaves[pageID] = json
        sceneSaveWork?.cancel()
        let item = DispatchWorkItem { [weak self] in
            guard let self else { return }
            let saves = self.pendingSceneSaves
            self.pendingSceneSaves.removeAll(keepingCapacity: true)
            for (id, json) in saves {
                self.writeScene(json, for: id)
                if let index = self.library.pages.firstIndex(where: { $0.id == id }) {
                    self.library.pages[index].updatedAt = Date()
                }
            }
            self.schedulePersist()
        }
        sceneSaveWork = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15, execute: item)
    }

    // MARK: - 文件夹管理

    @discardableResult
    func createFolder(name: String = "新目录", parentID: UUID? = nil) -> Folder {
        var finalName = name
        var index = 1
        while library.folders.contains(where: { $0.parentID == parentID && $0.name == finalName }) {
            index += 1
            finalName = "\(name) \(index)"
        }
        let folder = Folder(name: finalName, parentID: parentID)
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
        guard folder(id) != nil else { return }
        var folderIDs: Set<UUID> = [id]
        var changed = true
        while changed {
            changed = false
            for candidate in library.folders where candidate.parentID.map(folderIDs.contains) == true {
                if folderIDs.insert(candidate.id).inserted { changed = true }
            }
        }
        let pageIDs = Set(
            library.folders
                .filter { folderIDs.contains($0.id) }
                .flatMap(\.pageIDs)
        )
        for pageID in pageIDs {
            try? FileManager.default.removeItem(at: scenesDir.appendingPathComponent(pageID.uuidString + ".excalidraw"))
        }
        library.folders.removeAll { folderIDs.contains($0.id) }
        library.pages.removeAll { pageIDs.contains($0.id) }
        persist()
    }

    // MARK: - 文件管理

    @discardableResult
    func createPage(
        folderID: UUID,
        afterPageID: UUID? = nil,
        name: String? = nil,
        initialSceneJSON: String = "[]"
    ) -> PageMeta {
        let existingNames = Set(pages(in: folderID).map(\.name))
        var index = existingNames.count + 1
        let baseName = name ?? "画板"
        var finalName = name ?? "\(baseName) 1"
        while existingNames.contains(finalName) {
            index += 1
            finalName = "\(baseName) \(index)"
        }
        let page = PageMeta(name: finalName)
        writeScene(initialSceneJSON, for: page.id)
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

    /// 删除文件，返回删除后应显示的相邻文件（同文件夹）。
    @discardableResult
    func deletePage(_ id: UUID) -> UUID? {
        guard let folderIndex = library.folders.firstIndex(where: { $0.pageIDs.contains(id) }) else {
            return nil
        }
        let ids = library.folders[folderIndex].pageIDs
        let index = ids.firstIndex(of: id) ?? 0
        library.folders[folderIndex].pageIDs.removeAll { $0 == id }
        library.pages.removeAll { $0.id == id }
        try? FileManager.default.removeItem(at: scenesDir.appendingPathComponent(id.uuidString + ".excalidraw"))
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
}
