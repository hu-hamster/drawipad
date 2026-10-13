import { FileView, TFile, WorkspaceLeaf } from "obsidian";

export const MERMAID_VIEW_TYPE = "drawpad-mermaid";

export interface MermaidViewCallbacks {
  onReady(view: MermaidView): void;
  onSceneChange(view: MermaidView, docJSON: string): void;
  onFileLoaded(view: MermaidView): void;
}

/**
 * Mermaid 编辑视图：iframe 加载插件目录内的 mermaid.html
 * （文本代码 + 实时渲染预览），通过 postMessage 双向通信，
 * 协议与 Canvas/白板编辑器一致（drawpadCanvas / drawpadCanvasCommand）。
 * 继承 FileView：onLoadFile 是文件绑定唯一可靠的入口（ItemView 下不会被调用）。
 */
export class MermaidView extends FileView {
  declare file: TFile | null;
  private iframe: HTMLIFrameElement | null = null;
  private ready = false;
  private pendingScene: string | null = null;

  constructor(
    leaf: WorkspaceLeaf,
    private readonly pluginBasePath: string,
    private readonly callbacks: MermaidViewCallbacks,
  ) {
    super(leaf);
  }

  getViewType(): string {
    return MERMAID_VIEW_TYPE;
  }

  canAcceptExtension(extension: string): boolean {
    return extension === "mermaid";
  }

  getDisplayText(): string {
    return this.file?.basename ?? "Mermaid";
  }

  getIcon(): string {
    return "git-graph";
  }

  async onLoadFile(file: TFile): Promise<void> {
    this.file = file;
    // 文件可能在 iframe 就绪前加载：缓存待应用内容；就绪后也可能换文件，通知插件重新读取
    if (this.ready) {
      this.callbacks.onFileLoaded(this);
    }
  }

  async onUnloadFile(file: TFile): Promise<void> {
    if (this.file?.path === file.path) this.file = null;
    this.ready = false;
    this.pendingScene = null;
  }

  get content(): HTMLElement {
    return this.contentEl;
  }

  async onOpen(): Promise<void> {
    this.contentEl.empty();
    this.contentEl.addClass("drawpad-mermaid-view");
    const frame = this.contentEl.createEl("iframe", {
      attr: {
        title: "DrawPad Mermaid",
        allow: "clipboard-read; clipboard-write",
      },
    });
    frame.addClass("drawpad-mermaid-frame");
    // 桌面端 Electron 支持以 app://local 加载本地插件资源
    frame.src = `app://local${this.pluginBasePath}/mermaid.html`;
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
      } else if (this.file) {
        // 就绪时已绑定文件：让插件读取并下发
        this.callbacks.onFileLoaded(this);
      }
      return;
    }
    if (name === "sceneChange" && typeof data === "string") {
      this.callbacks.onSceneChange(this, data);
    }
  }

  isReady(): boolean {
    return this.ready;
  }

  /** 判断 window message 事件是否来自本视图的 iframe。 */
  matchesSource(source: Window | null): boolean {
    return !!source && this.iframe?.contentWindow === source;
  }

  /** 推送场景（{"code": "...", "strokes": [...]} JSON 字符串）。 */
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
}
