import Foundation
import SwiftUI

/// iPad 端总状态：连接 + 项目树缓存 + Excalidraw 场景同步。
/// 全部在主线程。
final class PadModel: ObservableObject {
    private static let preferredServerNameKey = "DrawPadPreferredServerName"
    @Published var phase: DrawPadClient.Phase = .idle
    @Published var discovered: [MacBrowser.Item] = []
    @Published var snapshot = LibrarySnapshot()
    @Published var currentFolderID: UUID?
    @Published var currentPageID: UUID?
    @Published var toast: String?
    @Published var connectedServerName: String?
    @Published var webViewReady = false
    /// 画布就绪前到达的场景（就绪后应用）。
    var pendingScene: String?
    /// 初始场景确认写入当前 WebView 后才允许向 Mac 回传，防止空画布覆盖远端。
    private var sceneReadyForEditing = false
    private var isApplyingPendingScene = false
    /// 已成功连接过（断线重连时保持画布界面）。
    @Published var wasConnected = false

    let client = DrawPadClient()
    let browser = MacBrowser()

    weak var webView: (any PadBoardSurface)?

    /// 本地场景变化 → 推送 Mac 的节流。
    private var scenePushWork: DispatchWorkItem?
    private var latestSceneJSON: String?
    /// 视口同步。
    private var viewportPushWork: DispatchWorkItem?
    private var latestPan: (Double, Double)?
    /// 初始握手期间先缓存远端视口，等场景进入 WebView 后再套用，避免被场景居中逻辑覆盖。
    private var pendingViewportZoom: (zoom: Double, cx: Double, cy: Double, vw: Double, vh: Double)?
    private var viewportApplyWork: DispatchWorkItem?
    private var toastWork: DispatchWorkItem?
    /// 每次应用生命周期只自动尝试一次，避免用户主动断开后又被立即拉回连接。
    private var didTryAutomaticConnection = false

    init() {
        browser.onUpdate = { [weak self] items in
            guard let self else { return }
            self.discovered = items
            print("[DrawPad] 发现 Mac 数量: \(items.count) \(items.map(\.name))")
            self.reconnectToRediscoveredServiceIfNeeded(items)
            self.connectAutomaticallyIfPossible(items)
        }
        client.onPhase = { [weak self] phase in
            guard let self else { return }
            print("[DrawPad] 连接状态: \(phase)")
            self.phase = phase
            switch phase {
            case .connected:
                wasConnected = true
            case .failed:
                wasConnected = false
            case .idle:
                if !wasConnected {
                    connectedServerName = nil
                    resetSession()
                }
            default:
                break
            }
        }
        client.onMessage = { [weak self] message in
            self?.handle(message)
        }
        browser.start()
    }

    private func resetSession() {
        scenePushWork?.cancel()
        scenePushWork = nil
        latestSceneJSON = nil
        viewportPushWork?.cancel()
        viewportPushWork = nil
        latestPan = nil
        viewportApplyWork?.cancel()
        viewportApplyWork = nil
        pendingViewportZoom = nil
        webViewReady = false
        webView = nil
        pendingScene = nil
        sceneReadyForEditing = false
        isApplyingPendingScene = false
        snapshot = LibrarySnapshot()
        currentFolderID = nil
        currentPageID = nil
    }

    func attachWebView(_ view: any PadBoardSurface) {
        viewportApplyWork?.cancel()
        viewportApplyWork = nil
        webView = view
        webViewReady = false
        sceneReadyForEditing = false
        isApplyingPendingScene = false
    }

    func handleWebViewReady(_ view: any PadBoardSurface) {
        guard webView === view else { return }
        webViewReady = true
        applyPendingSceneIfReady()
    }

    private func applyPendingSceneIfReady() {
        guard webViewReady,
              !isApplyingPendingScene,
              let view = webView,
              let scene = pendingScene,
              let pageID = currentPageID
        else { return }

        isApplyingPendingScene = true
        print("[DrawPad] 应用待加载场景 \(scene.count) 字节")
        view.applyScene(scene) { [weak self, weak view] success in
            guard let self, let view, self.webView === view else { return }
            self.isApplyingPendingScene = false

            if success, self.currentPageID == pageID, self.pendingScene == scene {
                self.pendingScene = nil
                self.sceneReadyForEditing = true
                print("[DrawPad] 初始场景已加载，可安全编辑")
                self.applyPendingViewportZoomWhenReady()
                return
            }

            if !success {
                print("[DrawPad] 初始场景加载失败，保持禁止回传")
            }
            if self.currentPageID != pageID || self.pendingScene != scene {
                self.applyPendingSceneIfReady()
            }
        }
    }

    // MARK: - 派生数据

