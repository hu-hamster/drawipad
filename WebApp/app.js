(() => {
  "use strict";

  const STORAGE_KEY = "drawpad-web-v2";
  const LEGACY_STORAGE_KEY = "drawpad-web-v1";
  const SWIFT_REFERENCE_DATE_UNIX = 978307200;
  const state = loadState();
  const lastSceneJSONByPage = new Map(
    state.pages.map((page) => [page.id, sceneJSON(page)]),
  );
  const canvasFrame = document.getElementById("canvas-app");
  let canvasReady = false;
  let api = null;
  let socket = null;
  let suppressUntil = 0;
  let viewportSuppressUntil = 0;
  let lastSentViewport = null;
  let pendingViewportMessage = null;
  let viewportPushTimer = null;
  let ipadConnected = false;
  let browserActive = true;

  function sameID(left, right) {
    return typeof left === "string" && typeof right === "string"
      ? left.toLowerCase() === right.toLowerCase()
      : left === right;
  }

  function isCanvas(page) { return page?.fileExtension === "canvas"; }
  function emptyCanvas() { return { nodes: [], edges: [] }; }
  function sceneJSON(page) {
    return JSON.stringify(isCanvas(page) ? (page.canvas || emptyCanvas()) : page.elements);
  }
  function sendCanvasCommand(name, data) {
    if (canvasReady) canvasFrame.contentWindow?.postMessage({ drawpadCanvasCommand: true, name, data }, location.origin);
  }

  function makeDefaultState() {
    const folderID = crypto.randomUUID();
    const pageID = crypto.randomUUID();
    const now = Date.now();
    return {
      folders: [{ id: folderID, name: "网页画板", parentID: null, createdAt: now }],
      pages: [{ id: pageID, folderID, name: "画板 1", createdAt: now, updatedAt: now, elements: [] }],
      currentFolderID: folderID,
      currentPageID: pageID,
      openPageIDs: [pageID],
      expandedFolderIDs: [folderID],
    };
  }

  function loadState() {
    try {
      const current = JSON.parse(localStorage.getItem(STORAGE_KEY) || "null");
      if (current && Array.isArray(current.folders) && Array.isArray(current.pages)) {
        return normalizeState(current);
      }
      const legacy = JSON.parse(localStorage.getItem(LEGACY_STORAGE_KEY) || "null");
      if (legacy && Array.isArray(legacy.pages) && legacy.pages.length) {
        const folderID = legacy.projectID || crypto.randomUUID();
        const createdAt = Math.min(...legacy.pages.map((page) => page.createdAt || Date.now()));
        return normalizeState({
          folders: [{ id: folderID, name: "网页画板", parentID: null, createdAt }],
          pages: legacy.pages.map((page) => ({ ...page, folderID })),
          currentFolderID: folderID,
          currentPageID: legacy.currentPageID,
          expandedFolderIDs: [folderID],
        });
      }
    } catch (_) {}
    return makeDefaultState();
  }

  function normalizeState(value) {
    const originalFolderIDs = new Set(value.folders.map((folder) => folder.id));
    value.folders = value.folders.map((folder) => ({
      id: folder.id || crypto.randomUUID(),
      name: folder.name || "未命名目录",
      parentID: folder.parentID && originalFolderIDs.has(folder.parentID) ? folder.parentID : null,
      createdAt: folder.createdAt || Date.now(),
    }));
    const folderIDs = new Set(value.folders.map((folder) => folder.id));
    const firstFolderID = value.folders[0]?.id || null;
    value.pages = (firstFolderID ? value.pages : []).map((page) => ({
      id: page.id || crypto.randomUUID(),
      folderID: folderIDs.has(page.folderID) ? page.folderID : firstFolderID,
      name: page.name || "未命名画板",
      createdAt: page.createdAt || Date.now(),
      updatedAt: page.updatedAt || Date.now(),
      fileExtension: page.fileExtension === "canvas" ? "canvas" : undefined,
      elements: Array.isArray(page.elements) ? page.elements : [],
      canvas: page.canvas && typeof page.canvas === "object" && Array.isArray(page.canvas.nodes) && Array.isArray(page.canvas.edges)
        ? page.canvas : emptyCanvas(),
    }));
    const hadTabState = Array.isArray(value.openPageIDs);
    value.openPageIDs = hadTabState
      ? [...new Set(value.openPageIDs)].filter((id) => value.pages.some((page) => sameID(page.id, id)))
      : value.pages.some((page) => sameID(page.id, value.currentPageID)) ? [value.currentPageID] : [];
    if (!value.pages.some((page) => sameID(page.id, value.currentPageID))) {
      value.currentPageID = value.openPageIDs.at(-1) || (!hadTabState ? value.pages[0]?.id : null) || null;
    }
    const selectedPage = value.pages.find((page) => sameID(page.id, value.currentPageID));
    value.currentFolderID = selectedPage?.folderID || (
      folderIDs.has(value.currentFolderID) ? value.currentFolderID : firstFolderID
    );
    value.expandedFolderIDs = Array.isArray(value.expandedFolderIDs)
      ? value.expandedFolderIDs.filter((id) => folderIDs.has(id))
      : value.folders.filter((folder) => folder.parentID === null).map((folder) => folder.id);
    return value;
  }

  const statusEl = document.getElementById("status");
  const treeEl = document.getElementById("tree");
  const tabsEl = document.getElementById("tabs");
  const contextMenuEl = document.getElementById("context-menu");

  function folderByID(id) {
    return state.folders.find((folder) => sameID(folder.id, id)) || null;
  }

  function currentPage() {
    return state.pages.find((page) => sameID(page.id, state.currentPageID)) || null;
  }

  function pagesInFolder(folderID) {
    return state.pages.filter((page) => sameID(page.folderID, folderID));
  }

  function childFolders(parentID) {
    return state.folders.filter((folder) => folder.parentID === parentID);
  }

  function persist() {
    localStorage.setItem(STORAGE_KEY, JSON.stringify(state));
  }

  function swiftDate(ms) {
    return ms / 1000 - SWIFT_REFERENCE_DATE_UNIX;
  }

  function snapshot() {
    return {
      folders: state.folders.map((folder) => ({
        id: folder.id,
        name: folder.name,
        createdAt: swiftDate(folder.createdAt),
        parentID: folder.parentID,
        pageIDs: pagesInFolder(folder.id).map((page) => page.id),
      })),
      pages: state.pages.map((page) => ({
        id: page.id,
        name: page.name,
        createdAt: swiftDate(page.createdAt),
        updatedAt: swiftDate(page.updatedAt),
        width: 1366,
        height: 1024,
        fileExtension: isCanvas(page) ? "canvas" : undefined,
      })),
    };
  }

  function isExpanded(folderID) {
    return state.expandedFolderIDs.includes(folderID);
  }

  function setExpanded(folderID, expanded) {
    const ids = new Set(state.expandedFolderIDs);
    if (expanded) ids.add(folderID); else ids.delete(folderID);
    state.expandedFolderIDs = [...ids];
    persist();
    renderTree();
  }

  function expandAncestors(folderID) {
    const ids = new Set(state.expandedFolderIDs);
    let current = folderByID(folderID);
    const visited = new Set();
    while (current && !visited.has(current.id)) {
      visited.add(current.id);
      ids.add(current.id);
      current = current.parentID ? folderByID(current.parentID) : null;
    }
    state.expandedFolderIDs = [...ids];
  }

  function showContextMenu(x, y, items) {
    contextMenuEl.replaceChildren();
    for (const item of items) {
      if (item === null) {
        contextMenuEl.append(document.createElement("hr"));
        continue;
      }
      const button = document.createElement("button");
      button.type = "button";
      button.role = "menuitem";
      button.textContent = item.label;
      if (item.danger) button.classList.add("danger");
      button.onclick = () => {
        contextMenuEl.hidden = true;
        item.action();
      };
      contextMenuEl.append(button);
    }
    contextMenuEl.hidden = false;
    contextMenuEl.style.left = `${Math.max(4, Math.min(x, window.innerWidth - contextMenuEl.offsetWidth - 4))}px`;
    contextMenuEl.style.top = `${Math.max(4, Math.min(y, window.innerHeight - contextMenuEl.offsetHeight - 4))}px`;
    contextMenuEl.querySelector("button")?.focus();
  }

  function folderMenu(folder) {
    return [
      { label: "新建画板", action: () => createPage(folder.id) },
      { label: "新建 Canvas", action: () => createPage(folder.id, null, "canvas") },
      { label: "新建子目录…", action: () => createFolder(folder.id) },
      null,
      { label: "重命名目录…", action: () => renameFolder(folder.id) },
      { label: "删除目录及其内容…", danger: true, action: () => deleteFolder(folder.id) },
    ];
  }

  function pageMenu(page) {
    const kind = isCanvas(page) ? "Canvas" : "画板";
    return [
      { label: `打开${kind}`, action: () => openPage(page.id, true) },
      { label: `重命名${kind}…`, action: () => renamePage(page.id) },
      null,
      { label: `删除${kind}…`, danger: true, action: () => deletePage(page.id) },
    ];
  }

  function renderFolder(folder) {
    const node = document.createElement("div");
    node.className = "folder-node";
    const row = document.createElement("div");
    row.className = `folder-row${folder.id === state.currentFolderID ? " selected" : ""}`;
    row.tabIndex = 0;
    row.oncontextmenu = (event) => {
      event.preventDefault();
      event.stopPropagation();
      showContextMenu(event.clientX, event.clientY, folderMenu(folder));
    };
    row.onkeydown = (event) => {
      if (event.key === "ContextMenu" || (event.shiftKey && event.key === "F10")) {
        event.preventDefault();
        const rect = row.getBoundingClientRect();
        showContextMenu(rect.left + 24, rect.bottom, folderMenu(folder));
      }
    };
    const directPages = pagesInFolder(folder.id);

    const disclosure = document.createElement("button");
    disclosure.className = "disclosure";
    disclosure.textContent = isExpanded(folder.id) ? "▾" : "▸";
    disclosure.onclick = () => setExpanded(folder.id, !isExpanded(folder.id));
    row.append(disclosure);

    const name = document.createElement("button");
    name.className = "folder-name";
    name.textContent = `📁 ${folder.name}`;
    name.onclick = () => selectFolder(folder.id, true);
    name.ondblclick = () => renameFolder(folder.id);
    row.append(name);
    const count = document.createElement("span");
    count.className = "folder-count";
    count.textContent = String(directPages.length);
    row.append(count);
    node.append(row);

    if (isExpanded(folder.id)) {
      const contents = document.createElement("div");
      contents.className = "folder-contents";
      for (const child of childFolders(folder.id)) contents.append(renderFolder(child));
      for (const page of directPages) {
        const pageRow = document.createElement("div");
        pageRow.className = `page-row${page.id === state.currentPageID ? " selected" : ""}`;
        pageRow.tabIndex = 0;
        pageRow.oncontextmenu = (event) => {
          event.preventDefault();
          event.stopPropagation();
          showContextMenu(event.clientX, event.clientY, pageMenu(page));
        };
        pageRow.onkeydown = (event) => {
          if (event.key === "ContextMenu" || (event.shiftKey && event.key === "F10")) {
            event.preventDefault();
            const rect = pageRow.getBoundingClientRect();
            showContextMenu(rect.left + 24, rect.bottom, pageMenu(page));
          }
        };
        const pageButton = document.createElement("button");
        pageButton.className = "page-name";
        pageButton.textContent = `${isCanvas(page) ? "▣" : "〰"} ${page.name}`;
        pageButton.onclick = () => openPage(page.id, true);
        pageButton.ondblclick = () => renamePage(page.id);
        pageRow.append(pageButton);
        contents.append(pageRow);
      }
      node.append(contents);
    }
    return node;
  }

  function renderTree() {
    treeEl.replaceChildren();
    for (const folder of childFolders(null)) treeEl.append(renderFolder(folder));
    renderTabs();
  }

  function renderTabs() {
    tabsEl.replaceChildren();
    state.openPageIDs = state.openPageIDs.filter((id) => state.pages.some((page) => sameID(page.id, id)));
    for (const id of state.openPageIDs) {
      const page = state.pages.find((item) => sameID(item.id, id));
      const tab = document.createElement("div");
      tab.className = `tab${sameID(page.id, state.currentPageID) ? " active" : ""}`;
      const title = document.createElement("button");
      title.className = "tab-title";
      title.role = "tab";
      title.ariaSelected = String(sameID(page.id, state.currentPageID));
      title.title = page.name;
      title.textContent = `${isCanvas(page) ? "▣" : "〰"} ${page.name}`;
      title.onclick = () => openPage(page.id, true);
      const close = document.createElement("button");
      close.className = "tab-close";
      close.textContent = "×";
      close.title = `关闭标签：${page.name}（不会删除画板）`;
      close.ariaLabel = close.title;
      close.onclick = () => closeTab(page.id);
      tab.append(title, close);
      tabsEl.append(tab);
    }
  }

  function updateStatus(message) {
    const connected = ipadConnected && browserActive;
    statusEl.textContent = message || (
      !browserActive ? "另一个网页窗口正在控制 iPad" :
      ipadConnected ? "iPad 已连接" : "等待 iPad 连接"
    );
    statusEl.className = `status${connected ? " connected" : " warn"}`;
  }

  function sendServerMessage(message) {
    if (socket?.readyState === WebSocket.OPEN) {
      socket.send(JSON.stringify({ type: "serverMessage", message }));
    }
  }

  function sendLibrary() {
    sendServerMessage({ libraryChanged: { snapshot: snapshot() } });
  }

  function sendFileOpened(pageID = state.currentPageID) {
    const page = state.pages.find((item) => sameID(item.id, pageID));
    if (!page) return;
    sendServerMessage({ fileOpened: {
      fileID: page.id,
      folderID: page.folderID,
      elementsJSON: sceneJSON(page),
    } });
    sendCurrentViewport();
  }

  function applyScene(page = currentPage()) {
    const canvas = isCanvas(page);
    document.getElementById("app").hidden = !page || canvas;
    canvasFrame.hidden = !page || !canvas;
    document.getElementById("empty-detail").hidden = Boolean(page);
    if (!page) return;
    lastSceneJSONByPage.set(page.id, sceneJSON(page));
    suppressUntil = Date.now() + 300;
    if (canvas) sendCanvasCommand("applyScene", sceneJSON(page));
    else api?.updateScene({ elements: page.elements });
  }

  function canvasSize() {
    const canvas = document.getElementById("app");
    return {
      width: canvas?.clientWidth || window.innerWidth,
      height: canvas?.clientHeight || window.innerHeight,
    };
  }

  function currentViewport(appState = null) {
    if (!api) return null;
    const current = appState || api.getAppState?.();
    if (!current) return null;
    const { width, height } = canvasSize();
    const zoom = current.zoom?.value || 1;
    const scrollX = current.scrollX || 0;
    const scrollY = current.scrollY || 0;
    return {
      centerX: width / 2 / zoom - scrollX,
      centerY: height / 2 / zoom - scrollY,
      zoom,
      viewWidth: width,
      viewHeight: height,
    };
  }

  function queueViewportMessage(message, immediate = false) {
    pendingViewportMessage = message;
    if (immediate) {
      if (viewportPushTimer !== null) window.clearTimeout(viewportPushTimer);
      viewportPushTimer = null;
      const pending = pendingViewportMessage;
      pendingViewportMessage = null;
      if (pending) sendServerMessage(pending);
      return;
    }
    if (viewportPushTimer !== null) return;
    viewportPushTimer = window.setTimeout(() => {
      viewportPushTimer = null;
      const pending = pendingViewportMessage;
      pendingViewportMessage = null;
      if (pending) sendServerMessage(pending);
    }, 50);
  }

  function sendCurrentViewport() {
    if (isCanvas(currentPage())) {
      sendCanvasCommand("requestViewport", null);
      return;
    }
    const viewport = currentViewport();
    if (!viewport) return;
    lastSentViewport = viewport;
    queueViewportMessage({ viewportZoomChanged: viewport }, true);
  }

  function handleViewportChange(appState) {
    if (Date.now() < viewportSuppressUntil) return;
    const viewport = currentViewport(appState);
    if (!viewport) return;
    if (lastSentViewport === null) {
      lastSentViewport = viewport;
      return;
    }
    const zoomChanged = Math.abs(lastSentViewport.zoom - viewport.zoom) > 0.002;
    const sizeChanged =
      Math.abs(lastSentViewport.viewWidth - viewport.viewWidth) > 0.5 ||
      Math.abs(lastSentViewport.viewHeight - viewport.viewHeight) > 0.5;
    const panChanged =
      Math.abs(lastSentViewport.centerX - viewport.centerX) > 0.5 ||
      Math.abs(lastSentViewport.centerY - viewport.centerY) > 0.5;
    if (!zoomChanged && !sizeChanged && !panChanged) return;
    lastSentViewport = viewport;
    if (zoomChanged || sizeChanged) {
      queueViewportMessage({ viewportZoomChanged: viewport }, true);
    } else {
      queueViewportMessage({ viewportPanChanged: {
        centerX: viewport.centerX,
        centerY: viewport.centerY,
      } });
    }
  }

  function applyViewportPan(centerX, centerY) {
    if (isCanvas(currentPage())) {
      sendCanvasCommand("applyViewportPan", { centerX, centerY });
      return;
    }
    if (!api) return;
    const viewport = currentViewport();
    if (!viewport) return;
    const { width, height } = canvasSize();
    viewportSuppressUntil = Date.now() + 300;
    lastSentViewport = { ...viewport, centerX, centerY, viewWidth: width, viewHeight: height };
    api.updateScene({ appState: {
      scrollX: width / 2 / viewport.zoom - centerX,
      scrollY: height / 2 / viewport.zoom - centerY,
    } });
  }

  function applyViewportZoom(value) {
    if (isCanvas(currentPage())) {
      sendCanvasCommand("applyViewportZoom", value);
      return;
    }
    if (!api) return;
    const { width, height } = canvasSize();
    const ratio = Math.min(
      width / (value.viewWidth || width),
      height / (value.viewHeight || height),
    );
    const zoom = Math.min(8, Math.max(0.1, value.zoom * ratio));
    viewportSuppressUntil = Date.now() + 300;
    lastSentViewport = {
      centerX: value.centerX,
      centerY: value.centerY,
      zoom,
      viewWidth: width,
      viewHeight: height,
    };
    api.updateScene({ appState: {
      zoom: { value: zoom },
      scrollX: width / 2 / zoom - value.centerX,
      scrollY: height / 2 / zoom - value.centerY,
    } });
  }

  function selectFolder(folderID, notifyIPad) {
    const folder = folderByID(folderID);
    if (!folder) return;
    state.currentFolderID = folder.id;
    expandAncestors(folder.id);
    const pages = pagesInFolder(folder.id);
    if (pages.length) {
      openPage(pages[pages.length - 1].id, notifyIPad);
      return;
    }
    state.currentPageID = null;
    persist();
    renderTree();
    applyScene(null);
  }

  function openPage(pageID, notifyIPad) {
    const page = state.pages.find((item) => sameID(item.id, pageID));
    if (!page) return;
    if (!state.openPageIDs.some((id) => sameID(id, page.id))) state.openPageIDs.push(page.id);
    state.currentFolderID = page.folderID;
    state.currentPageID = page.id;
    expandAncestors(page.folderID);
    persist();
    renderTree();
    applyScene(page);
    if (notifyIPad) sendFileOpened(pageID);
  }

  function closeTab(pageID) {
    const index = state.openPageIDs.findIndex((id) => sameID(id, pageID));
    if (index < 0) return;
    state.openPageIDs.splice(index, 1);
    const wasCurrent = sameID(state.currentPageID, pageID);
    if (wasCurrent) {
      const nextID = state.openPageIDs[index] || state.openPageIDs.at(-1) || null;
      if (nextID) {
        openPage(nextID, true);
        return;
      }
      state.currentPageID = null;
    }
    persist();
    renderTree();
    if (wasCurrent) applyScene(null);
  }

  function uniqueFolderName(parentID, preferred, excludingID = null) {
    const siblingNames = new Set(
      childFolders(parentID).filter((folder) => folder.id !== excludingID).map((folder) => folder.name),
    );
    let name = preferred;
    let index = 2;
    while (siblingNames.has(name)) name = `${preferred} ${index++}`;
    return name;
  }

  function createFolder(parentID = null) {
    const rawName = window.prompt(parentID ? "子目录名称" : "根目录名称", "新目录");
    if (rawName === null) return;
    const preferred = rawName.trim();
    if (!preferred) return;
    const folder = {
      id: crypto.randomUUID(),
      name: uniqueFolderName(parentID, preferred),
      parentID,
      createdAt: Date.now(),
    };
    state.folders.push(folder);
    if (parentID && !state.expandedFolderIDs.includes(parentID)) {
      state.expandedFolderIDs.push(parentID);
    }
    state.currentFolderID = folder.id;
    state.currentPageID = null;
    expandAncestors(folder.id);
    persist();
    renderTree();
    applyScene(null);
    sendLibrary();
  }

  function renameFolder(folderID) {
    const folder = folderByID(folderID);
    if (!folder) return;
    const rawName = window.prompt("重命名目录", folder.name);
    if (rawName === null || !rawName.trim()) return;
    folder.name = uniqueFolderName(folder.parentID, rawName.trim(), folder.id);
    persist();
    renderTree();
    sendLibrary();
  }

  function descendantFolderIDs(folderID) {
    const ids = new Set([folderID]);
    let changed = true;
    while (changed) {
      changed = false;
      for (const folder of state.folders) {
        if (folder.parentID && ids.has(folder.parentID) && !ids.has(folder.id)) {
          ids.add(folder.id);
          changed = true;
        }
      }
    }
    return ids;
  }

  function deleteFolder(folderID) {
    const folder = folderByID(folderID);
    if (!folder || !window.confirm(`删除目录“${folder.name}”及其全部子目录和画板？`)) return;
    const previousPageID = state.currentPageID;
    const ids = descendantFolderIDs(folderID);
    for (const page of state.pages) {
      if (ids.has(page.folderID)) lastSceneJSONByPage.delete(page.id);
    }
    state.folders = state.folders.filter((item) => !ids.has(item.id));
    state.pages = state.pages.filter((page) => !ids.has(page.folderID));
    state.expandedFolderIDs = state.expandedFolderIDs.filter((id) => !ids.has(id));
    ensureUsableState();
    persist();
    renderTree();
    if (!sameID(previousPageID, state.currentPageID)) applyScene();
    sendLibrary();
    if (!sameID(previousPageID, state.currentPageID)) sendFileOpened();
  }

  function uniquePageName(folderID, type = "excalidraw") {
    const names = new Set(pagesInFolder(folderID).map((page) => page.name));
    let index = 1;
    const prefix = type === "canvas" ? "Canvas" : "画板";
    let name = `${prefix} ${index}`;
    while (names.has(name)) name = `${prefix} ${++index}`;
    return name;
  }

  function createPage(folderID = state.currentFolderID, afterPageID = state.currentPageID, type = "excalidraw") {
    const folder = folderByID(folderID) || state.folders[0];
    if (!folder) {
      window.alert("请先新建目录");
      return;
    }
    const now = Date.now();
    const page = {
      id: crypto.randomUUID(), folderID: folder.id, name: uniquePageName(folder.id, type),
      createdAt: now, updatedAt: now, fileExtension: type === "canvas" ? "canvas" : undefined,
      elements: [], canvas: emptyCanvas(),
    };
    const afterIndex = afterPageID
      ? state.pages.findIndex((item) => sameID(item.id, afterPageID))
      : -1;
    if (afterIndex >= 0 && sameID(state.pages[afterIndex].folderID, folder.id)) {
      state.pages.splice(afterIndex + 1, 0, page);
    } else {
      state.pages.push(page);
    }
    lastSceneJSONByPage.set(page.id, sceneJSON(page));
    state.openPageIDs.push(page.id);
    state.currentFolderID = folder.id;
    state.currentPageID = page.id;
    expandAncestors(folder.id);
    persist();
    renderTree();
    applyScene(page);
    sendLibrary();
    sendFileOpened(page.id);
  }

  function renamePage(pageID) {
    const page = state.pages.find((item) => item.id === pageID);
    if (!page) return;
    const rawName = window.prompt("重命名画板", page.name);
    if (rawName === null || !rawName.trim()) return;
    page.name = rawName.trim();
    page.updatedAt = Date.now();
    persist();
    renderTree();
    sendLibrary();
  }

  function ensureUsableState(preferredFolderID = null) {
    if (!state.folders.length) {
      state.pages = [];
      state.openPageIDs = [];
      state.currentFolderID = null;
      state.currentPageID = null;
      state.expandedFolderIDs = [];
      return;
    }
    state.openPageIDs = state.openPageIDs.filter((id) => state.pages.some((page) => sameID(page.id, id)));
    if (state.currentPageID !== null && !state.pages.some((page) => sameID(page.id, state.currentPageID))) {
      const page = state.pages.find((item) => sameID(item.id, state.openPageIDs.at(-1))) || state.pages[0];
      state.currentPageID = page?.id || null;
      if (page && !state.openPageIDs.includes(page.id)) state.openPageIDs.push(page.id);
    }
    const current = currentPage();
    if (current) state.currentFolderID = current.folderID;
    else if (!folderByID(state.currentFolderID)) {
      state.currentFolderID = folderByID(preferredFolderID)?.id || state.folders[0].id;
    }
  }

  function deletePage(pageID = state.currentPageID, confirmDelete = true) {
    const page = state.pages.find((item) => sameID(item.id, pageID));
    if (!page) return;
    if (confirmDelete && !window.confirm(`删除${isCanvas(page) ? "Canvas" : "画板"}“${page.name}”？`)) return;
    const wasCurrent = sameID(state.currentPageID, page.id);
    const siblings = pagesInFolder(page.folderID);
    const siblingIndex = siblings.findIndex((item) => item.id === page.id);
    const neighbor = siblings[siblingIndex > 0 ? siblingIndex - 1 : siblingIndex + 1];
    state.pages = state.pages.filter((item) => item.id !== page.id);
    state.openPageIDs = state.openPageIDs.filter((id) => !sameID(id, page.id));
    lastSceneJSONByPage.delete(page.id);
    if (wasCurrent) {
      state.currentPageID = state.openPageIDs.at(-1) || neighbor?.id || state.pages[0]?.id || null;
      if (state.currentPageID && !state.openPageIDs.includes(state.currentPageID)) state.openPageIDs.push(state.currentPageID);
    }
    ensureUsableState(page.folderID);
    persist();
    renderTree();
    if (wasCurrent) applyScene();
    sendLibrary();
    if (wasCurrent) sendFileOpened();
  }

  function handleClientMessage(message) {
    if (message.requestProjectList) {
      sendLibrary();
      sendFileOpened();
    } else if (message.openFile) {
      openPage(message.openFile.fileID, false);
      sendFileOpened(message.openFile.fileID);
    } else if (message.projectSelect) {
      selectFolder(message.projectSelect.folderID, false);
      sendFileOpened();
    } else if (message.fileCreate) {
      createPage(message.fileCreate.folderID, message.fileCreate.afterFileID);
    } else if (message.fileCreateCanvas) {
      createPage(message.fileCreateCanvas.folderID, message.fileCreateCanvas.afterFileID, "canvas");
    } else if (message.fileDelete) {
      deletePage(message.fileDelete.fileID, false);
    } else if (message.viewportPanChanged) {
      applyViewportPan(
        message.viewportPanChanged.centerX,
        message.viewportPanChanged.centerY,
      );
    } else if (message.viewportZoomChanged) {
      applyViewportZoom(message.viewportZoomChanged);
    } else if (message.sceneUpdate) {
      const page = state.pages.find((item) => sameID(item.id, message.sceneUpdate.fileID));
      if (!page) {
        updateStatus("收到 iPad 笔迹，但画板 ID 不一致；请刷新当前页");
        return;
      }
      try {
        const incoming = JSON.parse(message.sceneUpdate.elementsJSON);
        if (isCanvas(page)) {
          if (!incoming || !Array.isArray(incoming.nodes) || !Array.isArray(incoming.edges)) return;
          page.canvas = incoming;
        } else {
          if (!Array.isArray(incoming)) return;
          page.elements = incoming;
        }
        page.updatedAt = Date.now();
        lastSceneJSONByPage.set(page.id, message.sceneUpdate.elementsJSON);
        persist();
        if (sameID(page.id, state.currentPageID)) applyScene(page);
        updateStatus("iPad 已连接 · 笔迹已同步");
      } catch (_) {
        updateStatus("收到 iPad 笔迹，但场景数据无法解析");
      }
    }
  }

  function connect() {
    const protocol = location.protocol === "https:" ? "wss" : "ws";
    socket = new WebSocket(`${protocol}://${location.host}`);
    socket.onopen = () => {
      updateStatus("Bridge 已连接，等待 iPad");
      sendLibrary();
      sendFileOpened();
    };
    socket.onmessage = (event) => {
      let packet;
      try { packet = JSON.parse(event.data); } catch (_) { return; }
      if (packet.type === "bridgeState") {
        ipadConnected = Boolean(packet.ipadConnected);
        browserActive = packet.browserActive !== false;
        updateStatus();
        if (ipadConnected && browserActive) { sendLibrary(); sendFileOpened(); }
      } else if (packet.type === "ipadConnected") {
        ipadConnected = true;
        updateStatus(`iPad 已连接：${packet.deviceName || "iPad"}`);
        sendLibrary();
        sendFileOpened();
      } else if (packet.type === "clientMessage") {
        handleClientMessage(packet.message || {});
      } else if (packet.type === "error") {
        updateStatus(packet.message || "Bridge 同步错误");
      }
    };
    socket.onclose = () => {
      ipadConnected = false;
      updateStatus("Bridge 未连接，正在重试…");
      window.setTimeout(connect, 1500);
    };
    socket.onerror = () => updateStatus("Bridge 连接失败");
  }

  document.getElementById("new-folder").onclick = () => createFolder(null);
  document.getElementById("new-tab").onclick = (event) => {
    const rect = event.currentTarget.getBoundingClientRect();
    showContextMenu(rect.left, rect.bottom, [
      { label: "新建画板", action: () => createPage() },
      { label: "新建 Canvas", action: () => createPage(state.currentFolderID, null, "canvas") },
    ]);
  };
  document.querySelector(".sidebar").addEventListener("contextmenu", (event) => {
    if (event.defaultPrevented) return;
    event.preventDefault();
    showContextMenu(event.clientX, event.clientY, [
      { label: "新建根目录…", action: () => createFolder(null) },
      ...(folderByID(state.currentFolderID) ? [
        { label: "新建画板", action: () => createPage() },
        { label: "新建 Canvas", action: () => createPage(state.currentFolderID, null, "canvas") },
      ] : []),
    ]);
  });
  document.addEventListener("pointerdown", (event) => {
    if (!contextMenuEl.contains(event.target)) contextMenuEl.hidden = true;
  });
  document.addEventListener("keydown", (event) => {
    if (event.key === "Escape") contextMenuEl.hidden = true;
  });
  window.addEventListener("resize", () => { contextMenuEl.hidden = true; });
  document.querySelector(".sidebar").addEventListener("scroll", () => { contextMenuEl.hidden = true; }, true);
  window.addEventListener("message", (event) => {
    if (event.source !== canvasFrame.contentWindow || event.origin !== location.origin) return;
    const packet = event.data;
    if (!packet?.drawpadCanvas) return;
    if (packet.name === "ready") {
      canvasReady = true;
      if (isCanvas(currentPage())) {
        applyScene();
        sendCurrentViewport();
      }
    } else if (packet.name === "sceneChange") {
      const page = currentPage();
      if (!isCanvas(page)) return;
      try {
        const canvas = JSON.parse(packet.data);
        if (!canvas || !Array.isArray(canvas.nodes) || !Array.isArray(canvas.edges)) return;
        if (packet.data === lastSceneJSONByPage.get(page.id)) return;
        page.canvas = canvas;
        page.updatedAt = Date.now();
        lastSceneJSONByPage.set(page.id, packet.data);
        persist();
        sendServerMessage({ sceneUpdate: { fileID: page.id, elementsJSON: packet.data } });
      } catch (_) {}
    } else if (packet.name === "viewportPan" || packet.name === "viewportZoom") {
      if (!isCanvas(currentPage())) return;
      try {
        const value = JSON.parse(packet.data);
        const viewport = { centerX: value.cx, centerY: value.cy, zoom: value.z, viewWidth: value.vw, viewHeight: value.vh };
        if (packet.name === "viewportZoom") queueViewportMessage({ viewportZoomChanged: viewport }, true);
        else queueViewportMessage({ viewportPanChanged: { centerX: value.cx, centerY: value.cy } });
      } catch (_) {}
    }
  });
  expandAncestors(state.currentFolderID);
  persist();
  renderTree();

  ExcalidrawLib.createRoot(document.getElementById("app")).render(
    ExcalidrawLib.React.createElement(ExcalidrawLib.Excalidraw, {
      langCode: "zh-CN",
      renderWelcomeScreen: false,
      initialData: { elements: currentPage()?.elements || [], appState: { viewBackgroundColor: "#ffffff" } },
      onExcalidrawAPI: (value) => {
        api = value;
        applyScene();
        sendCurrentViewport();
      },
      onChange: (elements, appState) => {
        if (isCanvas(currentPage())) return;
        handleViewportChange(appState);
        if (Date.now() < suppressUntil) return;
        const page = currentPage();
        if (!page) return;
        const elementsJSON = JSON.stringify(elements);
        if (elementsJSON === lastSceneJSONByPage.get(page.id)) return;
        lastSceneJSONByPage.set(page.id, elementsJSON);
        page.elements = elements;
        page.updatedAt = Date.now();
        persist();
        sendServerMessage({ sceneUpdate: { fileID: page.id, elementsJSON } });
      },
    }),
  );
  connect();
})();
