import SwiftUI

/// iPad 端画布界面：全屏 Excalidraw + 顶部轻量工具栏（项目/切换/新建/删除）。
struct CanvasScreen: View {
    @EnvironmentObject private var model: PadModel
    @State private var confirmDelete = false

    var body: some View {
        ZStack(alignment: .top) {
            document
                .ignoresSafeArea()

            VStack(spacing: 10) {
                topBar
                if reconnectBanner {
                    reconnectView
                }
            }
        }
        .overlay(alignment: .bottom) {
            if let toast = model.toast {
                Text(toast)
                    .font(.callout)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .background(.ultraThinMaterial, in: Capsule())
                    .padding(.bottom, 70)
            }
        }
        .confirmationDialog(
            "删除当前画板？",
            isPresented: $confirmDelete,
            titleVisibility: .visible
        ) {
            Button("删除", role: .destructive) {
                model.deleteCurrentPage()
            }
            Button("取消", role: .cancel) {}
        }
    }

    @ViewBuilder
    private var document: some View {
        if model.snapshot.pages.first(where: { $0.id == model.currentPageID })?.isCanvas == true {
            CanvasPadScreen(model: model)
                .id(model.currentPageID)
        } else {
            ExcalidrawPadWebView(model: model)
                .id(model.currentPageID)
        }
    }

    private var reconnectBanner: Bool {
        switch model.phase {
        case .reconnecting, .connecting, .waitingAccept:
            return true
        default:
            return false
        }
    }

    private var reconnectView: some View {
        HStack(spacing: 8) {
            ProgressView()
                .controlSize(.small)
            Text("连接中断，正在重连…")
                .font(.callout)
            Button("取消") {
                model.disconnect()
            }
            .font(.callout)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(.ultraThinMaterial, in: Capsule())
    }

    // MARK: 顶部栏

    private var topBar: some View {
        HStack(spacing: 12) {
            folderMenu

            pageNav

            Menu {
                Button("新建 Excalidraw", action: model.newPage)
                Button("新建 Canvas", action: model.newCanvas)
            } label: {
                Image(systemName: "plus.square.on.square")
            }
            .help("新建画板或 Canvas")

            Button {
                confirmDelete = true
            } label: {
                Image(systemName: "trash")
            }
            .disabled(model.currentPageID == nil)
            .help("删除当前画板")

            Spacer(minLength: 4)

            Button {
                model.localZoom(0.8)
            } label: {
                Image(systemName: "minus.magnifyingglass")
            }
            .help("缩小（同步到 Mac）")

            Button {
                model.localZoom(1.25)
            } label: {
                Image(systemName: "plus.magnifyingglass")
            }
            .help("放大（同步到 Mac）")

            Button {
                model.fitToContent()
            } label: {
                Image(systemName: "arrow.up.left.and.arrow.down.right")
            }
            .help("适应画板内容（同步到 Mac）")

            moreMenu

            statusDot
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14))
        .overlay(
            RoundedRectangle(cornerRadius: 14)
                .strokeBorder(Color.primary.opacity(0.08), lineWidth: 1)
        )
        .padding(.horizontal, 12)
    }

    private var moreMenu: some View {
        Menu {
            Button(role: .destructive) {
                model.disconnect()
            } label: {
                Label("断开连接", systemImage: "xmark.circle")
            }
        } label: {
            Image(systemName: "ellipsis")
        }
        .help("更多")
    }

    private var folderMenu: some View {
        Menu {
            ForEach(model.snapshot.folders) { folder in
                Button {
                    model.selectFolder(folder.id)
                } label: {
                    if folder.id == model.currentFolderID {
                        Label(folder.name, systemImage: "checkmark")
                    } else {
                        Text(folder.name)
                    }
                }
            }
        } label: {
            HStack(spacing: 5) {
                Image(systemName: "folder")
                Text(model.currentFolder?.name ?? "项目")
                    .lineLimit(1)
                    .frame(maxWidth: 150)
            }
        }
        .help("切换项目")
    }

    private var pageNav: some View {
        HStack(spacing: 10) {
            Button {
                model.prevPage()
            } label: {
                Image(systemName: "chevron.left")
            }
            .disabled(model.currentIndex <= 0)
            .help("上一个画板")

            Text(model.pageIndicator)
                .font(.subheadline.monospacedDigit())
                .frame(minWidth: 52)

            Button {
                model.nextPage()
            } label: {
                Image(systemName: "chevron.right")
            }
            .disabled(model.currentIndex < 0 || model.currentIndex >= model.currentPageMetas.count - 1)
            .help("下一个画板")
        }
    }

    private var statusDot: some View {
        Circle()
            .fill(model.phase == .connected ? Color.green : Color.orange)
            .frame(width: 9, height: 9)
            .help(model.phase == .connected ? "已连接" : "重连中")
    }
}
