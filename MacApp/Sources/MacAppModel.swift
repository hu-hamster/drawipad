import Foundation
import PencilKit
import SwiftUI

/// Mac 端进行中的实时预览笔迹（未提交的采集点）。
struct LiveStroke: Identifiable {
    let id: UUID
    var color: NSColor
    var width: CGFloat
    var points: [LivePoint]
}

/// 重命名目标。
enum RenameTarget: Identifiable {
    case folder(UUID)
    case page(UUID)

    var id: UUID {
        switch self {
        case .folder(let id), .page(let id):
            return id
        }
    }
}

/// Mac 端总状态：数据仓库 + 服务端 + 画布显示。
/// 全部在主线程。
final class MacAppModel: ObservableObject {
    struct PairingPrompt: Identifiable {
        let id = UUID()
        let deviceName: String
        let accept: () -> Void
        let reject: () -> Void
    }

    let store = LibraryStore()
    let server = DrawPadServer()

    @Published var selectedFolderID: UUID?
    @Published var selectedPageID: UUID?
    @Published var displayedDrawing = PKDrawing()
    /// displayedDrawing 每次内容变化时 +1，驱动画布刷新。
    @Published var drawingRevision = 0
    /// 当前页底图。
    @Published var displayedBgImage: NSImage?
    /// 画板缩放百分比（相对"适配窗口"）。
    @Published var zoomPercent = 100
    @Published var liveStroke: LiveStroke?
    @Published var pairing: PairingPrompt?
    @Published var clientName: String?
    @Published var renameTarget: RenameTarget?
    @Published var renameText = ""
    @Published var confirmDeleteCurrent = false

    /// 预览笔迹的安全清除定时（笔画结束后若真实笔迹未到达则清掉）。
    private var liveClearWork: DispatchWorkItem?

    /// 调试参数：自动接受配对（本地自动化测试用，正常使用不传）。
    private let autoAcceptPairing = ProcessInfo.processInfo.arguments.contains("--auto-accept-pairing")

    /// 当前画板视图（浮动缩放控件调用）。
    weak var boardView: BoardCanvasView?

    func boardZoomIn() {
        boardView?.zoomIn()
    }

    func boardZoomOut() {
        boardView?.zoomOut()
    }

    func boardFit() {
        boardView?.fit()
    }

    init() {
        store.loadIfNeeded()
        // 优先选中最后一个"有页面"的文件夹，避免打开即空状态
        let folder = store.folders.last(where: { !$0.pageIDs.isEmpty })
            ?? store.folders.last
        if let folder {
            selectedFolderID = folder.id
            selectedPageID = folder.pageIDs.last
        }
        loadDisplayed()
        startServer()
    }

    var currentMeta: PageMeta? {
        selectedPageID.flatMap { store.pageMeta($0) }
    }

    // MARK: - 浮动工具条辅助

    var pageIndicatorText: String {
        guard let folderID = selectedFolderID else { return "—" }
        let metas = store.pages(in: folderID)
        guard let id = selectedPageID,
              let index = metas.firstIndex(where: { $0.id == id }) else {
            return "— / \(metas.count)"
        }
        return "\(index + 1) / \(metas.count)"
    }

    func pageIndex(_ page: PageMeta) -> Int {
        guard let folderID = selectedFolderID else { return -1 }
        return store.pages(in: folderID).firstIndex { $0.id == page.id } ?? -1
    }

    func pageCount(in page: PageMeta) -> Int {
        store.pages(in: store.folderID(containing: page.id) ?? UUID()).count
    }

    func prevPageFromUI() {
        guard let folderID = selectedFolderID else { return }
        let metas = store.pages(in: folderID)
        guard let id = selectedPageID,
              let index = metas.firstIndex(where: { $0.id == id }),
              index > 0 else { return }
        selectPage(metas[index - 1].id, remote: false)
    }

    func nextPageFromUI() {
        guard let folderID = selectedFolderID else { return }
        let metas = store.pages(in: folderID)
        guard let id = selectedPageID,
              let index = metas.firstIndex(where: { $0.id == id }),
              index < metas.count - 1 else { return }
        selectPage(metas[index + 1].id, remote: false)
    }

