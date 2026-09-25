import { App, TFile, normalizePath } from "obsidian";
import { randomUUID } from "node:crypto";
import { Folder, LibrarySnapshot, PageMeta } from "./protocol";
import { emptyExcalidrawMarkdown, isExcalidrawPath, pageNameFromPath, parseExcalidraw, replaceElements } from "./scene";

export interface DataStore {
  loadData(): Promise<unknown>;
  saveData(data: unknown): Promise<void>;
}

interface PersistedIdentity {
  folders: Record<string, string>;
  pages: Record<string, string>;
}

interface FolderInfo {
  path: string;
  folder: Folder;
}

const SWIFT_REFERENCE_DATE_UNIX = 978307200;

function swiftDate(milliseconds: number): number {
  return milliseconds / 1000 - SWIFT_REFERENCE_DATE_UNIX;
}

function idKey(id: string): string {
  return id.toLowerCase();
}

export class VaultLibrary {
  private identity: PersistedIdentity = { folders: {}, pages: {} };
  private folderInfo = new Map<string, FolderInfo>();
  private pageFiles = new Map<string, TFile>();
  private pageFolders = new Map<string, string>();
  private snapshot: LibrarySnapshot = { folders: [], pages: [] };

  constructor(private readonly app: App, private readonly dataStore: DataStore) {}

  async load(): Promise<void> {
    const stored = await this.dataStore.loadData();
    if (stored && typeof stored === "object") {
      const candidate = stored as Partial<PersistedIdentity>;
      if (candidate.folders && candidate.pages) {
        this.identity = { folders: { ...candidate.folders }, pages: { ...candidate.pages } };
      }
    }
    await this.refresh();
  }

  async refresh(): Promise<LibrarySnapshot> {
    const files = this.app.vault
      .getFiles()
      .filter((file) => isExcalidrawPath(file.path))
      .sort((a, b) => a.path.localeCompare(b.path));
    const grouped = new Map<string, TFile[]>();
    const folderPaths = new Set<string>([""]);
    for (const file of files) {
      const folderPath = file.parent?.path ?? "";
      const list = grouped.get(folderPath) ?? [];
      list.push(file);
      grouped.set(folderPath, list);
      let ancestor = folderPath;
      while (ancestor) {
        folderPaths.add(ancestor);
        const separator = ancestor.lastIndexOf("/");
        ancestor = separator >= 0 ? ancestor.slice(0, separator) : "";
      }
    }

    this.folderInfo.clear();
    this.pageFiles.clear();
    this.pageFolders.clear();
    const folders: Folder[] = [];
    const pages: PageMeta[] = [];

    const orderedFolderPaths = [...folderPaths].sort((a, b) => {
      const depthDifference = a.split("/").filter(Boolean).length - b.split("/").filter(Boolean).length;
      return depthDifference || a.localeCompare(b);
    });
    for (const folderPath of orderedFolderPaths) {
      const folderFiles = grouped.get(folderPath) ?? [];
      const folderID = this.identity.folders[folderPath] ?? randomUUID();
      this.identity.folders[folderPath] = folderID;
      const folderName = folderPath ? folderPath.split("/").pop()! : this.app.vault.getName();
      const separator = folderPath.lastIndexOf("/");
      const parentPath = folderPath ? (separator >= 0 ? folderPath.slice(0, separator) : "") : null;
      const parentID = parentPath === null ? null : this.identity.folders[parentPath] ?? null;
      const pageIDs: string[] = [];
      const descendantFiles = files.filter((file) => {
        const candidatePath = file.parent?.path ?? "";
        return candidatePath === folderPath || (folderPath !== "" && candidatePath.startsWith(`${folderPath}/`));
      });
      const createdAt = descendantFiles.reduce(
        (earliest, file) => Math.min(earliest, swiftDate(file.stat.ctime)),
        Number.POSITIVE_INFINITY,
      );
      for (const file of folderFiles) {
        const pageID = this.identity.pages[file.path] ?? randomUUID();
        this.identity.pages[file.path] = pageID;
        const fileCreated = swiftDate(file.stat.ctime);
        const fileUpdated = swiftDate(file.stat.mtime);
        pageIDs.push(pageID);
        pages.push({
          id: pageID,
          name: pageNameFromPath(file.path),
          createdAt: fileCreated,
          updatedAt: fileUpdated,
          width: 1366,
          height: 1024,
        });
        this.pageFiles.set(idKey(pageID), file);
        this.pageFolders.set(idKey(pageID), folderID);
      }
      const folder: Folder = {
        id: folderID,
        name: folderName,
        createdAt: Number.isFinite(createdAt) ? createdAt : swiftDate(Date.now()),
        parentID,
        pageIDs,
      };
      folders.push(folder);
      this.folderInfo.set(idKey(folderID), { path: folderPath, folder });
    }

    this.snapshot = { folders, pages };
    await this.persistIdentity();
    return this.snapshot;
  }

