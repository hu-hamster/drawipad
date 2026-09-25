import { Buffer } from "node:buffer";

export const DRAW_PAD_PROTOCOL_VERSION = 3;
export const DRAW_PAD_SERVICE_TYPE = "_drawpad._tcp";
export const MAX_FRAME_SIZE = 64 * 1024 * 1024;

export interface Folder {
  id: string;
  name: string;
  createdAt: number;
  parentID?: string | null;
  pageIDs: string[];
}

export interface PageMeta {
  id: string;
  name: string;
  createdAt: number;
  updatedAt: number;
  width: number;
  height: number;
}

export interface LibrarySnapshot {
  folders: Folder[];
  pages: PageMeta[];
}

export type ClientMessage =
  | { hello: { deviceName: string; protocolVersion: number } }
  | { requestProjectList: Record<string, never> }
  | { openFile: { fileID: string } }
  | { projectSelect: { folderID: string } }
  | { fileCreate: { folderID: string; afterFileID: string | null } }
  | { fileDelete: { fileID: string } }
  | { sceneUpdate: { fileID: string; elementsJSON: string } }
  | { viewportPanChanged: { centerX: number; centerY: number } }
  | {
      viewportZoomChanged: {
        zoom: number;
        centerX: number;
        centerY: number;
        viewWidth: number;
        viewHeight: number;
      };
    };

export type ServerMessage =
  | { helloAccepted: { serverName: string } }
  | { rejected: { reason: string } }
  | { sessionEnded: { reason: string } }
  | { libraryChanged: { snapshot: LibrarySnapshot } }
  | { fileOpened: { fileID: string; folderID: string; elementsJSON: string } }
  | { sceneUpdate: { fileID: string; elementsJSON: string } }
  | { viewportPanChanged: { centerX: number; centerY: number } }
  | {
      viewportZoomChanged: {
        zoom: number;
        centerX: number;
        centerY: number;
        viewWidth: number;
        viewHeight: number;
      };
    }
  | { serverError: { message: string } };

export class FrameDecoder {
  private buffer = Buffer.alloc(0);

  feed(chunk: Buffer): Buffer[] {
    this.buffer = Buffer.concat([this.buffer, chunk]);
    const frames: Buffer[] = [];
    while (this.buffer.length >= 4) {
      const size = this.buffer.readUInt32BE(0);
      if (size > MAX_FRAME_SIZE) {
        this.buffer = Buffer.alloc(0);
        return frames;
      }
      if (this.buffer.length < size + 4) break;
      frames.push(this.buffer.subarray(4, size + 4));
      this.buffer = this.buffer.subarray(size + 4);
    }
    return frames;
  }
}

export function frameJSON(value: unknown): Buffer {
  const payload = Buffer.from(JSON.stringify(value), "utf8");
  const frame = Buffer.allocUnsafe(payload.length + 4);
  frame.writeUInt32BE(payload.length, 0);
  payload.copy(frame, 4);
  return frame;
}

export function decodeJSON<T>(payload: Buffer): T | null {
  try {
    return JSON.parse(payload.toString("utf8")) as T;
  } catch {
    return null;
  }
}

export function isHello(message: ClientMessage): message is Extract<ClientMessage, { hello: unknown }> {
  return typeof message === "object" && message !== null && "hello" in message;
}