    func selectFolderFromUI(_ folderID: UUID) {
        guard let folder = store.folder(folderID) else { return }
        selectedFolderID = folderID
        if let last = folder.pageIDs.last {
            selectPage(last, remote: false)
        } else {
            selectedPageID = nil
            loadDisplayed()
        }
    }

    // MARK: - 选中页

    /// remote = 变化来自 iPad（不再回推）；false = 本地 UI 选中（需推送给 iPad）。
    func selectPage(_ id: UUID?, remote: Bool = false) {
        selectedPageID = id
        selectedFolderID = id.flatMap { store.folderID(containing: $0) } ?? selectedFolderID
        loadDisplayed()
        if !remote, let id, server.hasClient {
            pushPageOpen(id)
        }
    }

    func loadDisplayed() {
        if let id = selectedPageID,
           let data = store.drawingData(id),
           let drawing = try? PKDrawing(data: data) {
            displayedDrawing = drawing
        } else {
            displayedDrawing = PKDrawing()
        }
        displayedBgImage = selectedPageID.flatMap { store.bgImage($0) }
        drawingRevision += 1
        liveStroke = nil
    }

    private func pushPageOpen(_ id: UUID) {
        guard let data = store.drawingData(id),
              let folderID = store.folderID(containing: id) else { return }
        server.send(
            .pageOpened(
                pageID: id,
                folderID: folderID,
                drawingData: data,
                strokeCount: store.strokeCount(id),
                backgroundImage: store.bgImageData(id)
            )
        )
    }

    private func pushLibrary() {
        server.send(.libraryChanged(snapshot: store.snapshot()))
    }

    // MARK: - 服务端

    private func startServer() {
        server.onPairingRequest = { [weak self] request in
            guard let self else { return }
            if self.autoAcceptPairing {
                request.accept()
                return
            }
            let prompt = PairingPrompt(
                deviceName: request.deviceName,
                accept: { request.accept() },
                reject: { request.reject() }
            )
            self.pairing = prompt
        }
        server.onClientConnected = { [weak self] _ in
            guard let self else { return }
            self.clientName = self.server.clientName
            self.pushInitial()
        }
        server.onClientDisconnected = { [weak self] _ in
            self?.clientName = nil
            self?.liveStroke = nil
        }
        server.onMessage = { [weak self] message in
            self?.handleClientMessage(message)
        }
        do {
            try server.start()
        } catch {
            NSLog("DrawPad server start failed: \(error)")
        }
    }

    private func pushInitial() {
        pushLibrary()
        if let id = selectedPageID {
            pushPageOpen(id)
        }
    }

    func disconnectClient() {
        server.disconnectClient()
    }

    // MARK: - iPad 消息处理

