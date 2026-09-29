import LZString from "lz-string";

export interface ExcalidrawDocument {
  [key: string]: unknown;
  elements: unknown[];
}

export interface ParsedScene {
  elementsJSON: string;
  document: ExcalidrawDocument;
  encoding: "compressed-markdown" | "json";
}

const compressedFence = /```compressed-json\s*\r?\n([\s\S]*?)```/i;

export function parseExcalidraw(text: string): ParsedScene | null {
  const fence = compressedFence.exec(text);
  if (fence) {
    const encoded = fence[1].replace(/\s+/g, "");
    const decoded = LZString.decompressFromBase64(encoded);
    if (!decoded) return null;
    const document = parseDocument(decoded);
    return document ? { elementsJSON: JSON.stringify(document.elements), document, encoding: "compressed-markdown" } : null;
  }

  const document = parseDocument(text);
  return document ? { elementsJSON: JSON.stringify(document.elements), document, encoding: "json" } : null;
}

function parseDocument(text: string): ExcalidrawDocument | null {
  try {
    const parsed: unknown = JSON.parse(text);
    if (Array.isArray(parsed)) return { elements: parsed };
    if (typeof parsed !== "object" || parsed === null) return null;
    const candidate = parsed as Record<string, unknown>;
    if (!Array.isArray(candidate.elements)) return null;
    return candidate as ExcalidrawDocument;
  } catch {
    return null;
  }
}

export function replaceElements(
  text: string,
  elementsJSON: string,
  parsed: ParsedScene,
): string {
  let elements: unknown[];
  try {
    const value: unknown = JSON.parse(elementsJSON);
    if (!Array.isArray(value)) return text;
    elements = value;
  } catch {
    return text;
  }

  const nextDocument: ExcalidrawDocument = { ...parsed.document, elements };
  if (parsed.encoding === "json") {
    return JSON.stringify(nextDocument, null, 2) + "\n";
  }

  const encoded = LZString.compressToBase64(JSON.stringify(nextDocument));
  const replacement = `\`\`\`compressed-json\n${encoded}\n\`\`\``;
  return text.replace(compressedFence, replacement);
}

export function emptyExcalidrawMarkdown(): string {
  const document: ExcalidrawDocument = {
    type: "excalidraw",
    version: 2,
    source: "https://excalidraw.com",
    elements: [],
    appState: { gridSize: null, gridStep: 5, viewBackgroundColor: "#ffffff" },
    files: {},
  };
  const encoded = LZString.compressToBase64(JSON.stringify(document));
  return [
    "---",
    "excalidraw-plugin: parsed",
    "tags: [excalidraw]",
    "---",
    "",
    "# Excalidraw Data",
    "",
    "## Text Elements",
    "",
    "%%",
    "## Drawing",
    "```compressed-json",
    encoded,
    "```",
    "%%",
    "",
  ].join("\n");
}

export function pageNameFromPath(path: string): string {
  return path
    .split("/")
    .pop()!
    .replace(/\.excalidraw\.md$/i, "")
    .replace(/\.excalidraw$/i, "")
    .replace(/\.canvas$/i, "")
    .replace(/\.whiteboard$/i, "")
    .replace(/\.md$/i, "");
}

export function isExcalidrawPath(path: string): boolean {
  return /\.excalidraw(?:\.md)?$/i.test(path);
}

export function isCanvasPath(path: string): boolean {
  return /\.canvas$/i.test(path);
}

export function isWhiteboardPath(path: string): boolean {
  return /\.whiteboard$/i.test(path);
}

export function isDrawingPath(path: string): boolean {
  return isExcalidrawPath(path) || isCanvasPath(path) || isWhiteboardPath(path);
}

export const EMPTY_WHITEBOARD = '{"pages":[[]],"currentPage":0}';

/** 校验白板分页文档（{pages: [[elements]...], currentPage}），返回规范化 JSON 字符串。 */
export function parseWhiteboard(text: string): string | null {
  try {
    const value: unknown = JSON.parse(text);
    if (!value || typeof value !== "object" || Array.isArray(value)) return null;
    const document = value as Record<string, unknown>;
    if (!Array.isArray(document.pages) || document.pages.length === 0) return null;
    for (const page of document.pages) {
      if (!Array.isArray(page)) return null;
    }
    const currentPage = typeof document.currentPage === "number"
      ? Math.min(Math.max(0, Math.floor(document.currentPage)), document.pages.length - 1)
      : 0;
    return JSON.stringify({ pages: document.pages, currentPage });
  } catch {
    return null;
  }
}

export function parseCanvas(text: string): Record<string, unknown> | null {
  try {
    const value: unknown = JSON.parse(text);
    if (!value || typeof value !== "object" || Array.isArray(value)) return null;
    const document = value as Record<string, unknown>;
    if (document.nodes !== undefined && !Array.isArray(document.nodes)) return null;
    if (document.edges !== undefined && !Array.isArray(document.edges)) return null;
    return { ...document, nodes: document.nodes ?? [], edges: document.edges ?? [] };
  } catch {
    return null;
  }
}
