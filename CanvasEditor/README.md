# DrawPad JSON Canvas 编辑器

基于 [React Flow](https://reactflow.dev/) 12.12.0 构建，离线打包后由 Mac、iPad 和本地网页共用。画板数据直接读写 [JSON Canvas 1.0](https://jsoncanvas.org/spec/1.0/) 的 `nodes` / `edges`，额外字段会原样保留。

参考包已下载到 `/Users/hujing/project/xyflow-react-12.12.0`。该目录仅供查阅；运行时使用 `SharedWeb/vendor/canvas.bundle.js` 和 `canvas.bundle.css`，不依赖网络。

修改 `src/` 后重新打包：

```sh
cd CanvasEditor
npm install
npm run build
```

`SharedWeb/canvas.html` 是先前的单文件实现，保留供对照；实际加载入口是 `SharedWeb/canvas-react.html`。
