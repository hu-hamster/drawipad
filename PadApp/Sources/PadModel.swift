import Foundation
import PencilKit
import SwiftUI

/// 画笔种类（Notability 风格工具托盘）。
enum PenKind: String, CaseIterable, Identifiable {
    case pen
    case pencil
    case marker
    case eraser

    var id: String { rawValue }

    var icon: String {
        switch self {
        case .pen: return "pencil.tip"
        case .pencil: return "pencil"
        case .marker: return "highlighter"
        case .eraser: return "eraser.fill"
        }
    }

    var label: String {
        switch self {
        case .pen: return "钢笔"
        case .pencil: return "铅笔"
        case .marker: return "荧光笔"
        case .eraser: return "橡皮"
        }
    }

    var inkType: PKInkingTool.InkType? {
        switch self {
        case .pen: return .pen
        case .pencil: return .pencil
        case .marker: return .marker
        case .eraser: return nil
        }
    }
}

/// iPad 端总状态：连接 + 项目树缓存 + 画布 + 笔画同步。
/// 全部在主线程。
final class PadModel: ObservableObject {
    @Published var phase: DrawPadClient.Phase = .idle
    @Published var discovered: [MacBrowser.Item] = []
    @Published var snapshot = LibrarySnapshot()
    @Published var currentFolderID: UUID?
    @Published var currentPageID: UUID?
    @Published var canvasDrawing = PKDrawing()
    /// canvasDrawing 内容变化时 +1，驱动画布刷新。
    @Published var drawingRevision = 0
    @Published var toast: String?
    @Published var connectedServerName: String?
    /// 已成功连接过（用于断线重连时保持画布界面而非退回连接页）。
    @Published var wasConnected = false

    let client = DrawPadClient()
    let browser = MacBrowser()

    // MARK: 同步状态

    /// 最近一次与服务端一致的整页数据。
    private var lastSyncedData: Data?
    private var lastSyncedCount = 0
    private var resyncWork: DispatchWorkItem?

    // MARK: 实时点流

    private var liveStrokeID: UUID?
    private var liveBuffer: [LivePoint] = []
    private var liveFlushWork: DispatchWorkItem?
    /// 画布当前屏幕尺寸（新建页面时作为页面尺寸，实现全屏覆盖）。
    var canvasScreenSize: CGSize = CGSize(width: 1366, height: 1024)

    weak var canvasRef: FittingPKCanvas?
    weak var canvasContainer: PadCanvasContainer?

    // MARK: 画笔状态（Notability 风格托盘）

    static let palette: [UIColor] = [
        UIColor(red: 0.13, green: 0.13, blue: 0.13, alpha: 1), // 墨黑
        UIColor(red: 0.45, green: 0.45, blue: 0.45, alpha: 1), // 灰
        UIColor(red: 0.95, green: 0.26, blue: 0.26, alpha: 1), // 红
        UIColor(red: 0.98, green: 0.58, blue: 0.12, alpha: 1), // 橙
        UIColor(red: 0.99, green: 0.80, blue: 0.15, alpha: 1), // 黄
        UIColor(red: 0.25, green: 0.72, blue: 0.35, alpha: 1), // 绿
        UIColor(red: 0.13, green: 0.55, blue: 0.95, alpha: 1), // 蓝
        UIColor(red: 0.20, green: 0.35, blue: 0.85, alpha: 1), // 靛
        UIColor(red: 0.62, green: 0.28, blue: 0.90, alpha: 1), // 紫
        UIColor(red: 0.95, green: 0.40, blue: 0.62, alpha: 1), // 粉
    ]

    static let widthOptions: [PenKind: [CGFloat]] = [
        .pen: [3.5, 7, 12],
        .pencil: [3.5, 7, 12],
        .marker: [16, 24, 34],
        .eraser: [1, 1, 1],
    ]

    @Published var toolKind: PenKind = .pen {
        didSet {
            if oldValue != toolKind {
                toolWidthIndex = min(toolWidthIndex, widthCount - 1)
                applyToolToCanvas()
            }
        }
    }

    @Published var toolColorIndex: Int = 0 {
        didSet { applyToolToCanvas() }
    }

    @Published var toolWidthIndex: Int = 1 {
        didSet { applyToolToCanvas() }
    }

    var widthCount: Int {
        Self.widthOptions[toolKind]?.count ?? 1
    }

    var toolColor: UIColor {
        Self.palette[min(toolColorIndex, Self.palette.count - 1)]
    }

    var toolWidth: CGFloat {
        Self.widthOptions[toolKind]?[min(toolWidthIndex, widthCount - 1)] ?? 6
    }

    var currentTool: PKTool {
        guard let inkType = toolKind.inkType else {
            return PKEraserTool(.bitmap)
        }
        return PKInkingTool(inkType, color: toolColor, width: toolWidth)
    }

    /// 实时预览用的墨迹样式；橡皮无预览。
    var liveInkStyle: StrokeStyleInfo? {
        guard let inkType = toolKind.inkType else { return nil }
        var red: CGFloat = 0
        var green: CGFloat = 0
        var blue: CGFloat = 0
        var alpha: CGFloat = 1
        toolColor.getRed(&red, green: &green, blue: &blue, alpha: &alpha)
        let previewAlpha: CGFloat = toolKind == .marker ? 0.5 : 1
        _ = inkType
        return StrokeStyleInfo(
            red: Double(red),
            green: Double(green),
            blue: Double(blue),
            alpha: Double(alpha * previewAlpha),
            width: Double(toolWidth)
        )
    }

    private func applyToolToCanvas() {
        canvasRef?.tool = currentTool
    }

    private var toastWork: DispatchWorkItem?