    var currentFolder: Folder? {
        snapshot.folders.first { $0.id == currentFolderID }
    }

    var currentPageMetas: [PageMeta] {
        guard let folder = currentFolder else { return [] }
        let byID = Dictionary(uniqueKeysWithValues: snapshot.pages.map { ($0.id, $0) })
        return folder.pageIDs.compactMap { byID[$0] }
    }

    var currentIndex: Int {
        currentPageMetas.firstIndex { $0.id == currentPageID } ?? -1
    }

    var pageIndicator: String {
        let metas = currentPageMetas
        if currentIndex >= 0, !metas.isEmpty {
            return "\(currentIndex + 1) / \(metas.count)"
        }
        return "— / \(metas.count)"
    }

    // MARK: - 连接

    func connect(_ item: MacBrowser.Item) {
        UserDefaults.standard.set(item.name, forKey: Self.preferredServerNameKey)
        didTryAutomaticConnection = true
        client.connect(to: item.endpoint)
    }

    private func connectAutomaticallyIfPossible(_ items: [MacBrowser.Item]) {
        guard !didTryAutomaticConnection,
              phase == .idle,
              !items.isEmpty
        else { return }

        let preferredName = UserDefaults.standard.string(forKey: Self.preferredServerNameKey)
        let target = preferredName.flatMap { name in
            items.first { $0.name == name }
        } ?? items.first { $0.name == "DrawPad Web" }
          ?? (items.count == 1 ? items[0] : nil)

        guard let target else { return }
        didTryAutomaticConnection = true
        print("[DrawPad] 自动连接: \(target.name)")
        connect(target)
    }

    /// 服务重启后 Bonjour 端口会变化；断线重连时采用同名服务的新 endpoint，
    /// 不再无限重试已经失效的旧端口。
    private func reconnectToRediscoveredServiceIfNeeded(_ items: [MacBrowser.Item]) {
        guard case .reconnecting = phase,
              let preferredName = UserDefaults.standard.string(forKey: Self.preferredServerNameKey),
              let target = items.first(where: { $0.name == preferredName })
        else { return }

        print("[DrawPad] 服务已重新发现，切换到新端点: \(target.name)")
        client.connect(to: target.endpoint)
    }

    func disconnect() {
        client.disconnect()
        wasConnected = false
        connectedServerName = nil
        resetSession()
    }

    // MARK: - 服务端消息

    private func handle(_ message: ServerMessage) {
        switch message {
        case .helloAccepted(let serverName):
            print("[DrawPad] 已被 Mac 接受: \(serverName)")
            connectedServerName = serverName

        case .rejected(let reason):
            print("[DrawPad] 被拒绝: \(reason)")
            showToast(reason)
            connectedServerName = nil

        case .sessionEnded(let reason):
            print("[DrawPad] Mac 已结束会话: \(reason)")
            disconnect()
            showToast(reason)

        case .libraryChanged(let newSnapshot):
            print("[DrawPad] 收到项目树: \(newSnapshot.folders.count) 项目 \(newSnapshot.pages.count) 画板")
            snapshot = newSnapshot
            if let id = currentFolderID,
               newSnapshot.folders.contains(where: { $0.id == id }) {
                // 当前项目仍在，保持
            } else {
                currentFolderID = newSnapshot.folders.last?.id
            }

        case .fileOpened(let fileID, let folderID, let elementsJSON):
            print("[DrawPad] 收到画板: \(fileID.uuidString.prefix(8)) 元素字节=\(elementsJSON.count)")
            currentFolderID = folderID
            currentPageID = fileID
            sceneReadyForEditing = false
            pendingScene = elementsJSON
            if !webViewReady {
                print("[DrawPad] 画布未就绪，场景暂存 \(elementsJSON.count) 字节")
            }
            applyPendingSceneIfReady()
            toast = nil

        case .sceneUpdate(let fileID, let elementsJSON):
            print("[DrawPad] 远端场景更新: \(fileID.uuidString.prefix(8))")
            guard fileID == currentPageID else { return }
            if sceneReadyForEditing, webViewReady {
                webView?.applyScene(elementsJSON)
            } else {
                pendingScene = elementsJSON
                applyPendingSceneIfReady()
            }

        case .viewportPanChanged(let centerX, let centerY):
            webView?.applyViewportPan(centerX, centerY)

        case .viewportZoomChanged(let zoom, let centerX, let centerY, let viewWidth, let viewHeight):
            pendingViewportZoom = (zoom, centerX, centerY, viewWidth, viewHeight)
            applyPendingViewportZoomWhenReady()

        case .serverError(let message):
            showToast(message)
        }
    }

