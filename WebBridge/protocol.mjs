export const DRAW_PAD_PROTOCOL_VERSION = 3;
export const MAX_FRAME_SIZE = 64 * 1024 * 1024;

export function frameJSON(value) {
  const payload = Buffer.from(JSON.stringify(value), "utf8");
  const frame = Buffer.allocUnsafe(payload.length + 4);
  frame.writeUInt32BE(payload.length, 0);
  payload.copy(frame, 4);
  return frame;
}

export function decodeJSON(payload) {
  try {
    return JSON.parse(payload.toString("utf8"));
  } catch {
    return null;
  }
}

export class FrameDecoder {
  #buffer = Buffer.alloc(0);

  feed(chunk) {
    this.#buffer = Buffer.concat([this.#buffer, chunk]);
    const frames = [];
    while (this.#buffer.length >= 4) {
      const size = this.#buffer.readUInt32BE(0);
      if (size > MAX_FRAME_SIZE) {
        this.#buffer = Buffer.alloc(0);
        return frames;
      }
      if (this.#buffer.length < size + 4) break;
      frames.push(this.#buffer.subarray(4, size + 4));
      this.#buffer = this.#buffer.subarray(size + 4);
    }
    return frames;
  }
}
