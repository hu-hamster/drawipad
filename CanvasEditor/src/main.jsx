import React, { memo, useEffect, useMemo, useRef, useState } from "react";
import { createPortal } from "react-dom";
import { createRoot } from "react-dom/client";
import {
  ReactFlow, Background, BackgroundVariant, Controls, Handle, MarkerType,
  NodeResizer, Position, applyNodeChanges, applyEdgeChanges,
} from "@xyflow/react";
import "@xyflow/react/dist/style.css";
import "./style.css";

const COLORS = [
  ["0", "#ffffff", "#31353c"], ["1", "#ffe3e3", "#c92a2a"],
  ["2", "#ffe8cc", "#d9480f"], ["3", "#fff3bf", "#e67700"],
  ["4", "#d3f9d8", "#2b8a3e"], ["5", "#d0ebff", "#1864ab"],
  ["6", "#e5dbff", "#5f3dc4"],
];
const COLOR_MAP = Object.fromEntries(COLORS.map(([key, fill, stroke]) => [key, { fill, stroke }]));
const SIDES = { top: Position.Top, right: Position.Right, bottom: Position.Bottom, left: Position.Left };
// 支持按下-拖拽-松开绘制的形状工具
const CREATING = ["text", "rect", "ellipse", "diamond", "group", "link", "file"];
const EMPTY = { nodes: [], edges: [] };
const uid = () => globalThis.crypto?.randomUUID?.() || Math.random().toString(16).slice(2);
const round = (value) => Math.round(Number(value) || 0);

function colorOf(value) {
  return COLOR_MAP[value] || (typeof value === "string" && /^#[0-9a-f]{6}$/i.test(value)
    ? { fill: value, stroke: value } : COLOR_MAP["0"]);
}

function post(name, data) {
  if (window.parent !== window) {
    window.parent.postMessage({ drawpadCanvas: true, name, data }, window.location.origin);
  } else {
    window.webkit?.messageHandlers?.[name]?.postMessage(data);
  }
}

function toFlowNode(raw, index) {
  const isDraw = raw.type === "draw";
  return {
    id: raw.id,
    type: "canvasNode",
    position: { x: Number(raw.x) || 0, y: Number(raw.y) || 0 },
    style: { width: Math.max(isDraw ? 8 : 72, Number(raw.width) || 220), height: Math.max(isDraw ? 8 : 48, Number(raw.height) || 120) },
    data: { raw },
    zIndex: index,
  };
}

function toFlowEdge(raw) {
  const stroke = colorOf(raw.color).stroke;
  return {
    id: raw.id,
    source: raw.fromNode,
    target: raw.toNode,
    sourceHandle: `source-${raw.fromSide || "right"}`,
    targetHandle: `target-${raw.toSide || "left"}`,
    type: "smoothstep",
    label: raw.label || undefined,
    markerStart: raw.fromEnd === "arrow" ? { type: MarkerType.ArrowClosed, color: stroke } : undefined,
    markerEnd: raw.toEnd === "none" ? undefined : { type: MarkerType.ArrowClosed, color: stroke },
    style: { stroke, strokeWidth: 2.3 },
    animated: raw.animated === true,
    data: { raw },
  };
}

function pathD(points, offsetX = 0, offsetY = 0) {
  return points.map(([x, y], index) => `${index ? "L" : "M"}${round(x + offsetX)} ${round(y + offsetY)}`).join(" ");
}

const CanvasNode = memo(function CanvasNode({ id, data, selected }) {
  const { raw, editing, updateText, finishEdit, beginResize, finishResize } = data;
  const palette = colorOf(raw.color);
  if (raw.type === "draw") {
    return <div className={`canvas-node draw ${selected ? "selected" : ""}`}>
      <svg className="draw-svg" viewBox={`0 0 ${Math.max(1, raw.width)} ${Math.max(1, raw.height)}`} preserveAspectRatio="none">
        <path d={pathD(raw.points || [])} stroke={palette.stroke} strokeWidth={3.2} fill="none"
          strokeLinecap="round" strokeLinejoin="round" vectorEffect="non-scaling-stroke" />
      </svg>
    </div>;
  }
  const shape = raw.type === "group" ? "group" : raw.shape || "rect";
  const field = raw.type === "group" ? "label" : raw.type === "link" ? "url" : "text";
  const content = raw.type === "file" ? raw.file : raw[field];
  const inputRef = useRef(null);
  useEffect(() => { if (editing) inputRef.current?.focus(); }, [editing]);
  return <div className={`canvas-node ${shape} ${selected ? "selected" : ""}`} style={{ background: palette.fill, borderColor: palette.stroke }}>
    <NodeResizer isVisible={selected} minWidth={72} minHeight={48} onResizeStart={beginResize} onResizeEnd={(_, params) => finishResize(id, params)} />
    {raw.image ? <img className="node-image" src={raw.image} alt="" /> : null}
    {editing && raw.type !== "file" ?
      <textarea ref={inputRef} className="nodrag" value={content || ""} onChange={(event) => updateText(id, field, event.target.value)} onBlur={finishEdit} onKeyDown={(event) => { if (event.key === "Escape") { event.stopPropagation(); finishEdit(); } }} /> :
      <div className="node-content">{content || (raw.type === "group" ? "分组" : raw.type === "file" ? "文件" : "双击编辑")}</div>}
    {Object.entries(SIDES).map(([side, position]) => <React.Fragment key={side}>
      <Handle type="target" id={`target-${side}`} position={position} className={`canvas-handle target-${side}`} />
      <Handle type="source" id={`source-${side}`} position={position} className={`canvas-handle source-${side}`} />
    </React.Fragment>)}
  </div>;
});
const NODE_TYPES = { canvasNode: CanvasNode };

