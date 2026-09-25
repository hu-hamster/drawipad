import {
  App,
  Modal,
  Notice,
  Plugin,
  PluginSettingTab,
  Setting,
  TFile,
} from "obsidian";
import { VaultLibrary } from "./library";
import { DrawPadServer, PairingRequest } from "./server";
import { ClientMessage, DRAW_PAD_PROTOCOL_VERSION, LibrarySnapshot, ServerMessage } from "./protocol";
import { isExcalidrawPath } from "./scene";

interface DrawPadSettings {
  startOnStartup: boolean;
  autoAcceptKnownDevices: boolean;
}

interface PersistedPluginData {
  settings?: Partial<DrawPadSettings>;
  identity?: unknown;
}

interface ExcalidrawAppStateLike {
  scrollX?: number;
  scrollY?: number;
  zoom?: { value?: number };
}

interface ExcalidrawAPILike {
  getAppState(): ExcalidrawAppStateLike;
  getSceneElements(): unknown[];
  onChange?(callback: (elements: readonly unknown[]) => void): () => void;
  updateScene(scene: {
    appState?: Record<string, unknown>;
    elements?: unknown[];
    commitToHistory?: boolean;
  }): void;
}

interface ExcalidrawViewLike {
  getViewType?(): string;
  excalidrawAPI?: ExcalidrawAPILike;
  contentEl?: HTMLElement;
  file?: TFile;
  forceSave?(silent?: boolean): void | Promise<void>;
}

interface ViewportState {
  centerX: number;
  centerY: number;
  zoom: number;
  viewWidth: number;
  viewHeight: number;
}

type PendingViewport =
  | { kind: "pan"; centerX: number; centerY: number }
  | { kind: "zoom"; viewport: ViewportState };

const DEFAULT_SETTINGS: DrawPadSettings = {
  startOnStartup: true,
  autoAcceptKnownDevices: false,
};

function sameID(left: string | null | undefined, right: string | null | undefined): boolean {
  if (typeof left !== "string" || typeof right !== "string") return left === right;
  return left.toLowerCase() === right.toLowerCase();
}

export default class DrawPadSyncPlugin extends Plugin {
  settings: DrawPadSettings = DEFAULT_SETTINGS;
  library!: VaultLibrary;
  server!: DrawPadServer;

  private statusBar!: HTMLElement;
  private refreshTimer: number | null = null;
  private lastViewport: ViewportState | null = null;
  private viewportSuppressUntil = 0;
  private pendingViewport: PendingViewport | null = null;
  private lastSceneJSONByPage = new Map<string, string>();
  private subscribedSceneAPI: ExcalidrawAPILike | null = null;
  private unsubscribeScene: (() => void) | null = null;
  private sceneSuppressUntil = 0;
  private announcedPageID: string | null = null;
  private fileOpenGeneration = 0;

  async onload(): Promise<void> {
    const raw = await this.loadData();
    const stored = raw && typeof raw === "object" ? raw as PersistedPluginData & Partial<DrawPadSettings> : {};
    const storedSettings = stored.settings ?? stored;
    const storedIdentity = stored.identity ?? ("folders" in stored && "pages" in stored ? stored : null);
    this.settings = { ...DEFAULT_SETTINGS, ...storedSettings };
    this.library = new VaultLibrary(this.app, {
      loadData: async () => storedIdentity,
      saveData: async (identity) => {
        const current = await this.loadData();
        const base = current && typeof current === "object" ? current as Record<string, unknown> : {};
        await this.saveData({ ...base, settings: this.settings, identity });
      },
    });
    await this.library.load();

    this.statusBar = this.addStatusBarItem();
    this.statusBar.addClass("drawpad-sync-status");
    this.updateStatus();
    this.addRibbonIcon("tablet-smartphone", "DrawPad 同步", () => void this.toggleServer());
    this.addCommand({
      id: "toggle-sync",
      name: "切换 DrawPad iPad 同步",
      callback: () => void this.toggleServer(),
    });
    this.addCommand({
      id: "refresh-library",
      name: "刷新 DrawPad 画板列表",
      callback: () => void this.refreshAndBroadcast(),
    });
    this.addSettingTab(new DrawPadSettingTab(this.app, this));

    this.registerEvent(this.app.vault.on("create", () => this.scheduleRefresh()));
    this.registerEvent(this.app.vault.on("delete", () => this.scheduleRefresh()));
    this.registerEvent(this.app.vault.on("rename", () => this.scheduleRefresh()));
    this.registerEvent(this.app.vault.on("modify", (file) => {
      if (file instanceof TFile && isExcalidrawPath(file.path)) this.scheduleRefresh();
    }));
    this.registerEvent(this.app.workspace.on("active-leaf-change", () => {
      this.handleActivePageChanged();
    }));

    this.server = new DrawPadServer(`DrawPad · ${this.app.vault.getName()}`);
    this.server.onPairingRequest = (request) => this.handlePairing(request);
    this.server.onClientConnected = (name) => {
      new Notice(`DrawPad 已连接：${name}`);
      this.lastViewport = null;
      this.lastSceneJSONByPage.clear();
      this.announcedPageID = null;
      this.updateStatus();
      void this.sendCurrentPage();
    };
    this.server.onClientDisconnected = () => {
      new Notice("DrawPad 已断开连接");
      this.lastViewport = null;
      this.pendingViewport = null;
      this.lastSceneJSONByPage.clear();
      this.announcedPageID = null;
      this.fileOpenGeneration += 1;
      this.updateStatus();
    };
    this.server.onMessage = (message) => void this.handleMessage(message);
    this.server.onError = (error) => {
      this.updateStatus("服务错误");
      console.error("DrawPad Sync server error", error);
    };
    this.registerInterval(window.setInterval(() => this.pollCanvas(), 50));

    if (this.settings.startOnStartup) await this.startServer();
  }

