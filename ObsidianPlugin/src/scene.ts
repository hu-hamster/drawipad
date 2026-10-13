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

export interface IncomingScene {
  elements: unknown[];
  files: Record<string, unknown> | null;
}

/** 解析对端发来的 Excalidraw 场景：兼容旧格式（元素数组）与新格式（{elements, files}）。 */
export function parseIncomingScene(elementsJSON: string): IncomingScene | null {
  try {
    const value: unknown = JSON.parse(elementsJSON);
    if (Array.isArray(value)) return { elements: value, files: null };
    if (typeof value !== "object" || value === null) return null;
    const candidate = value as Record<string, unknown>;
    if (!Array.isArray(candidate.elements)) return null;
    const files = candidate.files;
    return {
      elements: candidate.elements,
      files: files && typeof files === "object" && !Array.isArray(files)
        ? files as Record<string, unknown>
        : null,
    };
  } catch {
    return null;
  }
}

export function replaceElements(
  text: string,
  elementsJSON: string,
  parsed: ParsedScene,
): string {
  const incoming = parseIncomingScene(elementsJSON);
  if (!incoming) return text;

  const previousFiles = parsed.document.files && typeof parsed.document.files === "object"
    ? parsed.document.files as Record<string, unknown>
    : {};
  const nextDocument: ExcalidrawDocument = {
    ...parsed.document,
    elements: incoming.elements,
    // 图片资源按 id 合并：新场景带 files 则覆盖同 id 项，否则保留原文档的
    ...(incoming.files ? { files: { ...previousFiles, ...incoming.files } } : {}),
  };
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
    .replace(/\.mermaid$/i, "")
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

export function isMermaidPath(path: string): boolean {
  return /\.mermaid$/i.test(path);
}

export function isDrawingPath(path: string): boolean {
  return isExcalidrawPath(path) || isCanvasPath(path) || isWhiteboardPath(path) || isMermaidPath(path);
}

export const EMPTY_WHITEBOARD = '{"pages":[[]],"currentPage":0}';
export const EMPTY_MERMAID = '{"code":""}';

/** 校验 Mermaid 文档（{code: string, strokes?: [...]}），返回规范化 JSON 字符串（保留展示标注）。 */
export function parseMermaid(text: string): string | null {
  try {
    const value: unknown = JSON.parse(text);
    if (!value || typeof value !== "object" || Array.isArray(value)) return null;
    const document = value as Record<string, unknown>;
    if (typeof document.code !== "string") return null;
    const strokes: unknown[] = Array.isArray(document.strokes) ? document.strokes : [];
    const kept = strokes.filter((stroke): stroke is { points: [number, number][]; color: string; width: number } => {
      if (!stroke || typeof stroke !== "object" || !Array.isArray((stroke as { points?: unknown }).points)) return false;
      const points = (stroke as { points: unknown[] }).points.filter(
        (point): point is [number, number] =>
          Array.isArray(point) && typeof point[0] === "number" && typeof point[1] === "number",
      );
      return points.length >= 2;
    });
    return JSON.stringify({ code: document.code, strokes: kept });
  } catch {
    return null;
  }
}

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
