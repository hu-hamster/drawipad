import Foundation
import SwiftUI

/// iPad 端总状态：连接 + 项目树缓存 + Excalidraw 场景同步。
/// 全部在主线程。
final class PadModel: ObservableObject {
    @Published var phase: DrawPadClient.Phase = .idle
    @Published var discovered: [MacBrowser.Item] = []
    @Published var snapshot = LibrarySnapshot()
    @Published var currentFolderID: UUID?
    @Published var currentPageID: UUID?
    @Published var toast: String?
    @Published var connectedServerName: String?
    @Published var webViewReady = false
    /// 已成功连接过（断线重连时保持画布界面）。
    @Published var wasConnected = false

    let client = DrawPadClient()
    let browser = MacBrowser()

    weak var webView: PadBoardWebView?

    /// 本地场景变化 → 推送 Mac 的防抖。
    private var scenePushWork: DispatchWorkItem?
    private var toastWork: DispatchWorkItem?

    init() {
        browser.onUpdate = { [weak self] items in
            guard let self else { return }
            self.discovered = items
            print("[DrawPad] 发现 Mac 数量: \(items.count) \(items.map(\.name))")
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
        snapshot = LibrarySnapshot()
        currentFolderID = nil
        currentPageID = nil
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
        client.connect(to: item.endpoint)
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
            print("[DrawPad] 收到画板: \(fileID.uuidString.prefix(8)) 元素数=\((elementsJSON as NSString).length / 100)")
            currentFolderID = folderID
            currentPageID = fileID
            webView?.applyScene(elementsJSON)
            toast = nil

        case .sceneUpdate(let fileID, let elementsJSON):
            print("[DrawPad] 远端场景更新: \(fileID.uuidString.prefix(8))")
            guard fileID == currentPageID else { return }
            webView?.applyScene(elementsJSON)

        case .serverError(let message):
            showToast(message)
        }
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

    func handleLocalSceneChange(_ json: String) {
        guard case .connected = phase, let pageID = currentPageID else { return }
        print("[DrawPad] 本地场景变化 → 推送 (\(json.count) 字节)")
        scenePushWork?.cancel()
        let item = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.client.send(.sceneUpdate(fileID: pageID, elementsJSON: json))
        }
        scenePushWork = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12, execute: item)
    }
}