  onunload(): void {
    if (this.refreshTimer !== null) window.clearTimeout(this.refreshTimer);
    this.detachSceneSubscription();
    this.server?.stop();
  }

  async startServer(): Promise<void> {
    try {
      await this.server.start();
      this.updateStatus();
      new Notice(`DrawPad 同步已启动：端口 ${this.server.advertisedPort}`);
    } catch (error) {
      this.updateStatus("启动失败");
      new Notice(`DrawPad 同步启动失败：${error instanceof Error ? error.message : String(error)}`);
    }
  }

  stopServer(): void {
    this.server.stop();
    this.updateStatus();
    new Notice("DrawPad 同步已停止");
  }

  async saveSettings(): Promise<void> {
    const current = await this.loadData();
    const base = current && typeof current === "object" ? current as Record<string, unknown> : {};
    await this.saveData({ ...base, settings: this.settings });
  }

  private async toggleServer(): Promise<void> {
    if (this.server.advertisedPort) this.stopServer();
    else await this.startServer();
  }

  private handlePairing(request: PairingRequest): void {
    if (this.settings.autoAcceptKnownDevices) {
      request.accept();
      return;
    }
    new PairingModal(this.app, request).open();
  }

  private async handleMessage(message: ClientMessage): Promise<void> {
    try {
      if ("hello" in message) return;
      if ("requestProjectList" in message) {
        await this.sendLibrary();
        await this.sendCurrentPage();
      } else if ("openFile" in message) {
        await this.library.openPage(message.openFile.fileID);
        await this.sendFileOpened(message.openFile.fileID);
      } else if ("projectSelect" in message) {
        const folder = this.library.getSnapshot().folders.find(
          (item) => sameID(item.id, message.projectSelect.folderID),
        );
        const pageID = folder && folder.pageIDs.length > 0 ? folder.pageIDs[folder.pageIDs.length - 1] : undefined;
        if (pageID) {
          await this.library.openPage(pageID);
          await this.sendFileOpened(pageID);
        }
      } else if ("fileCreate" in message) {
        const page = await this.library.createPage(message.fileCreate.folderID, message.fileCreate.afterFileID);
        await this.sendLibrary();
        await this.library.openPage(page.id);
        await this.sendFileOpened(page.id);
      } else if ("fileDelete" in message) {
        const current = this.library.currentPageID();
        const deletedID = message.fileDelete.fileID;
        const folderBefore = this.library.getSnapshot().folders.find(
          (folder) => folder.pageIDs.some((pageID) => sameID(pageID, deletedID)),
        );
        const folderID = folderBefore?.id;
        const deletedIndex = folderBefore?.pageIDs.findIndex((pageID) => sameID(pageID, deletedID)) ?? -1;
        const neighborID = deletedIndex > 0
          ? folderBefore?.pageIDs[deletedIndex - 1]
          : folderBefore?.pageIDs[deletedIndex + 1];
        await this.library.deletePage(deletedID);
        await this.sendLibrary();
        if (sameID(current, deletedID) && folderID) {
          if (neighborID && this.library.getPageFile(neighborID)) {
            await this.library.openPage(neighborID);
            await this.sendFileOpened(neighborID);
          }
        }
      } else if ("viewportPanChanged" in message) {
        this.pendingViewport = {
          kind: "pan",
          centerX: message.viewportPanChanged.centerX,
          centerY: message.viewportPanChanged.centerY,
        };
        this.applyPendingViewport();
      } else if ("viewportZoomChanged" in message) {
        this.pendingViewport = {
          kind: "zoom",
          viewport: message.viewportZoomChanged,
        };
        this.applyPendingViewport();
      } else if ("sceneUpdate" in message) {
        const appliedLive = this.applyRemoteScene(
          message.sceneUpdate.fileID,
          message.sceneUpdate.elementsJSON,
        );
        if (appliedLive) {
          const view = this.activeExcalidrawView();
          // 让 Excalidraw 插件自己保存当前实时场景，避免外部改文件触发整页重载。
          window.setTimeout(() => void Promise.resolve(view?.forceSave?.(true)), 0);
        } else {
          await this.library.updateScene(message.sceneUpdate.fileID, message.sceneUpdate.elementsJSON);
        }
      }
    } catch (error) {
      const text = error instanceof Error ? error.message : String(error);
      this.server.send({ serverError: { message: text } });
      console.error("DrawPad Sync request failed", error);
    }
  }

