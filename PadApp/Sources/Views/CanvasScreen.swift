import PhotosUI
import SwiftUI

/// iPad 端画布界面：全屏画布 + 顶部栏（项目/翻页/图片/撤销）+ 底部画笔托盘。
struct CanvasScreen: View {
    @EnvironmentObject private var model: PadModel
    @State private var confirmDelete = false
    @State private var photoItem: PhotosPickerItem?

    var body: some View {
        ZStack(alignment: .top) {
            PadCanvasView(model: model)
                .ignoresSafeArea()

            VStack(spacing: 10) {
                topBar
                if reconnectBanner {
                    reconnectView
                }
            }

            // 空项目提示
            if case .connected = model.phase, model.currentPageMetas.isEmpty {
                emptyState
            }
        }
        .overlay(alignment: .bottom) {
            if !model.currentPageMetas.isEmpty {
                PenTray()
                    .padding(.bottom, 10)
            }
        }
        .overlay(alignment: .bottom) {
            if let toast = model.toast {
                Text(toast)
                    .font(.callout)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .background(.ultraThinMaterial, in: Capsule())
                    .padding(.bottom, 84)
            }
        }
        .confirmationDialog(
            "删除当前页面？",
            isPresented: $confirmDelete,
            titleVisibility: .visible
        ) {
            Button("删除", role: .destructive) {
                model.deleteCurrentPage()
            }
            Button("取消", role: .cancel) {}
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

    private var emptyState: some View {
        VStack(spacing: 14) {
            Image(systemName: "doc.badge.plus")
                .font(.system(size: 44))
                .foregroundStyle(.secondary)
            Text("此项目还没有页面")
                .foregroundStyle(.secondary)
            Button {
                model.newPage()
            } label: {
                Label("新建页面", systemImage: "plus")
            }
            .buttonStyle(.borderedProminent)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.white.opacity(0.6))
    }

    // MARK: 顶部栏

    private var topBar: some View {
        HStack(spacing: 12) {
            folderMenu

            pageNav

            Button {
                model.newPage()
            } label: {
                Image(systemName: "plus.square.on.square")
            }
            .help("新建页面")

            Button {
                confirmDelete = true
            } label: {
                Image(systemName: "trash")
            }
            .disabled(model.currentPageID == nil)
            .help("删除当前页面")

            PhotosPicker(selection: $photoItem, matching: .images) {
                Image(systemName: "photo.badge.plus")
            }
            .disabled(model.currentPageID == nil)
            .help("从相册导入底图")

            moreMenu

            Spacer(minLength: 4)

            Button {
                model.undo()
            } label: {
                Image(systemName: "arrow.uturn.backward")
            }
            .help("撤销")

            Button {
                model.redo()
            } label: {
                Image(systemName: "arrow.uturn.forward")
            }
            .help("重做")

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
        .onChange(of: photoItem) { _, item in
            guard let item else { return }
            Task {
                if let data = try? await item.loadTransferable(type: Data.self),
                   let composed = composeBackgroundJPEG(data) {
                    model.setBackgroundImage(jpeg: composed)
                } else {
                    model.showToast("图片导入失败")
                }
                photoItem = nil
            }
        }
    }

    private var moreMenu: some View {
        Menu {
            Button(role: .destructive) {
                model.setBackgroundImage(jpeg: Data())
            } label: {
                Label("移除底图", systemImage: "photo.badge.minus")
            }
            .disabled(model.currentPageID == nil)
            Divider()
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
            .help("上一页")

            Text(model.pageIndicator)
                .font(.subheadline.monospacedDigit())
                .frame(minWidth: 52)

            Button {
                model.nextPage()
            } label: {
                Image(systemName: "chevron.right")
            }
            .disabled(model.currentIndex < 0 || model.currentIndex >= model.currentPageMetas.count - 1)
            .help("下一页")
        }
    }

    private var statusDot: some View {
        Circle()
            .fill(model.phase == .connected ? Color.green : Color.orange)
            .frame(width: 9, height: 9)
            .help(model.phase == .connected ? "已连接" : "重连中")
    }

    // MARK: 底图合成

    /// 将所选图片等比居中合成为页面比例的底图 JPEG。
    private func composeBackgroundJPEG(_ data: Data) -> Data? {
        guard let image = UIImage(data: data) else { return nil }
        let pageSize = model.currentPageSize ?? model.canvasScreenSize
        guard pageSize.width > 1, pageSize.height > 1 else { return nil }
        let format = UIGraphicsImageRendererFormat()
        format.scale = 2
        format.opaque = false
        let renderer = UIGraphicsImageRenderer(size: pageSize, format: format)
        let composed = renderer.image { _ in
            let size = image.size
            guard size.width > 0, size.height > 0 else { return }
            let fit = min(pageSize.width / size.width, pageSize.height / size.height)
            let target = CGSize(width: size.width * fit, height: size.height * fit)
            image.draw(
                in: CGRect(
                    x: (pageSize.width - target.width) / 2,
                    y: (pageSize.height - target.height) / 2,
                    width: target.width,
                    height: target.height
                )
            )
        }
        return composed.jpegData(compressionQuality: 0.82)
    }
}

// MARK: - 画笔托盘（Notability 风格）

struct PenTray: View {
    @EnvironmentObject private var model: PadModel

    private var widthDots: [CGFloat] { [8, 13, 19] }

    var body: some View {
        HStack(spacing: 14) {
            // 笔类
            HStack(spacing: 2) {
                ForEach(PenKind.allCases) { kind in
                    Button {
                        model.toolKind = kind
                    } label: {
                        Image(systemName: kind.icon)
                            .font(.system(size: 16, weight: .medium))
                            .frame(width: 40, height: 36)
                            .background(
                                RoundedRectangle(cornerRadius: 9)
                                    .fill(
                                        model.toolKind == kind
                                            ? Color.primary.opacity(0.13)
                                            : Color.clear
                                    )
                            )
                            .foregroundStyle(
                                model.toolKind == kind ? .primary : .secondary
                            )
                    }
                    .help(kind.label)
                }
            }

            trayDivider

            // 色板
            HStack(spacing: 7) {
                ForEach(0..<PadModel.palette.count, id: \.self) { index in
                    let isSelected = model.toolColorIndex == index
                    Button {
                        model.toolColorIndex = index
                    } label: {
                        Circle()
                            .fill(Color(uiColor: PadModel.palette[index]))
                            .frame(width: isSelected ? 24 : 19, height: isSelected ? 24 : 19)
                            .overlay(
                                Circle()
                                    .strokeBorder(
                                        isSelected ? Color.primary : Color.clear,
                                        lineWidth: 2
                                    )
                                    .padding(-3)
                            )
                            .animation(.easeOut(duration: 0.12), value: model.toolColorIndex)
                    }
                    .buttonStyle(.plain)
                }
            }

            trayDivider

            // 粗细
            HStack(spacing: 6) {
                ForEach(0..<3, id: \.self) { index in
                    let isSelected = model.toolWidthIndex == index
                    Button {
                        model.toolWidthIndex = index
                    } label: {
                        Circle()
                            .fill(isSelected ? Color.primary : Color.secondary)
                            .frame(width: widthDots[index], height: widthDots[index])
                            .frame(width: 32, height: 32)
                            .background(
                                RoundedRectangle(cornerRadius: 8)
                                    .fill(
                                        isSelected
                                            ? Color.primary.opacity(0.1)
                                            : Color.clear
                                    )
                            )
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 17))
        .overlay(
            RoundedRectangle(cornerRadius: 17)
                .strokeBorder(Color.primary.opacity(0.08), lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.1), radius: 8, y: 2)
    }

    private var trayDivider: some View {
        Rectangle()
            .fill(Color.primary.opacity(0.12))
            .frame(width: 1, height: 24)
    }
}