function App() {
  const [nodes, setNodes] = useState([]);
  const [edges, setEdges] = useState([]);
  const [tool, setTool] = useState("select");
  const [color, setColor] = useState("5");
  const [editingId, setEditingId] = useState(null);
  const [selectedEdge, setSelectedEdge] = useState(null);
  const [ready, setReady] = useState(false);
  const [connectFrom, setConnectFrom] = useState(null);
  // 拖拽绘制草稿（fx/fy = 画布坐标，sx/sy = 屏幕坐标用于预览）
  const [draft, setDraft] = useState(null);
  // 画笔正在进行的笔画
  const [stroke, setStroke] = useState(null);
  // 连线工具的拖拽预连接（fromId + 屏幕坐标预览线）
  const [connectDrag, setConnectDrag] = useState(null);
  // 连线文字的内联编辑（输入框直接出现在线中间）
  const [editingEdge, setEditingEdge] = useState(null);
  const [edgeEditValue, setEdgeEditValue] = useState("");
  const edgeEditRef = useRef(null);
  // 连线快捷组：Portal 到 body，避免被工具栏的 overflow 裁剪
  const arrowSlotRef = useRef(null);
  const [flyoutPos, setFlyoutPos] = useState(null);
  const scene = useRef({ ...EMPTY });
  const instance = useRef(null);
  const root = useRef(null);
  const undo = useRef([]);
  const redo = useRef([]);
  const lastSent = useRef("");
  const emitTimer = useRef(null);
  const suppressViewport = useRef(false);
  const movingGroup = useRef(null);

  function serialize() {
    return JSON.stringify(scene.current, (key, value) =>
      ["x", "y", "width", "height"].includes(key) && typeof value === "number" ? round(value) : value);
  }
  function emit() {
    clearTimeout(emitTimer.current);
    emitTimer.current = setTimeout(() => {
      const json = serialize();
      if (json !== lastSent.current) {
        lastSent.current = json;
        post("sceneChange", json);
      }
    }, 100);
  }
  function remember() {
    undo.current.push(serialize());
    if (undo.current.length > 100) undo.current.shift();
    redo.current = [];
  }
  function loadScene(next, notify = false) {
    scene.current = next;
    setNodes(next.nodes.map(toFlowNode));
    setEdges(next.edges.map(toFlowEdge));
    setEditingId(null);
    setSelectedEdge(null);
    if (notify) emit();
    else lastSent.current = serialize();
  }
  function updateNode(id, field, value) {
    const next = scene.current.nodes.map((node) => node.id === id ? { ...node, [field]: value } : node);
    scene.current = { ...scene.current, nodes: next };
    setNodes((old) => old.map((node) => node.id === id ? { ...node, data: { raw: next.find((item) => item.id === id) } } : node));
    emit();
  }
  function syncNodeBounds(nextNodes) {
    const positions = new Map(nextNodes.map((node) => [node.id, node]));
    scene.current = {
      ...scene.current,
      nodes: scene.current.nodes.filter((node) => positions.has(node.id)).map((node) => {
        const flow = positions.get(node.id);
        return { ...node, x: round(flow.position.x), y: round(flow.position.y),
          width: round(flow.style?.width || flow.measured?.width || node.width),
          height: round(flow.style?.height || flow.measured?.height || node.height) };
      }),
    };
    emit();
  }
  function onNodesChange(changes) {
    if (changes.some((change) => change.type === "remove")) remember();
    setNodes((old) => {
      const next = applyNodeChanges(changes, old);
      if (changes.some((change) => ["position", "dimensions", "remove"].includes(change.type))) syncNodeBounds(next);
      return next;
    });
    const removed = changes.filter((change) => change.type === "remove").map((change) => change.id);
    if (removed.length) {
      scene.current = { ...scene.current, edges: scene.current.edges.filter((edge) => !removed.includes(edge.fromNode) && !removed.includes(edge.toNode)) };
      setEdges(scene.current.edges.map(toFlowEdge));
      emit();
    }
  }
  function onEdgesChange(changes) {
    if (changes.some((change) => change.type === "remove")) remember();
    setEdges((old) => applyEdgeChanges(changes, old));
    const removed = changes.filter((change) => change.type === "remove").map((change) => change.id);
    if (removed.length) {
      scene.current = { ...scene.current, edges: scene.current.edges.filter((edge) => !removed.includes(edge.id)) };
      setSelectedEdge(null);
      emit();
    }
  }
  function onConnect(connection) {
    if (!connection.source || !connection.target || connection.source === connection.target) return;
    setConnectFrom(null);
    setTool("select");
    remember();
    const next = { id: uid(), fromNode: connection.source,
      fromSide: connection.sourceHandle?.replace("source-", "") || "right",
      toNode: connection.target, toSide: connection.targetHandle?.replace("target-", "") || "left",
      toEnd: "arrow", color };
    scene.current = { ...scene.current, edges: [...scene.current.edges, next] };
    setEdges(scene.current.edges.map(toFlowEdge));
    emit();
  }
  function connectClickedNodes(fromID, toID) {
    const from = scene.current.nodes.find((node) => node.id === fromID);
    const to = scene.current.nodes.find((node) => node.id === toID);
    if (!from || !to || fromID === toID) return;
    const dx = to.x + to.width / 2 - from.x - from.width / 2;
    const dy = to.y + to.height / 2 - from.y - from.height / 2;
    const horizontal = Math.abs(dx) >= Math.abs(dy);
    const fromSide = horizontal ? (dx >= 0 ? "right" : "left") : (dy >= 0 ? "bottom" : "top");
    const toSide = horizontal ? (dx >= 0 ? "left" : "right") : (dy >= 0 ? "top" : "bottom");
    onConnect({ source: fromID, target: toID, sourceHandle: `source-${fromSide}`, targetHandle: `target-${toSide}` });
  }
  function addNode(kind, point, size) {
    remember();
    const group = kind === "group";
    const raw = { id: uid(), type: group ? "group" : kind === "link" ? "link" : kind === "file" ? "file" : "text",
      x: round(point.x), y: round(point.y),
      width: size ? round(size.width) : (group ? 380 : 220),
      height: size ? round(size.height) : (group ? 240 : 120),
      ...(group ? { label: "分组" } : kind === "link" ? { url: "https://" } : kind === "file" ? { file: "" } : { text: "" }),
      ...(kind === "rect" || kind === "ellipse" || kind === "diamond" ? { shape: kind } : {}),
      color };
    scene.current = { ...scene.current, nodes: [...scene.current.nodes, raw] };
    setNodes(scene.current.nodes.map(toFlowNode));
    setTool("select");
    if (!group && kind !== "file") setEditingId(raw.id);
    emit();
  }
  // 画笔落笔：一次笔画 = 一个 draw 节点（可整体选中/移动/擦除）
  function addStroke(points) {
    if (!points || points.length < 2) return;
    remember();
    const xs = points.map((p) => p[0]), ys = points.map((p) => p[1]);
    const x = round(Math.min(...xs)), y = round(Math.min(...ys));
    const w = Math.max(4, round(Math.max(...xs) - x)), h = Math.max(4, round(Math.max(...ys) - y));
    const raw = { id: uid(), type: "draw", x, y, width: w, height: h,
      points: points.map(([px, py]) => [round(px - x), round(py - y)]), color };
    scene.current = { ...scene.current, nodes: [...scene.current.nodes, raw] };
    setNodes(scene.current.nodes.map(toFlowNode));
    emit();
  }
  function eraseNode(id) {
    remember();
    scene.current = { nodes: scene.current.nodes.filter((node) => node.id !== id),
      edges: scene.current.edges.filter((edge) => edge.fromNode !== id && edge.toNode !== id) };
    setNodes(scene.current.nodes.map(toFlowNode));
    setEdges(scene.current.edges.map(toFlowEdge));
    setSelectedEdge(null);
    emit();
  }
  function eraseEdge(id) {
    remember();
    scene.current = { ...scene.current, edges: scene.current.edges.filter((edge) => edge.id !== id) };
    setEdges(scene.current.edges.map(toFlowEdge));
    setSelectedEdge(null);
    emit();
  }
  // ---- 拖拽绘制 / 画笔的指针处理（挂在编辑器容器上）----
  function toFlow(clientX, clientY) {
    return instance.current?.screenToFlowPosition({ x: clientX, y: clientY }) || { x: 0, y: 0 };
  }
  function editorPoint(event) {
    const rect = root.current?.getBoundingClientRect();
    return { x: event.clientX - (rect?.left || 0), y: event.clientY - (rect?.top || 0) };
  }
  function onEditorPointerDown(event) {
    if (event.button !== 0) return;
    if (tool === "pen") {
      const overlay = event.target.closest(".pen-overlay");
      if (!overlay) return;
      event.preventDefault();
      const f = toFlow(event.clientX, event.clientY);
      const s = editorPoint(event);
      setStroke({ pts: [[f.x, f.y]], screen: [[s.x, s.y]] });
      try { overlay.setPointerCapture(event.pointerId); } catch (e) {}
      return;
    }
    if (tool === "arrow") {
      // 从节点上按住拖拽发起连线
      const nodeEl = event.target.closest(".react-flow__node");
      if (!nodeEl?.dataset.id) return;
      event.preventDefault();
      const s = editorPoint(event);
      setConnectDrag({ fromId: nodeEl.dataset.id, sx: s.x, sy: s.y, cx: s.x, cy: s.y });
      try { nodeEl.setPointerCapture(event.pointerId); } catch (e) {}
      return;
    }
    if (!CREATING.includes(tool)) return;
    // 仅在空白画布上起笔；工具栏/节点/连线不参与
    if (!event.target.closest(".react-flow__pane")) return;
    event.preventDefault();
    const f = toFlow(event.clientX, event.clientY);
    const s = editorPoint(event);
    setDraft({ fx0: f.x, fy0: f.y, fx1: f.x, fy1: f.y, sx0: s.x, sy0: s.y, sx1: s.x, sy1: s.y });
    try { event.target.setPointerCapture(event.pointerId); } catch (e) {}
  }
  function onEditorPointerMove(event) {
    if (connectDrag) {
      const s = editorPoint(event);
      setConnectDrag((old) => old ? { ...old, cx: s.x, cy: s.y } : old);
    } else if (draft) {
      const f = toFlow(event.clientX, event.clientY);
      const s = editorPoint(event);
      setDraft((old) => old ? { ...old, fx1: f.x, fy1: f.y, sx1: s.x, sy1: s.y } : old);
    } else if (stroke) {
      const f = toFlow(event.clientX, event.clientY);
      const s = editorPoint(event);
      setStroke((old) => {
        if (!old) return old;
        const last = old.screen[old.screen.length - 1];
        if (Math.hypot(s.x - last[0], s.y - last[1]) < 2.5) return old;
        return { pts: [...old.pts, [f.x, f.y]], screen: [...old.screen, [s.x, s.y]] };
      });
    } else if (tool === "select") {
      // 近距捕获：指针离某条线 26px 内即高亮，为点击选中提供对称命中带
      setHoverEdge(nearestEdgeElement(event, 26));
    }
  }
  function onEditorPointerUp(event) {
    if (connectDrag) {
      const drag = connectDrag;
      setConnectDrag(null);
      // 拖动距离足够才视为拖拽连线；轻微移动交给原点击逻辑处理
      if (Math.hypot(drag.cx - drag.sx, drag.cy - drag.sy) >= 10) {
        const hit = docElementFromPoint(event)?.closest(".react-flow__node");
        const targetId = hit?.dataset.id;
        if (targetId && targetId !== drag.fromId) {
          connectClickedNodes(drag.fromId, targetId);
          setTool("select");
          setConnectFrom(null);
        }
      }
      return;
    }
    if (stroke) {
      const pts = stroke.pts;
      setStroke(null);
      addStroke(pts);
      return;
    }
    if (draft) {
      const { fx0, fy0, fx1, fy1 } = draft;
      setDraft(null);
      const w = Math.abs(fx1 - fx0), h = Math.abs(fy1 - fy0);
      if (w >= 14 || h >= 14) {
        addNode(tool, { x: Math.min(fx0, fx1), y: Math.min(fy0, fy1) },
          { width: Math.max(w, 60), height: Math.max(h, 36) });
      } else {
        addNode(tool, { x: fx0, y: fy0 }); // 点按 → 默认尺寸
      }
    }
  }
  // 指针捕获下 event.target 不会变，需要按坐标做命中测试
  function docElementFromPoint(event) {
    const doc = event.target?.ownerDocument;
    if (!doc) return null;
    return doc.elementFromPoint(event.clientX, event.clientY);
  }
  // ---- 近距捕获连线：按到线段的几何距离做对称命中带（26px），不受 SVG 容器裁剪影响 ----
  const hoverEdgeRef = useRef(null);
  function setHoverEdge(el) {
    if (hoverEdgeRef.current === el) return;
    hoverEdgeRef.current?.classList?.remove("hover-near");
    hoverEdgeRef.current = el || null;
    el?.classList?.add("hover-near");
  }
  function nearestEdgeElement(event, threshold) {
    const doc = event.target?.ownerDocument;
    if (!doc?.querySelectorAll) return null;
    let best = null;
    let bestDistance = threshold;
    for (const path of doc.querySelectorAll(".react-flow__edge-path")) {
      const ctm = path.getScreenCTM?.();
      const total = path.getTotalLength?.();
      if (!ctm || !total) continue;
      const steps = Math.min(50, Math.max(10, Math.round(total / 15)));
      for (let i = 0; i <= steps; i++) {
        const point = path.getPointAtLength(total * i / steps).matrixTransform(ctm);
        const distance = Math.hypot(point.x - event.clientX, point.y - event.clientY);
        if (distance < bestDistance) {
          bestDistance = distance;
          best = path.closest(".react-flow__edge");
        }
      }
    }
    return best;
  }
  function changeColor(value) {
    setColor(value);
    const selected = nodes.filter((node) => node.selected).map((node) => node.id);
    if (!selected.length && !selectedEdge) return;
    remember();
    scene.current = { ...scene.current,
      nodes: scene.current.nodes.map((node) => selected.includes(node.id) ? { ...node, color: value } : node),
      edges: scene.current.edges.map((edge) => edge.id === selectedEdge ? { ...edge, color: value } : edge) };
    setNodes(scene.current.nodes.map(toFlowNode));
    setEdges(scene.current.edges.map(toFlowEdge));
    emit();
  }
  function history(direction) {
    const source = direction === "undo" ? undo.current : redo.current;
    const target = direction === "undo" ? redo.current : undo.current;
    if (!source.length) return;
    target.push(serialize());
    loadScene(JSON.parse(source.pop()), true);
  }
  function startNodeDrag(_, node) {
    remember();
    const group = scene.current.nodes.find((item) => item.id === node.id);
    if (group?.type !== "group") { movingGroup.current = null; return; }
    movingGroup.current = { id: node.id, x: group.x, y: group.y,
      children: scene.current.nodes.filter((item) => item.id !== group.id &&
        item.x >= group.x && item.y >= group.y &&
        item.x + item.width <= group.x + group.width && item.y + item.height <= group.y + group.height)
        .map((item) => item.id) };
  }
  function stopNodeDrag() {
    const group = movingGroup.current;
    movingGroup.current = null;
    if (!group) return;
    const moved = scene.current.nodes.find((node) => node.id === group.id);
    if (!moved) return;
    const dx = moved.x - group.x, dy = moved.y - group.y;
    if (!dx && !dy) return;
    scene.current = { ...scene.current, nodes: scene.current.nodes.map((node) => group.children.includes(node.id)
      ? { ...node, x: node.x + dx, y: node.y + dy } : node) };
    setNodes(scene.current.nodes.map(toFlowNode));
    emit();
  }
  // ---- 选中连线的快捷操作（工具栏 T / ≋ / ⇄ 共用）----
  const activeEdgeRaw = edges.find((edge) => edge.id === selectedEdge)?.data?.raw;
  function patchSelectedEdge(patch) {
    if (!selectedEdge) return;
    scene.current = { ...scene.current, edges: scene.current.edges.map((edge) => edge.id === selectedEdge ? { ...edge, ...patch(edge) } : edge) };
    setEdges(scene.current.edges.map(toFlowEdge));
    emit();
  }
  function toggleEdgeAnimated() {
    if (!activeEdgeRaw) return;
    remember();
    patchSelectedEdge((edge) => ({ animated: !edge.animated }));
  }
  function toggleEdgeBidirectional() {
    if (!activeEdgeRaw) return;
    remember();
    patchSelectedEdge((edge) => ({ fromEnd: edge.fromEnd === "arrow" ? undefined : "arrow" }));
  }
  function beginEdgeLabelEdit(edgeId) {
    const target = edgeId || selectedEdge;
    if (!target) return;
    remember();
    setEdgeEditValue(scene.current.edges.find((edge) => edge.id === target)?.label || "");
    setSelectedEdge(target);
    setEditingEdge(target);
  }
  function removeSelection() {
    const ids = nodes.filter((node) => node.selected).map((node) => node.id);
    const edgeIDs = edges.filter((edge) => edge.selected).map((edge) => edge.id);
    if (!ids.length && !edgeIDs.length) return;
    remember();
    scene.current = { ...scene.current,
      nodes: scene.current.nodes.filter((node) => !ids.includes(node.id)),
      edges: scene.current.edges.filter((edge) => !edgeIDs.includes(edge.id) && !ids.includes(edge.fromNode) && !ids.includes(edge.toNode)) };
    setNodes(scene.current.nodes.map(toFlowNode));
    setEdges(scene.current.edges.map(toFlowEdge));
    setSelectedEdge(null);
    emit();
  }
  function currentViewport() {
    const { x, y, zoom } = instance.current?.getViewport() || { x: 0, y: 0, zoom: 1 };
    const width = root.current?.clientWidth || window.innerWidth;
    const height = root.current?.clientHeight || window.innerHeight;
    return { cx: (width / 2 - x) / zoom, cy: (height / 2 - y) / zoom, z: zoom, vw: width, vh: height };
  }
  function publishViewport() {
    if (suppressViewport.current) return;
    const value = currentViewport();
    post("viewportZoom", JSON.stringify(value));
  }
  function setViewport(cx, cy, zoom) {
    if (!instance.current) return "not-ready";
    const width = root.current?.clientWidth || window.innerWidth;
    const height = root.current?.clientHeight || window.innerHeight;
    const z = Math.min(4, Math.max(0.2, zoom));
    suppressViewport.current = true;
    instance.current.setViewport({ x: width / 2 - cx * z, y: height / 2 - cy * z, zoom: z });
    setTimeout(() => { suppressViewport.current = false; }, 150);
    return "ok";
  }
  useEffect(() => {
    window.__applyScene = (json) => {
      try {
        const next = JSON.parse(json);
        if (!next || !Array.isArray(next.nodes) || !Array.isArray(next.edges)) return "invalid";
        clearTimeout(emitTimer.current);
        undo.current = []; redo.current = [];
        loadScene(next);
        return "ok";
      } catch (error) { return `error:${error}`; }
    };
    window.__getScene = serialize;
    window.__getViewport = () => JSON.stringify(currentViewport());
    window.__applyViewportPan = (cx, cy) => setViewport(cx, cy, currentViewport().z);
    window.__applyViewportZoom = (z, cx, cy, peerWidth, peerHeight) => {
      const ratio = Math.min((root.current?.clientWidth || 1) / (peerWidth || root.current?.clientWidth || 1),
        (root.current?.clientHeight || 1) / (peerHeight || root.current?.clientHeight || 1));
      return setViewport(cx, cy, z * ratio);
    };
    window.__localZoom = (factor) => { const view = currentViewport(); return setViewport(view.cx, view.cy, view.z * factor); };
    window.__fitToContent = () => { instance.current?.fitView({ padding: 0.2, duration: 180 }); return "ok"; };
    const onMessage = (event) => {
      if (event.origin !== location.origin || !event.data?.drawpadCanvasCommand) return;
      const { name, data } = event.data;
      if (name === "applyScene") window.__applyScene(data);
      if (name === "applyViewportPan") window.__applyViewportPan(data.centerX, data.centerY);
      if (name === "applyViewportZoom") window.__applyViewportZoom(data.zoom, data.centerX, data.centerY, data.viewWidth, data.viewHeight);
      if (name === "requestViewport") post("viewportZoom", window.__getViewport());
    };
    window.addEventListener("message", onMessage);
    return () => { window.removeEventListener("message", onMessage); clearTimeout(emitTimer.current); };
  }, []);
  useEffect(() => { if (ready) post("ready", { version: 2 }); }, [ready]);
  // 内联连线文字：定位到线中间并跟随视口移动。
  // 编辑区本身完全透明（只承载光标），实时 patch 让画布上的真实标签即时显示文字——
  // 纯 Excalidraw 式所见即所得；注意 React 合成 onChange 在此构建不可靠，用原生 input 驱动。
  useEffect(() => {
    if (!editingEdge) return;
    const input = edgeEditRef.current;
    const edgeEl = root.current?.querySelector(`.react-flow__edge[data-id="${editingEdge}"]`);
    const reposition = () => {
      if (!input || !edgeEl || !root.current) return;
      const base = root.current.getBoundingClientRect();
      const zoom = instance.current?.getViewport?.()?.zoom || 1;
      // 首选：直接对齐真实标签元素的矩形中心（所见即所得）；
      // 标签为空时回退：路径中点上移约 8px*zoom（标签 translateY(-10px) 后的视觉中心）
      let cx, cy;
      const label = edgeEl.querySelector(".react-flow__edge-text");
      if (label) {
        const r = label.getBoundingClientRect();
        cx = r.left + r.width / 2; cy = r.top + r.height / 2;
      } else {
        const path = edgeEl.querySelector(".react-flow__edge-path");
        const m = path?.getScreenCTM?.();
        if (path && m) {
          const p = path.getPointAtLength(path.getTotalLength() / 2);
          const anchor = new DOMPoint(p.x, p.y).matrixTransform(m);
          cx = anchor.x; cy = anchor.y - 8 * m.a;
        } else {
          const r = edgeEl.getBoundingClientRect();
          cx = r.left + r.width / 2; cy = r.top + r.height / 2;
        }
      }
      input.style.left = (cx - base.left) + "px";
      input.style.top = (cy - base.top) + "px";
      input.style.fontSize = (10 * zoom).toFixed(1) + "px";
    };
    if (input && edgeEl) {
      reposition();
      input.textContent = edgeEditValue;
      input.oninput = () => patchSelectedEdge(() => ({ label: input.textContent.replace(/\n/g, "") }));
    }
    if (input) {
      input.focus();
      const doc = input.ownerDocument;
      const range = doc.createRange();
      range.selectNodeContents(input);
      const selection = doc.getSelection();
      selection?.removeAllRanges();
      selection?.addRange(range);
    }
    // 平移/缩放画布时编辑区跟随连线：逐帧跟随（rAF），
    // 不依赖 React Flow 实例事件（v12 的 on() 在此构建不可用，之前订阅静默失败导致光标飘走）
    const offMove = instance.current?.on?.("move", reposition);
    const offZoom = instance.current?.on?.("zoom", reposition);
    let raf = 0;
    const follow = () => { reposition(); raf = requestAnimationFrame(follow); };
    raf = requestAnimationFrame(follow);
    return () => {
      cancelAnimationFrame(raf);
      offMove?.();
      offZoom?.();
      if (input) input.oninput = null;
    };
  }, [editingEdge]);
  // 连线快捷组跟随「连线 ↗」按钮定位（viewport 坐标，Portal 渲染）
  useEffect(() => {
    if (!selectedEdge) { setFlyoutPos(null); return; }
    const locate = () => {
      const slot = arrowSlotRef.current;
      if (!slot) return;
      const rect = slot.getBoundingClientRect();
      setFlyoutPos({ left: rect.right + 10, top: rect.top + rect.height / 2 });
    };
    locate();
    window.addEventListener("resize", locate);
    return () => window.removeEventListener("resize", locate);
  }, [selectedEdge]);
  useEffect(() => {
    const onKey = (event) => {
      // 输入状态（含连线文字的 contenteditable 编辑区）：退格/删除等交给输入本身，
      // 不能被"删除元素"快捷键拦截，否则标签文字只能加不能删
      const active = document.activeElement;
      const typing = !!active && (["INPUT", "TEXTAREA"].includes(active.tagName) || active.isContentEditable);
      if (typing) return;
      const key = event.key.toLowerCase();
      if ((event.metaKey || event.ctrlKey) && key === "z") {
        event.preventDefault(); history(event.shiftKey ? "redo" : "undo"); return;
      }
      if (key === "escape") { setTool("select"); setConnectFrom(null); setSelectedEdge(null); return; }
      if (key === "delete" || key === "backspace") { event.preventDefault(); removeSelection(); return; }
      if (!event.metaKey && !event.ctrlKey && { v: 1, t: 1, r: 1, o: 1, d: 1, g: 1, a: 1, p: 1, e: 1 }[key]) {
        setTool({ v: "select", t: "text", r: "rect", o: "ellipse", d: "diamond", g: "group", a: "arrow", p: "pen", e: "eraser" }[key]);
      }
    };
    window.addEventListener("keydown", onKey);
    return () => window.removeEventListener("keydown", onKey);
  });
  useEffect(() => {
    const onPaste = (event) => {
      const active = document.activeElement;
      if (active && (["INPUT", "TEXTAREA"].includes(active.tagName) || active.isContentEditable)) return;
      const item = [...(event.clipboardData?.items || [])].find((entry) => entry.type.startsWith("image/"));
      if (!item) return;
      event.preventDefault();
      const reader = new FileReader();
      reader.onload = () => {
        const view = currentViewport();
        remember();
        const raw = { id: uid(), type: "text", text: "图片（仅 DrawPad 显示）", image: reader.result,
          x: round(view.cx - 160), y: round(view.cy - 110), width: 320, height: 220 };
        scene.current = { ...scene.current, nodes: [...scene.current.nodes, raw] };
        setNodes(scene.current.nodes.map(toFlowNode));
        emit();
      };
      reader.readAsDataURL(item.getAsFile());
    };
    window.addEventListener("paste", onPaste);
    return () => window.removeEventListener("paste", onPaste);
  });
  const renderedNodes = useMemo(() => nodes.map((node) => ({ ...node, data: { ...node.data,
    editing: editingId === node.id,
    updateText: updateNode,
    finishEdit: () => setEditingId(null),
    beginResize: remember,
    finishResize: (id, params) => {
      const raw = scene.current.nodes.find((item) => item.id === id);
      if (!raw) return;
      scene.current = { ...scene.current, nodes: scene.current.nodes.map((item) => item.id === id
        ? { ...item, x: round(params.x), y: round(params.y), width: round(params.width), height: round(params.height) } : item) };
      emit();
    },
  } })), [nodes, editingId]);
  return <div id="editor" ref={root}
    className={tool === "eraser" ? "eraser-mode" : (tool === "arrow" ? "arrow-mode" : undefined)}
    onPointerDown={onEditorPointerDown} onPointerMove={onEditorPointerMove}
    onPointerUp={onEditorPointerUp} onPointerCancel={onEditorPointerUp}>
    <ReactFlow nodes={renderedNodes} edges={edges} nodeTypes={NODE_TYPES}
      onError={(code, message) => console.error("RF onError", code, message)}
      onInit={(api) => { instance.current = api; setReady(true); }}
      onNodesChange={onNodesChange} onEdgesChange={onEdgesChange} onConnect={onConnect}
      onNodeDragStart={startNodeDrag} onNodeDragStop={stopNodeDrag}
      onNodeClick={(_, node) => {
        if (tool === "eraser") { eraseNode(node.id); return; }
        if (tool !== "arrow") return;
        if (!connectFrom) setConnectFrom(node.id);
        else { connectClickedNodes(connectFrom, node.id); setConnectFrom(null); setTool("select"); }
      }}
      onNodeDoubleClick={(_, node) => { if (node.data.raw.type !== "file") { remember(); setEditingId(node.id); } }}
      onEdgeClick={(_, edge) => {
        if (tool === "eraser") { eraseEdge(edge.id); return; }
        setSelectedEdge(edge.id);
      }}
      onEdgeDoubleClick={(_, edge) => {
        if (tool === "eraser") return;
        beginEdgeLabelEdit(edge.id);
      }}
      onPaneClick={(event) => {
        const near = nearestEdgeElement(event, 26);
        if (near?.dataset?.id) {
          setConnectFrom(null);
          // 双击线附近：与 Excalidraw 一致，直接进入线的文字编辑；单击则只选中
          if (event.detail === 2 && tool !== "eraser") beginEdgeLabelEdit(near.dataset.id);
          else setSelectedEdge(near.dataset.id);
          return;
        }
        setHoverEdge(null);
        setSelectedEdge(null);
        setConnectFrom(null);
        if (tool === "select" && event.detail === 2) {
          addNode("text", instance.current.screenToFlowPosition({ x: event.clientX, y: event.clientY }));
        }
      }}
      onMoveEnd={publishViewport} deleteKeyCode={null} minZoom={0.2} maxZoom={4}
      panOnDrag={CREATING.includes(tool) ? false : [0, 1, 2]} panOnScroll zoomOnScroll={false} zoomOnPinch zoomOnDoubleClick={false}
      fitView={false} connectionRadius={24} defaultViewport={{ x: 40, y: 40, zoom: 1 }}
      nodesConnectable nodesDraggable={tool !== "arrow"} elementsSelectable>
      <Background variant={BackgroundVariant.Dots} gap={22} size={1.2} color="#ccd4e0" />
      <Controls showInteractive={false} position="bottom-right" />
    </ReactFlow>
    {tool === "pen" && <div className="pen-overlay">
      {stroke && <svg className="stroke-preview">
        <path d={pathD(stroke.screen)} stroke={colorOf(color).stroke} strokeWidth={3.2} fill="none"
          strokeLinecap="round" strokeLinejoin="round" />
      </svg>}
    </div>}
    {draft && <div className="draft-preview" style={{
      left: Math.min(draft.sx0, draft.sx1), top: Math.min(draft.sy0, draft.sy1),
      width: Math.abs(draft.sx1 - draft.sx0), height: Math.abs(draft.sy1 - draft.sy0),
      borderColor: colorOf(color).stroke }} />}
    {connectDrag && <svg className="connect-preview">
      <defs><marker id="dpad-arrow" markerWidth="9" markerHeight="9" refX="7" refY="4.5" orient="auto">
        <path d="M0,0 L8,4.5 L0,9 z" fill="#6965db" /></marker></defs>
      <line x1={connectDrag.sx} y1={connectDrag.sy} x2={connectDrag.cx} y2={connectDrag.cy}
        stroke="#6965db" strokeWidth={2.4} strokeDasharray="6 5" markerEnd="url(#dpad-arrow)" />
    </svg>}
    <div className="canvas-tools" role="toolbar" aria-label="Canvas 工具">
      {[["select", "↖", "选择 V"], ["text", "T", "文本 T"], ["rect", "▢", "矩形 R"],
        ["ellipse", "◯", "椭圆 O"], ["diamond", "◇", "菱形 D"], ["group", "▣", "分组 G"],
        ["pen", "✎", "画笔 P"], ["eraser", "⌫", "橡皮擦 E"], ["link", "🔗", "链接"],
        ["file", "▤", "文件"]].map(([name, icon, title]) =>
        <button key={name} type="button" title={title} aria-label={title} className={tool === name ? "active" : ""} onClick={() => { setTool(name); setConnectFrom(null); }}>{icon}</button>)}
      <span className="arrow-slot" ref={arrowSlotRef}>
        <button type="button" title="连线 A" aria-label="连线 A" className={tool === "arrow" ? "active" : ""}
          onClick={() => { setTool("arrow"); setConnectFrom(null); }}>↗</button>
      </span>
      <span className="tool-divider" />
      <button type="button" title="撤销" onClick={() => history("undo")}>↶</button>
      <button type="button" title="重做" onClick={() => history("redo")}>↷</button>
      <button type="button" title="适配内容" onClick={() => window.__fitToContent()}>⛶</button>
    </div>
    <div className="canvas-colors" role="toolbar" aria-label="颜色">
      {COLORS.map(([key, fill]) => <button key={key} type="button" title={`颜色 ${key}`} className={color === key ? "active" : ""}
        style={{ background: fill }} onClick={() => changeColor(key)} />)}
    </div>
    {selectedEdge && flyoutPos && createPortal(
      <span className="edge-flyout" role="group" aria-label="选中连线操作"
        style={{ left: flyoutPos.left, top: flyoutPos.top }}>
        <button type="button" title="连线添加文字" onClick={beginEdgeLabelEdit}>T</button>
        <button type="button" title="连线开/关流动" className={activeEdgeRaw?.animated ? "on" : ""} onClick={toggleEdgeAnimated}>≋</button>
        <button type="button" title="连线开/关双向箭头" className={activeEdgeRaw?.fromEnd === "arrow" ? "on" : ""} onClick={toggleEdgeBidirectional}>⇄</button>
      </span>, document.body)}
    {editingEdge && <div ref={edgeEditRef} className="edge-inline-edit" contentEditable suppressContentEditableWarning
      onKeyDown={(event) => {
        if (event.key === "Enter") {
          event.preventDefault(); // 连线标签不换行，Enter 即提交
          patchSelectedEdge(() => ({ label: edgeEditRef.current?.textContent ?? "" }));
          setEditingEdge(null);
        } else if (event.key === "Escape") {
          patchSelectedEdge(() => ({ label: edgeEditValue }));
          setEditingEdge(null);
        }
      }}
      onBlur={() => {
        if (edgeEditRef.current) patchSelectedEdge(() => ({ label: edgeEditRef.current.textContent }));
        setEditingEdge(null);
      }} />}
    <div className="canvas-hint">{connectFrom ? "再点击一个节点完成连线"
      : tool === "pen" ? "画笔：在画布上拖动书写，一笔一个元素；按 ↖ 退出"
      : tool === "eraser" ? "橡皮擦：点击要删除的元素（整条笔画/节点/连线）"
      : tool === "arrow" ? "连线：从节点按住拖到目标节点松开（也可依次点击两个节点）"
      : "双击空白新建文本 · 选形状后按住拖拽绘制 · ✎ 画笔 · ⌫ 橡皮擦 · 拖节点边缘连线"}</div>
  </div>;
}

createRoot(document.getElementById("canvas-root")).render(<App />);