  private async sendLibrary(): Promise<void> {
    const snapshot = await this.library.refresh();
    this.server.send({ libraryChanged: { snapshot } });
  }

  private async sendCurrentPage(): Promise<void> {
    const pageID = this.library.currentPageID();
    if (!pageID) {
      this.announcedPageID = null;
      this.fileOpenGeneration += 1;
      return;
    }
    await this.sendFileOpened(pageID);
  }

  private async sendFileOpened(pageID: string): Promise<void> {
    const pageKey = pageID.toLowerCase();
    if (this.announcedPageID === pageKey) return;
    const generation = ++this.fileOpenGeneration;
    const folderID = this.library.getSnapshot().folders.find(
      (folder) => folder.pageIDs.some((candidate) => sameID(candidate, pageID)),
    )?.id;
    if (!folderID) return;
    const elementsJSON = await this.library.readScene(pageID);
    if (generation !== this.fileOpenGeneration) return;
    this.lastSceneJSONByPage.set(pageID.toLowerCase(), elementsJSON);
    this.server.send({ fileOpened: { fileID: pageID, folderID, elementsJSON } });
    this.announcedPageID = pageKey;
    this.lastViewport = null;
  }

  private handleActivePageChanged(): void {
    if (!this.server?.clientName) return;
    const pageID = this.library.currentPageID();
    if (!pageID) {
      this.announcedPageID = null;
      this.fileOpenGeneration += 1;
      return;
    }
    void this.sendFileOpened(pageID);
  }

  private pollCanvas(): void {
    this.pollScene();
    this.pollViewport();
  }

  private pollScene(): void {
    if (!this.server?.clientName) return;
    const pageID = this.library.currentPageID();
    const view = this.activeExcalidrawView();
    const api = view?.excalidrawAPI;
    if (!pageID || !api) return;

    this.ensureSceneSubscription(api);
    this.pushSceneIfChanged(pageID, api.getSceneElements());
  }

  private ensureSceneSubscription(api: ExcalidrawAPILike): void {
    if (this.subscribedSceneAPI === api) return;
    this.detachSceneSubscription();
    this.subscribedSceneAPI = api;
    if (typeof api.onChange !== "function") return;
    this.unsubscribeScene = api.onChange((elements) => {
      const pageID = this.library.currentPageID();
      if (!pageID || !this.server?.clientName) return;
      this.pushSceneIfChanged(pageID, elements);
    });
  }

  private detachSceneSubscription(): void {
    this.unsubscribeScene?.();
    this.unsubscribeScene = null;
    this.subscribedSceneAPI = null;
  }

  private pushSceneIfChanged(pageID: string, elements: readonly unknown[]): void {
    if (Date.now() < this.sceneSuppressUntil) return;
    const elementsJSON = JSON.stringify(elements);
    const key = pageID.toLowerCase();
    if (this.lastSceneJSONByPage.get(key) === elementsJSON) return;
    this.lastSceneJSONByPage.set(key, elementsJSON);
    this.server.send({ sceneUpdate: { fileID: pageID, elementsJSON } });
  }

