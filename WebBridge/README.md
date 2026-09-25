# DrawPad Web

这是一个独立的浏览器版本，不修改现有 Mac/iPad 工程。

## 启动

```bash
cd WebBridge
npm install
npm start
```

然后打开 <http://127.0.0.1:8787/>。iPad 的 DrawPad 会在局域网中看到 `DrawPad Web`，点进去即可连接浏览器画布。

网页的多级目录树、画板和场景保存在浏览器的 `localStorage` 中。可以新建根目录、任意层级子目录，重命名或递归删除目录，并在每个目录中管理画板。旧版单级数据会在首次打开时自动迁移。网页和 iPad 通过协议 v3 同步：iPad 的目录/画板操作会传给网页，网页绘制以及画布平移、缩放视口会实时同步到 iPad，iPad 的视口变化也会同步回网页。

## 说明

- Bridge 同时提供 HTTP、WebSocket 和 `_drawpad._tcp` Bonjour 服务。
- 浏览器本身不能直接发现 Bonjour 或连接原始 TCP，因此必须先启动 Bridge。
- 如果 Mac DrawPad、Obsidian 插件和 Web Bridge 同时运行，iPad 会看到多个服务；选择 `DrawPad Web` 即可进入网页版本。
- 若要让多个浏览器远程访问，需要把 WebSocket 从本地 Bridge 改为 HTTPS/WSS 中继服务；本版本先聚焦同一局域网。