    init() {
        browser.onUpdate = { [weak self] items in
            self?.discovered = items
        }
        client.onPhase = { [weak self] phase in
            guard let self else { return }
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
        canvasDrawing = PKDrawing()
        drawingRevision += 1
        lastSyncedData = nil
        lastSyncedCount = 0
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

    var currentPageMeta: PageMeta? {
        currentPageID.flatMap { id in snapshot.pages.first { $0.id == id } }
    }

    var currentPageSize: CGSize? {
        currentPageMeta?.pageSize
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
            connectedServerName = serverName

        case .rejected(let reason):
            showToast(reason)
            connectedServerName = nil

        case .libraryChanged(let newSnapshot):
            snapshot = newSnapshot
            if let id = currentFolderID,
               newSnapshot.folders.contains(where: { $0.id == id }) {
                // 当前项目仍在，保持
            } else {
                currentFolderID = newSnapshot.folders.last?.id
            }

        case .pageOpened(let pageID, let folderID, let drawingData, let strokeCount, let backgroundImage):
            currentFolderID = folderID
            currentPageID = pageID
            let drawing = (try? PKDrawing(data: drawingData)) ?? PKDrawing()
            lastSyncedData = drawingData
            lastSyncedCount = strokeCount
            canvasDrawing = drawing
            drawingRevision += 1
            if let backgroundImage, let image = UIImage(data: backgroundImage) {
                canvasContainer?.setBackground(image)
            } else {
                canvasContainer?.setBackground(nil)
            }
            toast = nil

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

    // MARK: - 页面操作

    func openPage(_ id: UUID) {
        guard id != currentPageID else { return }
        client.send(.openPage(pageID: id))
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
        // 页面尺寸取当前屏幕方向，新页面在 iPad 上天然全屏
        let size = canvasScreenSize.width > 100 ? canvasScreenSize : CGSize(width: 1366, height: 1024)
        client.send(
            .pageCreate(
                folderID: folderID,
                afterPageID: currentPageID,
                width: Double(size.width),
                height: Double(size.height)
            )
        )
    }

    func deleteCurrentPage() {
        guard let pageID = currentPageID else { return }
        client.send(.pageDelete(pageID: pageID))
    }

    func undo() {
        canvasRef?.undoManager?.undo()
    }

    func redo() {
        canvasRef?.undoManager?.redo()
    }

    // MARK: - 笔画同步（画布回调）

    /// 一笔结束（含新笔画）。快路径：只发新增的一笔。
    func canvasDidEndStroke() {
        guard let pageID = currentPageID else { return }
        let drawing = canvasRef?.drawing ?? canvasDrawing
        let data = drawing.dataRepresentation()
        let count = drawing.strokes.count
        if count == lastSyncedCount + 1, let last = drawing.strokes.last {
            let single = PKDrawing(strokes: [last])
            client.send(
                .strokeCommitted(pageID: pageID, strokeData: single.dataRepresentation(), strokeCount: count)
            )
        } else if data != lastSyncedData {
            // 意外差异（如橡皮），整页重传
            client.send(.fullPageResync(pageID: pageID, drawingData: data, strokeCount: count))
        }
        lastSyncedData = data
        lastSyncedCount = count
    }

    /// 画布内容变化（撤销/橡皮/移动/粘贴等）。防抖后一致性校验。
    func canvasDrawingDidChange() {
        resyncWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, let pageID = self.currentPageID else { return }
            let drawing = self.canvasRef?.drawing ?? self.canvasDrawing
            let data = drawing.dataRepresentation()
            if data != self.lastSyncedData {
                self.client.send(
                    .fullPageResync(pageID: pageID, drawingData: data, strokeCount: drawing.strokes.count)
                )
                self.lastSyncedData = data
                self.lastSyncedCount = drawing.strokes.count
            }
        }
        resyncWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.45, execute: work)
    }

    // MARK: - 底图（图片导入，画在其上）

    /// 设置/替换/移除当前页底图并同步到 Mac（空 Data = 移除）。
    func setBackgroundImage(jpeg: Data) {
        guard let pageID = currentPageID else { return }
        client.send(.backgroundImageSet(pageID: pageID, imageData: jpeg))
        if jpeg.isEmpty {
            canvasContainer?.setBackground(nil)
        } else if let image = UIImage(data: jpeg) {
            canvasContainer?.setBackground(image)
        }
    }

    // MARK: - 实时点流（StrokeObserver 回调）

    func liveStrokeBegan() {
        guard case .connected = phase,
              let pageID = currentPageID,
              let style = liveInkStyle else {
            liveStrokeID = nil
            return
        }
        let id = UUID()
        liveStrokeID = id
        liveBuffer.removeAll(keepingCapacity: true)
        client.send(.liveBegin(strokeID: id, pageID: pageID, style: style))
    }

    func liveStrokeAppend(_ points: [LivePoint]) {
        guard liveStrokeID != nil else { return }
        guard liveBuffer.count < 4096 else { return }
        liveBuffer.append(contentsOf: points)
        if liveFlushWork == nil {
            let work = DispatchWorkItem { [weak self] in
                self?.flushLive()
            }
            liveFlushWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.033, execute: work)
        }
    }

    private func flushLive() {
        liveFlushWork = nil
        guard let strokeID = liveStrokeID,
              let pageID = currentPageID,
              !liveBuffer.isEmpty else { return }
        client.send(.livePoints(strokeID: strokeID, pageID: pageID, points: liveBuffer))
        liveBuffer.removeAll(keepingCapacity: true)
    }

    func liveStrokeEnded() {
        flushLive()
        if let strokeID = liveStrokeID, let pageID = currentPageID {
            client.send(.liveEnd(strokeID: strokeID, pageID: pageID))
        }
        liveStrokeID = nil
    }
}
