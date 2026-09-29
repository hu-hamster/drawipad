#!/usr/bin/env python3
"""DrawPad MCP server（stdio, newline-delimited JSON-RPC）

把 DrawPad 的 HTTP API 暴露为 MCP 工具，供 Claude Code / Cursor 等 agent 使用。
endpoint 自动从 ~/.drawpad/api.json 发现。

注册（Claude Code 示例）:
  claude mcp add drawpad -- python3 /Users/hujing/project/drawipad/bin/drawpad-mcp.py
"""
import json
import os
import sys
import urllib.request

DISCOVERY = os.path.expanduser("~/.drawpad/api.json")


def endpoint() -> str:
    with open(DISCOVERY) as f:
        return json.load(f)["endpoint"]


def api(method: str, path: str, body=None):
    data = json.dumps(body).encode() if body is not None else None
    req = urllib.request.Request(
        endpoint() + path, data=data, method=method,
        headers={"Content-Type": "application/json"})
    with urllib.request.urlopen(req, timeout=120) as resp:
        return json.loads(resp.read().decode())


TOOLS = [
    {
        "name": "drawpad_status",
        "description": "获取 DrawPad 画板服务状态与能力清单（iPad 是否连接等）",
        "inputSchema": {"type": "object", "properties": {}},
    },
    {
        "name": "drawpad_list_boards",
        "description": "列出所有画板（返回 id、名称、所属项目）",
        "inputSchema": {"type": "object", "properties": {}},
    },
    {
        "name": "drawpad_create_board",
        "description": "新建画板，返回画板 id",
        "inputSchema": {
            "type": "object",
            "properties": {"name": {"type": "string", "description": "画板名称"}},
            "required": ["name"],
        },
    },
    {
        "name": "drawpad_get_scene",
        "description": "读取画板当前全部元素的 JSON（编辑流程：读→改→set）",
        "inputSchema": {
            "type": "object",
            "properties": {"board": {"type": "string", "description": "画板 id"}},
            "required": ["board"],
        },
    },
    {
        "name": "drawpad_set_scene",
        "description": "整体替换画板元素（JSON 数组字符串）",
        "inputSchema": {
            "type": "object",
            "properties": {
                "board": {"type": "string"},
                "elements": {"type": "string", "description": "Excalidraw 元素 JSON 数组"},
            },
            "required": ["board", "elements"],
        },
    },
    {
        "name": "drawpad_add_elements",
        "description": (
            "向画板追加元素（支持简写）："
            "type=rectangle/ellipse/diamond/text/arrow/line/freedraw；"
            "通用字段 id,x,y,width,height,stroke,fill,strokeWidth,opacity；"
            "shape 支持 label（自动生成绑定文本）；"
            "arrow 支持 from/to（元素 id，自动连接到元素中心）或 x1,y1,x2,y2，可带 label"
        ),
        "inputSchema": {
            "type": "object",
            "properties": {
                "board": {"type": "string"},
                "elements": {
                    "type": "string",
                    "description": "简写元素 JSON 数组，如 "
                        '[{"type":"rectangle","id":"n1","x":100,"y":100,"label":"服务A","fill":"#a5d8ff"},'
                        '{"type":"arrow","from":"n1","to":"n2"}]',
                },
            },
            "required": ["board", "elements"],
        },
    },
    {
        "name": "drawpad_delete_elements",
        "description": "按 id 删除画板元素（多个用逗号分隔，绑定文本自动跟随删除）",
        "inputSchema": {
            "type": "object",
            "properties": {
                "board": {"type": "string"},
                "ids": {"type": "string", "description": "元素 id，逗号分隔"},
            },
            "required": ["board", "ids"],
        },
    },
    {
        "name": "drawpad_import_file",
        "description": "导入 .excalidraw 或 Obsidian .excalidraw.md 文件为新画板",
        "inputSchema": {
            "type": "object",
            "properties": {
                "path": {"type": "string", "description": "文件绝对路径（支持 ~）"},
                "name": {"type": "string", "description": "画板名（默认取文件名）"},
            },
            "required": ["path"],
        },
    },
]


def call_tool(name: str, arguments: dict) -> str:
    if name == "drawpad_status":
        return json.dumps(api("GET", "/api/health"), ensure_ascii=False)
    if name == "drawpad_list_boards":
        return json.dumps(api("GET", "/api/boards"), ensure_ascii=False)
    if name == "drawpad_create_board":
        return json.dumps(api("POST", "/api/boards", {"name": arguments["name"]}), ensure_ascii=False)
    if name == "drawpad_get_scene":
        return api("GET", f'/api/boards/{arguments["board"]}/scene')["elements"]
    if name == "drawpad_set_scene":
        return json.dumps(
            api("PUT", f'/api/boards/{arguments["board"]}/scene',
                {"elements": json.loads(arguments["elements"])}), ensure_ascii=False)
    if name == "drawpad_add_elements":
        return json.dumps(
            api("POST", f'/api/boards/{arguments["board"]}/elements',
                {"elements": json.loads(arguments["elements"])}), ensure_ascii=False)
    if name == "drawpad_delete_elements":
        ids = [s.strip() for s in arguments["ids"].split(",") if s.strip()]
        return json.dumps(
            api("DELETE", f'/api/boards/{arguments["board"]}/elements', {"ids": ids}),
            ensure_ascii=False)
    if name == "drawpad_import_file":
        body = {"path": arguments["path"]}
        if "name" in arguments:
            body["name"] = arguments["name"]
        return json.dumps(api("POST", "/api/import", body), ensure_ascii=False)
    raise ValueError(f"未知工具: {name}")


def send(message: dict):
    sys.stdout.write(json.dumps(message, ensure_ascii=False) + "\n")
    sys.stdout.flush()


def main():
    for line in sys.stdin:
        line = line.strip()
        if not line:
            continue
        try:
            message = json.loads(line)
        except json.JSONDecodeError:
            continue
        method = message.get("method", "")
        msg_id = message.get("id")

        if method == "initialize":
            send({"jsonrpc": "2.0", "id": msg_id, "result": {
                "protocolVersion": "2024-11-05",
                "capabilities": {"tools": {}},
                "serverInfo": {"name": "drawpad", "version": "1.0.0"},
            }})
        elif method == "notifications/initialized":
            pass
        elif method == "tools/list":
            send({"jsonrpc": "2.0", "id": msg_id, "result": {"tools": TOOLS}})
        elif method == "tools/call":
            try:
                result = call_tool(message["params"]["name"], message["params"].get("arguments", {}))
                send({"jsonrpc": "2.0", "id": msg_id, "result": {
                    "content": [{"type": "text", "text": result}]}})
            except Exception as error:  # noqa: BLE001
                send({"jsonrpc": "2.0", "id": msg_id, "result": {
                    "content": [{"type": "text", "text": f"错误: {error}"}],
                    "isError": True}})
        elif msg_id is not None:
            send({"jsonrpc": "2.0", "id": msg_id,
                  "error": {"code": -32601, "message": f"未知方法: {method}"}})


if __name__ == "__main__":
    if not os.path.exists(DISCOVERY):
        sys.stderr.write(f"未找到 {DISCOVERY} —— 请先启动 DrawPad Mac app\n")
        sys.exit(1)
    main()
