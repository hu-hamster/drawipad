import http from "node:http";
import net from "node:net";
import { readFile } from "node:fs/promises";
import { extname, resolve, sep } from "node:path";
import { fileURLToPath } from "node:url";
import Bonjour from "bonjour-service";
import { WebSocketServer, WebSocket } from "ws";
import {
  DRAW_PAD_PROTOCOL_VERSION,
  FrameDecoder,
  decodeJSON,
  frameJSON,
} from "./protocol.mjs";

const here = resolve(fileURLToPath(new URL(".", import.meta.url)));
const webRoot = resolve(here, "../WebApp");
const sharedRoot = resolve(here, "../SharedWeb");
const httpPort = Number(process.env.DRAWPAD_WEB_PORT || 8787);
const serviceName = process.env.DRAWPAD_WEB_NAME || "DrawPad Web";

const MIME_TYPES = {
  ".html": "text/html; charset=utf-8",
  ".js": "text/javascript; charset=utf-8",
  ".css": "text/css; charset=utf-8",
  ".woff": "font/woff",
  ".woff2": "font/woff2",
};

function safePath(root, relativePath) {
  const candidate = resolve(root, `.${sep}${relativePath}`);
  return candidate === root || candidate.startsWith(`${root}${sep}`) ? candidate : null;
}

async function serveStatic(request, response) {
  const pathname = decodeURIComponent(new URL(request.url || "/", "http://localhost").pathname);
  let root = webRoot;
  let relativePath = pathname === "/" ? "index.html" : pathname.slice(1);
  if (pathname.startsWith("/vendor/")) {
    root = resolve(sharedRoot, "vendor");
    relativePath = pathname.slice("/vendor/".length);
  }
  const filePath = safePath(root, relativePath);
  if (!filePath) {
    response.writeHead(403).end("Forbidden");
    return;
  }
  try {
    const body = await readFile(filePath);
    response.writeHead(200, {
      "Content-Type": MIME_TYPES[extname(filePath)] || "application/octet-stream",
      "Cache-Control": "no-cache",
    });
    response.end(body);
  } catch {
    response.writeHead(404).end("Not found");
  }
}

class DrawPadWebBridge {
  #tcp = net.createServer((socket) => this.#handleTCP(socket));
  #http = http.createServer((request, response) => void serveStatic(request, response));
  #wss = new WebSocketServer({ server: this.#http });
  #bonjour = new Bonjour();
  #bonjourService = null;
  #ipad = null;
  #browser = null;
  #activeFileID = null;
  #tcpPort = 0;

  constructor() {
    this.#tcp.on("error", (error) => console.error("DrawPad TCP error:", error));
    this.#wss.on("connection", (socket) => this.#handleBrowser(socket));
  }

