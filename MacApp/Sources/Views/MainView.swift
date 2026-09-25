import SwiftUI

struct MainView: View {
    @EnvironmentObject private var app: MacAppModel

    var body: some View {
        NavigationSplitView {
            SidebarView()
                .navigationSplitViewColumnWidth(min: 190, ideal: 230, max: 340)
        } detail: {
            detailView
        }
        .sheet(item: $app.pairing) { prompt in
            PairingSheet(prompt: prompt)
        }
        .sheet(item: $app.renameTarget) { _ in
            RenameSheet()
        }
        .sheet(isPresented: $app.isCreatingFolder) {
            NewProjectSheet()
        }
        .alert("无法导入 Excalidraw 文件", isPresented: importErrorPresented) {
            Button("好", role: .cancel) {}
        } message: {
            Text(app.importError ?? "未知错误")
        }
    }

    @ViewBuilder
    private var detailView: some View {
        if let meta = app.currentMeta {
            VStack(spacing: 0) {
                topBar
                    .frame(maxWidth: .infinity)
                    .background(.bar)

                ExcalidrawWebView(model: app)
                    .id(meta.id)
            }
            .navigationTitle(meta.name)
        } else {
            emptyView
        }
    }

    private var emptyView: some View {
        VStack(spacing: 12) {
            Image(systemName: "pencil.and.list.clipboard")
                .font(.system(size: 44))
                .foregroundStyle(.secondary)
            if app.store.folders.isEmpty {
                Text("创建一个目录开始绘制")
                    .foregroundStyle(.secondary)
                Button("新建目录") {
                    app.addFolder()
                }
            } else {
                Text("此目录还没有画板")
                    .foregroundStyle(.secondary)
                Button {
                    let folderID = app.selectedFolderID ?? app.store.folders.last?.id
                    if let folderID {
                        app.addPage(in: folderID)
                    }
                } label: {
                    Label("新建画板", systemImage: "plus.square.on.square")
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: 顶部轻量工具岛（画布能力由 Excalidraw 自身 UI 提供）

    private var topBar: some View {
        HStack(spacing: 4) {
            Button {
                app.prevPageFromUI()
            } label: {
                Image(systemName: "chevron.left")
            }
            .disabled(app.pageIndexCurrent <= 0)
            .help("上一个画板")

            Text(app.pageIndicatorText)
                .font(.system(size: 12, weight: .medium).monospacedDigit())
                .frame(minWidth: 44)
                .foregroundStyle(.secondary)

            Button {
                if let id = app.selectedPageID {
                    app.beginRename(.page(id))
                }
            } label: {
                Image(systemName: "pencil")
            }
            .disabled(app.selectedPageID == nil)
            .help("重命名当前画板")

            Button {
                app.nextPageFromUI()
            } label: {
                Image(systemName: "chevron.right")
            }
            .disabled(app.pageIndexCurrent >= app.pageCountCurrent - 1)
            .help("下一个画板")

            divider

            Button {
                app.addPage()
            } label: {
                Image(systemName: "plus.square.on.square")
            }
            .help("新建画板")

            Button {
                app.importExcalidraw()
            } label: {
                Image(systemName: "square.and.arrow.down")
            }
            .help("导入 Excalidraw（含 .excalidraw.md）")

            Button {
                app.fitToContent()
            } label: {
                Image(systemName: "arrow.up.left.and.arrow.down.right")
            }
            .help("适应画板内容（同步到 iPad）")

            Button(role: .destructive) {
                app.confirmDeleteCurrent = true
            } label: {
                Image(systemName: "trash")
            }
            .help("删除当前画板")

            divider

            connectionStatus
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(Color.primary.opacity(0.08), lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.12), radius: 10, y: 3)
        .padding(.top, 8)
        .padding(.bottom, 8)
        .confirmationDialog(
            "删除当前画板？",
            isPresented: $app.confirmDeleteCurrent,
            titleVisibility: .visible
        ) {
            Button("删除", role: .destructive) {
                if let id = app.selectedPageID {
                    app.deletePageLocal(id)
                }
            }
            Button("取消", role: .cancel) {}
        }
    }

    private var divider: some View {
        Rectangle()
            .fill(Color.primary.opacity(0.12))
            .frame(width: 1, height: 16)
    }

    private var importErrorPresented: Binding<Bool> {
        Binding(
            get: { app.importError != nil },
            set: { isPresented in
                if !isPresented { app.importError = nil }
            }
        )
    }

    private var connectionStatus: some View {
        Menu {
            if let name = app.clientName {
                Text("已连接：\(name)")
                Button("断开连接", role: .destructive) {
                    app.disconnectClient()
                }
            } else {
                Text("等待 iPad 连接…")
            }
        } label: {
            HStack(spacing: 6) {
                Circle()
                    .fill(app.clientName != nil ? Color.green : Color.secondary.opacity(0.45))
                    .frame(width: 8, height: 8)
                Text(app.clientName ?? "未连接")
            }
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .disabled(app.clientName == nil)
        .help("iPad 连接状态")
    }
}

// MARK: - 侧边栏

struct SidebarView: View {
    @EnvironmentObject private var app: MacAppModel
    @State private var expandedFolderIDs: Set<UUID> = []
    @State private var pagePendingDeletion: PageMeta?
    @State private var folderPendingDeletion: Folder?

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Label("目录", systemImage: "square.stack.3d.up")
                    .font(.headline)
                Spacer()
                Button {
                    app.addFolder(parentID: nil)
                } label: {
                    Image(systemName: "folder.badge.plus")
                }
                .buttonStyle(.borderless)
                .help("新建根目录")
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)

            List(selection: pageSelection) {
                ForEach(app.store.rootFolders) { folder in
                    FolderNodeView(
                        folder: folder,
                        expandedFolderIDs: $expandedFolderIDs,
                        pagePendingDeletion: $pagePendingDeletion,
                        folderPendingDeletion: $folderPendingDeletion
                    )
                }
            }
            .listStyle(.sidebar)
        }
        .overlay {
            if app.store.folders.isEmpty {
                ContentUnavailableView(
                    "还没有目录",
                    systemImage: "folder.badge.plus",
                    description: Text("点击左上角 + 创建根目录")
                )
            }
        }
        .confirmationDialog(
            pagePendingDeletion.map { "删除画板“\($0.name)”？" } ?? "删除画板？",
            isPresented: deletePageDialogPresented,
            titleVisibility: .visible
        ) {
            Button("删除", role: .destructive) {
                if let page = pagePendingDeletion {
                    app.deletePageLocal(page.id)
                }
                pagePendingDeletion = nil
            }
            Button("取消", role: .cancel) {
                pagePendingDeletion = nil
            }
        } message: {
            Text("此操作会删除该画板及其绘图内容，不会删除目录中的其他画板。")
        }
        .confirmationDialog(
            folderPendingDeletion.map { "删除目录“\($0.name)”？" } ?? "删除目录？",
            isPresented: deleteFolderDialogPresented,
            titleVisibility: .visible
        ) {
            Button("删除", role: .destructive) {
                if let folder = folderPendingDeletion {
                    app.deleteFolderLocal(folder.id)
                }
                folderPendingDeletion = nil
            }
            Button("取消", role: .cancel) {
                folderPendingDeletion = nil
            }
        } message: {
            Text("此操作会删除该目录、所有子目录及其中的全部画板。")
        }
    }

    private var pageSelection: Binding<UUID?> {
        Binding(
            get: { app.selectedPageID },
            set: { app.selectPage($0, remote: false) }
        )
    }

    private var deletePageDialogPresented: Binding<Bool> {
        Binding(
            get: { pagePendingDeletion != nil },
            set: { isPresented in
                if !isPresented { pagePendingDeletion = nil }
            }
        )
    }

    private var deleteFolderDialogPresented: Binding<Bool> {
        Binding(
            get: { folderPendingDeletion != nil },
            set: { isPresented in
                if !isPresented { folderPendingDeletion = nil }
            }
        )
    }
}

private struct FolderNodeView: View {
    @EnvironmentObject private var app: MacAppModel
    let folder: Folder
    @Binding var expandedFolderIDs: Set<UUID>
    @Binding var pagePendingDeletion: PageMeta?
    @Binding var folderPendingDeletion: Folder?

    var body: some View {
        DisclosureGroup(isExpanded: folderExpansion) {
            ForEach(app.store.childFolders(of: folder.id)) { child in
                FolderNodeView(
                    folder: child,
                    expandedFolderIDs: $expandedFolderIDs,
                    pagePendingDeletion: $pagePendingDeletion,
                    folderPendingDeletion: $folderPendingDeletion
                )
            }
            ForEach(app.store.pages(in: folder.id)) { page in
                Label(page.name, systemImage: "scribble.variable")
                    .tag(page.id as UUID?)
                    .contextMenu {
                        Button("重命名画板…") {
                            app.beginRename(.page(page.id))
                        }
                        Divider()
                        Button("删除画板", role: .destructive) {
                            pagePendingDeletion = page
                        }
                    }
            }
        } label: {
            folderHeader
                .contextMenu {
                    Button("新建画板") {
                        expandedFolderIDs.insert(folder.id)
                        app.addPage(in: folder.id)
                    }
                    Button("新建子目录…") {
                        expandedFolderIDs.insert(folder.id)
                        app.addFolder(parentID: folder.id)
                    }
                    Button("重命名目录…") {
                        app.beginRename(.folder(folder.id))
                    }
                    Divider()
                    Button("删除目录", role: .destructive) {
                        folderPendingDeletion = folder
                    }
                }
        }
    }

    private var folderHeader: some View {
        HStack(spacing: 6) {
            Button {
                app.selectFolderFromUI(folder.id)
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "folder.fill")
                        .foregroundStyle(.blue)
                    Text(folder.name)
                        .lineLimit(1)
                    Text("\(folder.pageIDs.count)")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .padding(.vertical, 3)
            .background {
                if app.selectedFolderID == folder.id && app.selectedPageID == nil {
                    RoundedRectangle(cornerRadius: 5)
                        .fill(Color.accentColor.opacity(0.14))
                }
            }

            Menu {
                Button("新建画板") {
                    expandedFolderIDs.insert(folder.id)
                    app.addPage(in: folder.id)
                }
                Button("新建子目录") {
                    expandedFolderIDs.insert(folder.id)
                    app.addFolder(parentID: folder.id)
                }
            } label: {
                Image(systemName: "plus")
                    .font(.caption.weight(.semibold))
                    .frame(width: 22, height: 22)
                    .contentShape(Rectangle())
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .help("在「\(folder.name)」中新建内容")
        }
    }

    private var folderExpansion: Binding<Bool> {
        Binding(
            get: {
                expandedFolderIDs.contains(folder.id)
                    || app.store.containsFolder(app.selectedFolderID, within: folder.id)
            },
            set: { isExpanded in
                if isExpanded {
                    expandedFolderIDs.insert(folder.id)
                } else {
                    expandedFolderIDs.remove(folder.id)
                }
            }
        )
    }
}

struct NewProjectSheet: View {
    @EnvironmentObject private var app: MacAppModel
    @FocusState private var focused: Bool

    var body: some View {
        VStack(spacing: 14) {
            Text(app.newFolderParentID == nil ? "新建根目录" : "新建子目录")
                .font(.headline)
            if let parentID = app.newFolderParentID,
               let parent = app.store.folder(parentID) {
                Text("位置：\(parent.name)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            TextField("目录名称", text: $app.newFolderName)
                .textFieldStyle(.roundedBorder)
                .focused($focused)
                .onSubmit(createProject)
            HStack(spacing: 12) {
                Button("取消") {
                    app.newFolderParentID = nil
                    app.isCreatingFolder = false
                }
                .keyboardShortcut(.cancelAction)
                Button("创建", action: createProject)
                    .keyboardShortcut(.defaultAction)
                    .disabled(app.newFolderName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(22)
        .frame(width: 320)
        .onAppear { focused = true }
    }

    private func createProject() {
        app.createFolderFromUI()
        app.isCreatingFolder = false
    }
}

// MARK: - 配对确认

struct PairingSheet: View {
    @EnvironmentObject private var app: MacAppModel
    let prompt: MacAppModel.PairingPrompt

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "ipad.and.arrow.forward")
                .font(.system(size: 40))
                .foregroundStyle(.blue)
            Text("“\(prompt.deviceName)” 请求连接")
                .font(.title3.bold())
            Text("允许后，这台 iPad 将与 Mac 实时同步画板。")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            HStack(spacing: 12) {
                Button("拒绝") {
                    prompt.reject()
                    app.pairing = nil
                }
                .keyboardShortcut(.cancelAction)
                Button("允许") {
                    prompt.accept()
                    app.pairing = nil
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(28)
        .frame(width: 340)
        .interactiveDismissDisabled()
    }
}

// MARK: - 重命名

struct RenameSheet: View {
    @EnvironmentObject private var app: MacAppModel
    @FocusState private var focused: Bool

    var body: some View {
        VStack(spacing: 14) {
            Text(app.renameTarget?.isFolder == true ? "重命名目录" : "重命名画板")
                .font(.headline)
            TextField("名称", text: $app.renameText)
                .textFieldStyle(.roundedBorder)
                .focused($focused)
                .onSubmit {
                    app.commitRename()
                }
            HStack(spacing: 12) {
                Button("取消") {
                    app.renameTarget = nil
                }
                .keyboardShortcut(.cancelAction)
                Button("好") {
                    app.commitRename()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(22)
        .frame(width: 300)
        .onAppear {
            focused = true
        }
    }
}
