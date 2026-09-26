import React, { memo, useEffect, useMemo, useRef, useState } from "react";
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
  return {
    id: raw.id,
    type: "canvasNode",
    position: { x: Number(raw.x) || 0, y: Number(raw.y) || 0 },
    style: { width: Math.max(72, Number(raw.width) || 220), height: Math.max(48, Number(raw.height) || 120) },
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

const CanvasNode = memo(function CanvasNode({ id, data, selected }) {
  const { raw, editing, updateText, finishEdit, beginResize, finishResize } = data;
  const palette = colorOf(raw.color);
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
  const [edgeLabel, setEdgeLabel] = useState("");
  const [ready, setReady] = useState(false);
  const [connectFrom, setConnectFrom] = useState(null);
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
  function addNode(kind, point) {
    remember();
    const group = kind === "group";
    const raw = { id: uid(), type: group ? "group" : kind === "link" ? "link" : kind === "file" ? "file" : "text",
      x: round(point.x), y: round(point.y), width: group ? 380 : 220, height: group ? 240 : 120,
      ...(group ? { label: "分组" } : kind === "link" ? { url: "https://" } : kind === "file" ? { file: "" } : { text: "" }),
      ...(kind === "rect" || kind === "ellipse" || kind === "diamond" ? { shape: kind } : {}),
      color };
    scene.current = { ...scene.current, nodes: [...scene.current.nodes, raw] };
    setNodes(scene.current.nodes.map(toFlowNode));
    setTool("select");
    if (!group && kind !== "file") setEditingId(raw.id);
    emit();
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
  useEffect(() => {
    const onKey = (event) => {
      const typing = ["INPUT", "TEXTAREA"].includes(document.activeElement?.tagName);
      if (typing) return;
      const key = event.key.toLowerCase();
      if ((event.metaKey || event.ctrlKey) && key === "z") {
        event.preventDefault(); history(event.shiftKey ? "redo" : "undo"); return;
      }
      if (key === "delete" || key === "backspace") { event.preventDefault(); removeSelection(); return; }
      if (!event.metaKey && !event.ctrlKey && { v: 1, t: 1, r: 1, o: 1, d: 1, g: 1, a: 1 }[key]) {
        setTool({ v: "select", t: "text", r: "rect", o: "ellipse", d: "diamond", g: "group", a: "arrow" }[key]);
      }
    };
    window.addEventListener("keydown", onKey);
    return () => window.removeEventListener("keydown", onKey);
  });
  useEffect(() => {
    const onPaste = (event) => {
      if (["INPUT", "TEXTAREA"].includes(document.activeElement?.tagName)) return;
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
  return <div id="editor" ref={root}>
    <ReactFlow nodes={renderedNodes} edges={edges} nodeTypes={NODE_TYPES}
      onInit={(api) => { instance.current = api; setReady(true); }}
      onNodesChange={onNodesChange} onEdgesChange={onEdgesChange} onConnect={onConnect}
      onNodeDragStart={startNodeDrag} onNodeDragStop={stopNodeDrag}
      onNodeClick={(_, node) => {
        if (tool !== "arrow") return;
        if (!connectFrom) setConnectFrom(node.id);
        else { connectClickedNodes(connectFrom, node.id); setConnectFrom(null); setTool("select"); }
      }}
      onNodeDoubleClick={(_, node) => { if (node.data.raw.type !== "file") { remember(); setEditingId(node.id); } }}
      onEdgeClick={(_, edge) => { setSelectedEdge(edge.id); setEdgeLabel(scene.current.edges.find((item) => item.id === edge.id)?.label || ""); }}
      onPaneClick={(event) => {
        setSelectedEdge(null);
        setConnectFrom(null);
        const kind = tool === "select" && event.detail === 2 ? "text" : tool;
        if (kind !== "select" && kind !== "arrow") addNode(kind, instance.current.screenToFlowPosition({ x: event.clientX, y: event.clientY }));
      }}
      onMoveEnd={publishViewport} deleteKeyCode={null} minZoom={0.2} maxZoom={4}
      panOnDrag={[0, 1, 2]} panOnScroll zoomOnScroll={false} zoomOnPinch zoomOnDoubleClick={false}
      fitView={false} connectionRadius={24} defaultViewport={{ x: 40, y: 40, zoom: 1 }}
      nodesConnectable nodesDraggable elementsSelectable>
      <Background variant={BackgroundVariant.Dots} gap={22} size={1.2} color="#ccd4e0" />
      <Controls showInteractive={false} position="bottom-right" />
    </ReactFlow>
    <div className="canvas-tools" role="toolbar" aria-label="Canvas 工具">
      {[["select", "↖", "选择 V"], ["text", "T", "文本 T"], ["rect", "▢", "矩形 R"],
        ["ellipse", "◯", "椭圆 O"], ["diamond", "◇", "菱形 D"], ["group", "▣", "分组 G"],
        ["link", "🔗", "链接"], ["file", "▤", "文件"], ["arrow", "↗", "连线 A"]].map(([name, icon, title]) =>
        <button key={name} type="button" title={title} aria-label={title} className={tool === name ? "active" : ""} onClick={() => { setTool(name); setConnectFrom(null); }}>{icon}</button>)}
      <span className="tool-divider" />
      <button type="button" title="撤销" onClick={() => history("undo")}>↶</button>
      <button type="button" title="重做" onClick={() => history("redo")}>↷</button>
      <button type="button" title="适配内容" onClick={() => window.__fitToContent()}>⛶</button>
    </div>
    <div className="canvas-colors" role="toolbar" aria-label="颜色">
      {COLORS.map(([key, fill]) => <button key={key} type="button" title={`颜色 ${key}`} className={color === key ? "active" : ""}
        style={{ background: fill }} onClick={() => changeColor(key)} />)}
    </div>
    {selectedEdge && <label className="edge-editor">连线文字
      <input value={edgeLabel} onFocus={remember} onChange={(event) => {
        const value = event.target.value;
        setEdgeLabel(value);
        scene.current = { ...scene.current, edges: scene.current.edges.map((edge) => edge.id === selectedEdge ? { ...edge, label: value } : edge) };
        setEdges(scene.current.edges.map(toFlowEdge));
        emit();
      }} />
    </label>}
    <div className="canvas-hint">{connectFrom ? "再点击一个节点完成连线" : "双击空白处新建文本 · 拖动节点边缘连线 · 拖动画布平移 · Shift 拖动框选"}</div>
  </div>;
}

createRoot(document.getElementById("canvas-root")).render(<App />);