  getSnapshot(): LibrarySnapshot {
    return this.snapshot;
  }

  getPageFile(pageID: string): TFile | undefined {
    return this.pageFiles.get(idKey(pageID));
  }

  getFolder(folderID: string): FolderInfo | undefined {
    return this.folderInfo.get(idKey(folderID));
  }

  async readScene(pageID: string): Promise<string> {
    const file = this.pageFiles.get(idKey(pageID));
    if (!file) throw new Error("找不到画板文件");
    const text = await this.app.vault.read(file);
    const parsed = parseExcalidraw(text);
    if (!parsed) throw new Error(`无法解析“${file.path}”中的 Excalidraw 场景`);
    return parsed.elementsJSON;
  }

  async updateScene(pageID: string, elementsJSON: string): Promise<void> {
    const file = this.pageFiles.get(idKey(pageID));
    if (!file) throw new Error("找不到画板文件");
    const text = await this.app.vault.read(file);
    const parsed = parseExcalidraw(text);
    if (!parsed) throw new Error(`无法解析“${file.path}”中的 Excalidraw 场景`);
    await this.app.vault.modify(file, replaceElements(text, elementsJSON, parsed));
    await this.refresh();
  }

  async createPage(folderID: string, afterPageID: string | null): Promise<PageMeta> {
    const info = this.folderInfo.get(idKey(folderID));
    if (!info) throw new Error("找不到项目");
    const folderPrefix = info.path ? `${info.path}/` : "";
    const existing = new Set(info.folder.pageIDs.map((id) => this.snapshot.pages.find((page) => page.id === id)?.name));
    let name = "画板 1";
    let index = 1;
    while (existing.has(name)) name = `画板 ${++index}`;
    let path = normalizePath(`${folderPrefix}${name}.excalidraw.md`);
    while (this.app.vault.getAbstractFileByPath(path)) {
      name = `画板 ${++index}`;
      path = normalizePath(`${folderPrefix}${name}.excalidraw.md`);
    }
    const file = await this.app.vault.create(path, emptyExcalidrawMarkdown());
    if (afterPageID) {
      // Filesystem order is not part of Obsidian's API; refresh still gives a
      // deterministic path order, while the requested page remains available.
      void afterPageID;
    }
    await this.refresh();
    const pageID = this.identity.pages[file.path];
    const page = this.snapshot.pages.find((candidate) => candidate.id === pageID);
    if (!page) throw new Error("新建画板后无法建立索引");
    return page;
  }

  async deletePage(pageID: string): Promise<void> {
    const file = this.pageFiles.get(idKey(pageID));
    if (!file) throw new Error("找不到画板文件");
    await this.app.vault.trash(file, true);
    await this.refresh();
  }

  async openPage(pageID: string): Promise<void> {
    const file = this.pageFiles.get(idKey(pageID));
    if (!file) throw new Error("找不到画板文件");
    await this.app.workspace.openLinkText(file.path, "", false);
  }

  currentPageID(): string | null {
    const active = this.app.workspace.getActiveFile();
    return active ? this.identity.pages[active.path] ?? null : null;
  }

  async persistIdentity(): Promise<void> {
    await this.dataStore.saveData(this.identity);
  }
}