    private func handleClientMessage(_ message: ClientMessage) {
        switch message {
        case .hello:
            break // 握手已在服务端处理

        case .requestProjectList:
            pushLibrary()
            if let id = selectedPageID {
                pushPageOpen(id)
            }

        case .openPage(let pageID):
            guard store.pageMeta(pageID) != nil else { break }
            selectPage(pageID, remote: true)

        case .projectSelect(let folderID):
            guard let folder = store.folder(folderID) else { break }
            selectedFolderID = folderID
            if let last = folder.pageIDs.last {
                selectPage(last, remote: true)
            } else {
                selectedPageID = nil
                loadDisplayed()
            }

        case .pageCreate(let folderID, let afterPageID, let width, let height):
            guard store.folder(folderID) != nil else { break }
            let size = CGSize(width: max(320, width), height: max(320, height))
            let meta = store.createPage(
                folderID: folderID,
                afterPageID: afterPageID,
                size: size
            )
            pushLibrary()
            selectPage(meta.id, remote: true)
            pushPageOpen(meta.id)

        case .pageDelete(let pageID):
            let wasCurrent = pageID == selectedPageID
            let neighbor = store.deletePage(pageID)
            pushLibrary()
            if wasCurrent {
                if let neighbor {
                    selectPage(neighbor, remote: true)
                    pushPageOpen(neighbor)
                } else {
                    selectedPageID = nil
                    loadDisplayed()
                }
            }

        case .strokeCommitted(let pageID, let strokeData, _):
            let stroke = store.appendStroke(pageID: pageID, strokeData: strokeData)
            if pageID == selectedPageID {
                if let stroke {
                    displayedDrawing = PKDrawing(strokes: displayedDrawing.strokes + [stroke])
                    drawingRevision += 1
                }
                liveStroke = nil
            }

        case .liveBegin(let strokeID, let pageID, let style):
            guard pageID == selectedPageID else { break }
            liveStroke = LiveStroke(
                id: strokeID,
                color: NSColor(
                    srgbRed: CGFloat(style.red),
                    green: CGFloat(style.green),
                    blue: CGFloat(style.blue),
                    alpha: CGFloat(style.alpha)
                ),
                width: CGFloat(style.width),
                points: []
            )

        case .livePoints(_, let pageID, let points):
            guard pageID == selectedPageID, liveStroke != nil else { break }
            liveStroke?.points.append(contentsOf: points)

        case .liveEnd(_, let pageID):
            // 保留预览直到真实笔迹（strokeCommitted）到达；超时兜底清除
            guard pageID == selectedPageID, liveStroke != nil else { break }
            scheduleLiveClear()

        case .fullPageResync(let pageID, let drawingData, _):
            guard let drawing = try? PKDrawing(data: drawingData) else { break }
            store.replaceDrawing(pageID: pageID, drawingData: drawingData)
            if pageID == selectedPageID {
                displayedDrawing = drawing
                drawingRevision += 1
                liveStroke = nil
            }

        case .backgroundImageSet(let pageID, let imageData):
            store.saveBgImage(pageID, imageData: imageData)
            if pageID == selectedPageID {
                displayedBgImage = imageData.isEmpty ? nil : NSImage(data: imageData)
            }
        }
    }

    private func scheduleLiveClear() {
        liveClearWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.liveStroke = nil
        }
        liveClearWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5, execute: work)
    }

    // MARK: - 本地管理操作（UI 调用）

    func addFolder() {
        let folder = store.createFolder()
        selectedFolderID = folder.id
        pushLibrary()
    }

    func addPage(in folderID: UUID? = nil) {
        let targetFolder = folderID ?? selectedFolderID ?? store.folders.last?.id
        guard let targetFolder else { return }
        let meta = store.createPage(folderID: targetFolder, afterPageID: selectedPageID)
        pushLibrary()
        selectPage(meta.id, remote: false)
    }

    func deletePageLocal(_ id: UUID) {
        let wasCurrent = id == selectedPageID
        let neighbor = store.deletePage(id)
        pushLibrary()
        if wasCurrent {
            if let neighbor {
                selectPage(neighbor, remote: false)
            } else {
                selectedPageID = nil
                loadDisplayed()
            }
        }
    }

    func deleteFolderLocal(_ id: UUID) {
        store.deleteFolder(id)
        pushLibrary()
        reselect()
    }

    private func reselect() {
        if let folder = store.folders.last, let pageID = folder.pageIDs.last {
            selectPage(pageID, remote: false)
        } else {
            selectedFolderID = nil
            selectedPageID = nil
            loadDisplayed()
        }
    }

    // MARK: - 重命名

    func beginRename(_ target: RenameTarget) {
        switch target {
        case .folder(let id):
            renameText = store.folder(id)?.name ?? ""
        case .page(let id):
            renameText = store.pageMeta(id)?.name ?? ""
        }
        renameTarget = target
    }

    func commitRename() {
        guard let target = renameTarget else { return }
        let name = renameText.trimmingCharacters(in: .whitespacesAndNewlines)
        switch target {
        case .folder(let id):
            store.renameFolder(id, to: name)
        case .page(let id):
            store.renamePage(id, to: name)
        }
        renameTarget = nil
        pushLibrary()
    }
}
