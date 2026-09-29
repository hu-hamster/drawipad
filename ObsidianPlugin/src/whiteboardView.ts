import { ItemView, TFile, WorkspaceLeaf } from "obsidian";

export const WHITEBOARD_VIEW_TYPE = "drawpad-whiteboard";

export interface WhiteboardViewport {
  cx: number;
  cy: number;
  z: number;
  vw: number;
  vh: number;
}

export interface WhiteboardViewCallbacks {
  onReady(view: WhiteboardView): void;
  onSceneChange(view: WhiteboardView, docJSON: string): void;
  onViewport(view: WhiteboardView, viewport: WhiteboardViewport, zoomChanged: boolean): void;
}

/**
 * 白板编辑视图：iframe 加载插件目录内的 whiteboard.html
 * （内嵌 Excalidraw 分页编辑器），通过 postMessage 双向通信，
 * 协议与 Canvas 编辑器一致（drawpadCanvas / drawpadCanvasCommand）。
 */
export class WhiteboardView extends ItemView {
  file: TFile | null = null;
  private iframe: HTMLIFrameElement | null = null;
  private ready = false;
  private pendingScene: string | null = null;

  constructor(
    leaf: WorkspaceLeaf,
    private readonly pluginBasePath: string,
    private readonly callbacks: WhiteboardViewCallbacks,
  ) {
    super(leaf);
  }

  getViewType(): string {
    return WHITEBOARD_VIEW_TYPE;
  }

  getDisplayText(): string {
    return this.file?.basename ?? "白板";
  }

  getIcon(): string {
    return "rectangle-on-rectangle";
  }

  setFile(file: TFile): void {
    this.file = file;
    this.app.workspace.requestSaveLayout?.();
  }

  async onLoadFile(file: TFile): Promise<void> {
    this.setFile(file);
  }

  get content(): HTMLElement {
    return this.contentEl;
  }

  async onOpen(): Promise<void> {
    this.contentEl.empty();
    this.contentEl.addClass("drawpad-whiteboard-view");
    const frame = this.contentEl.createEl("iframe", {
      attr: {
        title: "DrawPad 白板",
        allow: "clipboard-read; clipboard-write",
      },
    });
    frame.addClass("drawpad-whiteboard-frame");
    // 桌面端 Electron 支持以 app://local 加载本地插件资源
    frame.src = `app://local${this.pluginBasePath}/whiteboard.html`;
    this.iframe = frame;
  }

  async onClose(): Promise<void> {
    this.iframe?.remove();
    this.iframe = null;
    this.ready = false;
  }

  /** 供插件分发 iframe 消息（插件在 window 层统一监听）。 */
  handlePacket(name: string, data: unknown): void {
    if (name === "ready") {
      this.ready = true;
      this.callbacks.onReady(this);
      if (this.pendingScene !== null) {
        const scene = this.pendingScene;
        this.pendingScene = null;
        this.applyScene(scene);
      }
      return;
    }
    if (name === "sceneChange" && typeof data === "string") {
      this.callbacks.onSceneChange(this, data);
      return;
    }
    if ((name === "viewportPan" || name === "viewportZoom") && typeof data === "string") {
      try {
        const value = JSON.parse(data) as WhiteboardViewport;
        if (typeof value.cx === "number" && typeof value.cy === "number" && typeof value.z === "number") {
          this.callbacks.onViewport(this, value, name === "viewportZoom");
        }
      } catch {
        // 忽略无法解析的视口载荷
      }
    }
  }

  isReady(): boolean {
    return this.ready;
  }

  /** 判断 window message 事件是否来自本视图的 iframe。 */
  matchesSource(source: Window | null): boolean {
    return !!source && this.iframe?.contentWindow === source;
  }

  /** 推送场景（整个白板分页文档 JSON 字符串）。 */
  applyScene(docJSON: string): void {
    if (!this.ready) {
      this.pendingScene = docJSON;
      return;
    }
    this.iframe?.contentWindow?.postMessage(
      { drawpadCanvasCommand: true, name: "__applyScene", data: docJSON },
      "*",
    );
  }

  applyViewportPan(cx: number, cy: number): void {
    this.iframe?.contentWindow?.postMessage(
      { drawpadCanvasCommand: true, name: "__applyViewportPan", data: { cx, cy } },
      "*",
    );
  }

  applyViewportZoom(viewport: WhiteboardViewport): void {
    this.iframe?.contentWindow?.postMessage(
      { drawpadCanvasCommand: true, name: "__applyViewportZoom", data: viewport },
      "*",
    );
  }
}