  private applyRemoteScene(pageID: string, elementsJSON: string): boolean {
    const currentPageID = this.library.currentPageID();
    if (!sameID(currentPageID, pageID)) return false;
    const view = this.activeExcalidrawView();
    const api = view?.excalidrawAPI;
    if (!api) return false;

    try {
      const elements: unknown = JSON.parse(elementsJSON);
      if (!Array.isArray(elements)) return false;
      this.lastSceneJSONByPage.set(pageID.toLowerCase(), elementsJSON);
      this.sceneSuppressUntil = Date.now() + 200;
      api.updateScene({ elements, commitToHistory: true });
      return true;
    } catch {
      // 持久化路径会返回更具体的错误，不在此处重复提示。
      return false;
    }
  }

  private activeExcalidrawView(): ExcalidrawViewLike | null {
    const activeFile = this.app.workspace.getActiveFile();
    const mostRecent = this.app.workspace.getMostRecentLeaf()?.view as unknown as ExcalidrawViewLike | undefined;
    if (
      mostRecent?.getViewType?.() === "excalidraw" &&
      mostRecent.excalidrawAPI &&
      (!activeFile || mostRecent.file?.path === activeFile.path)
    ) {
      return mostRecent;
    }
    for (const leaf of this.app.workspace.getLeavesOfType("excalidraw")) {
      const view = leaf.view as unknown as ExcalidrawViewLike;
      if (
        view.getViewType?.() === "excalidraw" &&
        view.excalidrawAPI &&
        activeFile &&
        view.file?.path === activeFile.path
      ) {
        return view;
      }
    }
    return null;
  }

  private viewSize(view: ExcalidrawViewLike): { width: number; height: number } {
    const canvas = view.contentEl?.querySelector<HTMLElement>(".excalidraw") ?? view.contentEl;
    return {
      width: Math.max(1, canvas?.clientWidth ?? window.innerWidth),
      height: Math.max(1, canvas?.clientHeight ?? window.innerHeight),
    };
  }

  private readViewport(view: ExcalidrawViewLike): ViewportState | null {
    const api = view.excalidrawAPI;
    if (!api) return null;
    const appState = api.getAppState();
    const { width, height } = this.viewSize(view);
    const zoom = appState.zoom?.value || 1;
    const scrollX = appState.scrollX || 0;
    const scrollY = appState.scrollY || 0;
    return {
      centerX: width / 2 / zoom - scrollX,
      centerY: height / 2 / zoom - scrollY,
      zoom,
      viewWidth: width,
      viewHeight: height,
    };
  }

  private pollViewport(): void {
    if (!this.server?.clientName) return;
    const view = this.activeExcalidrawView();
    if (!view) {
      this.lastViewport = null;
      return;
    }
    if (this.pendingViewport) {
      this.applyPendingViewport(view);
      return;
    }
    if (Date.now() < this.viewportSuppressUntil) return;
    const viewport = this.readViewport(view);
    if (!viewport) return;
    if (!this.lastViewport) {
      this.lastViewport = viewport;
      this.server.send({ viewportZoomChanged: viewport });
      return;
    }
    const zoomChanged = Math.abs(this.lastViewport.zoom - viewport.zoom) > 0.002;
    const sizeChanged =
      Math.abs(this.lastViewport.viewWidth - viewport.viewWidth) > 0.5 ||
      Math.abs(this.lastViewport.viewHeight - viewport.viewHeight) > 0.5;
    const panChanged =
      Math.abs(this.lastViewport.centerX - viewport.centerX) > 0.5 ||
      Math.abs(this.lastViewport.centerY - viewport.centerY) > 0.5;
    if (!zoomChanged && !sizeChanged && !panChanged) return;
    this.lastViewport = viewport;
    if (zoomChanged || sizeChanged) {
      this.server.send({ viewportZoomChanged: viewport });
    } else {
      this.server.send({ viewportPanChanged: {
        centerX: viewport.centerX,
        centerY: viewport.centerY,
      } });
    }
  }

