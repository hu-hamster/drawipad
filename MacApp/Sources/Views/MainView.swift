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
                Text("创建一个项目文件夹开始绘制")
                    .foregroundStyle(.secondary)
                Button("新建文件夹") {
                    app.addFolder()
                }
            } else {
                Text("此项目还没有画板")
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

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Label("项目", systemImage: "square.stack.3d.up")
                    .font(.headline)
                Spacer()
                Button {
                    app.addFolder()
                } label: {
                    Image(systemName: "folder.badge.plus")
                }
                .buttonStyle(.borderless)
                .help("新建项目")
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)

            List(selection: pageSelection) {
                ForEach(app.store.folders) { folder in
                    DisclosureGroup(isExpanded: folderExpansion(folder.id)) {
                        ForEach(app.store.pages(in: folder.id)) { page in
                            Label(page.name, systemImage: "scribble.variable")
                                .tag(page.id as UUID?)
                                .contextMenu {
                                    Button("重命名画板…") {
                                        app.beginRename(.page(page.id))
                                    }
                                    Divider()
                                    Button("删除画板", role: .destructive) {
                                        app.deletePageLocal(page.id)
                                    }
                                }
                        }
                    } label: {
                        projectHeader(folder)
                    }
                    .contextMenu {
                        Button("新建画板") {
                            app.addPage(in: folder.id)
                        }
                        Button("重命名项目…") {
                            app.beginRename(.folder(folder.id))
                        }
                        Divider()
                        Button("删除项目", role: .destructive) {
                            app.deleteFolderLocal(folder.id)
                        }
                    }
                }
            }
            .listStyle(.sidebar)
        }
        .overlay {
            if app.store.folders.isEmpty {
                ContentUnavailableView(
                    "还没有项目",
                    systemImage: "folder.badge.plus",
                    description: Text("点击左上角 + 创建项目")
                )
            }
        }
    }

    private func projectHeader(_ folder: Folder) -> some View {
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

            Button {
                expandedFolderIDs.insert(folder.id)
                app.addPage(in: folder.id)
            } label: {
                Image(systemName: "plus")
                    .font(.caption.weight(.semibold))
                    .frame(width: 22, height: 22)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.borderless)
            .help("在「\(folder.name)」中新建画板")
        }
    }

    private func folderExpansion(_ id: UUID) -> Binding<Bool> {
        Binding(
            get: {
                expandedFolderIDs.contains(id)
                    || app.selectedPageID.map { app.store.folder(id)?.pageIDs.contains($0) == true } == true
            },
            set: { isExpanded in
                if isExpanded {
                    expandedFolderIDs.insert(id)
                } else {
                    expandedFolderIDs.remove(id)
                }
            }
        )
    }

    private var pageSelection: Binding<UUID?> {
        Binding(
            get: { app.selectedPageID },
            set: { app.selectPage($0, remote: false) }
        )
    }
}

struct NewProjectSheet: View {
    @EnvironmentObject private var app: MacAppModel
    @FocusState private var focused: Bool

    var body: some View {
        VStack(spacing: 14) {
            Text("新建项目")
                .font(.headline)
            TextField("项目名称", text: $app.newFolderName)
                .textFieldStyle(.roundedBorder)
                .focused($focused)
                .onSubmit(createProject)
            HStack(spacing: 12) {
                Button("取消") {
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
            Text(app.renameTarget?.isFolder == true ? "重命名文件夹" : "重命名画板")
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
