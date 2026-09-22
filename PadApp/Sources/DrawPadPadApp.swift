import PencilKit
import SwiftUI

@main
struct DrawPadPadApp: App {
    @StateObject private var model = PadModel()

    var body: some Scene {
        WindowGroup {
            PadRootView()
                .environmentObject(model)
        }
    }
}

struct PadRootView: View {
    @EnvironmentObject private var model: PadModel

    var body: some View {
        if case .connected = model.phase {
            CanvasScreen()
        } else if model.wasConnected {
            // 断线重连期间保持画布，顶部提示
            CanvasScreen()
        } else {
            ConnectView()
        }
    }
}

// MARK: - 连接页

struct ConnectView: View {
    @EnvironmentObject private var model: PadModel

    var body: some View {
        VStack(spacing: 0) {
            VStack(spacing: 10) {
                Image(systemName: "pencil.and.outline")
                    .font(.system(size: 44))
                    .foregroundStyle(.blue)
                Text("DrawPad")
                    .font(.title.bold())
                Text("连接 Mac 后，用 Apple Pencil 在 iPad 上绘制，\n内容将实时显示在 Mac 上")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            .padding(.top, 48)
            .padding(.bottom, 24)

            statusBanner

            List {
                Section("附近的 Mac") {
                    if model.discovered.isEmpty {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("正在搜索…")
                                .foregroundStyle(.secondary)
                            Text("请确认：\n· Mac 与 iPad 在同一 Wi-Fi 网络\n· Mac 端 DrawPad 已打开")
                                .font(.caption)
                                .foregroundStyle(.tertiary)
                        }
                        .padding(.vertical, 4)
                    }
                    ForEach(model.discovered) { item in
                        Button {
                            model.connect(item)
                        } label: {
                            HStack {
                                Image(systemName: "desktopcomputer")
                                    .foregroundStyle(.blue)
                                Text(item.name)
                                    .foregroundStyle(.primary)
                                Spacer()
                                Image(systemName: "chevron.right")
                                    .font(.caption)
                                    .foregroundStyle(.tertiary)
                            }
                        }
                    }
                }
            }
            .listStyle(.insetGrouped)
        }
    }

    @ViewBuilder
    private var statusBanner: some View {
        switch model.phase {
        case .connecting:
            Label("正在连接…", systemImage: "antenna.radiowaves.left.and.right")
                .font(.callout)
                .foregroundStyle(.secondary)
                .padding(.bottom, 12)
        case .waitingAccept, .reconnecting:
            VStack(spacing: 6) {
                ProgressView()
                Text("正在等待 Mac 确认连接…")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            .padding(.bottom, 12)
        case .failed(let reason):
            VStack(spacing: 8) {
                Label(reason, systemImage: "exclamationmark.triangle")
                    .font(.callout)
                    .foregroundStyle(.red)
                Button("返回") {
                    model.disconnect()
                }
                .buttonStyle(.bordered)
            }
            .padding(.bottom, 12)
        default:
            EmptyView()
        }
    }
}