    private func applyPendingViewportZoomWhenReady() {
        guard webViewReady, sceneReadyForEditing, let view = webView,
              pendingViewportZoom != nil else { return }

        viewportApplyWork?.cancel()
        let work = DispatchWorkItem { [weak self, weak view] in
            guard let self, let view,
                  self.webView === view,
                  self.webViewReady,
                  self.sceneReadyForEditing,
                  let viewport = self.pendingViewportZoom else { return }

            self.pendingViewportZoom = nil
            self.viewportApplyWork = nil
            view.applyViewportZoom(
                viewport.zoom,
                centerX: viewport.cx,
                centerY: viewport.cy,
                peerWidth: viewport.vw,
                peerHeight: viewport.vh
            )
        }
        viewportApplyWork = work
        // Excalidraw 的 updateScene 会在下一轮渲染中提交；让视口应用排在初始场景之后。
        DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(80), execute: work)
    }

    func showToast(_ text: String) {
        toast = text
        toastWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.toast = nil
        }
        toastWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5, execute: work)
    }

    // MARK: - 文件操作

    func openPage(_ id: UUID) {
        guard id != currentPageID else { return }
        client.send(.openFile(fileID: id))
    }

    func prevPage() {
        let index = currentIndex
        guard index > 0, index <= currentPageMetas.count - 1 else { return }
        openPage(currentPageMetas[index - 1].id)
    }

    func nextPage() {
        let index = currentIndex
        guard index >= 0, index < currentPageMetas.count - 1 else { return }
        openPage(currentPageMetas[index + 1].id)
    }

    func selectFolder(_ id: UUID) {
        guard id != currentFolderID else { return }
        client.send(.projectSelect(folderID: id))
    }

    func newCanvas() {
        let folderID = currentFolderID ?? snapshot.folders.last?.id
        guard let folderID else {
            showToast("没有可用项目")
            return
        }
        client.send(.fileCreateCanvas(folderID: folderID, afterFileID: currentPageID))
    }

    func newPage() {
        let folderID = currentFolderID ?? snapshot.folders.last?.id
        guard let folderID else {
            showToast("没有可用项目")
            return
        }
        client.send(.fileCreate(folderID: folderID, afterFileID: currentPageID))
    }

    func deleteCurrentPage() {
        guard let pageID = currentPageID else { return }
        client.send(.fileDelete(fileID: pageID))
    }

    // MARK: - 本地场景变化 → Mac

    /// 本地场景变化 → 节流推送 Mac（固定节奏 ~80ms，不因连续绘制而推迟）。
    func handleLocalSceneChange(_ json: String) {
        guard case .connected = phase,
              let pageID = currentPageID
        else { return }
        // 初始化期画布会多次自报空场景，空内容仍需拦截，避免覆盖远端。
        // 但只要用户已经画出了非空内容，就不能因为初始场景确认回调缺失而丢弃更新。
        if !sceneReadyForEditing && json == "[]" {
            return
        }
        if !sceneReadyForEditing {
            sceneReadyForEditing = true
            print("[DrawPad] 检测到本地非空绘制，解除场景回传保护")
        }
        latestSceneJSON = json
        guard scenePushWork == nil else { return } // 已排定节奏，到点发最新值
        let item = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.scenePushWork = nil
            if let json = self.latestSceneJSON {
                self.latestSceneJSON = nil
                self.client.send(.sceneUpdate(fileID: pageID, elementsJSON: json))
            }
        }
        scenePushWork = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.08, execute: item)
    }

    // MARK: - 视口同步

    /// 本端平移：节流推送 Mac（~50ms 节奏）。
    func handleLocalViewportPan(_ cx: Double, _ cy: Double) {
        guard case .connected = phase else { return }
        latestPan = (cx, cy)
        guard viewportPushWork == nil else { return }
        let item = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.viewportPushWork = nil
            if let pan = self.latestPan {
                self.latestPan = nil
                self.client.send(.viewportPanChanged(centerX: pan.0, centerY: pan.1))
            }
        }
        viewportPushWork = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05, execute: item)
    }

    /// 本端捏合缩放：立即推送（对端按屏幕比例换算，画面完整映射）。
    func handleLocalViewportZoom(_ z: Double, _ cx: Double, _ cy: Double, _ vw: Double, _ vh: Double) {
        guard case .connected = phase else { return }
        viewportPushWork?.cancel()
        viewportPushWork = nil
        latestPan = nil
        client.send(
            .viewportZoomChanged(zoom: z, centerX: cx, centerY: cy, viewWidth: vw, viewHeight: vh)
        )
    }

    /// iPad 按钮缩放（同步到 Mac）。
    func localZoom(_ factor: Double) {
        webView?.localZoom(factor)
    }

    func fitToContent() {
        webView?.fitToContent()
    }
}
