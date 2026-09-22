import Foundation
import SwiftUI

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

    var isFolder: Bool {
        if case .folder = self { return true }
        return false
    }
}

/// Mac 端总状态：数据仓库 + 服务端 + 嵌入式 Excalidraw 画布。
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
    @Published var pairing: PairingPrompt?
    @Published var clientName: String?
    @Published var renameTarget: RenameTarget?
    @Published var renameText = ""
    @Published var isCreatingFolder = false
    @Published var newFolderName = ""
    @Published var confirmDeleteCurrent = false
    @Published var webViewReady = false

    /// 调试参数：自动接受配对（本地自动化测试用，正常使用不传）。
    private let autoAcceptPairing = ProcessInfo.processInfo.arguments.contains("--auto-accept-pairing")

    weak var webView: BoardWebView?

    /// 场景推送节流。
    private var scenePushWork: DispatchWorkItem?
    private var latestSceneJSON: String?
    /// 视口同步。
    private var viewportPushWork: DispatchWorkItem?
    private var pendingPan: (cx: Double, cy: Double)?
    /// 最近一次已知视口（连接对齐用）。
    private(set) var lastViewport: (cx: Double, cy: Double, z: Double, vw: Double, vh: Double)?
    private var initialViewportSentForClient = false
    private var initialViewportReadInFlight = false
    private var initialViewportRetryWork: DispatchWorkItem?

    init() {
        store.loadIfNeeded()
        let folder = store.folders.last(where: { !$0.pageIDs.isEmpty }) ?? store.folders.last
        if let folder {
            selectedFolderID = folder.id
            selectedPageID = folder.pageIDs.last
        }
        startServer()
    }

    var currentMeta: PageMeta? {
        selectedPageID.flatMap { store.pageMeta($0) }
    }

    // MARK: - 画布（WebView）回调

    func handleWebViewReady() {
        webViewReady = true
        showCurrentSceneInWebView()
        if server.hasClient {
            sendInitialViewportIfReady()
        } else {
            // 预先记录视口，连接回调仍会重新读取一次最新值。
            webView?.requestViewport { [weak self] viewport in
                if let viewport { self?.lastViewport = viewport }
            }
        }
        // 工具栏位置探针：验证右侧布局 CSS 是否生效（延后避开重挂载竞态）
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { [weak self] in
            self?.webView?.toolbarProbe()
        }
    }

    /// 本端平移：节流推送给 iPad（~50ms 节奏）。
    func handleLocalViewportPan(_ cx: Double, _ cy: Double) {
        lastViewport?.cx = cx
        lastViewport?.cy = cy
        guard server.hasClient else { return }
        pendingPan = (cx, cy)
        guard viewportPushWork == nil else { return }
        let item = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.viewportPushWork = nil
            if let pending = self.pendingPan {
                self.pendingPan = nil
                self.server.send(.viewportPanChanged(centerX: pending.cx, centerY: pending.cy))
            }
        }
        viewportPushWork = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05, execute: item)
    }

    /// 本端缩放：立即推送（低频事件）。
    func handleLocalViewportZoom(_ z: Double, _ cx: Double, _ cy: Double, _ vw: Double, _ vh: Double) {
        lastViewport = (cx, cy, z, vw, vh)
        guard server.hasClient else { return }
        viewportPushWork?.cancel()
        viewportPushWork = nil
        pendingPan = nil
        server.send(
            .viewportZoomChanged(zoom: z, centerX: cx, centerY: cy, viewWidth: vw, viewHeight: vh)
        )
    }

    func fitToContent() {
        webView?.fitToContent()
    }

    /// 本端 Excalidraw 场景变化：存盘 + 节流推送给 iPad（~80ms 固定节奏）。
    func handleLocalSceneChange(_ json: String) {
        guard let id = selectedPageID else { return }
        // 初始化期画布会多次自报空场景，直接忽略，防止清空已有内容
        if json == "[]" {
            BoardWebViewMessageProxy.diag("忽略本端空场景广播（初始化噪声）")
            return
        }
        store.scheduleSaveScene(id, json: json)
        guard server.hasClient else { return }
        latestSceneJSON = json
        guard scenePushWork == nil else { return } // 已排定节奏，到点发最新值
        let item = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.scenePushWork = nil
            if let json = self.latestSceneJSON {
                self.latestSceneJSON = nil
                self.server.send(.sceneUpdate(fileID: id, elementsJSON: json))
            }
        }
        scenePushWork = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.08, execute: item)
    }

    private func showCurrentSceneInWebView() {
        let scene = selectedPageID.flatMap { store.sceneJSON($0) } ?? "[]"
        webView?.applyScene(scene)
    }

    // MARK: - 选中文件

    /// remote = 变化来自 iPad（不再回推）；false = 本地 UI 选中（需推送给 iPad）。
    func selectPage(_ id: UUID?, remote: Bool = false) {
        selectedPageID = id
        selectedFolderID = id.flatMap { store.folderID(containing: $0) } ?? selectedFolderID
        showCurrentSceneInWebView()
        if !remote, let id, server.hasClient {
            pushFileOpen(id)
        }
    }

    private func pushFileOpen(_ id: UUID) {
        guard let folderID = store.folderID(containing: id) else { return }
        server.send(
            .fileOpened(
                fileID: id,
                folderID: folderID,
                elementsJSON: store.sceneJSON(id) ?? "[]"
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
            self.initialViewportSentForClient = false
            self.initialViewportReadInFlight = false
            self.initialViewportRetryWork?.cancel()
            self.initialViewportRetryWork = nil
            self.pushInitial()
        }
        server.onClientDisconnected = { [weak self] _ in
            guard let self else { return }
            self.clientName = nil
            self.initialViewportRetryWork?.cancel()
            self.initialViewportRetryWork = nil
            self.initialViewportReadInFlight = false
            self.initialViewportSentForClient = false
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
            pushFileOpen(id)
        }
        sendInitialViewportIfReady()
    }

    /// 场景树和当前文件下发后，等 Mac 画布 WebView 就绪并读取一次实时视口再发给 iPad。
    private func sendInitialViewportIfReady(attempt: Int = 0) {
        guard server.hasClient, webViewReady,
              !initialViewportSentForClient,
              !initialViewportReadInFlight,
              let webView else { return }

        initialViewportReadInFlight = true
        webView.requestViewport { [weak self] viewport in
            guard let self else { return }
            self.initialViewportReadInFlight = false
            guard self.server.hasClient,
                  self.webViewReady,
                  !self.initialViewportSentForClient else { return }

            if let viewport {
                self.lastViewport = viewport
                self.server.send(
                    .viewportZoomChanged(
                        zoom: viewport.z,
                        centerX: viewport.cx,
                        centerY: viewport.cy,
                        viewWidth: viewport.vw,
                        viewHeight: viewport.vh
                    )
                )
                self.initialViewportSentForClient = true
                return
            }

            if attempt < 5 {
                let retry = DispatchWorkItem { [weak self] in
                    self?.initialViewportRetryWork = nil
                    self?.sendInitialViewportIfReady(attempt: attempt + 1)
                }
                self.initialViewportRetryWork?.cancel()
                self.initialViewportRetryWork = retry
                DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(120), execute: retry)
            } else if let fallback = self.lastViewport {
                self.server.send(
                    .viewportZoomChanged(
                        zoom: fallback.z,
                        centerX: fallback.cx,
                        centerY: fallback.cy,
                        viewWidth: fallback.vw,
                        viewHeight: fallback.vh
                    )
                )
                self.initialViewportSentForClient = true
            } else {
                BoardWebViewMessageProxy.diag("无法读取初始视口；等待下一次视口变化")
            }
        }
    }

    func disconnectClient() {
        server.disconnectClient()
    }

    // MARK: - iPad 消息处理

    private func handleClientMessage(_ message: ClientMessage) {
        switch message {
        case .hello:
            break

        case .requestProjectList:
            pushLibrary()
            if let id = selectedPageID {
                pushFileOpen(id)
            }

        case .openFile(let fileID):
            guard store.pageMeta(fileID) != nil else { break }
            selectPage(fileID, remote: true)

        case .projectSelect(let folderID):
            guard let folder = store.folder(folderID) else { break }
            selectedFolderID = folderID
            if let last = folder.pageIDs.last {
                selectPage(last, remote: true)
            } else {
                selectedPageID = nil
                showCurrentSceneInWebView()
            }

        case .fileCreate(let folderID, let afterFileID):
            guard store.folder(folderID) != nil else { break }
            let meta = store.createPage(folderID: folderID, afterPageID: afterFileID)
            pushLibrary()
            selectPage(meta.id, remote: true)
            pushFileOpen(meta.id)

        case .fileDelete(let fileID):
            let wasCurrent = fileID == selectedPageID
            let neighbor = store.deletePage(fileID)
            pushLibrary()
            if wasCurrent {
                if let neighbor {
                    selectPage(neighbor, remote: true)
                    pushFileOpen(neighbor)
                } else {
                    selectedPageID = nil
                    showCurrentSceneInWebView()
                }
            }

        case .sceneUpdate(let fileID, let elementsJSON):
            BoardWebViewMessageProxy.diag("iPad 场景推送: \(elementsJSON.count) 字节 (file \(fileID.uuidString.prefix(6)), 当前 \(selectedPageID?.uuidString.prefix(6) ?? "-"))")
            store.scheduleSaveScene(fileID, json: elementsJSON)
            if fileID == selectedPageID {
                webView?.applyScene(elementsJSON)
            }

        case .viewportPanChanged(let centerX, let centerY):
            lastViewport?.cx = centerX
            lastViewport?.cy = centerY
            webView?.applyViewportPan(centerX, centerY)

        case .viewportZoomChanged(let zoom, let centerX, let centerY, let viewWidth, let viewHeight):
            lastViewport = (centerX, centerY, zoom, viewWidth, viewHeight)
            webView?.applyViewportZoom(
                zoom,
                centerX: centerX,
                centerY: centerY,
                peerWidth: viewWidth,
                peerHeight: viewHeight
            )
        }
    }

    // MARK: - 本地管理操作（UI 调用）

    func addFolder() {
        newFolderName = ""
        isCreatingFolder = true
    }

    func createFolderFromUI() {
        let name = newFolderName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        let folder = store.createFolder(name: name)
        selectedFolderID = folder.id
        selectedPageID = nil
        showCurrentSceneInWebView()
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
                showCurrentSceneInWebView()
            }
        }
    }

    func deleteFolderLocal(_ id: UUID) {
        store.deleteFolder(id)
        pushLibrary()
        if let folder = store.folders.last(where: { !$0.pageIDs.isEmpty }) ?? store.folders.last {
            selectedFolderID = folder.id
            if let pageID = folder.pageIDs.last {
                selectPage(pageID, remote: false)
            } else {
                selectedPageID = nil
                showCurrentSceneInWebView()
            }
        } else {
            selectedFolderID = nil
            selectedPageID = nil
            showCurrentSceneInWebView()
        }
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

    var pageCountCurrent: Int {
        guard let folderID = selectedFolderID else { return 0 }
        return store.pages(in: folderID).count
    }

    var pageIndexCurrent: Int {
        guard let folderID = selectedFolderID,
              let id = selectedPageID else { return -1 }
        return store.pages(in: folderID).firstIndex { $0.id == id } ?? -1
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
            showCurrentSceneInWebView()
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
