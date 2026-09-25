import assert from "node:assert/strict";
import test from "node:test";
import {
  DRAW_PAD_PROTOCOL_VERSION,
  FrameDecoder,
  decodeJSON,
  frameJSON,
} from "../src/protocol.ts";
import {
  emptyExcalidrawMarkdown,
  parseExcalidraw,
  replaceElements,
} from "../src/scene.ts";

test("protocol framing preserves fragmented and coalesced messages", () => {
  const first = frameJSON({ hello: { deviceName: "iPad", protocolVersion: DRAW_PAD_PROTOCOL_VERSION } });
  const second = frameJSON({ requestProjectList: {} });
  const decoder = new FrameDecoder();
  const split = first.subarray(0, 3);
  assert.deepEqual(decoder.feed(split), []);
  const frames = decoder.feed(Buffer.concat([first.subarray(3), second]));
  assert.equal(frames.length, 2);
  assert.deepEqual(decodeJSON(frames[0]), {
    hello: { deviceName: "iPad", protocolVersion: 3 },
  });
  assert.deepEqual(decodeJSON(frames[1]), { requestProjectList: {} });
});

test("protocol frame uses a four-byte big-endian payload length", () => {
  const frame = frameJSON({ ok: true });
  assert.equal(frame.readUInt32BE(0), frame.length - 4);
  assert.equal(frame.subarray(4).toString("utf8"), '{"ok":true}');
});

test("viewport messages preserve pan, zoom, center, and peer dimensions", () => {
  const message = {
    viewportZoomChanged: {
      zoom: 1.25,
      centerX: 420.5,
      centerY: -36.25,
      viewWidth: 1440,
      viewHeight: 900,
    },
  };
  const decoder = new FrameDecoder();
  const [payload] = decoder.feed(frameJSON(message));
  assert.deepEqual(decodeJSON(payload), message);
});

test("compressed Excalidraw Markdown round-trips its elements", () => {
  const source = emptyExcalidrawMarkdown();
  const parsed = parseExcalidraw(source);
  assert.ok(parsed);
  const next = replaceElements(source, JSON.stringify([{ id: "shape-1", type: "rectangle" }]), parsed);
  const reparsed = parseExcalidraw(next);
  assert.ok(reparsed);
  assert.deepEqual(JSON.parse(reparsed.elementsJSON), [{ id: "shape-1", type: "rectangle" }]);
});
