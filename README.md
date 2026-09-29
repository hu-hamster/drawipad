# DrawPad — Mac / iPad / 浏览器 / Obsidian 同步画板

三种画板类型，四端互联：

- **Excalidraw 画板**：无限画布，Mac 端内嵌**真正的 Excalidraw**（WKWebView + 官方引擎），具备 excalidraw.com 的全部能力：矩形/菱形/椭圆/箭头/线条/自由手绘/文字/图片、选择/移动/缩放/旋转、图层、样式面板（颜色/线宽/风格/透明度）、撤销重做、菜单导出 PNG/SVG/JSON。
- **JSON Canvas**（`.canvas`）：节点图编辑器（React Flow），支持节点拖动、连线、分组、视口同步。
- **白板**（`.whiteboard`）：分页式电视白板，**每一页都是一个完整的 Excalidraw 场景**。页面固定 1600×1200（4:3），底部页栏提供 ◀▶ 翻页、＋加页、－删页（两步确认）和适应页面；页码随文档同步，对端自动跟随翻页。

iPad 与 Mac 通过本地网络（Bonjour 自动发现）连接后，两端共享同一场景数据，**双向实时同步**：iPad 上画，Mac 立即显示；Mac 上编辑，iPad 实时刷新。白板的加页/删页/翻页不需要额外协议——整个分页文档作为一个场景同步。

## 架构

```
├── project.yml            # XcodeGen 工程定义（改后需 xcodegen generate）
├── Core/                  # 两端共享：模型/协议/网络（连接层与 v1 相同）
│   ├── Messages.swift     # 文件模型 + 场景同步消息（sceneUpdate / fileOpened 等）
│   └── ...                # Bonjour / 服务端 / 客户端 / 帧编解码
├── SharedWeb/             # 两端共用的前端资产（随 app 打包，无网络依赖）
│   ├── index.html         # Excalidraw 嵌入页 + JS 桥（onExcalidrawAPI / updateScene / onChange）
│   ├── whiteboard.html    # 白板嵌入页（分页 Excalidraw + 页栏 + 同款 JS 桥）
│   └── vendor/            # esbuild 打包产物（Excalidraw + React 19 单文件 IIFE）
├── MacApp/Sources/        # macOS 端：ExcalidrawWebView / CanvasWebView / WhiteboardWebView
│                          # 多级目录树/画板管理 + 场景持久化
├── PadApp/Sources/        # iPadOS 端：三款画布 + 连接页 + 实时同步
└── ObsidianPlugin/        # 独立的 Obsidian 桌面插件（不参与 Xcode 构建）
```

### 同步原理

- 每个画板 = 一个场景 JSON，Mac 磁盘持久化（`scenes/<uuid>.excalidraw|canvas|whiteboard`）
- Excalidraw/Canvas 的场景是元素数组或 `{nodes,edges}`；白板的场景是分页文档 `{pages:[[elements]...],currentPage}`
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
4. Mac 侧边栏支持任意层级的目录树，可在任一目录中新建子目录和三种画板（Excalidraw / Canvas / 白板）；从侧边栏打开的画板会保留在顶部标签栏，标签可切换、关闭（关闭标签不删除文件）；删除目录前会提示并递归删除其中内容
5. 白板：底部页栏 ◀▶ 翻页、＋加页、－删页（两步确认）、⤢ 适应页面；页码随文档同步到对端
6. Excalidraw 菜单导出的文件自动存到“下载”。要导入 Obsidian 的 `.excalidraw.md`，点击 Mac 顶栏的“导入 Excalidraw”按钮；也支持原生 `.excalidraw` 与 JSON 场景

### Obsidian 插件（独立构建）

`ObsidianPlugin/` 是单独的桌面插件工程，不会改动 Mac/iPad 应用。它直接复用 Vault 的原生目录树，把各层目录及其中的 `.excalidraw.md` / `.excalidraw` / `.canvas` / `.whiteboard` 文件通过同一套 Bonjour + TCP 协议提供给 DrawPad iPad 端，不维护额外的目录数据。Canvas 编辑使用 Obsidian 原生画布；本插件同步节点和连线，但 Obsidian 原生 Canvas 的视口暂不参与同步。白板（`.whiteboard`）在 Obsidian 中由插件自带的白板视图（iframe 内嵌同一套 Excalidraw 分页编辑器）打开编辑。

```bash
cd ObsidianPlugin
npm install
npm run build
```

构建产物除 `main.js`、`manifest.json`、`styles.css` 外，还有 `whiteboard.html` 和 `vendor/`（白板编辑器资产），需一并复制到 Vault 的 `.obsidian/plugins/drawpad-sync/` 后，在 Obsidian 设置中启用 **DrawPad Sync**。插件仅支持 Obsidian 桌面端，因为它需要本机 TCP/Bonjour 服务；原有 Mac/iPad app 不需要重新接入插件。

