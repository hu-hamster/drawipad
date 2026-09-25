# DrawPad — Mac 全功能 Excalidraw + iPad 实时同步画板

Mac 端内嵌**真正的 Excalidraw**（WKWebView + 官方引擎），具备 excalidraw.com 的全部能力：矩形/菱形/椭圆/箭头/线条/自由手绘/文字/图片、选择/移动/缩放/旋转、图层、样式面板（颜色/线宽/风格/透明度）、无限画布、撤销重做、菜单导出 PNG/SVG/JSON。

iPad 与 Mac 通过本地网络（Bonjour 自动发现）连接后，两端共享同一场景数据，**双向实时同步**：iPad 上画，Mac 立即显示；Mac 上编辑，iPad 实时刷新。

## 架构

```
├── project.yml            # XcodeGen 工程定义（改后需 xcodegen generate）
├── Core/                  # 两端共享：模型/协议/网络（连接层与 v1 相同）
│   ├── Messages.swift     # 文件模型 + 场景同步消息（sceneUpdate / fileOpened 等）
│   └── ...                # Bonjour / 服务端 / 客户端 / 帧编解码
├── SharedWeb/             # 两端共用的前端资产（随 app 打包，无网络依赖）
│   ├── index.html         # 嵌入页 + JS 桥（onExcalidrawAPI / updateScene / onChange）
│   └── vendor/            # esbuild 打包产物（Excalidraw + React 19 单文件 IIFE）
├── MacApp/Sources/        # macOS 端：ExcalidrawWebView（含导出下载处理）
│                          # 多级目录树/画板管理 + 场景持久化
├── PadApp/Sources/        # iPadOS 端：同款 Excalidraw 画布 + 连接页 + 实时同步
└── ObsidianPlugin/        # 独立的 Obsidian 桌面插件（不参与 Xcode 构建）
```

### 同步原理

- 每个画板 = 一个 Excalidraw 场景（elements JSON），Mac 磁盘持久化（`scenes/<uuid>.excalidraw`）
- 任一端 `onChange` → 防抖 ~120ms → `sceneUpdate` 推给对端 → 对端 `updateScene` 应用
- 远端应用时置 `lastRemoteJSON` 抑制回播，无环路
- iPad 断线自动重连（指数退避），重连后自动重拉项目树 + 当前画板

### 前端产物构建（从 excalidraw 仓库）

```bash
cd /path/to/excalidraw
yarn install && yarn build:packages
node node_modules/esbuild/bin/esbuild drawpad-bundle-entry.mjs \
  --bundle --minify --format=iife --target=safari16 --conditions=production \
  --define:process.env.NODE_ENV='"production"' --define:process.env.IS_PREACT='"false"' \
  '--define:import.meta.env={"MODE":"production","PROD":true,"DEV":false,"SSR":false}' \
  --loader:.woff2=file --loader:.woff=file --loader:.ttf=file --loader:.otf=file --loader:.wasm=file \
  --outdir=/tmp/excal_bundle --entry-names=excalidraw.production.min \
  --asset-names='excalidraw-assets/[name]-[hash]'
cp /tmp/excal_bundle/excalidraw.production.min.* <DrawPad>/SharedWeb/vendor/
rm -rf <DrawPad>/SharedWeb/vendor/excalidraw-assets
cp -R /tmp/excal_bundle/excalidraw-assets <DrawPad>/SharedWeb/vendor/
```

要点（都是踩过的坑）：React 必须打进 bundle 并从中导出（页面级双 React 实例会 hooks 崩溃）；`import.meta.env` 需 define 注入；本仓库版组件 API 回调是 `onExcalidrawAPI`。

## 运行

### Mac 端
Xcode 打开 `DrawPad.xcodeproj` → scheme **DrawPadMac** → ⌘R（本地 ad-hoc 签名即可）。

### iPad 真机
1. iPad USB 连接，Xcode scheme **DrawPadPad**、目标选 iPad
2. Signing 里选你的 Personal Team（免费即可，7 天重签）
3. ⌘R；首次在 iPad 设置→通用→VPN与设备管理 信任开发者
4. 首次运行两端都要允许**本地网络**权限

### 使用
1. Mac 端打开 DrawPad（自动广播）
2. iPad 打开 DrawPad → 点你的 Mac → Mac 上点"允许"
3. 两端任意编辑，实时同步；iPad 顶栏可切目录/翻页/新建/删除；Excalidraw 自带工具栏画图
4. Mac 侧边栏支持任意层级的目录树，可在任一目录中新建子目录和画板；删除目录前会提示并递归删除其中内容
5. Excalidraw 菜单导出的文件自动存到“下载”。要导入 Obsidian 的 `.excalidraw.md`，点击 Mac 顶栏的“导入 Excalidraw”按钮；也支持原生 `.excalidraw` 与 JSON 场景

### Obsidian 插件（独立构建）

`ObsidianPlugin/` 是单独的桌面插件工程，不会改动 Mac/iPad 应用。它直接复用 Vault 的原生目录树，把各层目录及其中的 `.excalidraw.md` / `.excalidraw` 文件通过同一套 Bonjour + TCP 协议提供给 DrawPad iPad 端，不维护额外的目录数据。

```bash
cd ObsidianPlugin
npm install
npm run build
```

将生成的 `main.js`、`manifest.json`、`styles.css` 复制到 Vault 的 `.obsidian/plugins/drawpad-sync/` 后，在 Obsidian 设置中启用 **DrawPad Sync**。插件仅支持 Obsidian 桌面端，因为它需要本机 TCP/Bonjour 服务；原有 Mac/iPad app 不需要重新接入插件。

### 浏览器版本

`WebBridge/` + `WebApp/` 是独立的浏览器版本。它复用现有 Excalidraw 网页资产，通过本地 WebSocket/Bonjour Bridge 与 iPad 同步，不参与 Mac/iPad 的 Xcode 构建：

```bash
cd WebBridge
npm install
npm start
```

然后访问 `http://127.0.0.1:8787/`，在 iPad 的 DrawPad 连接列表中选择 **DrawPad Web**。网页侧支持可展开的多级目录树、子目录创建/重命名/递归删除，以及目录内画板管理；已有的单级浏览器数据会自动迁移成根目录。

## 调试

- Mac app 启动参数 `--auto-accept-pairing`：自动接受配对（自动化联调）
- 诊断日志：`~/Library/Containers/com.hujing.drawpad.mac/Data/tmp/drawpad_diag.log`（页面加载/挂载/桥错误）
- 协议版本 v3（v1 PencilKit 版本见 git 历史 tag: 初始提交）