  private applyPendingViewport(view = this.activeExcalidrawView()): void {
    const pending = this.pendingViewport;
    const api = view?.excalidrawAPI;
    if (!pending || !view || !api) return;
    const local = this.readViewport(view);
    if (!local) return;
    const { width, height } = this.viewSize(view);
    this.viewportSuppressUntil = Date.now() + 300;
    if (pending.kind === "pan") {
      this.lastViewport = {
        ...local,
        centerX: pending.centerX,
        centerY: pending.centerY,
        viewWidth: width,
        viewHeight: height,
      };
      api.updateScene({ appState: {
        scrollX: width / 2 / local.zoom - pending.centerX,
        scrollY: height / 2 / local.zoom - pending.centerY,
      } });
    } else {
      const remote = pending.viewport;
      const ratio = Math.min(
        width / (remote.viewWidth || width),
        height / (remote.viewHeight || height),
      );
      const zoom = Math.min(8, Math.max(0.1, remote.zoom * ratio));
      this.lastViewport = {
        centerX: remote.centerX,
        centerY: remote.centerY,
        zoom,
        viewWidth: width,
        viewHeight: height,
      };
      api.updateScene({ appState: {
        zoom: { value: zoom },
        scrollX: width / 2 / zoom - remote.centerX,
        scrollY: height / 2 / zoom - remote.centerY,
      } });
    }
    this.pendingViewport = null;
  }

  private scheduleRefresh(): void {
    if (this.refreshTimer !== null) window.clearTimeout(this.refreshTimer);
    this.refreshTimer = window.setTimeout(() => {
      this.refreshTimer = null;
      void this.refreshAndBroadcast();
    }, 250);
  }

  private async refreshAndBroadcast(): Promise<void> {
    await this.library.refresh();
    if (this.server.clientName) {
      await this.sendLibrary();
      // 文件修改只刷新目录元数据。实时场景由 Excalidraw API 的 onChange/
      // 轮询通道发送；重复 fileOpened 会让 iPad 整页重载并造成明显延迟。
    }
  }

  private updateStatus(message?: string): void {
    if (!this.statusBar || !this.server) return;
    if (message) {
      this.statusBar.setText(`DrawPad: ${message}`);
    } else if (this.server.clientName) {
      this.statusBar.setText(`DrawPad: ${this.server.clientName}`);
    } else if (this.server.advertisedPort) {
      this.statusBar.setText("DrawPad: 等待 iPad");
    } else {
      this.statusBar.setText("DrawPad: 已停止");
    }
  }
}

class PairingModal extends Modal {
  constructor(app: App, private readonly request: PairingRequest) {
    super(app);
  }

  onOpen(): void {
    this.modalEl.addClass("drawpad-sync-modal");
    this.titleEl.setText("允许 DrawPad 连接？");
    this.contentEl.createEl("p", { text: "以下设备请求连接当前 Vault，并将能够读取和修改 Excalidraw 画板：" });
    this.contentEl.createDiv({ cls: "drawpad-sync-device", text: this.request.deviceName });
    const actions = this.contentEl.createDiv({ cls: "drawpad-sync-actions" });
    new Setting(actions)
      .addButton((button) => button.setButtonText("拒绝").onClick(() => {
        this.request.reject();
        this.close();
      }))
      .addButton((button) => button.setCta().setButtonText("允许").onClick(() => {
        this.request.accept();
        this.close();
      }));
  }

  onClose(): void {
    this.request.reject();
    this.contentEl.empty();
  }
}

class DrawPadSettingTab extends PluginSettingTab {
  constructor(app: App, private readonly plugin: DrawPadSyncPlugin) {
    super(app, plugin);
  }

  display(): void {
    const { containerEl } = this;
    containerEl.empty();
    containerEl.createEl("h2", { text: "DrawPad Sync" });
    new Setting(containerEl)
      .setName("启动时开启同步")
      .setDesc("Obsidian 启动后自动广播 DrawPad 服务。")
      .addToggle((toggle) => toggle.setValue(this.plugin.settings.startOnStartup).onChange(async (value) => {
        this.plugin.settings.startOnStartup = value;
        await this.plugin.saveSettings();
        if (value && !this.plugin.server.advertisedPort) await this.plugin.startServer();
        if (!value && this.plugin.server.advertisedPort) this.plugin.stopServer();
      }));
    new Setting(containerEl)
      .setName("自动接受新的设备")
      .setDesc("关闭时首次连接会弹出确认；已允许过的设备在本次 Obsidian 会话内会自动重连。")
      .addToggle((toggle) => toggle.setValue(this.plugin.settings.autoAcceptKnownDevices).onChange(async (value) => {
        this.plugin.settings.autoAcceptKnownDevices = value;
        await this.plugin.saveSettings();
      }));
    const snapshot: LibrarySnapshot = this.plugin.library.getSnapshot();
    containerEl.createEl("p", { text: `当前 Vault：${this.app.vault.getName()}，${snapshot.pages.length} 个画板。` });
    containerEl.createEl("p", { text: `协议版本：${DRAW_PAD_PROTOCOL_VERSION}。服务端口：${this.plugin.server.advertisedPort || "未启动"}。` });
  }
}