### 浏览器版本

`WebBridge/` + `WebApp/` 是独立的浏览器版本。它复用现有 Excalidraw 网页资产，并用独立 JSON Canvas 编辑器处理 `.canvas` 画板，通过本地 WebSocket/Bonjour Bridge 与 iPad 同步，不参与 Mac/iPad 的 Xcode 构建：

```bash
cd WebBridge
npm install
npm start
```

然后访问 `http://127.0.0.1:8787/`，在 iPad 的 DrawPad 连接列表中选择 **DrawPad Web**。网页侧支持多级目录树；右键目录可新建画板、Canvas、白板、子目录或重命名/删除目录，右键画板可重命名/删除。打开的画板保留在顶部标签栏，关闭标签不会删除文件；已有的单级浏览器数据会自动迁移成根目录。Canvas 与白板在浏览器本地存储中持久化；粘贴图片作为 DrawPad 扩展字段，Obsidian 会显示文字回退。

Canvas 编辑器使用 React Flow 离线包，支持节点拖动、缩放、多选、四边连线、文字和连线标签编辑、颜色、分组、撤销重做以及视口同步。修改编辑器源码后，在 `CanvasEditor/` 执行 `npm install` 和 `npm run build`；依赖版本与参考包位置见 [CanvasEditor/README.md](CanvasEditor/README.md)。

## 调试

- Mac app 启动参数 `--auto-accept-pairing`：自动接受配对（自动化联调）
- 诊断日志：`~/Library/Containers/com.hujing.drawpad.mac/Data/tmp/drawpad_diag.log`（页面加载/挂载/桥错误）
- 协议版本 v5；Mac、iPad、Obsidian 插件和 Web Bridge 需使用相同版本（v1 PencilKit 版本见 git 历史 tag: 初始提交）

## AI 接口（让 Agent 操作画板）

DrawPad Mac app 内置本机 HTTP API（仅 127.0.0.1），AI agent / 脚本 / CLI / MCP 都能读写画板，结果实时渲染并同步到 iPad。

### 自识别（agent 第一步）

```bash
cat ~/.drawpad/api.json        # → {"endpoint": "http://127.0.0.1:7777", ...}
curl -s $(python3 -c "import json;print(json.load(open('$HOME/.drawpad/api.json'))['endpoint'])")/api/health
```
端口可配：`defaults write com.hujing.drawpad.mac api-port 8123` 或启动参数 `--api-port 8123`；被占用自动顺延，真实端口以发现文件为准。

### HTTP API

| 端点 | 说明 |
| --- | --- |
| `GET /api/health` | 状态 + 能力清单（含元素简写说明） |
| `GET/POST /api/folders` | 项目列表 / 新建 |
| `GET/POST /api/boards` | 画板列表（`?folder=` 过滤）/ 新建 `{name, folderId?}` |
| `DELETE /api/boards/<id>` | 删除画板 |
| `GET/PUT /api/boards/<id>/scene` | 读 / 整体替换元素 |
| `POST /api/boards/<id>/elements` | **追加（支持简写）** |
| `DELETE /api/boards/<id>/elements` | 按 id 删除 `{ids:[...]}`（绑定文本跟随删除） |
| `POST /api/import` | `{path, name?}` 导入 .excalidraw / Obsidian .excalidraw.md |

### 元素简写（AI 不用写全 26 个字段）

```json
[
  {"type":"rectangle","id":"n1","x":100,"y":100,"width":180,"height":60,"label":"服务A","fill":"#a5d8ff"},
  {"type":"arrow","from":"n1","to":"n2","label":"请求"}
]
```
- 通用：`type, id, x, y, width, height, angle, stroke, fill, fillStyle, strokeWidth, opacity, roughness`
- `label` 自动生成绑定文本元素；`from`/`to` 自动连接到目标元素中心并建立绑定
- type：`rectangle / ellipse / diamond / text / arrow / line / freedraw`
- 编辑流程：`GET scene` → 修改 → `PUT scene`

### CLI（bin/drawpad）

```bash
drawpad status
drawpad new "架构图" && drawpad rect <id> 100 100 160 64 "客户端" "#a5d8ff"
drawpad elements <id> '[{"type":"arrow","from":"n1","to":"n2"}]'
drawpad import ~/Documents/xxx.excalidraw.md
```

### MCP（接 Claude Code / Cursor）

```bash
claude mcp add drawpad -- python3 /Users/hujing/project/drawipad/bin/drawpad-mcp.py
```
提供 8 个工具：status / list_boards / create_board / get_scene / set_scene / add_elements / delete_elements / import_file。

### 注意

- 导入路径若在 iCloud/第三方同步目录，文件未下载到本地时会等待（已放后台线程不阻塞 UI）；Finder 中右键"立即下载"后即可
- Mac app 已关闭沙盒（AI 需要任意路径读写），仅本机使用场景
