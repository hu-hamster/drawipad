import Foundation
import SwiftUI
import AppKit
import UniformTypeIdentifiers

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
    @Published private(set) var openPageIDs: [UUID] = []
    @Published var pairing: PairingPrompt?
    @Published var clientName: String?
    @Published var renameTarget: RenameTarget?
    @Published var renameText = ""
    @Published var isCreatingFolder = false
    @Published var newFolderName = ""
    @Published var newFolderParentID: UUID?
    @Published var confirmDeleteCurrent = false
    @Published var webViewReady = false
    @Published var importError: String?

    /// 调试参数：自动接受配对（本地自动化测试用，正常使用不传）。
    private let autoAcceptPairing = ProcessInfo.processInfo.arguments.contains("--auto-accept-pairing")

    weak var webView: (any BoardSurface)?
    private var webViewPageID: UUID?

    /// 场景推送节流。
    private var scenePushWork: DispatchWorkItem?
    private var latestSceneUpdate: (pageID: UUID, json: String)?
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
            if let selectedPageID { openPageIDs = [selectedPageID] }
        }
        startServer()
    }

    var currentMeta: PageMeta? {
        selectedPageID.flatMap { store.pageMeta($0) }
    }

    var openPages: [PageMeta] {
        openPageIDs.compactMap { store.pageMeta($0) }
    }

    // MARK: - 画布（WebView）回调

    func attachWebView(_ view: any BoardSurface) {
        webView = view
        webViewPageID = selectedPageID
        webViewReady = false
    }

    func handleWebViewReady(_ view: any BoardSurface) {
        guard webView === view, webViewPageID == selectedPageID else { return }
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
    func handleLocalSceneChange(_ json: String, from view: any BoardSurface) {
        guard webView === view, webViewReady,
              let id = selectedPageID, webViewPageID == id else { return }
        // 初始化期画布会多次自报空场景，直接忽略，防止清空已有内容
        if json == "[]" {
            BoardWebViewMessageProxy.diag("忽略本端空场景广播（初始化噪声）")
            return
        }
        store.scheduleSaveScene(id, json: json)
        guard server.hasClient else { return }
        latestSceneUpdate = (id, json)
        guard scenePushWork == nil else { return } // 已排定节奏，到点发最新值
        let item = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.scenePushWork = nil
            if let update = self.latestSceneUpdate {
                self.latestSceneUpdate = nil
                self.server.send(.sceneUpdate(fileID: update.pageID, elementsJSON: update.json))
            }
        }
        scenePushWork = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.08, execute: item)
    }

    private func showCurrentSceneInWebView() {
        guard webViewReady, webViewPageID == selectedPageID else { return }
        let canvas = currentMeta?.isCanvas == true
        let scene = selectedPageID.flatMap { store.sceneJSON($0) } ?? (canvas ? PageMeta.emptyCanvas : "[]")
        webView?.applyScene(scene)
    }

    // MARK: - 选中文件

    /// remote = 变化来自 iPad（不再回推）；false = 本地 UI 选中（需推送给 iPad）。
    func selectPage(_ id: UUID?, remote: Bool = false) {
        if let id, store.pageMeta(id) == nil { return }
        if id != selectedPageID {
            flushPendingSceneUpdate()
            webView = nil
            webViewPageID = nil
            webViewReady = false
        }
        if let id, !openPageIDs.contains(id) { openPageIDs.append(id) }
        selectedPageID = id
        selectedFolderID = id.flatMap { store.folderID(containing: $0) } ?? selectedFolderID
        if !remote, let id, server.hasClient {
            pushFileOpen(id)
        }
    }

    func closePageTab(_ id: UUID) {
        guard let index = openPageIDs.firstIndex(of: id) else { return }
        openPageIDs.remove(at: index)
        guard selectedPageID == id else { return }
        let next = openPageIDs.indices.contains(index) ? openPageIDs[index] : openPageIDs.last
        selectPage(next, remote: false)
    }

    private func flushPendingSceneUpdate() {
        scenePushWork?.cancel()
        scenePushWork = nil
        if let update = latestSceneUpdate, server.hasClient {
            server.send(.sceneUpdate(fileID: update.pageID, elementsJSON: update.json))
        }
        latestSceneUpdate = nil
    }

    private func discardPendingSceneUpdate(for pageIDs: Set<UUID>) {
        guard let update = latestSceneUpdate, pageIDs.contains(update.pageID) else { return }
        scenePushWork?.cancel()
        scenePushWork = nil
        latestSceneUpdate = nil
    }

    private func pushFileOpen(_ id: UUID) {
        guard let folderID = store.folderID(containing: id) else { return }
        server.send(
            .fileOpened(
                fileID: id,
                folderID: folderID,
                elementsJSON: store.sceneJSON(id) ?? (store.pageMeta(id)?.isCanvas == true ? PageMeta.emptyCanvas : "[]")
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
            pushFileOpen(fileID)

        case .projectSelect(let folderID):
            guard let folder = store.folder(folderID) else { break }
            selectedFolderID = folderID
            if let last = folder.pageIDs.last {
                selectPage(last, remote: true)
                pushFileOpen(last)
            } else {
                selectPage(nil, remote: true)
            }

        case .fileCreate(let folderID, let afterFileID):
            createPageFromPeer(folderID: folderID, afterFileID: afterFileID, fileExtension: nil)

        case .fileCreateCanvas(let folderID, let afterFileID):
            createPageFromPeer(folderID: folderID, afterFileID: afterFileID, fileExtension: "canvas")

        case .fileDelete(let fileID):
            let wasCurrent = fileID == selectedPageID
            discardPendingSceneUpdate(for: [fileID])
            let neighbor = store.deletePage(fileID)
            openPageIDs.removeAll { $0 == fileID }
            pushLibrary()
            if wasCurrent {
                if let next = openPageIDs.last ?? neighbor {
                    selectPage(next, remote: true)
                    pushFileOpen(next)
                } else {
                    selectPage(nil, remote: true)
                }
            }

        case .sceneUpdate(let fileID, let elementsJSON):
            BoardWebViewMessageProxy.diag("iPad 场景推送: \(elementsJSON.count) 字节 (file \(fileID.uuidString.prefix(6)), 当前 \(selectedPageID?.uuidString.prefix(6) ?? "-"))")
            store.scheduleSaveScene(fileID, json: elementsJSON)
            if fileID == selectedPageID, webViewReady, webViewPageID == fileID {
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

    func addFolder(parentID: UUID? = nil) {
        newFolderName = ""
        newFolderParentID = parentID
        isCreatingFolder = true
    }

    func createFolderFromUI() {
        let name = newFolderName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        let folder = store.createFolder(name: name, parentID: newFolderParentID)
        selectedFolderID = folder.id
        selectPage(nil, remote: true)
        newFolderParentID = nil
        pushLibrary()
    }

    func addPage(in folderID: UUID? = nil, fileExtension: String? = nil) {
        let targetFolder = folderID ?? selectedFolderID ?? store.folders.last?.id
        guard let targetFolder else { return }
        let meta = store.createPage(
            folderID: targetFolder,
            afterPageID: selectedPageID,
            fileExtension: fileExtension
        )
        pushLibrary()
        selectPage(meta.id, remote: false)
    }

    private func createPageFromPeer(folderID: UUID, afterFileID: UUID?, fileExtension: String?) {
        guard store.folder(folderID) != nil else { return }
        let meta = store.createPage(
            folderID: folderID,
            afterPageID: afterFileID,
            fileExtension: fileExtension
        )
        pushLibrary()
        selectPage(meta.id, remote: true)
        pushFileOpen(meta.id)
    }

    // MARK: - Excalidraw 导入

    /// 选择并导入原生 .excalidraw 或 Obsidian 的 .excalidraw.md 文件。
    func importExcalidraw() {
        let panel = NSOpenPanel()
        panel.title = "导入 Excalidraw 画板"
        panel.message = "支持 .excalidraw、.excalidraw.md 和 JSON 场景文件"
        panel.prompt = "导入"
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        // `.excalidraw.md` is commonly registered as
        // `net.daringfireball.markdown`, while constructing a type from the
        // `md` extension can produce a different dynamic identifier.  That
        // mismatch leaves the file visible in NSOpenPanel but disables the
        // Import button.  Accept data files here and let ExcalidrawImport do
        // the actual (strict) content validation below.
        panel.allowedContentTypes = [.data]

        panel.begin { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            self?.importExcalidraw(from: url)
        }
    }

    private func importExcalidraw(from url: URL) {
        let accessed = url.startAccessingSecurityScopedResource()
        defer {
            if accessed { url.stopAccessingSecurityScopedResource() }
        }

        do {
            let text = try String(contentsOf: url, encoding: .utf8)
            guard let scene = ExcalidrawImport.parseScene(fromText: text) else {
                importError = "未能从“\(url.lastPathComponent)”找到有效的 Excalidraw 场景。"
                return
            }

            let folderID = selectedFolderID ?? store.folders.last?.id ?? store.createFolder(name: "导入").id
            let page = store.createPage(
                folderID: folderID,
                afterPageID: selectedPageID,
                name: ExcalidrawImport.pageName(fromFileName: url.lastPathComponent),
                initialSceneJSON: scene
            )
            pushLibrary()
            selectPage(page.id, remote: false)
        } catch {
            importError = "无法读取“\(url.lastPathComponent)”：\(error.localizedDescription)"
        }
    }

    func importCanvas() {
        let panel = NSOpenPanel()
        panel.title = "导入 Canvas"
        panel.prompt = "导入"
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [UTType(filenameExtension: "canvas") ?? .json, .json]
        panel.begin { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            self?.importCanvas(from: url)
        }
    }

    func exportCanvas() {
        guard currentMeta?.isCanvas == true, let id = selectedPageID else { return }
        let panel = NSSavePanel()
        panel.title = "导出 Canvas"
        panel.nameFieldStringValue = (currentMeta?.name ?? "Canvas") + ".canvas"
        panel.allowedContentTypes = [UTType(filenameExtension: "canvas") ?? .json]
        panel.begin { [weak self] response in
            guard response == .OK, let url = panel.url, let json = self?.store.sceneJSON(id) else { return }
            try? Data(json.utf8).write(to: url, options: .atomic)
        }
    }

    private func importCanvas(from url: URL) {
        let accessed = url.startAccessingSecurityScopedResource()
        defer { if accessed { url.stopAccessingSecurityScopedResource() } }
        do {
            let text = try String(contentsOf: url, encoding: .utf8)
            guard let data = text.data(using: .utf8),
                  var object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  (object["nodes"] == nil || object["nodes"] is [Any]),
                  (object["edges"] == nil || object["edges"] is [Any]) else {
                importError = "“\(url.lastPathComponent)”不是有效的 Canvas 文件。"
                return
            }
            if object["nodes"] == nil { object["nodes"] = [Any]() }
            if object["edges"] == nil { object["edges"] = [Any]() }
            let normalized = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
            let folderID = selectedFolderID ?? store.folders.last?.id ?? store.createFolder(name: "导入").id
            let page = store.createPage(
                folderID: folderID,
                afterPageID: selectedPageID,
                name: url.deletingPathExtension().lastPathComponent,
                fileExtension: "canvas",
                initialSceneJSON: String(decoding: normalized, as: UTF8.self)
            )
            pushLibrary()
            selectPage(page.id, remote: false)
        } catch {
            importError = "无法读取“\(url.lastPathComponent)”：\(error.localizedDescription)"
        }
    }

    func deletePageLocal(_ id: UUID) {
        let wasCurrent = id == selectedPageID
        discardPendingSceneUpdate(for: [id])
        let neighbor = store.deletePage(id)
        openPageIDs.removeAll { $0 == id }
        pushLibrary()
        if wasCurrent {
            if let next = openPageIDs.last ?? neighbor {
                selectPage(next, remote: false)
            } else {
                selectPage(nil, remote: false)
            }
        }
    }

    func deleteFolderLocal(_ id: UUID) {
        let removedPageIDs = Set(store.snapshot().folders
            .filter { store.containsFolder($0.id, within: id) }
            .flatMap(\.pageIDs))
        discardPendingSceneUpdate(for: removedPageIDs)
        store.deleteFolder(id)
        openPageIDs.removeAll { store.pageMeta($0) == nil }
        pushLibrary()
        if let selectedPageID, store.pageMeta(selectedPageID) != nil { return }
        if let next = openPageIDs.last {
            selectPage(next, remote: false)
            return
        }
        if let folder = store.folders.last(where: { !$0.pageIDs.isEmpty }) ?? store.folders.last {
            selectedFolderID = folder.id
            if let pageID = folder.pageIDs.last {
                selectPage(pageID, remote: false)
            } else {
                selectPage(nil, remote: false)
            }
        } else {
            selectedFolderID = nil
            selectPage(nil, remote: false)
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
            selectPage(nil, remote: false)
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