  async start() {
    await new Promise((resolveStart, reject) => {
      this.#tcp.once("error", reject);
      this.#tcp.listen(0, "0.0.0.0", () => {
        this.#tcp.off("error", reject);
        this.#tcpPort = this.#tcp.address().port;
        this.#bonjourService = this.#bonjour.publish({
          name: serviceName,
          type: "drawpad",
          protocol: "tcp",
          port: this.#tcpPort,
        });
        resolveStart();
      });
    });
    await new Promise((resolveStart, reject) => {
      this.#http.once("error", reject);
      this.#http.listen(httpPort, "127.0.0.1", () => {
        this.#http.off("error", reject);
        resolveStart();
      });
    });
    console.log(`DrawPad Web: http://127.0.0.1:${httpPort}/`);
    console.log(`DrawPad Web Bonjour: ${serviceName} (_drawpad._tcp, TCP ${this.#tcpPort})`);
  }

  stop() {
    this.#bonjourService?.stop();
    this.#bonjour.destroy();
    this.#ipad?.destroy();
    this.#tcp.close();
    this.#wss.close();
    this.#http.close();
  }

  #broadcast(value) {
    const payload = JSON.stringify(value);
    for (const socket of this.#wss.clients) {
      if (socket.readyState === WebSocket.OPEN) socket.send(payload);
    }
  }

  #sendToBrowser(socket, value) {
    if (socket?.readyState === WebSocket.OPEN) socket.send(JSON.stringify(value));
  }

  #sendBrowserStates() {
    for (const socket of this.#wss.clients) {
      this.#sendToBrowser(socket, {
        type: "bridgeState",
        ipadConnected: Boolean(this.#ipad),
        browserActive: socket === this.#browser,
      });
    }
  }

  #sendToIPad(message) {
    if (this.#ipad && !this.#ipad.destroyed) this.#ipad.write(frameJSON(message));
  }

  #handleBrowser(socket) {
    // 与 Mac App 保持一致：同一时刻只有一个网页负责项目/画板状态。
    // 新打开（或刷新）的页面成为活动页面，旧页面保持连接但不再参与同步，
    // 避免多个标签页轮流下发不同 fileID，导致 iPad 笔迹被当前页丢弃。
    this.#browser = socket;
    this.#activeFileID = null;
    console.log(`Browser connected (${this.#wss.clients.size} total); active browser updated`);
    this.#sendBrowserStates();
    socket.on("message", (raw) => {
      let message;
      try {
        message = JSON.parse(raw.toString("utf8"));
      } catch {
        socket.send(JSON.stringify({ type: "error", message: "网页消息不是有效 JSON" }));
        return;
      }
      if (message?.type === "serverMessage" && message.message) {
        if (socket !== this.#browser) {
          this.#sendToBrowser(socket, { type: "error", message: "此标签页不是当前活动的 DrawPad Web" });
          return;
        }
        console.log(`Browser -> iPad: ${Object.keys(message.message)[0] || "unknown"}`);
        if (message.message.fileOpened?.fileID) {
          this.#activeFileID = message.message.fileOpened.fileID;
        }
        this.#sendToIPad(message.message);
      }
    });
    socket.on("close", () => {
      if (socket !== this.#browser) return;
      const remaining = [...this.#wss.clients].filter(
        (candidate) => candidate !== socket && candidate.readyState === WebSocket.OPEN,
      );
      this.#browser = remaining.at(-1) || null;
      this.#activeFileID = null;
      console.log(`Active browser closed; ${remaining.length} browser(s) remain`);
      this.#sendBrowserStates();
    });
  }

  #handleTCP(socket) {
    socket.setNoDelay(true);
    if (this.#ipad) {
      socket.write(frameJSON({ rejected: { reason: "已有网页客户端连接此 DrawPad Web" } }));
      socket.end();
      return;
    }
    this.#ipad = socket;
    console.log(`iPad TCP connected: ${socket.remoteAddress || "unknown"}`);
    const decoder = new FrameDecoder();
    this.#sendBrowserStates();
    socket.on("data", (chunk) => {
      for (const payload of decoder.feed(chunk)) {
        const message = decodeJSON(payload);
        if (!message) {
          socket.destroy();
          return;
        }
        if (message.hello) {
          if (message.hello.protocolVersion !== DRAW_PAD_PROTOCOL_VERSION) {
            socket.write(frameJSON({ rejected: { reason: "版本不兼容，请更新 DrawPad Web" } }));
            socket.end();
            return;
          }
          socket.write(frameJSON({ helloAccepted: { serverName: serviceName } }));
          console.log(`iPad accepted: ${message.hello.deviceName}`);
          this.#sendToBrowser(this.#browser, {
            type: "ipadConnected",
            deviceName: message.hello.deviceName,
          });
        } else {
          const kind = Object.keys(message)[0] || "unknown";
          console.log(`iPad -> Browser: ${kind} (${payload.length} bytes)`);
          let routedMessage = message;
          // Swift 编码 UUID 时使用大写字母，浏览器 crypto.randomUUID() 使用小写。
          // 两者是同一 UUID 时只统一文本形式；真正不同的画板 ID 不做重定向。
          if (message.sceneUpdate && this.#activeFileID &&
              message.sceneUpdate.fileID !== this.#activeFileID &&
              message.sceneUpdate.fileID.toLowerCase() === this.#activeFileID.toLowerCase()) {
            console.log(
              `Remap sceneUpdate ${message.sceneUpdate.fileID} -> ${this.#activeFileID}`,
            );
            routedMessage = {
              ...message,
              sceneUpdate: { ...message.sceneUpdate, fileID: this.#activeFileID },
            };
          }
          this.#sendToBrowser(this.#browser, {
            type: "clientMessage",
            message: routedMessage,
          });
        }
      }
    });
    socket.on("close", () => {
      if (this.#ipad !== socket) return;
      this.#ipad = null;
      console.log("iPad TCP disconnected");
      this.#sendBrowserStates();
    });
    socket.on("error", () => socket.destroy());
  }
}

const bridge = new DrawPadWebBridge();
await bridge.start();
process.once("SIGINT", () => {
  bridge.stop();
  process.exit(0);
});
process.once("SIGTERM", () => {
  bridge.stop();
  process.exit(0);
});
