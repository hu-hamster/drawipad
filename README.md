# DrawPad — iPad 手绘 · Mac 实时显示画板

用 Apple Pencil 在 iPad 上绘制，内容**实时**显示在 Mac 上。Mac 端同时是项目管理器（文件夹/页面/缩略图/导出 PNG），iPad 端是绘图板（翻页/新建/删除/切换项目，无需放下笔）。

## 功能

- **连接**：同一 Wi-Fi 下自动发现（Bonjour，与 Sidecar 无线同机制），Mac 端弹窗确认配对；断线自动重连（会话内免二次确认）
- **绘制**：PencilKit 墨迹（压感/多笔刷/颜色/粗细，系统工具条）
- **实时同步**：笔画进行中流式发送轨迹点 → Mac 即时显示预览线；抬笔后替换为真实墨迹
- **一致性保证**：撤销/橡皮/移动等操作自动整页重传，两端最终一致
- **页面管理**：新建页、删除页、翻页（两端均可操作）
- **项目管理**：文件夹（项目）→ 页面 两级结构，重命名、缩略图、右键菜单（Mac 端）
- **导出**：任意页面导出为白底 PNG（2x）
- **持久化**：数据全部存在 Mac 端（`PKDrawing` 原生二进制 + JSON 元数据），iPad 零依赖

## 运行

### 环境要求

- Xcode 15+（在 macOS 14+ 上）
- iPadOS 17+ 的 iPad + Apple Pencil
- 两台设备在同一 Wi-Fi（也支持设备间点对点 Wi-Fi）

### Mac 端

```bash
xcodegen generate   # 已生成过 DrawPad.xcodeproj 则跳过
open DrawPad.xcodeproj
```

Xcode 中选择 scheme **DrawPadMac**，`Cmd+R` 直接运行（本地 ad-hoc 签名即可）。

### iPad 端（真机）

1. iPad 用数据线连接 Mac
2. Xcode 中选择 scheme **DrawPadPad**，目标设备选你的 iPad
3. Signing & Capabilities 里选择你的 Apple ID（免费个人 Team 即可）
4. `Cmd+R` 运行；首次需在 iPad 上信任开发者证书（设置 → 通用 → VPN 与设备管理）
5. 免费账号签名 **7 天过期**，过期后重新 `Cmd+R` 即可；付费开发者账号无此限制

### 首次运行权限

两端首次使用时系统会弹出**本地网络**权限确认，请选择"允许"（未授权时 iPad 搜不到 Mac）。

### 使用流程

1. Mac 端打开 DrawPad（自动开始广播）
2. iPad 端打开 DrawPad → 等待列出你的 Mac → 点击 → Mac 上点"允许"
3. 开始绘制；顶部栏可翻页/新建/删除/切项目；工具条提供笔刷
4. Mac 侧边栏管理文件夹与页面，右键导出 PNG

## 架构

```
├── project.yml            # XcodeGen 工程定义（改配置后需 xcodegen generate）
├── Core/                  # 两端共享
│   ├── Models.swift       # Folder / PageMeta / LibrarySnapshot
│   ├── Messages.swift     # 协议消息（iPad↔Mac 全部命令）
│   ├── Wire.swift         # JSON 编解码 + 4 字节长度前缀帧
│   ├── PeerConnection.swift  # NWConnection 封装（拆包/派发主线程）
│   ├── DrawPadServer.swift   # Mac：Bonjour 广播 + 单客户端会话 + 配对
│   ├── DrawPadClient.swift   # iPad：连接 + 指数退避重连
│   └── MacBrowser.swift      # iPad：服务发现
├── MacApp/Sources/        # macOS 端
│   ├── LibraryStore.swift    # 持久化（~/Containers/.../DrawPad）
│   ├── MacAppModel.swift     # 总状态 + 消息处理
│   └── Views/                # 侧边栏/画布（位图渲染）/配对/导出
└── PadApp/Sources/        # iPadOS 端
    ├── PadModel.swift        # 会话状态 + 笔画同步 + 实时点流
    ├── PadCanvasView.swift   # PKCanvasView 桥接 + 旁路点采集 GR
    └── Views/CanvasScreen.swift
```

### 同步协议（TCP，4 字节长度前缀 + JSON）

| iPad → Mac | 说明 |
| --- | --- |
| `hello` | 握手（设备名 + 协议版本） |
| `requestProjectList` | 请求项目树 + 当前页 |
| `openPage` / `projectSelect` | 翻页 / 切项目 |
| `pageCreate` / `pageDelete` | 新建 / 删除页面 |
| `liveBegin` / `livePoints` / `liveEnd` | 实时点流（~30ms 批量，含压感与工具样式） |
| `strokeCommitted` | 抬笔提交（单笔 PKStroke 二进制，快路径） |
| `fullPageResync` | 撤销/橡皮等差异的整页重传 |

| Mac → iPad | 说明 |
| --- | --- |
| `helloAccepted` / `rejected` | 配对结果 |
| `libraryChanged` | 项目树快照 |
| `pageOpened` | 打开页面（整页 PKDrawing 二进制） |
| `serverError` | 错误提示 |

### 关键实现点

- **坐标系统一**：每页有固定逻辑尺寸（创建时取 iPad 屏幕方向），两端笔迹数据共用同一坐标系
- **Mac 端显示**：PKCanvasView 是 iOS 专属 API，macOS 用 `PKDrawing.image(from:scale:)` 位图渲染 + 实时预览叠加层（已用像素测试验证方向正确性）
- **实时预览**：自定义 `UIGestureRecognizer` 旁路观察 PencilKit 输入（`cancelsTouchesInView=false`、永不进入 recognized 状态），不干扰绘制
- **数据安全**：Mac 为唯一数据源，iPad 断线重连后自动重新拉取

## 已知限制（v1）

- iPad 端完整运行时行为（PencilKit 手感、工具条、旁路采集兼容性）需真机验证——本项目开发环境无 iOS 模拟器 runtime 与真机
- 单 iPad 连接（第二台会被拒绝）
- 无 iCloud/多设备数据同步
- Mac 端画布为只读显示（按设计）

## 二期候选

- USB 线直连（usbmux 隧道，不依赖 Wi-Fi）
- PIN 配对码、多 iPad 同时连接
- 页面内缩放/平移、多页无限画布模式
- iCloud 同步、导出 PDF/批量导出

## 开发调试

```bash
# 重新生成工程（修改 project.yml 或增删文件后）
xcodegen generate

# 命令行编译验证
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild \
  -project DrawPad.xcodeproj -scheme DrawPadMac -destination 'platform=macOS' build

DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild \
  -project DrawPad.xcodeproj -target DrawPadPad -sdk iphoneos \
  CODE_SIGNING_ALLOWED=NO build

# 自动化联调（模拟 iPad 客户端跑完整协议，需先以调试参数启动 Mac 端）
open <BuiltPath>/DrawPad.app --args --auto-accept-pairing
```
